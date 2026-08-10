# LLO Preset Config Router Setup v2
# Hardware-adaptive inference parameter derivation + models-preset.ini generation.
#
# All inference parameters (n-gpu-layers, flash-attn, ubatch-size, cache types,
# context size, etc.) are derived from the live hardware profile produced by Profile.ps1.
# No values are hardcoded in the global preset block.
#
# Override policy:
#   1. Hardware-derived value   (automatic, based on GPU tier + RAM)
#   2. config.overrides key     (explicit user intent, always wins)
#
# Old flat config keys (ubatch_size, cache_type_k, etc.) that pre-date this version
# are intentionally ignored for hardware-adaptive params to prevent stale wizard
# values from defeating auto-tuning. Non-hardware keys (models_dir, idle_timeout_sec,
# fallback_provider, etc.) continue to be read from the flat config as before.

param(
    [string]$ModelsDir    = "",
    [string]$TemplatesDir = "",
    [string]$GrammarsDir  = "",
    [string]$PresetFile   = "",
    [string]$ConfigFile   = ""
)

$ErrorActionPreference = "Stop"

$ManagerDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
if ([string]::IsNullOrWhiteSpace($ConfigFile)) {
    $appDataConfig = if ($env:APPDATA) {
        Join-Path $env:APPDATA "LLM Manager\llo-config.json"
    } elseif ($env:USERPROFILE) {
        Join-Path $env:USERPROFILE ".config\LLM Manager\llo-config.json"
    } elseif ($env:HOME) {
        Join-Path $env:HOME ".config/LLM Manager/llo-config.json"
    } else { $null }

    if ($appDataConfig -and (Test-Path $appDataConfig)) {
        $ConfigFile = $appDataConfig
    } else {
        $ConfigFile = Join-Path $ManagerDir "llo-config.json"
    }
}
$ConfigFile = [System.IO.Path]::GetFullPath($ConfigFile)

if ([string]::IsNullOrWhiteSpace($PresetFile))   { $PresetFile   = Join-Path (Split-Path -Parent $ConfigFile) "models-preset.ini" }
$PresetFile = [System.IO.Path]::GetFullPath($PresetFile)

if ([string]::IsNullOrWhiteSpace($ModelsDir))    { $ModelsDir    = [System.IO.Path]::GetFullPath((Join-Path $ManagerDir "..\models")) }
if ([string]::IsNullOrWhiteSpace($TemplatesDir)) { $TemplatesDir = [System.IO.Path]::GetFullPath((Join-Path $ManagerDir "..\templates")) }
if ([string]::IsNullOrWhiteSpace($GrammarsDir))  { $GrammarsDir  = [System.IO.Path]::GetFullPath((Join-Path $ManagerDir "..\grammars")) }

# ── Load Hardware Profiler ─────────────────────────────────────────────────────
$profileScript = Join-Path $PSScriptRoot "Profile.ps1"
if (-not (Test-Path $profileScript)) { throw "Profile.ps1 not found at: $profileScript" }
. $profileScript
$hardware = Get-SystemHardwareProfile

# ── Load Config ───────────────────────────────────────────────────────────────
$config = @{
    # Non-hardware operational settings
    fallback_provider    = "none"
    fallback_api_key     = ""
    fallback_endpoint    = ""
    fallback_model       = ""
    idle_timeout_sec     = 60
    enable_tools         = $true
    installation_type    = "none"
    llama_server_path    = ""
    llama_repo_path      = ""
    models_dir           = ""
    templates_dir        = ""
    use_default_template = $false
    cache_idle_slots     = $true
    parallel_slots       = -1
    threads             = 0
    numa                = ""
    cache_ram           = 0
    temperature         = ""
    top_k               = ""
    top_p               = ""
    samplers            = ""
    dynatemp_range      = ""
    dynatemp_exp        = ""
    mmproj_auto         = $null
    mmproj_path         = ""
    mmproj_no_offload    = $false
    custom_args          = ""
    integrations         = @()

    # Context Manager Proxy operational settings
    context_manager      = @{
        enabled              = $false
        warn_threshold       = 0.70
        keep_turns           = 6
        proxy_port           = 8090
        ctx_limit            = 0
        tokenizer_repo       = ""
        summary_max_tokens   = 768
        summarize_with_model = "same"
    }

    # Explicit user overrides (hardware-adaptive params only; these always win)
    # Example: "overrides": { "ubatch_size": 512, "ctx_size": 8192, "parallel": 1 }
    overrides            = @{}
}

