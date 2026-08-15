# LLO start-server.ps1
# Terminate existing servers, run optimizer configuration, setup environment variables, and launch llama-server.

param(
    [int]$Port = 8080,
    [string]$HostAddr = "127.0.0.1",
    [string]$LlamaServer = "",
    [string]$LlamaDir = "",
    [string]$ConfigFile = "",
    [string]$LogDir = "",
    [string]$ModelsDir = "",
    [int]$Parallel = 0,
    [int]$CtxSize = 0,
    [int]$UbatchSize = 0,
    [string]$FlashAttn = "",
    [string]$CacheTypeK = "",
    [string]$CacheTypeV = ""
)

$ErrorActionPreference = "Stop"

$ManagerDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$lloCoreDir = Join-Path $ManagerDir "llo-core"
if (Test-Path (Join-Path $lloCoreDir "Paths.ps1")) {
    . (Join-Path $lloCoreDir "Paths.ps1")
}

if ([string]::IsNullOrWhiteSpace($ConfigFile)) {
    if (Get-Command "Get-LLMManagerConfigPath" -ErrorAction SilentlyContinue) {
        $ConfigFile = Get-LLMManagerConfigPath -ManagerDir $ManagerDir
    }
    if (-not $ConfigFile) {
        $ConfigFile = Join-Path $ManagerDir "llo-config.json"
    }
}
$ConfigFile = [System.IO.Path]::GetFullPath($ConfigFile)

# Store preset configuration in user AppData folder alongside llo-config.json
$UserDir = Split-Path -Parent $ConfigFile
$PresetFile = [System.IO.Path]::GetFullPath((Join-Path $UserDir "models-preset.ini"))

if ([string]::IsNullOrWhiteSpace($LogDir)) {
    $LogDir = $ManagerDir
} else {
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
}
$LogDir = [System.IO.Path]::GetFullPath($LogDir)

