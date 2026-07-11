# LLO Preset Config Router Setup
# Scans models directory, estimates memory constraints, associates custom chat templates, and writes models-preset.ini.

param(
    [string]$ModelsDir = "",
    [string]$TemplatesDir = "",
    [string]$PresetFile = "",
    [string]$ConfigFile = ""
)

$ErrorActionPreference = "Stop"

$ManagerDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
if ([string]::IsNullOrWhiteSpace($ConfigFile)) {
    $ConfigFile = Join-Path $ManagerDir "llo-config.json"
}
if ([string]::IsNullOrWhiteSpace($PresetFile)) {
    $PresetFile = Join-Path $ManagerDir "models-preset.ini"
}
if ([string]::IsNullOrWhiteSpace($ModelsDir)) {
    $ModelsDir = [System.IO.Path]::GetFullPath((Join-Path $ManagerDir "..\models"))
}
if ([string]::IsNullOrWhiteSpace($TemplatesDir)) {
    $TemplatesDir = [System.IO.Path]::GetFullPath((Join-Path $ManagerDir "..\templates"))
}

# Load Hardware Profiler
$profileScript = Join-Path $PSScriptRoot "Profile.ps1"
if (-not (Test-Path $profileScript)) {
    throw "Profile.ps1 script not found at: $profileScript"
}
. $profileScript
$hardware = Get-SystemHardwareProfile

# 1. Load existing config or initialize defaults
$config = @{
    fallback_provider = "none" # "none", "ollama", "openai", "anthropic", "nim"
    fallback_api_key = ""
    fallback_endpoint = ""
    fallback_model = ""
    default_context_size = 131072
    vram_margin_mb = 1024
    idle_timeout_sec = 60
    enable_tools = $true
    installation_type = "none" # "winget", "github", "other"
    llama_server_path = ""
    llama_repo_path = ""
    models_dir = ""
    templates_dir = ""
    use_default_template = $false
    cache_type_k = "f16"
    cache_type_v = "f16"
    flash_attn = "auto"
    context_shift = $true
    # New optimization params (auto-tuned by main.ps1 or set here as safe defaults)
    fit_ctx_min = 8192          # min ctx --fit is allowed to reduce to (tokens)
    cache_reuse_chunk = 256     # prefix KV cache reuse threshold (tokens, 0=disabled)
    ubatch_size = 512           # physical GPU kernel batch size (tokens)
    parallel_slots = 1          # concurrent request slots (-1 = auto)
    cache_idle_slots = $true    # save idle slot KV state between requests
    spec_type = "none"          # speculative decoding: none | ngram-simple | ...
    custom_args = ""
    integrations = @()
}

if (Test-Path $ConfigFile) {
    try {
        $loaded = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        foreach ($k in $loaded.PSObject.Properties.Name) {
            $config[$k] = $loaded.$k
        }
    } catch {
        Write-Host "Warning: Failed to parse llo-config.json. Using defaults." -ForegroundColor Yellow
    }
} else {
    $config | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigFile -Encoding UTF8
    Write-Host "Initialized configuration file at $ConfigFile" -ForegroundColor Cyan
}

if ($config.models_dir) {
    $ModelsDir = $config.models_dir
}
if ($config.templates_dir) {
    $TemplatesDir = $config.templates_dir
} else {
    # Default: sibling 'templates' folder next to llm-manager root (not relative to ModelsDir)
    $TemplatesDir = Join-Path $ManagerDir "templates"
}

# Ensure directories exist
if ($ModelsDir -and -not (Test-Path $ModelsDir)) {
    New-Item -ItemType Directory -Force -Path $ModelsDir | Out-Null
}
if ($TemplatesDir -and -not (Test-Path $TemplatesDir)) {
    New-Item -ItemType Directory -Force -Path $TemplatesDir | Out-Null
}