$loadedKeys = @()
if (Test-Path $ConfigFile) {
    try {
        $loaded = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        $loadedKeys = @($loaded.PSObject.Properties.Name)
        foreach ($k in $loadedKeys) {
            $config[$k] = $loaded.$k
        }
    } catch {
        Write-Host "Warning: Failed to parse llo-config.json. Using defaults." -ForegroundColor Yellow
    }
} else {
    $config | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigFile -Encoding UTF8
    Write-Host "Initialized configuration file at $ConfigFile" -ForegroundColor Cyan
}

# normalize overrides to a plain hashtable (json deserializes to pscustomobject)
if ($config.overrides -is [system.management.automation.pscustomobject]) {
    $ovr = @{}
    foreach ($prop in $config.overrides.psobject.properties) {
        $ovr[$prop.Name] = $config.overrides.$($prop.Name)
    }
    $config.overrides = $ovr
} elseif (-not ($config.overrides -is [hashtable])) {
    $config.overrides = @{}
}

function Map-LegacyConfigKeyToOverride {
    param(
        [string]$LegacyKey,
        [string]$OverrideKey
    )
    if ($config.ContainsKey($LegacyKey) -and -not $config.overrides.ContainsKey($OverrideKey) -and $loadedKeys -contains $LegacyKey) {
        $value = $config[$LegacyKey]
        if ($null -ne $value -and $value -ne "") {
            $config.overrides[$OverrideKey] = $value
            Write-Host "  [legacy] '$LegacyKey' mapped to config.overrides.$OverrideKey" -ForegroundColor Yellow
        }
    }
}

# Explicit config.overrides remain active. Flat top-level keys are maintained as baseline configuration
# and do not override hardware-adaptive tier settings unless placed in config.overrides.

# Enforce operational limits for Claude Code
if ($config.integrations -contains "claude-code" -and $config.idle_timeout_sec -lt 600) {
    $config.idle_timeout_sec = 600
    Write-Host "    [Claude Code] Idle timeout upgraded to 600 seconds (10m) to prevent mid-task sleeps." -ForegroundColor Cyan
}

if ($config.models_dir)    { $ModelsDir    = $config.models_dir }
if ($config.templates_dir) { $TemplatesDir = $config.templates_dir }
else                       { $TemplatesDir = Join-Path $ManagerDir "templates" }

if ($config.grammars_dir)  { $GrammarsDir  = $config.grammars_dir }
else                       { $GrammarsDir  = Join-Path $ManagerDir "grammars" }

# Ensure directories exist
if ($ModelsDir    -and -not (Test-Path $ModelsDir))    { New-Item -ItemType Directory -Force -Path $ModelsDir    | Out-Null }
if ($TemplatesDir -and -not (Test-Path $TemplatesDir)) { New-Item -ItemType Directory -Force -Path $TemplatesDir | Out-Null }
if ($GrammarsDir  -and -not (Test-Path $GrammarsDir))  { New-Item -ItemType Directory -Force -Path $GrammarsDir  | Out-Null }


# ═══════════════════════════════════════════════════════════════════════════════
# HARDWARE-ADAPTIVE PARAMETER DERIVATION
# ═══════════════════════════════════════════════════════════════════════════════