# Load current config settings
$config = @{}
if (Test-Path $ConfigFile) {
    try {
        $loaded = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        foreach ($k in $loaded.PSObject.Properties.Name) {
            $config[$k] = $loaded.$k
        }
    } catch {
        Write-Host "[WARNING] Failed to load configuration from llo-config.json: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    # Enforce operational limits for Claude Code
    if ($config.integrations -contains "claude-code" -and $config.idle_timeout_sec -lt 600) {
        $config.idle_timeout_sec = 600
    }
}

$claudeDisableTelemetry = if ($config.ContainsKey("claude_disable_telemetry")) { $config.claude_disable_telemetry } else { $true }
$disableTeleVal = if ($claudeDisableTelemetry) { "1" } else { "0" }

if ([string]::IsNullOrWhiteSpace($LlamaServer)) {
    if ($config.llama_server_path) {
        $LlamaServer = $config.llama_server_path
    } else {
        $LlamaServer = "llama-server"
    }
}
if ([string]::IsNullOrWhiteSpace($LlamaDir)) {
    if ($config.llama_repo_path) {
        $LlamaDir = $config.llama_repo_path
    } elseif ($config.llama_server_path) {
        $LlamaDir = Split-Path -Parent $config.llama_server_path
    } else {
        $LlamaDir = "."
    }
}

# 1. Run SetupRouter.ps1 to calculate optimal settings and scan models
$setupScript = Join-Path $ManagerDir "llo-core\SetupRouter.ps1"
if (-not (Test-Path $setupScript)) {
    throw "SetupRouter.ps1 script not found at: $setupScript"
}

# Run setup and capture returned GGUF models list
# Wrap in @() to prevent PowerShell from unrolling a single-element array into a scalar,
# which would make $models.Count return $null instead of 1 and fall through to bootstrap mode.
# Forward all user-data paths so SetupRouter reads config and preset from the correct location.
$setupArgs = @{}
$setupArgs["ConfigFile"] = $ConfigFile
$setupArgs["PresetFile"] = $PresetFile
if (-not [string]::IsNullOrWhiteSpace($ModelsDir)) {
    $setupArgs["ModelsDir"] = $ModelsDir
} elseif ($config.models_dir) {
    $setupArgs["ModelsDir"] = $config.models_dir
}
$models = @(. $setupScript @setupArgs)

# 2. Stop any existing llama-server on the port
if ($IsWindows) {
    # Windows: use WMI Win32_Process (original Windows codepath — unchanged)
    $running = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq "llama-server.exe" -and $_.CommandLine -match [regex]::Escape("--port $Port")
    })
    if ($running) {
        Write-Host "Stopping existing llama-server on port $Port..." -ForegroundColor Yellow
        $running | ForEach-Object {
            try { Stop-Process -Id $_.ProcessId -Force } catch {}
        }
        Start-Sleep -Seconds 2
    }
} else {
    # macOS / Linux: find the process via lsof (macOS) or ss/fuser (Linux)
    $existingPids = @()
    if ($IsMacOS) {
        try {
            $lsofOut = & lsof -ti ":$Port" 2>$null
            if ($lsofOut) {
                $existingPids = @($lsofOut -split "`n" | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
            }
        } catch {}
    } elseif ($IsLinux) {
        try {
            $ssOut = & ss -tlnp "sport = :$Port" 2>$null
            if ($ssOut) {
                $pidMatches = [regex]::Matches($ssOut, 'pid=(\d+)')
                $existingPids = @($pidMatches | ForEach-Object { [int]$_.Groups[1].Value })
            }
        } catch {}
        if ($existingPids.Count -eq 0) {
            try {
                $fuserOut = & fuser "${Port}/tcp" 2>$null
                if ($fuserOut) {
                    $existingPids = @($fuserOut.Trim() -split '\s+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
                }
            } catch {}
        }
    }
    $existingPids = @($existingPids | ForEach-Object {
        $proc = Get-Process -Id $_ -ErrorAction SilentlyContinue
        if ($proc -and $proc.Name -match 'llama.?server') { $_ }
    })
    if ($existingPids.Count -gt 0) {
        Write-Host "Stopping existing llama-server on port $Port..." -ForegroundColor Yellow
        $existingPids | ForEach-Object { try { Stop-Process -Id $_ -Force } catch {} }
        Start-Sleep -Seconds 2
    }
}

# 2.1 Scan for a free port if the target port is in use by another application
$listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
$usedPorts = $listeners.Port
if ($usedPorts -contains $Port) {
    Write-Host "Port $Port is occupied by another application. Scanning for the next available port..." -ForegroundColor Yellow
    while ($usedPorts -contains $Port) {
        $Port++
    }
    Write-Host "Automatically shifted server port to $Port." -ForegroundColor Green

    if ($Port -ne 8080 -and (Test-Path $ConfigFile)) {
        try {
            $cfgJson = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            $cfgJson | Add-Member -Force -NotePropertyName "port" -NotePropertyValue $Port
            if ($cfgJson.context_manager) {
                $cfgJson.context_manager | Add-Member -Force -NotePropertyName "llama_server_url" -NotePropertyValue "http://127.0.0.1:$Port"
            }
            $cfgJson | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigFile -Encoding UTF8
        } catch {
            Write-Host "[WARNING] Could not update port in llo-config.json: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

# 3. Determine running mode
$localBase = "http://$HostAddr`:$Port"
$openaiBase = "$localBase/v1"

# Update static .vscode/settings.json if present to prevent client port mismatches
$vsCodeSettings = Join-Path $ManagerDir ".vscode\settings.json"
if (Test-Path $vsCodeSettings) {
    try {
        $vsJson = Get-Content $vsCodeSettings -Raw | ConvertFrom-Json
        $updated = $false
        $targetUrl = "http://${HostAddr}:${Port}"
        $targetV1Url = "http://${HostAddr}:${Port}/v1"

        foreach ($osEnv in @("terminal.integrated.env.windows", "terminal.integrated.env.osx", "terminal.integrated.env.linux")) {
            if ($vsJson.PSObject.Properties.Name -contains $osEnv) {
                $envObj = $vsJson.$osEnv
                if ($envObj.LLAMA_BASE_URL -and $envObj.LLAMA_BASE_URL -ne $targetUrl) {
                    $envObj.LLAMA_BASE_URL = $targetUrl
                    $updated = $true
                }
                if ($envObj.LLAMA_OPENAI_BASE_URL -and $envObj.LLAMA_OPENAI_BASE_URL -ne $targetV1Url) {
                    $envObj.LLAMA_OPENAI_BASE_URL = $targetV1Url
                    $updated = $true
                }
                if ($envObj.OPENAI_BASE_URL -and $envObj.OPENAI_BASE_URL -ne $targetV1Url) {
                    $envObj.OPENAI_BASE_URL = $targetV1Url
                    $updated = $true
                }
                if ($envObj.OPENAI_API_BASE -and $envObj.OPENAI_API_BASE -ne $targetV1Url) {
                    $envObj.OPENAI_API_BASE = $targetV1Url
                    $updated = $true
                }
                if ($envObj.ANTHROPIC_BASE_URL -and $envObj.ANTHROPIC_BASE_URL -ne $targetUrl) {
                    $envObj.ANTHROPIC_BASE_URL = $targetUrl
                    $updated = $true
                }
            }
        }
        if ($updated) {
            $vsJson | ConvertTo-Json -Depth 10 | Set-Content -Path $vsCodeSettings -Encoding UTF8
            Write-Host "[VSCode] Synchronized .vscode/settings.json environment variables to active port $Port." -ForegroundColor Cyan
        }
    } catch {
        Write-Host "[WARNING] Could not update .vscode/settings.json: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# Safe default environment variables
$env:CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY = "1"

if ($models.Count -eq 0 -and $config.fallback_provider -ne "none") {
    # CLOUD PROXY / OLLAMA BOOTSTRAP MODE
    Write-Host "No local GGUF models. Entering Hybrid Proxy Fallback mode..." -ForegroundColor Yellow
    
    $provider = $config.fallback_provider.ToLower()
    $chosenModel = $config.fallback_model
    
    if ($provider -eq "anthropic") {
        Write-Host "Routing API client requests directly to Anthropic Cloud..." -ForegroundColor Green
        $env:ANTHROPIC_BASE_URL = if ($config.fallback_endpoint) { $config.fallback_endpoint } else { "https://api.anthropic.com" }
        $env:ANTHROPIC_API_KEY = $config.fallback_api_key
        $env:ANTHROPIC_MODEL = if ($chosenModel) { $chosenModel } else { "claude-3-5-sonnet-latest" }
    }
    elseif ($provider -eq "openai") {
        Write-Host "Routing API client requests directly to OpenAI Cloud..." -ForegroundColor Green
        $env:OPENAI_BASE_URL = if ($config.fallback_endpoint) { $config.fallback_endpoint } else { "https://api.openai.com/v1" }
        $env:OPENAI_API_BASE = $env:OPENAI_BASE_URL
        $env:OPENAI_API_KEY = $config.fallback_api_key
        $env:OPENAI_MODEL = if ($chosenModel) { $chosenModel } else { "gpt-4o" }
    }
    elseif ($provider -eq "nim") {
        Write-Host "Routing API client requests directly to NVIDIA NIM Cloud..." -ForegroundColor Green
        $env:OPENAI_BASE_URL = if ($config.fallback_endpoint) { $config.fallback_endpoint } else { "https://integrate.api.nvidia.com/v1" }
        $env:OPENAI_API_BASE = $env:OPENAI_BASE_URL
        $env:OPENAI_API_KEY = $config.fallback_api_key
        $env:OPENAI_MODEL = if ($chosenModel) { $chosenModel } else { "meta/llama-3.1-8b-instruct" }
    }
    elseif ($provider -eq "ollama") {
        $ollamaEndpoint = if ($config.fallback_endpoint) { $config.fallback_endpoint } else { "http://127.0.0.1:11434" }
        Write-Host "Routing API client requests to local Ollama instance ($ollamaEndpoint)..." -ForegroundColor Green
        
        $env:LLAMA_BASE_URL = $ollamaEndpoint
        $env:LLAMA_OPENAI_BASE_URL = "$ollamaEndpoint/v1"
        $env:OPENAI_BASE_URL = "$ollamaEndpoint/v1"
        $env:OPENAI_API_BASE = "$ollamaEndpoint/v1"
        $env:OPENAI_MODEL = if ($chosenModel) { $chosenModel } else { "llama3" }
        
        $env:ANTHROPIC_BASE_URL = $ollamaEndpoint
        $env:ANTHROPIC_AUTH_TOKEN = "local"
        $env:ANTHROPIC_MODEL = $env:OPENAI_MODEL
    }
    
    Write-Host "Dynamic environment configured. Clients will connect directly to $provider." -ForegroundColor Green
    return
}

# LOCAL INFRASTRUCTURE MODE
if (-not (Test-Path $LlamaServer)) {
    $binaryName = if ($IsWindows) { "llama-server.exe" } else { "llama-server" }
    throw "$binaryName not found at: $LlamaServer. Please compile the binary or adjust paths."
}

# 4. Construct command line arguments
$serverArgs = @(
    "--host", $HostAddr,
    "--port", "$Port",
    "--sleep-idle-seconds", "$($config.idle_timeout_sec)"
)

# 3.5 Check Context Manager Proxy status in config (default: false)
$cmEnabled = $false
if ($config.context_manager) {
    if ($config.context_manager.enabled -eq $true -or $config.context_manager.enabled -eq "true") {
        $cmEnabled = $true
    }
}

$defaultModelId = ""
$logPath = Join-Path $LogDir "llama-server.log"
$errPath = Join-Path $LogDir "llama-server.err.log"

if (Test-Path $logPath) { try { Clear-Content $logPath -ErrorAction SilentlyContinue } catch {} }
if (Test-Path $errPath) { try { Clear-Content $errPath -ErrorAction SilentlyContinue } catch {} }

if ($models.Count -gt 0) {
    # Use the generated models preset config file
    $serverArgs += @("--models-preset", $PresetFile)
    $serverArgs += @("--models-max", "1")

    # Match config.active_model against discovered model entries
    $selectedEntry = $null
    if ($config.active_model) {
        $activeName = $config.active_model.ToString().Trim().ToLowerInvariant()
        $selectedEntry = $models | Where-Object {
            $_.Alias.ToLowerInvariant() -eq $activeName -or
            $_.Path.ToLowerInvariant().Contains($activeName)
        } | Select-Object -First 1
    }

    if (-not $selectedEntry) {
        $selectedEntry = $models[0]
    }

    $defaultModelId = $selectedEntry.Alias
    $serverArgs += @("-m", $selectedEntry.Path)
    Write-Host "Selected Active Model for Inference: $($selectedEntry.Alias) ($($selectedEntry.Path))" -ForegroundColor Green

    # ── Context Size (-c) Resolution Hierarchy: CLI > SetupRouter Per-Model > UI Config Fallback ──
    $finalCtxSize = 0
    if ($PSBoundParameters.ContainsKey("CtxSize") -and $CtxSize -gt 0) {
        $finalCtxSize = $CtxSize
        Write-Host "Context Size: $finalCtxSize tokens (from CLI switch)" -ForegroundColor DarkYellow
    } elseif ($selectedEntry.CtxSize -and [int]$selectedEntry.CtxSize -gt 0) {
        $finalCtxSize = [int]$selectedEntry.CtxSize
        Write-Host "Context Size: $finalCtxSize tokens (from per-model hardware auto-tune)" -ForegroundColor Green
    } elseif ($config.ContainsKey("default_context_size") -and [int]$config.default_context_size -gt 0) {
        $finalCtxSize = [int]$config.default_context_size
        Write-Host "Context Size: $finalCtxSize tokens (from UI config fallback)" -ForegroundColor DarkGray
    }
    if ($finalCtxSize -gt 0) {
        $serverArgs += @("-c", "$finalCtxSize")
    }

    # ── Parallel Slots (-np) Resolution Hierarchy: CLI > UI Config > SetupRouter > Default ──
    if ($PSBoundParameters.ContainsKey("Parallel") -and $Parallel -gt 0) {
        $serverArgs += @("-np", "$Parallel")
        Write-Host "Parallel Slots: $Parallel (from CLI switch)" -ForegroundColor DarkYellow
    } elseif ($PSBoundParameters.ContainsKey("Parallel") -and $Parallel -eq -1) {
        Write-Host "Parallel Slots: auto (from CLI switch -1)" -ForegroundColor DarkYellow
    } elseif ($config.ContainsKey("parallel_slots") -and [int]$config.parallel_slots -gt 0) {
        $finalParallel = [int]$config.parallel_slots
        $serverArgs += @("-np", "$finalParallel")
        Write-Host "Parallel Slots: $finalParallel (from UI config.parallel_slots)" -ForegroundColor Green
    } elseif ($config.ContainsKey("parallel_slots") -and [int]$config.parallel_slots -eq -1) {
        Write-Host "Parallel Slots: auto (from UI config -1)" -ForegroundColor DarkGray
    } elseif ($selectedEntry.Parallel -and [int]$selectedEntry.Parallel -gt 0) {
        $finalParallel = [int]$selectedEntry.Parallel
        $serverArgs += @("-np", "$finalParallel")
        Write-Host "Parallel Slots: $finalParallel (from preset config)" -ForegroundColor DarkGray
    } else {
        $serverArgs += @("-np", "1")
    }

    # ── Micro-batch Size (-ub) Resolution Hierarchy: CLI > UI Config > Default (512) ──
    $finalUbatch = 0
    if ($PSBoundParameters.ContainsKey("UbatchSize") -and $UbatchSize -gt 0) {
        $finalUbatch = $UbatchSize
        Write-Host "Micro-Batch Size: $finalUbatch tokens (from CLI switch)" -ForegroundColor DarkYellow
    } elseif ($config.ContainsKey("ubatch_size") -and [int]$config.ubatch_size -gt 0) {
        $finalUbatch = [int]$config.ubatch_size
        Write-Host "Micro-Batch Size: $finalUbatch tokens (from UI config.ubatch_size)" -ForegroundColor Green
    }
    if ($finalUbatch -gt 0) {
        $serverArgs += @("-ub", "$finalUbatch")
    }

    # ── CLI Switches Overrides: Flash Attention & KV Cache Precision ──
    if ($PSBoundParameters.ContainsKey("FlashAttn") -and -not [string]::IsNullOrWhiteSpace($FlashAttn)) {
        $serverArgs += @("--flash-attn", $FlashAttn)
        Write-Host "Flash Attention: $FlashAttn (from CLI switch)" -ForegroundColor DarkYellow
    }
    if ($PSBoundParameters.ContainsKey("CacheTypeK") -and -not [string]::IsNullOrWhiteSpace($CacheTypeK)) {
        $serverArgs += @("--cache-type-k", $CacheTypeK)
        Write-Host "KV Cache K Precision: $CacheTypeK (from CLI switch)" -ForegroundColor DarkYellow
    }
    if ($PSBoundParameters.ContainsKey("CacheTypeV") -and -not [string]::IsNullOrWhiteSpace($CacheTypeV)) {
        $serverArgs += @("--cache-type-v", $CacheTypeV)
        Write-Host "KV Cache V Precision: $CacheTypeV (from CLI switch)" -ForegroundColor DarkYellow
    }

    # Explicitly pass --mmproj and --no-mmproj-offload CLI flags if configured
    if ($config.mmproj_path -and (Test-Path $config.mmproj_path) -and $config.mmproj_path -ne "none") {
        $serverArgs += @("--mmproj", $config.mmproj_path)
        Write-Host "Multimodal Vision Projector: $($config.mmproj_path)" -ForegroundColor Green
        if ($config.mmproj_no_offload) {
            $serverArgs += "--no-mmproj-offload"
            Write-Host "Vision Projector Offload: CPU (RAM)" -ForegroundColor Yellow
        } else {
            Write-Host "Vision Projector Offload: GPU (VRAM)" -ForegroundColor Green
        }
    }

    # Explicitly pass --chat-template-file CLI flag if active_template or use_default_template is set
    $resolvedTemplate = $null
    $templatesDir = if ($config.templates_dir -and (Test-Path $config.templates_dir)) {
        $config.templates_dir
    } else {
        Join-Path $ManagerDir "templates"
    }

    if ($config.active_template -and $config.active_template -ne "auto") {
        if (Test-Path $config.active_template) {
            $resolvedTemplate = $config.active_template
        } else {
            $cand = Join-Path $templatesDir $config.active_template
            if (Test-Path $cand) {
                $resolvedTemplate = $cand
            }
        }
    } elseif ($config.use_default_template) {
        $cand = Join-Path $templatesDir "default.jinja"
        if (Test-Path $cand) {
            $resolvedTemplate = $cand
        }
    }

    if ($resolvedTemplate) {
        $serverArgs += @("--chat-template-file", $resolvedTemplate)
        Write-Host "Chat Template File: $resolvedTemplate" -ForegroundColor Green
    }

    # Explicitly pass process priority if configured
    if ($config.prio -and [int]$config.prio -gt 0) {
        $serverArgs += @("--prio", "$($config.prio)")
        Write-Host "Process Priority: $($config.prio)" -ForegroundColor Green
    }

    # Explicitly pass memory locking flag if configured
    if ($config.mlock) {
        $serverArgs += "--mlock"
        Write-Host "Memory Locking: ENABLED" -ForegroundColor Green
    }

    # Explicitly pass reasoning tags behavior if configured
    if ($config.reasoning -and $config.reasoning -ne "auto") {
        $serverArgs += @("--reasoning", "$($config.reasoning)")
        Write-Host "Reasoning Output: $($config.reasoning)" -ForegroundColor Green
    }
} else {
    # Bootstrap download mode: No GGUFs and no cloud keys set. Run tiny local model from Hugging Face
    $bootstrapRepo = "Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF:Q4_K_M"
    Write-Host "No GGUF models. Bootstrapping with lightweight model from Hugging Face: $bootstrapRepo" -ForegroundColor Yellow
    $serverArgs += @("-hf", $bootstrapRepo)
    $defaultModelId = "qwen2-5-coder-1-5b-instruct"
}

# 4.1 Append custom CLI arguments if configured
if ($config.custom_args) {
    $customList = $config.custom_args -split '\s+' | Where-Object { [string]::IsNullOrWhiteSpace($_) -eq $false }
    $serverArgs += $customList
}

# Properly quote arguments that contain spaces for Start-Process -ArgumentList
$formattedServerArgs = $serverArgs | ForEach-Object {
    if ($_ -and $_.ToString().Contains(' ') -and -not ($_.ToString().StartsWith('"') -and $_.ToString().EndsWith('"'))) {
        "`"$_`""
    } else {
        $_
    }
}

Write-Host "Starting llama-server..." -ForegroundColor Cyan
Write-Host "Command: $LlamaServer $($formattedServerArgs -join ' ')" -ForegroundColor DarkGray

$proc = Start-Process -FilePath $LlamaServer -ArgumentList $formattedServerArgs -WorkingDirectory $LlamaDir -PassThru -NoNewWindow -RedirectStandardOutput $logPath -RedirectStandardError $errPath
Write-Host "Server process launched (PID: $($proc.Id))" -ForegroundColor Green
Write-Host "llama-server stdout log: $logPath" -ForegroundColor DarkGray
Write-Host "llama-server stderr log: $errPath" -ForegroundColor DarkGray

# Wait for server startup
Write-Host "Waiting for endpoint to become ready..." -NoNewline -ForegroundColor Cyan
$deadline = (Get-Date).AddSeconds(30)
$ready = $false

while ((Get-Date) -lt $deadline) {
    try {
        $resp = Invoke-RestMethod -Uri "$openaiBase/models" -TimeoutSec 3 -ErrorAction SilentlyContinue
        if ($resp -and $resp.data) {
            $ready = $true
            break
        }
    } catch {}
    Write-Host "." -NoNewline -ForegroundColor Cyan
    Start-Sleep -Milliseconds 1500
}
Write-Host ""

if (-not $ready) {
    if ($proc.HasExited) {
        throw "llama-server failed to start. Process exited with code $($proc.ExitCode)."
    }
    throw "llama-server failed to respond to API requests on port $Port within 30 seconds."
}

# Auto-start Context Manager Proxy if enabled once llama-server is ready
$activeCmPort = 8090
if ($ready -and $cmEnabled) {
    $cmPort = if ($config.context_manager -and $config.context_manager.proxy_port) { [int]$config.context_manager.proxy_port } else { 8090 }
    $cmScript = Join-Path $PSScriptRoot "StartContextManager.ps1"
    if (Test-Path $cmScript) {
        Write-Host "`n[Context Manager Proxy]" -ForegroundColor Cyan
        Write-Host "Auto-launching Context Manager Proxy on port $cmPort (Upstream llama-server port $Port)..." -ForegroundColor Cyan
        try {
            & $cmScript -Port $cmPort -UpstreamPort $Port -ConfigFile $ConfigFile
            # Read updated proxy_port in case StartContextManager shifted it
            if (Test-Path $ConfigFile) {
                $reloadedCfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
                if ($reloadedCfg.context_manager -and $reloadedCfg.context_manager.proxy_port) {
                    $activeCmPort = [int]$reloadedCfg.context_manager.proxy_port
                }
            }
        } catch {
            Write-Host "[WARNING] Failed to start Context Manager Proxy: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

# 5. Extract active models
$liveModels = @()
try {
    $resp = Invoke-RestMethod -Uri "$openaiBase/models" -TimeoutSec 5
    $liveModels = @($resp.data | ForEach-Object { $_.id })
} catch {
    Write-Host "[WARNING] Failed to retrieve active models list: $($_.Exception.Message)" -ForegroundColor Yellow
}

if ($liveModels.Count -gt 0) {
    $defaultModelId = $liveModels[0]
}

# 6. Export local API environment variables
# If Context Manager is enabled, client traffic routes to the Proxy port; otherwise directly to llama-server.
$clientBase = if ($cmEnabled) { "http://$HostAddr`:$activeCmPort" } else { $localBase }
$clientOpenaiBase = "$clientBase/v1"

$env:LLAMA_BASE_URL = $clientBase
$env:LLAMA_OPENAI_BASE_URL = $clientOpenaiBase
$env:OPENAI_BASE_URL = $clientOpenaiBase
$env:OPENAI_API_BASE = $clientOpenaiBase
$env:OPENAI_API_KEY = "local-key"

$env:ANTHROPIC_BASE_URL = $clientBase
$env:ANTHROPIC_AUTH_TOKEN = "local"
$env:ANTHROPIC_API_KEY = "local-key"
$env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = $disableTeleVal

$env:LLAMA_DEFAULT_MODEL = $defaultModelId
$env:OPENAI_MODEL = $defaultModelId
$env:ANTHROPIC_MODEL = $defaultModelId
$env:LOCAL_REASONING_MODEL = $defaultModelId
$env:LOCAL_FAST_MODEL = $defaultModelId

Write-Host "llama-server is live at $localBase!" -ForegroundColor Green
if ($cmEnabled) {
    Write-Host "Context Manager Proxy is active at $clientBase -> proxying to $localBase" -ForegroundColor Cyan
}
Write-Host "Active Model: $defaultModelId" -ForegroundColor Yellow
Write-Host "Available Models:" -ForegroundColor Cyan
if ($liveModels.Count -gt 0) {
    $liveModels | ForEach-Object { Write-Host "  - $_" }
} else {
    Write-Host "  - $defaultModelId (Bootstrapped)"
}
Write-Host ""
Write-Host "Client environment variables exported successfully." -ForegroundColor Green

# 7. Optionally launch Claude Code CLI in a new window (interactive console only)
if ([Environment]::UserInteractive) {
    try {
        $claudeCli = Get-Command "claude" -ErrorAction SilentlyContinue
        if ($claudeCli) {
            Write-Host "`n[Claude Code Integration]" -ForegroundColor Yellow
            Write-Host "Would you like to launch Claude Code CLI in a new window now? (Y/N) [N]: " -NoNewline -ForegroundColor White
            $ans = Read-Host
            if ($ans -and $ans.Trim().ToUpper() -eq "Y") {
                # Select model
                Write-Host "`nSelect model to run with Claude Code:" -ForegroundColor Cyan
                $modelsList = if ($liveModels.Count -gt 0) { $liveModels } else { @($defaultModelId) }
                for ($i = 0; $i -lt $modelsList.Count; $i++) {
                    Write-Host "  $($i + 1)) $($modelsList[$i])" -ForegroundColor DarkGray
                }
                Write-Host "Select option [1]: " -NoNewline -ForegroundColor White
                $sel = Read-Host
                $idx = 0
                if ($sel -match '^\d+$') {
                    $idx = [int]$sel - 1
                }
                if ($idx -lt 0 -or $idx -ge $modelsList.Count) { $idx = 0 }
                $selectedModel = $modelsList[$idx]
                
                Write-Host "Launching Claude Code with model '$selectedModel' in a new window..." -ForegroundColor Green
                
                # Prepare the startup command for the new window (pointing to $clientBase)
                $startupCmds = @(
                    "`$m = '$($selectedModel -replace "'","''")'",
                    "`$env:ANTHROPIC_BASE_URL = '$clientBase'",
                    "`$env:ANTHROPIC_AUTH_TOKEN = 'local'",
                    "`$env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '$disableTeleVal'",
                    "`$env:CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY = '1'",
                    "claude --model `$m"
                ) -join "; "
                
                if ($IsWindows) {
                    Start-Process powershell -ArgumentList "-NoExit", "-Command", "`"$startupCmds`""
                } else {
                    # macOS/Linux: PowerShell 7 binary is 'pwsh'
                    Start-Process pwsh -ArgumentList "-NoExit", "-Command", "`"$startupCmds`""
                }
            }
        } else {
            Write-Host "`n[Claude Code Integration]" -ForegroundColor Yellow
            Write-Host "Claude Code CLI not detected in your PATH." -ForegroundColor DarkGray
            Write-Host "To use Claude Code locally, install it via: npm install -g @anthropic-ai/claude-code" -ForegroundColor DarkGray
            Write-Host "And run: claude --model <model-name>" -ForegroundColor Yellow
        }
    } catch {
        # Non-interactive shell environment (e.g. launched via Tauri GUI without console input)
    }
}
