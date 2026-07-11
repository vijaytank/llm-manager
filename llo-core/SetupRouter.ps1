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
    cache_type_k = "f16"
    cache_type_v = "f16"
    flash_attn = "auto"
    context_shift = $true
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
}


# Ensure directories exist
if (-not (Test-Path $ModelsDir)) {
    New-Item -ItemType Directory -Force -Path $ModelsDir | Out-Null
}
if (-not (Test-Path $TemplatesDir)) {
    New-Item -ItemType Directory -Force -Path $TemplatesDir | Out-Null
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
$presetLines.Add("")

if ($modelEntries.Count -gt 0) {
    Write-Host "Found $($modelEntries.Count) local GGUF model(s):" -ForegroundColor Cyan
    foreach ($m in $modelEntries) {
        Write-Host "  - $($m.Alias) ($([math]::Round($m.SizeMB/1024, 2)) GB)"
        
        $presetLines.Add("[$($m.Alias)]")
        $presetLines.Add("model = $($m.Path -replace '\\','/')")
        $presetLines.Add("ctx-size = $($config.default_context_size)")
        if ($m.TemplateFile) {
            $presetLines.Add("chat-template-file = $($m.TemplateFile -replace '\\','/')")
            Write-Host "    -> Custom template mapped: $($m.TemplateFile)" -ForegroundColor DarkGray
        } else {
            # Assign standard built-in templates to prevent errors in third-party API clients
            $builtInTemplate = $null
            if ($m.Alias -match "qwen") { $builtInTemplate = "chatml" }
            elseif ($m.Alias -match "llama-3" -or $m.Alias -match "llama3" -or $m.Alias -match "llama4") { $builtInTemplate = "llama3" }
            elseif ($m.Alias -match "gemma") { $builtInTemplate = "gemma" }
            elseif ($m.Alias -match "deepseek") { $builtInTemplate = "deepseek" }
            elseif ($m.Alias -match "mistral" -or $m.Alias -match "mixtral") { $builtInTemplate = "mistral-v3" }
            
            if ($builtInTemplate) {
                $presetLines.Add("chat-template = $builtInTemplate")
                Write-Host "    -> Auto-assigned built-in template: $builtInTemplate" -ForegroundColor DarkCyan
            }
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