function Get-InferenceParams {
    <#
    .SYNOPSIS
        Derives all inference parameters from the hardware profile.
        Applies explicit config.overrides as the final step.
    .OUTPUTS
        Hashtable of all tunable inference params.
    #>
    param(
        [pscustomobject]$Hardware,
        [hashtable]$Overrides
    )

    $tier   = $Hardware.GPU.PerformanceTier
    $ramMB  = $Hardware.RAM.BudgetMB
    $vramMB = $Hardware.GPU.BudgetVramMB

    # ── Base parameter table per tier ─────────────────────────────────────────
    $params = switch ($tier) {

        "cpu" {
            # No GPU offload. Optimise for CPU throughput and RAM efficiency.
            # flash-attn:  CPU does not support Flash Attention.
            # fit:         VRAM fitting is meaningless without a GPU budget.
            # cache-reuse: Disabled; not supported by all architectures on CPU path.
            # spec-type:   ngram-simple is validated per-model before writing.
            @{
                n_gpu_layers  = 0
                flash_attn    = "off"
                use_fit       = $false
                fit_target    = 0
                fit_ctx_min   = 0
                cache_type_k  = "f16"      # f16 is required when flash_attn is off
                cache_type_v  = "f16"
                ubatch_size   = 128        # small physical batches suit CPU throughput
                parallel      = 1
                spec_type     = "ngram-simple"   # validated per-model before emitting
                context_shift = $true
                cache_reuse   = 0
                mmap          = 1
            }
        }

        "low" {
            # 2–4 GB dedicated GPU. Attempt full offload; fit-throttle handles overflow.
            # q8_0 KV cache: safer quality trade-off than q4_0 at small context sizes.
            # spec-type: omitted — low VRAM risk of OOM during speculative steps.
            @{
                n_gpu_layers  = -1
                flash_attn    = "on"
                use_fit       = $true
                fit_target    = 512        # tighter margin for small VRAM budget
                fit_ctx_min   = 4096
                cache_type_k  = "q8_0"
                cache_type_v  = "q8_0"
                ubatch_size   = 256
                parallel      = 1
                spec_type     = "none"     # risky at low VRAM — skip
                context_shift = $true
                cache_reuse   = 256
                mmap          = 1
            }
        }

        "mid" {
            # 4–8 GB dedicated GPU. Full offload is achievable for most small/mid models.
            # parallel: upgraded to 2 conditionally (checked below).
            @{
                n_gpu_layers  = -1
                flash_attn    = "on"
                use_fit       = $true
                fit_target    = 1024
                fit_ctx_min   = 8192
                cache_type_k  = "q8_0"
                cache_type_v  = "q8_0"
                ubatch_size   = 512
                parallel      = 1
                spec_type     = "ngram-simple"
                context_shift = $true
                cache_reuse   = 256
                mmap          = 1
            }
        }

        "high" {
            # > 8 GB dedicated GPU. Comfortable for large models and context.
            # cache-type: f16 for VRAM > 12 GB (quality wins); q8_0 otherwise.
            # parallel: upgraded to 2 conditionally (checked below).
            @{
                n_gpu_layers  = -1
                flash_attn    = "on"
                use_fit       = $true
                fit_target    = 1024
                fit_ctx_min   = 8192
                cache_type_k  = if ($vramMB -gt 12288) { "f16" } else { "q8_0" }
                cache_type_v  = if ($vramMB -gt 12288) { "f16" } else { "q8_0" }
                ubatch_size   = 1024
                parallel      = 1
                spec_type     = "ngram-simple"
                context_shift = $true
                cache_reuse   = 256
                mmap          = 1
            }
        }

        default {
            # Safe fallback: CPU-only defaults
            @{
                n_gpu_layers  = 0
                flash_attn    = "off"
                use_fit       = $false
                fit_target    = 0
                fit_ctx_min   = 0
                cache_type_k  = "f16"
                cache_type_v  = "f16"
                ubatch_size   = 128
                parallel      = 1
                spec_type     = "ngram-simple"
                context_shift = $true
                cache_reuse   = 0
                mmap          = 1
            }
        }
    }

    # ── Conditional parallel = 2 upgrade (mid / high only) ───────────────────
    # Concurrency multiplies KV-cache pressure. Only upgrade when both VRAM and
    # RAM have headroom to safely absorb a second concurrent slot.
    if ($tier -in @("mid", "high") -and $ramMB -gt 16384 -and $vramMB -gt 4096) {
        $params.parallel = 2
    }

    # ── Apply explicit user overrides ─────────────────────────────────────────
    # Keys present in config.overrides always take final priority.
    foreach ($key in $Overrides.Keys) {
        if ($params.ContainsKey($key)) {
            Write-Host "  [override] $key = $($Overrides[$key])  (from config.overrides)" -ForegroundColor DarkYellow
            $params[$key] = $Overrides[$key]
        }
    }

    # Support legacy and top-level config key mappings for user settings
    if (-not $Overrides.ContainsKey("parallel") -and $config.ContainsKey("parallel_slots") -and [int]$config.parallel_slots -gt 0) {
        $params.parallel = [int]$config.parallel_slots
        Write-Host "  [config] parallel = $($params.parallel)  (from config.parallel_slots)" -ForegroundColor DarkYellow
    }

    # Claude Code integration requires at least 2 parallel slots to avoid subagent deadlocks.
    if ($config.integrations -contains "claude-code") {
        if ($params.parallel -lt 2) {
            $params.parallel = 2
            Write-Host "    [Claude Code] Enforced parallel = 2 floor to prevent subagent deadlock." -ForegroundColor Cyan
        }
    }

    # ── Safeguard validations ──────────────────────────────────────────────────
    # Low-VRAM Speculative Decoding Safeguard (Issue 2.1)
    if ($tier -eq "low" -and $params.spec_type -ne "none") {
        Write-Host "  [!] Low VRAM tier ('low') detected. Enforcing spec_type = 'none' to prevent out-of-memory errors." -ForegroundColor Yellow
        $params.spec_type = "none"
    }

    # ── Post-override validation ──────────────────────────────────────────────
    # Quantized KV cache (specifically V cache quantization) requires flash_attn
    # to be enabled. Force both to f16 if flash_attn is disabled to prevent crash.
    if ($params.flash_attn -eq "off") {
        if ($params.cache_type_k -ne "f16") {
            Write-Host "  [notice] flash-attn is off; forcing cache-type-k to f16 (required by llama.cpp)" -ForegroundColor Yellow
            $params.cache_type_k = "f16"
        }
        if ($params.cache_type_v -ne "f16") {
            Write-Host "  [notice] flash-attn is off; forcing cache-type-v to f16 (required by llama.cpp)" -ForegroundColor Yellow
            $params.cache_type_v = "f16"
        }
    }

    return $params
}

