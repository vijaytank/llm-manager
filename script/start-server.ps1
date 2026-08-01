# LLO start-server.ps1
# Terminate existing servers, run optimizer configuration, setup environment variables, and launch llama-server.

param(
    [int]$Port = 8080,
    [string]$HostAddr = "127.0.0.1",
    [string]$LlamaServer = "",
    [string]$LlamaDir = "",
    [string]$ConfigFile = "",
    [string]$LogDir = "",
    [string]$ModelsDir = ""
)

$ErrorActionPreference = "Stop"

$ManagerDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))

if ([string]::IsNullOrWhiteSpace($ConfigFile)) {
    $ConfigFile = Join-Path $ManagerDir "llo-config.json"
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
}

# 3. Determine running mode
$localBase = "http://$HostAddr`:$Port"
$openaiBase = "$localBase/v1"

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

$defaultModelId = ""
$logPath = Join-Path $LogDir "llama-server.log"
$errPath = Join-Path $LogDir "llama-server.err.log"

if (Test-Path $logPath) { Remove-Item $logPath -Force }
if (Test-Path $errPath) { Remove-Item $errPath -Force }

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

    if ($selectedEntry.CtxSize -and [int]$selectedEntry.CtxSize -gt 0) {
        $serverArgs += @("-c", "$($selectedEntry.CtxSize)")
        Write-Host "Configured Context Size: $($selectedEntry.CtxSize) tokens" -ForegroundColor Green
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
$env:LLAMA_BASE_URL = $localBase
$env:LLAMA_OPENAI_BASE_URL = $openaiBase
$env:OPENAI_BASE_URL = $openaiBase
$env:OPENAI_API_BASE = $openaiBase
$env:OPENAI_API_KEY = "local-key"

$env:ANTHROPIC_BASE_URL = $localBase
$env:ANTHROPIC_AUTH_TOKEN = "local"
$env:ANTHROPIC_API_KEY = "local-key"
$env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = $disableTeleVal

$env:LLAMA_DEFAULT_MODEL = $defaultModelId
$env:OPENAI_MODEL = $defaultModelId
$env:ANTHROPIC_MODEL = $defaultModelId
$env:LOCAL_REASONING_MODEL = $defaultModelId
$env:LOCAL_FAST_MODEL = $defaultModelId

Write-Host "llama-server is live at $localBase!" -ForegroundColor Green
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
                
                # Prepare the startup command for the new window
                $startupCmds = @(
                    "`$env:ANTHROPIC_BASE_URL = '$localBase'",
                    "`$env:ANTHROPIC_AUTH_TOKEN = 'local'",
                    "`$env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '$disableTeleVal'",
                    "`$env:CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY = '1'",
                    "claude --model $selectedModel"
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