# Copy default.jinja from llm-manager package to active templates folder if missing
$defaultDest = Join-Path $TemplatesDir "default.jinja"
$packagedSource = Join-Path (Split-Path $PSScriptRoot) "templates\default.jinja"
if (-not (Test-Path $defaultDest) -and (Test-Path $packagedSource)) {
    try {
        Copy-Item -Path $packagedSource -Destination $defaultDest -Force | Out-Null
        Write-Host "Copied default chat template from package to: $defaultDest" -ForegroundColor Green
    } catch {
        Write-Host "[WARNING] Failed to copy default template: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# 2. Scan for GGUF files
$ggufs = Get-ChildItem -Path $ModelsDir -Recurse -File -Filter *.gguf | Sort-Object FullName
$modelEntries = New-Object System.Collections.Generic.List[object]

function Normalize-ModelAlias {
    param([string]$Filename)
    $a = $Filename.ToLowerInvariant()
    $a = $a -replace '\.gguf$', ''
    $a = $a -replace '[^a-z0-9]+', '-'
    $a = $a.Trim('-')
    if ([string]::IsNullOrWhiteSpace($a)) { $a = "model" }
    return $a
}

function Find-MatchingTemplate {
    param([string]$Alias)
    if (-not (Test-Path $TemplatesDir)) { return $null }
    $files = Get-ChildItem -Path $TemplatesDir -Filter *.jinja
    foreach ($f in $files) {
        $templateBase = $f.BaseName.ToLowerInvariant() -replace '[^a-z0-9]+', '-'
        if ($Alias -match $templateBase -or $templateBase -match $Alias) {
            return $f.FullName
        }
    }
    return $null
}

$usedAliases = @{}

foreach ($gguf in $ggufs) {
    # Generate clean alias
    $baseName = $gguf.BaseName
    $rawAlias = Normalize-ModelAlias -Filename $baseName
    
    # Resolve collisions
    $alias = $rawAlias
    $i = 2
    while ($usedAliases.ContainsKey($alias)) {
        $alias = "$rawAlias-$i"
        $i++
    }
    $usedAliases[$alias] = $true

    # Find custom template override
    $templatePath = Find-MatchingTemplate -Alias $alias

    # Sizing checks
    $fileSizeMB = [math]::Round($gguf.Length / 1MB, 0)
    
    # Check if GPU is present and model size exceeds safe VRAM budget
    if ($hardware.GPU -and $hardware.GPU.BudgetVramMB -gt 0 -and $fileSizeMB -gt $hardware.GPU.BudgetVramMB) {
        Write-Host "[WARNING] Model '$alias' ($([math]::Round($fileSizeMB/1024, 2)) GB) is larger than the safe VRAM budget ($([math]::Round($hardware.GPU.BudgetVramMB/1024, 2)) GB). Spilling to system RAM may occur!" -ForegroundColor Yellow
    }
    
    $modelEntries.Add([pscustomobject]@{
        Alias        = $alias
        Path         = $gguf.FullName
        SizeMB       = $fileSizeMB
        TemplateFile = $templatePath
    })
}

# 3. Write Preset file
$presetLines = New-Object System.Collections.Generic.List[string]

# Global Default Presets
$presetLines.Add("[*]")
$presetLines.Add("mmap = 1")
# Offload to GPU by default; llama.cpp's --fit will throttle layers down if it exceeds GPU memory
$presetLines.Add("n-gpu-layers = -1")
$presetLines.Add("threads = $($hardware.CPU.OptimalThreads)")
$presetLines.Add("sleep-idle-seconds = $($config.idle_timeout_sec)")
if ($config.enable_tools) {
    $presetLines.Add("tools = all")
}
# Built-in fit features
$presetLines.Add("fit = on")
$presetLines.Add("fit-target = $($config.vram_margin_mb)")
# Minimum context size --fit is permitted to reduce to (prevents silent truncation)
if ($config.fit_ctx_min -gt 0) {
    $presetLines.Add("fit-ctx = $($config.fit_ctx_min)")
}

# Optimized KV Cache, Flash Attention, and Context Shift
if ($config.flash_attn) {
    $presetLines.Add("flash-attn = $($config.flash_attn)")
}
if ($config.cache_type_k) {
    $presetLines.Add("cache-type-k = $($config.cache_type_k)")
}
if ($config.cache_type_v) {
    $presetLines.Add("cache-type-v = $($config.cache_type_v)")
}
if ($null -ne $config.context_shift) {
    if ($config.context_shift) {
        $presetLines.Add("context-shift = 1")
    } else {
        $presetLines.Add("no-context-shift = 1")
    }
}

# Physical batch size per GPU kernel call (tuned by hardware profiler)
if ($config.ubatch_size -and $config.ubatch_size -gt 0) {
    $presetLines.Add("ubatch-size = $($config.ubatch_size)")
}

# KV Cache prefix reuse: speeds up repeat-prefix requests (Claude Code, Cursor system prompts)
if ($null -ne $config.cache_reuse_chunk -and $config.cache_reuse_chunk -gt 0) {
    $presetLines.Add("cache-reuse = $($config.cache_reuse_chunk)")
}

# Idle slot KV caching: saves and restores slot state between bursty requests
if ($null -ne $config.cache_idle_slots) {
    if ($config.cache_idle_slots) {
        $presetLines.Add("cache-idle-slots = 1")
    } else {
        $presetLines.Add("no-cache-idle-slots = 1")
    }
}

# Concurrent request slots: capped at 1 for safety on VRAM-constrained GPUs
if ($null -ne $config.parallel_slots -and $config.parallel_slots -ne 0) {
    $presetLines.Add("parallel = $($config.parallel_slots)")
}

# Speculative decoding: ngram-simple gives ~10-15% throughput boost, no draft model needed
if ($config.spec_type -and $config.spec_type -ne "none") {
    $presetLines.Add("spec-type = $($config.spec_type)")
}
$presetLines.Add("")

if ($modelEntries.Count -gt 0) {
    Write-Host "Found $($modelEntries.Count) local GGUF model(s):" -ForegroundColor Cyan

    foreach ($m in $modelEntries) {
        Write-Host "  - $($m.Alias) ($([math]::Round($m.SizeMB/1024, 2)) GB)"
        
        $presetLines.Add("[$($m.Alias)]")
        $presetLines.Add("model = $($m.Path -replace '\\','/')")
        $presetLines.Add("ctx-size = $($config.default_context_size)")
        
        $defaultTemplatePath = Join-Path $TemplatesDir "default.jinja"
        if ($m.TemplateFile) {
            $presetLines.Add("chat-template-file = $($m.TemplateFile -replace '\\','/')")
            Write-Host "    -> Custom template mapped: $($m.TemplateFile)" -ForegroundColor DarkGray
        } elseif ($config.use_default_template -and (Test-Path $defaultTemplatePath)) {
            $presetLines.Add("chat-template-file = $($defaultTemplatePath -replace '\\','/')")
            Write-Host "    -> Default template mapped: $defaultTemplatePath" -ForegroundColor DarkGray
        } else {
            Write-Host "    -> No template parameter written (using GGUF internal template)" -ForegroundColor DarkCyan
        }
        $presetLines.Add("")
    }
} else {
    Write-Host "No local GGUF models found in $ModelsDir." -ForegroundColor Yellow
    Write-Host "Server preset configured to fallback/bootstrap." -ForegroundColor Cyan
}

# Write preset.ini
Set-Content -Path $PresetFile -Value $presetLines -Encoding ASCII
Write-Host "Preset configuration written: $PresetFile" -ForegroundColor Green

# Output the list of local models to other scripts
return $modelEntries.ToArray()