function Get-SafeContextSize {
    <#
    .SYNOPSIS
        Computes a safe context ceiling for a specific model on the current hardware.
        Always a ceiling target — starts high and clamps down. Never a floor.
    .PARAMETER ModelBytes    GGUF file size in bytes
    .PARAMETER RamMB         Safe RAM budget (after OS reservation)
    .PARAMETER VramMB        Safe VRAM budget (0 = CPU-only path)
    .PARAMETER GpuTier       cpu | low | mid | high
    .PARAMETER Parallel      Concurrent slot count (multiplies KV cache pressure)
    .PARAMETER CacheTypeK    KV-K cache quant type (f16 | q8_0 | q4_0)
    #>
    param(
        [long]  $ModelBytes,
        [int]   $RamMB,
        [int]   $VramMB,
        [string]$GpuTier,
        [int]   $Parallel,
        [string]$CacheTypeK,
        [string[]]$Integrations = @()
    )

    $modelMB  = [math]::Round($ModelBytes / 1MB, 0)
    $parallel = [math]::Max($Parallel, 1)

    # Dynamic KV cache estimation based on model size (parameters/layers scale with weight).
    # ~12.0 MB per GB of model size is a conservative baseline for q8_0 KV Cache.
    $modelGB = $modelMB / 1024.0
    $baseKV = 12.0 * $modelGB
    
    # Mathematically exact element byte calculator matching ui/src/lib/validation.ts
    $getBytesPerElem = {
        param([string]$Type)
        switch ($Type) {
            "q4_0"  { 0.5625 }
            "q8_0"  { 1.0625 }
            "f16"   { 2.0 }
            "bf16"  { 2.0 }
            default { 1.0625 }
        }
    }
    $elemBytesK = & $getBytesPerElem $CacheTypeK
    # Assume symmetric K/V cache quant unless specified
    $kvRatio = ($elemBytesK * 2.0) / 2.125  # 2.125 = q8_0 (1.0625) + q8_0 (1.0625) baseline
    $kvMBPerKToken = $baseKV * $kvRatio
    
    # Floor the estimate at a minimum of 5.0 MB per 1000 tokens for safety
    $kvMBPerKToken = [math]::Max($kvMBPerKToken, 5.0)
    $kvMBPerKToken *= $parallel

    # RAM ceiling: subtract model weights + 512 MB runtime headroom, then divide by KV rate
    $availRam      = $RamMB - $modelMB - 512
    $maxCtxFromRam = if ($availRam -gt 0) {
        [int]([math]::Floor($availRam / $kvMBPerKToken) * 1000)
    } else { 4096 }

    # The physical allocation ceiling is bounded by system RAM. 
    # Because llama-server supports CPU offloading and mmap, VRAM tightness does not cause loading crashes;
    # it only causes partial layer/cache offloading. Thus, RAM is the binding constraint for allocation.
    $rawCtx = $maxCtxFromRam

    # Snap down to the nearest standard llama.cpp context value (O(1) bitwise calculation)
    if ($rawCtx -le 0) { $chosen = 4096 } else {
        # Calculate the largest power of two less than or equal to rawCtx
        $exponent = [math]::Floor([math]::Log($rawCtx) / [math]::Log(2))
        $chosen = [math]::Pow(2, $exponent)
    }

    # Upper bounds by tier to avoid aggressive context sizes on mid/low VRAM.
    $tierMaxCtx = switch ($GpuTier) {
        "cpu"  { 16384 }
        "low"  { 32768 }
        "mid"  { 65536 }
        "high" { 131072 }
        default { 65536 }
    }
    $chosen = [math]::Min($chosen, $tierMaxCtx)

    # Integration-aware context floor:
    # Claude Code needs a large context (> 24k) to launch its initial prompts.
    $hasClaude = $Integrations -contains "claude-code"
    $minFloor = if ($GpuTier -eq "cpu") {
        if ($hasClaude) { 32768 } else { 4096 }
    } else {
        if ($hasClaude) { 65536 } else { 8192 }
    }

    return [math]::Max($chosen, $minFloor)
}

function Get-ValidatedSpecType {
    <#
    .SYNOPSIS
        Validates whether spec-type is safe for a given model alias.
        Skips ngram-simple for known-incompatible architectures (MoE, multimodal).
    #>
    param([string]$SpecType, [string]$ModelAlias)

    if ($SpecType -eq "none" -or [string]::IsNullOrEmpty($SpecType)) { return "none" }

    # Patterns where ngram-simple is known to fail or degrade quality
    $incompatible = @("moe", "mixture", "vision", "llava", "clip", "phi-3-v", "qwen.*vl", "minicpm-v", "cogvlm")
    foreach ($pattern in $incompatible) {
        if ($ModelAlias -match $pattern) {
            Write-Host "    [!] spec-type=$SpecType skipped for '$ModelAlias' (incompatible: '$pattern')" -ForegroundColor DarkYellow
            return "none"
        }
    }
    return $SpecType
}

# ── Derive all parameters from hardware ───────────────────────────────────────
$inferParams = Get-InferenceParams -Hardware $hardware -Overrides $config.overrides

function Add-OptionalPresetEntry {
    param(
        [string]$Name,
        $Value
    )

    if ($null -eq $Value) { return }
    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) { return }
    $presetLines.Add("$Name = $Value")
}

# ═══════════════════════════════════════════════════════════════════════════════
# HARDWARE SUMMARY (printed before model scan so users can verify auto-tuning)
# ═══════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "  HARDWARE PROFILE" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "  CPU  : $($hardware.CPU.Name)" -ForegroundColor White
Write-Host "         $($hardware.CPU.PhysicalCores) cores → $($hardware.CPU.OptimalThreads) inference threads" -ForegroundColor DarkGray
Write-Host "  RAM  : $($hardware.RAM.TotalGB) GB total  |  $($hardware.RAM.BudgetMB) MB safe budget" -ForegroundColor White
Write-Host "  GPU  : $($hardware.GPU.Name)" -ForegroundColor White
Write-Host "         Adapter Class : $($hardware.GPU.AdapterClass)" -ForegroundColor DarkGray
if ($hardware.GPU.TotalVramMB -gt 0) {
    $vramFreeStr = if ($hardware.GPU.FreeVramMB -gt 0 -and $hardware.GPU.FreeVramMB -ne $hardware.GPU.TotalVramMB) {
        "$([math]::Round($hardware.GPU.FreeVramMB/1024,1)) GB free"
    } else { "n/a" }
    Write-Host "         VRAM          : $([math]::Round($hardware.GPU.TotalVramMB/1024,1)) GB total  |  $vramFreeStr" -ForegroundColor DarkGray
}
$cudaStr = if ($hardware.GPU.HasCudaBackend) { "AVAILABLE  (driver $($hardware.GPU.CudaDriver))" } else { "not available" }
Write-Host "         CUDA Backend  : $cudaStr" -ForegroundColor DarkGray
Write-Host "  ---" -ForegroundColor DarkGray
$tierColor = if ($hardware.GPU.PerformanceTier -eq "cpu") { "Yellow" } else { "Green" }
Write-Host "  GPU Tier    : $($hardware.GPU.PerformanceTier.ToUpper())" -ForegroundColor $tierColor
Write-Host "  Tier Reason : $($hardware.GPU.TierReason)" -ForegroundColor DarkGray
Write-Host "  ---" -ForegroundColor DarkGray
Write-Host "  Derived Inference Parameters:" -ForegroundColor Cyan
Write-Host "    n-gpu-layers : $($inferParams.n_gpu_layers)" -ForegroundColor White
Write-Host "    flash-attn   : $($inferParams.flash_attn)" -ForegroundColor White
$fitStr = if ($inferParams.use_fit) { "on  (fit-target=$($inferParams.fit_target) MB, fit-ctx-min=$($inferParams.fit_ctx_min))" } else { "off" }
Write-Host "    fit          : $fitStr" -ForegroundColor White
Write-Host "    cache-type   : $($inferParams.cache_type_k) / $($inferParams.cache_type_v)  (K / V)" -ForegroundColor White
Write-Host "    ubatch-size  : $($inferParams.ubatch_size)" -ForegroundColor White
Write-Host "    parallel     : $($inferParams.parallel)" -ForegroundColor White
Write-Host "    spec-type    : $($inferParams.spec_type)  (validated per-model)" -ForegroundColor White
Write-Host "    threads      : $($hardware.CPU.OptimalThreads)" -ForegroundColor White
$cmStr = if ($config.context_manager -and $config.context_manager.enabled) { "ENABLED (port $($config.context_manager.proxy_port), threshold $([int]($config.context_manager.warn_threshold * 100))%)" } else { "disabled" }
Write-Host "    context-mgr  : $cmStr" -ForegroundColor White
Write-Host "==========================================================" -ForegroundColor Green
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════════
# MODEL DISCOVERY
# ═══════════════════════════════════════════════════════════════════════════════
$ggufs        = Get-ChildItem -Path $ModelsDir -Recurse -File -Filter *.gguf | Sort-Object FullName
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
    if ($files.Count -eq 0) { return $null }

    $normalizedAlias = $Alias.ToLowerInvariant() -replace '[^a-z0-9]+', '-'

    # Priority 1: Exact base-name match (normalized)
    foreach ($f in $files) {
        if ($f.Name -eq "default.jinja") { continue }
        $templateBase = $f.BaseName.ToLowerInvariant() -replace '[^a-z0-9]+', '-'
        if ($templateBase -eq $normalizedAlias) { return $f.FullName }
    }

    # Priority 2: Substring token match scoring
    $bestMatch = $null
    $bestScore = 0
    $aliasTokens = $normalizedAlias -split '-' | Where-Object {
        $_.Length -gt 1 -and $_ -notmatch '^\d+$' -and $_ -ne 'gguf' -and $_ -ne 'q4' -and $_ -ne 'q5' -and $_ -ne 'q8' -and $_ -ne 'k' -and $_ -ne 'm' -and $_ -ne 's' -and $_ -ne 'l'
    }
    if ($aliasTokens.Count -gt 0) {
        foreach ($f in $files) {
            if ($f.Name -eq "default.jinja") { continue }
            $templateBase = $f.BaseName.ToLowerInvariant() -replace '[^a-z0-9]+', '-'
            $matchCount = 0
            foreach ($t in $aliasTokens) {
                if ($templateBase -match [regex]::Escape($t)) {
                    $matchCount++
                }
            }
            $score = $matchCount / $aliasTokens.Count
            if ($score -gt $bestScore -and $score -ge 0.4) {
                $bestScore = $score
                $bestMatch = $f.FullName
            }
        }
    }
    if ($bestMatch) { return $bestMatch }

    return $null
}

$usedAliases = @{}

foreach ($gguf in $ggufs) {
    $baseName = $gguf.BaseName
    $rawAlias = Normalize-ModelAlias -Filename $baseName

    # Resolve alias collisions
    $alias = $rawAlias
    $i = 2
    while ($usedAliases.ContainsKey($alias)) { $alias = "$rawAlias-$i"; $i++ }
    $usedAliases[$alias] = $true

    $templatePath = Find-MatchingTemplate -Alias $alias
    $fileSizeMB   = [math]::Round($gguf.Length / 1MB, 0)

    # Compute safe context ceiling for this model on this hardware
    $ctxSize = Get-SafeContextSize `
        -ModelBytes   $gguf.Length `
        -RamMB        $hardware.RAM.BudgetMB `
        -VramMB       $hardware.GPU.BudgetVramMB `
        -GpuTier      $hardware.GPU.PerformanceTier `
        -Parallel     $inferParams.parallel `
        -CacheTypeK   $inferParams.cache_type_k `
        -Integrations $config.integrations

    # User context size configuration or override takes priority
    if ($config.ContainsKey("default_context_size") -and $config.default_context_size -and [int]$config.default_context_size -gt 0) {
        $ctxSize = [int]$config.default_context_size
        Write-Host "    [config] ctx-size = $ctxSize  (from config.default_context_size)" -ForegroundColor Green
    } elseif ($config.overrides.ContainsKey("ctx_size")) {
        $ctxSize = [int]$config.overrides["ctx_size"]
        Write-Host "    [override] ctx-size = $ctxSize  (from config.overrides)" -ForegroundColor DarkYellow
    }

    # Warn if model exceeds VRAM budget (GPU tiers only; CPU tier uses RAM spill via mmap)
    if ($hardware.GPU.PerformanceTier -ne "cpu" -and
        $hardware.GPU.BudgetVramMB -gt 0 -and
        $fileSizeMB -gt $hardware.GPU.BudgetVramMB) {
        Write-Host "  [WARNING] '$alias' ($([math]::Round($fileSizeMB/1024,2)) GB) exceeds VRAM budget ($([math]::Round($hardware.GPU.BudgetVramMB/1024,2)) GB). Fit-throttle will reduce GPU layers." -ForegroundColor Yellow
    }

    $modelEntries.Add([pscustomobject]@{
        Alias        = $alias
        Path         = $gguf.FullName
        SizeMB       = $fileSizeMB
        TemplateFile = $templatePath
        CtxSize      = $ctxSize
    })
}

# ═══════════════════════════════════════════════════════════════════════════════
# WRITE PRESET FILE
# ═══════════════════════════════════════════════════════════════════════════════
$presetLines = New-Object System.Collections.Generic.List[string]

# ── [*] Global defaults (apply to all models unless overridden per-model) ──────
$presetLines.Add("[*]")
if ($config.ContainsKey('mmap') -and $config.mmap -ne $null -and $config.mmap -ne "") {
    if ($config.mmap -eq 0 -or $config.mmap -eq '0') {
        $presetLines.Add("no-mmap = 1")
    } else {
        $presetLines.Add("mmap = 1")
    }
} else {
    $presetLines.Add("mmap = $($inferParams.mmap)")
}

if ($config.ContainsKey('threads') -and $config.threads -ne $null -and $config.threads -ne 0 -and $config.threads -ne "") {
    $presetLines.Add("threads = $($config.threads)")
} else {
    $presetLines.Add("threads = $($hardware.CPU.OptimalThreads)")
}

$presetLines.Add("n-gpu-layers = $($inferParams.n_gpu_layers)")
$presetLines.Add("sleep-idle-seconds = $($config.idle_timeout_sec)")

if ($config.enable_tools) {
    $presetLines.Add("tools = all")
}

$presetLines.Add("flash-attn = $($inferParams.flash_attn)")

# fit is only meaningful with GPU offload active
if ($inferParams.use_fit) {
    $presetLines.Add("fit = on")
    $presetLines.Add("fit-target = $($inferParams.fit_target)")
    if ($inferParams.fit_ctx_min -gt 0) {
        $presetLines.Add("fit-ctx = $($inferParams.fit_ctx_min)")
    }
}

$presetLines.Add("cache-type-k = $($inferParams.cache_type_k)")
$presetLines.Add("cache-type-v = $($inferParams.cache_type_v)")

if ($inferParams.context_shift) {
    $presetLines.Add("context-shift = 1")
} else {
    $presetLines.Add("no-context-shift = 1")
}

$presetLines.Add("ubatch-size = $($inferParams.ubatch_size)")

# KV prefix cache reuse (disabled on CPU tier; not supported by all model architectures)
if ($inferParams.cache_reuse -gt 0) {
    $presetLines.Add("cache-reuse = $($inferParams.cache_reuse)")
}

if ($config.cache_idle_slots) {
    $presetLines.Add("cache-idle-slots = 1")
} else {
    $presetLines.Add("no-cache-idle-slots = 1")
}

$presetLines.Add("parallel = $($inferParams.parallel)")

# Optional advanced tuning flags
if ($config.ContainsKey('numa') -and $config.numa -and -not [string]::IsNullOrWhiteSpace($config.numa)) {
    $presetLines.Add("numa = $($config.numa)")
}
if ($config.ContainsKey('cache_ram') -and $config.cache_ram -ne $null -and $config.cache_ram -ne 0) {
    $presetLines.Add("cache-ram = $($config.cache_ram)")
}
if ($config.ContainsKey('temperature') -and $config.temperature -and -not [string]::IsNullOrWhiteSpace($config.temperature)) {
    $presetLines.Add("temperature = $($config.temperature)")
}
if ($config.ContainsKey('top_k') -and $config.top_k -and -not [string]::IsNullOrWhiteSpace($config.top_k)) {
    $presetLines.Add("top-k = $($config.top_k)")
}
if ($config.ContainsKey('top_p') -and $config.top_p -and -not [string]::IsNullOrWhiteSpace($config.top_p)) {
    $presetLines.Add("top-p = $($config.top_p)")
}
if ($config.ContainsKey('samplers') -and $config.samplers -and -not [string]::IsNullOrWhiteSpace($config.samplers)) {
    $presetLines.Add("samplers = $($config.samplers)")
}
if ($config.ContainsKey('dynatemp_range') -and $config.dynatemp_range -and -not [string]::IsNullOrWhiteSpace($config.dynatemp_range)) {
    $presetLines.Add("dynatemp-range = $($config.dynatemp_range)")
}
if ($config.ContainsKey('dynatemp_exp') -and $config.dynatemp_exp -and -not [string]::IsNullOrWhiteSpace($config.dynatemp_exp)) {
    $presetLines.Add("dynatemp-exp = $($config.dynatemp_exp)")
}
if ($config.ContainsKey('mmproj_path') -and $config.mmproj_path -and -not [string]::IsNullOrWhiteSpace($config.mmproj_path) -and $config.mmproj_path -ne "none") {
    $mmprojNorm = $config.mmproj_path -replace '\\','/'
    $presetLines.Add("mmproj = $mmprojNorm")
    if ($config.ContainsKey('mmproj_no_offload') -and $config.mmproj_no_offload) {
        $presetLines.Add("no-mmproj-offload = 1")
    }
} elseif ($config.ContainsKey('mmproj_auto') -and $null -ne $config.mmproj_auto) {
    if ($config.mmproj_auto) {
        $presetLines.Add("mmproj-auto = 1")
    } else {
        $presetLines.Add("no-mmproj-auto = 1")
    }
}

# Global spec-type default (may be overridden per-model by validation gate)
if ($inferParams.spec_type -and $inferParams.spec_type -ne "none") {
    $presetLines.Add("spec-type = $($inferParams.spec_type)")
}



$presetLines.Add("")

# ── Per-model sections ────────────────────────────────────────────────────────
if ($modelEntries.Count -gt 0) {
    Write-Host "Found $($modelEntries.Count) local GGUF model(s):" -ForegroundColor Cyan

    foreach ($m in $modelEntries) {
        Write-Host "  - $($m.Alias) ($([math]::Round($m.SizeMB/1024, 2)) GB)  →  ctx=$($m.CtxSize) tokens"

        # Validate spec-type for this specific model
        $modelSpecType = Get-ValidatedSpecType -SpecType $inferParams.spec_type -ModelAlias $m.Alias

        $presetLines.Add("[$($m.Alias)]")
        $presetLines.Add("model = $($m.Path -replace '\\','/')")
        $presetLines.Add("ctx-size = $($m.CtxSize)")

        if ($config.ContainsKey('mmproj_path') -and $config.mmproj_path -and -not [string]::IsNullOrWhiteSpace($config.mmproj_path) -and $config.mmproj_path -ne "none") {
            $presetLines.Add("mmproj = $($config.mmproj_path -replace '\\','/')")
            if ($config.ContainsKey('mmproj_no_offload') -and $config.mmproj_no_offload) {
                $presetLines.Add("no-mmproj-offload = 1")
            }
        }

        # Per-model spec-type override when validation result differs from global
        if ($modelSpecType -ne $inferParams.spec_type) {
            $presetLines.Add("spec-type = none")
        }

        # Chat template resolution
        $defaultTemplatePath = Join-Path $TemplatesDir "default.jinja"
        $resolvedActiveTemplate = $null
        if ($config.ContainsKey('active_template') -and $config.active_template -and -not [string]::IsNullOrWhiteSpace($config.active_template) -and $config.active_template -ne "auto") {
            if (Test-Path $config.active_template) {
                $resolvedActiveTemplate = $config.active_template
            } else {
                $cand = Join-Path $TemplatesDir $config.active_template
                if (Test-Path $cand) {
                    $resolvedActiveTemplate = $cand
                }
            }
        }

        if ($resolvedActiveTemplate) {
            $presetLines.Add("chat-template-file = $($resolvedActiveTemplate -replace '\\','/')")
            Write-Host "    -> Selected template: $resolvedActiveTemplate" -ForegroundColor DarkGray
        } elseif ($m.TemplateFile) {
            $presetLines.Add("chat-template-file = $($m.TemplateFile -replace '\\','/')")
            Write-Host "    -> Custom template  : $($m.TemplateFile)" -ForegroundColor DarkGray
        } elseif ($config.use_default_template -and (Test-Path $defaultTemplatePath)) {
            $presetLines.Add("chat-template-file = $($defaultTemplatePath -replace '\\','/')")
            Write-Host "    -> Default template : $defaultTemplatePath" -ForegroundColor DarkGray
        } else {
            Write-Host "    -> No template written (using GGUF internal template)" -ForegroundColor DarkCyan
        }

        $presetLines.Add("")
    }
} else {
    Write-Host "No local GGUF models found in $ModelsDir." -ForegroundColor Yellow
    Write-Host "Server preset configured to fallback/bootstrap." -ForegroundColor Cyan
}

Set-Content -Path $PresetFile -Value $presetLines -Encoding ASCII
Write-Host "Preset configuration written: $PresetFile" -ForegroundColor Green

# Return model list to caller (start-server.ps1 captures this via @(. $setupScript))
return $modelEntries.ToArray()
