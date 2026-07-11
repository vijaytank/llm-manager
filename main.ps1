# LLM Manager Main Setup Wizard (main.ps1)
# Interactive setup entry point.

$ErrorActionPreference = "Stop"
$ManagerDir = $PSScriptRoot

# Clear console for a fresh look
Clear-Host

Write-Host "==========================================================" -ForegroundColor Green
Write-Host "       _      _      __  __   __  __                                " -ForegroundColor Green
Write-Host "      | |    | |    |  \/  | |  \/  |                              " -ForegroundColor Green
Write-Host "      | |    | |    | \  / | | \  / |  _ __ ___   __ _  _ __   __ _  _ __ " -ForegroundColor Green
Write-Host "      | |    | |    | |\/| | | |\/| | | '_ ` _ \ / _` || '_ \ / _` || '__|" -ForegroundColor Green
Write-Host "      | |____| |____| |  | | | |  | | | | | | | | (_| || | | | (_| || |   " -ForegroundColor Green
Write-Host "      |______|______|____|__|_|____|__|_|_|_|_|_|\__,_||_| |_|\__, ||_|   " -ForegroundColor Green
Write-Host "                             |______|                         |___/       " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "           LLM MANAGER - INTERACTIVE SETUP WIZARD" -ForegroundColor Cyan
Write-Host "==========================================================`n" -ForegroundColor Green

# 1. Helper functions for input
function Get-UserInput {
    param(
        [string]$Prompt,
        [string]$DefaultVal = ""
    )
    if ($DefaultVal) {
        Write-Host "$Prompt [$DefaultVal]: " -NoNewline -ForegroundColor White
    } else {
        Write-Host "${Prompt}: " -NoNewline -ForegroundColor White
    }
    $val = Read-Host
    if ([string]::IsNullOrWhiteSpace($val)) {
        return $DefaultVal
    }
    # Trim whitespace and remove surrounding double or single quotes
    return $val.Trim().Trim('"', "'")
}

function Get-UserChoice {
    param(
        [string]$Prompt,
        [array]$Options,
        [int]$DefaultChoice = 1
    )
    Write-Host $Prompt -ForegroundColor Cyan
    for ($i = 0; $i -lt $Options.Count; $i++) {
        Write-Host "  $($i + 1)) $($Options[$i])" -ForegroundColor DarkGray
    }
    $choice = Get-UserInput "Select option" -DefaultVal $DefaultChoice
    $idx = [int]$choice - 1
    if ($idx -ge 0 -and $idx -lt $Options.Count) {
        return $idx
    }
    return $DefaultChoice - 1
}

# 2. Setup Config object
$ConfigFile = Join-Path $ManagerDir "llo-config.json"
$config = @{
    installation_type = "none"
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
    idle_timeout_sec = 60
    vram_margin_mb = 1024
    fallback_provider = "none"
    default_context_size = 131072
    fallback_model = ""
    fallback_api_key = ""
    enable_tools = $true
    fallback_endpoint = ""
}

# Load existing configuration if available
if (Test-Path $ConfigFile) {
    try {
        $loaded = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        foreach ($k in $loaded.PSObject.Properties.Name) {
            $config[$k] = $loaded.$k
        }
        Write-Host "[INFO] Loaded existing configuration from llo-config.json.`n" -ForegroundColor DarkGray
    } catch {}
}

# Run hardware profiling first so it is available for auto-tuning defaults
Write-Host "Profiling system hardware..." -ForegroundColor Cyan
$profileScript = Join-Path $ManagerDir "llo-core\Profile.ps1"
if (Test-Path $profileScript) {
    . $profileScript
    $hw = Get-SystemHardwareProfile
} else {
    Write-Host "[WARNING] Profile.ps1 not found in llo-core/." -ForegroundColor Yellow
    $hw = $null
}

# Step 1: Llama.cpp installation details
$defaultChoice = 3
if ($config.installation_type -eq "winget") {
    $defaultChoice = 1
} elseif ($config.installation_type -eq "github") {
    $defaultChoice = 2
}

Write-Host "Step 1: How is llama.cpp installed on your system?" -ForegroundColor Cyan
Write-Host "  1) Pre-built package (installed via Winget / in PATH)" -ForegroundColor DarkGray
Write-Host "  2) Manual build (compiled from GitHub repository)" -ForegroundColor DarkGray
Write-Host "  3) Custom path (provide binary location directly)" -ForegroundColor DarkGray

$choice = Get-UserInput "Select option (1-3) or paste path to llama-server.exe / repository folder" -DefaultVal $defaultChoice

$llamaServerPath = ""
$llamaRepoPath = ""
$installationType = ""

if ($choice -match '^[1-3]$') {
    $installTypeIdx = [int]$choice - 1
    $installTypes = @("winget", "github", "other")
    $installationType = $installTypes[$installTypeIdx]
} else {
    # If the user pasted a path directly
    if (Test-Path $choice) {
        if (Test-Path $choice -PathType Leaf) {
            $llamaServerPath = [System.IO.Path]::GetFullPath($choice)
            $installationType = "other"
            Write-Host "  [Detected Path] Directly using llama-server path: $llamaServerPath" -ForegroundColor Green
        } else {
            $llamaRepoPath = [System.IO.Path]::GetFullPath($choice)
            $installationType = "github"
            Write-Host "  [Detected Path] Treating directory as repository root: $llamaRepoPath" -ForegroundColor Green
        }
    } else {
        Write-Host "[WARNING] Entered path does not exist. Falling back to default selection." -ForegroundColor Yellow
        $installTypeIdx = [int]$defaultChoice - 1
        $installTypes = @("winget", "github", "other")
        $installationType = $installTypes[$installTypeIdx]
    }
}

$config.installation_type = $installationType

if ($config.installation_type -eq "winget") {
    if (-not $llamaServerPath) {
        Write-Host "`nScanning system PATH for llama-server..." -ForegroundColor Cyan
        $cmd = Get-Command "llama-server" -ErrorAction SilentlyContinue
        if ($cmd) {
            $llamaServerPath = $cmd.Source
            Write-Host "  Found llama-server at: $llamaServerPath" -ForegroundColor Green
            $confirm = Get-UserInput "Use this binary? (Y/N)" -DefaultVal "Y"
            if ($confirm.ToUpper() -ne "Y") {
                $llamaServerPath = ""
            }
        }
        
        if (-not $llamaServerPath) {
            while ($true) {
                $pathInput = Get-UserInput "Please enter the path to llama-server.exe" -DefaultVal $config.llama_server_path
                if (Test-Path $pathInput -PathType Leaf) {
                    $llamaServerPath = [System.IO.Path]::GetFullPath($pathInput)
                    break
                }
                Write-Host "[ERROR] Path is not a valid file. Please try again." -ForegroundColor Red
            }
        }
    }
}
elseif ($config.installation_type -eq "github") {
    if (-not $llamaRepoPath) {
        $defaultRepo = if ($config.llama_repo_path) { $config.llama_repo_path } else { [System.IO.Path]::GetFullPath((Join-Path $ManagerDir "..\llama.cpp")) }
        while ($true) {
            $repoInput = Get-UserInput "Step 1.1: Enter path to llama.cpp repository root" -DefaultVal $defaultRepo
            if (Test-Path $repoInput -PathType Container) {
                $llamaRepoPath = [System.IO.Path]::GetFullPath($repoInput)
                break
            }
            Write-Host "[ERROR] Directory does not exist. Please try again." -ForegroundColor Red
        }
    }
    
    if (-not $llamaServerPath) {
        # Scan for compiled binary inside build outputs
        $scanPaths = @(
            "build\bin\Release\llama-server.exe",
            "build\bin\Debug\llama-server.exe",
            "build\bin\llama-server.exe",
            "bin\llama-server.exe"
        )
        $foundBinary = ""
        foreach ($sp in $scanPaths) {
            $fullSp = Join-Path $llamaRepoPath $sp
            if (Test-Path $fullSp) {
                $foundBinary = $fullSp
                break
            }
        }
        
        if ($foundBinary) {
            $llamaServerPath = $foundBinary
            Write-Host "  Automatically located compiled binary: $llamaServerPath" -ForegroundColor Green
            $confirm = Get-UserInput "Use this binary? (Y/N)" -DefaultVal "Y"
            if ($confirm.ToUpper() -ne "Y") {
                $llamaServerPath = ""
            }
        }
        
        if (-not $llamaServerPath) {
            while ($true) {
                $pathInput = Get-UserInput "Please enter the path to llama-server.exe manually" -DefaultVal $config.llama_server_path
                if (Test-Path $pathInput -PathType Leaf) {
                    $llamaServerPath = [System.IO.Path]::GetFullPath($pathInput)
                    break
                }
                Write-Host "[ERROR] File not found. Please try again." -ForegroundColor Red
            }
        }
    }
}
else {
    if (-not $llamaServerPath) {
        while ($true) {
            $pathInput = Get-UserInput "`nPlease enter the full path to llama-server.exe" -DefaultVal $config.llama_server_path
            if (Test-Path $pathInput -PathType Leaf) {
                $llamaServerPath = [System.IO.Path]::GetFullPath($pathInput)
                break
            }
            Write-Host "[ERROR] File not found. Please try again." -ForegroundColor Red
        }
    }
}

$config.llama_server_path = $llamaServerPath
$config.llama_repo_path = $llamaRepoPath

# Step 2: Resolve GGUF Models Path
Write-Host "`nStep 2: Configuring GGUF Models Directory..." -ForegroundColor Cyan
$detectedModelsDir = [System.IO.Path]::GetFullPath((Join-Path $ManagerDir "..\models"))
$defaultModelsInput = if ($config.models_dir) { $config.models_dir } elseif (Test-Path $detectedModelsDir) { $detectedModelsDir } else { "" }

$modelsDir = ""
while ($true) {
    $modelsInput = Get-UserInput "Enter the absolute path to your GGUF models folder" -DefaultVal $defaultModelsInput
    if ([string]::IsNullOrWhiteSpace($modelsInput)) {
        Write-Host "[ERROR] Models folder path is required." -ForegroundColor Red
        continue
    }
    
    if (Test-Path $modelsInput) {
        $modelsDir = [System.IO.Path]::GetFullPath($modelsInput)
        break
    } else {
        $create = Get-UserInput "Directory does not exist. Create it? (Y/N)" -DefaultVal "Y"
        if ($create.ToUpper() -eq "Y") {
            try {
                New-Item -ItemType Directory -Path $modelsInput -Force | Out-Null
                $modelsDir = [System.IO.Path]::GetFullPath($modelsInput)
                break
            } catch {
                Write-Host "[ERROR] Failed to create directory: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
}
$config.models_dir = $modelsDir

# Step 2.1: Resolve Chat Templates Path
Write-Host "`nStep 2.1: Configuring Jinja Chat Templates Directory (Optional)..." -ForegroundColor Cyan
$detectedTemplatesDir = [System.IO.Path]::GetFullPath((Join-Path $ManagerDir "..\templates"))
$defaultTemplatesInput = if ($config.templates_dir) { $config.templates_dir } elseif (Test-Path $detectedTemplatesDir) { $detectedTemplatesDir } else { "" }

$templatesDir = ""
while ($true) {
    $promptMsg = "Enter the absolute path to your Chat Templates folder (press Enter to skip/use built-in)"
    $templatesInput = Get-UserInput $promptMsg -DefaultVal $defaultTemplatesInput
    
    if ([string]::IsNullOrWhiteSpace($templatesInput) -or $templatesInput.ToLower() -eq "none") {
        Write-Host "  No custom templates directory configured. Server will fallback to built-in model templates." -ForegroundColor Green
        $templatesDir = ""
        break
    }
    
    if (Test-Path $templatesInput) {
        $templatesDir = [System.IO.Path]::GetFullPath($templatesInput)
        break
    } else {
        $create = Get-UserInput "Directory does not exist. Create it? (Y/N)" -DefaultVal "Y"
        if ($create.ToUpper() -eq "Y") {
            try {
                New-Item -ItemType Directory -Path $templatesInput -Force | Out-Null
                $templatesDir = [System.IO.Path]::GetFullPath($templatesInput)
                break
            } catch {
                Write-Host "[ERROR] Failed to create directory: $($_.Exception.Message)" -ForegroundColor Red
            }
        } else {
            $templatesDir = ""
            break
        }
    }
}
$config.templates_dir = $templatesDir

# Step 2.2: Automated Memory & Performance Optimization
Write-Host "`nStep 2.2: Automatically tuning performance parameters for your system..." -ForegroundColor Cyan

$flashAttn = "auto"
$cacheType = "f16"
$contextShift = $true

if ($hw) {
    # 1. Enable Flash Attention if GPU is present
    if ($hw.GPU -and $hw.GPU.TotalVramMB -gt 0) {
        $flashAttn = "on"
    }
    
    # 2. Heuristically select KV Cache quantization to prevent VRAM bottlenecks
    if ($hw.GPU -and $hw.GPU.TotalVramMB -gt 0) {
        $vramGB = $hw.GPU.TotalVramMB / 1024
        if ($vramGB -lt 6.0) {
            $cacheType = "q4_0" # Max VRAM savings for low-end GPUs
        } elseif ($vramGB -lt 12.0) {
            $cacheType = "q8_0" # Balanced savings for mid-range GPUs (like RTX 5060)
        } else {
            $cacheType = "f16"  # High precision for high-end GPUs
        }
    } else {
        # CPU-only: q8_0 reduces cache memory bandwidth and speeds up CPU inference significantly
        $cacheType = "q8_0"
    }

    # 3. Heuristically select context size to balance VRAM and capacity
    $defaultCtxSize = 65536
    if ($hw.GPU -and $hw.GPU.TotalVramMB -gt 0) {
        $vramGB = $hw.GPU.TotalVramMB / 1024
        if ($vramGB -le 8.0) {
            $defaultCtxSize = 32768 # 32k limits VRAM footprint for cards with <= 8GB
        } elseif ($vramGB -ge 16.0) {
            $defaultCtxSize = 131072 # 128k for high-end GPUs
        }
    }
}

$config.cache_type_k = $cacheType
$config.cache_type_v = $cacheType
$config.flash_attn = $flashAttn
$config.context_shift = $contextShift
$config.default_context_size = $defaultCtxSize

Write-Host "  -> Flash Attention Auto-Tuned to: $flashAttn" -ForegroundColor Green
Write-Host "  -> KV Cache Type Auto-Tuned to  : $cacheType" -ForegroundColor Green
Write-Host "  -> Context Size Auto-Tuned to   : $defaultCtxSize tokens" -ForegroundColor Green
Write-Host "  -> Context Shift Auto-Tuned to  : Enabled" -ForegroundColor Green

# 4. Optional Custom Arguments Override
$defaultCustom = if ($config.custom_args) { $config.custom_args } else { "" }
Write-Host "`nAdvanced users: You can add specific parameters to pass to llama-server (e.g. -ngl 70 -c 65536)." -ForegroundColor White
$customArgsInput = Get-UserInput "Enter any custom arguments to append (press Enter for none)" -DefaultVal $defaultCustom
$config.custom_args = $customArgsInput

# Step 3: Integrations & Usage
Write-Host "`nStep 3: Integration Configuration..." -ForegroundColor Cyan
Write-Host "Where do you plan to use llama.cpp? Select integrations (comma-separated numbers, e.g. 1,3):" -ForegroundColor White
Write-Host "  1) VSCode Workspace tasks & shortcuts" -ForegroundColor DarkGray
Write-Host "  2) Claude Code CLI Client (env settings)" -ForegroundColor DarkGray
Write-Host "  3) Cursor / Continue IDE plug-ins" -ForegroundColor DarkGray
Write-Host "  4) Droid / GitHub CLI / Other Client" -ForegroundColor DarkGray
Write-Host "  5) Server only (Direct REST API calls)" -ForegroundColor DarkGray

$defaultIntegrations = if ($config.integrations.Count -gt 0) { $config.integrations -join "," } else { "5" }
$integrationInput = Get-UserInput "Select integrations" -DefaultVal $defaultIntegrations

$selectedIntegrations = New-Object System.Collections.Generic.List[string]
$choices = $integrationInput -split ","
foreach ($c in $choices) {
    switch ($c.Trim()) {
        "1" { $selectedIntegrations.Add("vscode") }
        "2" { $selectedIntegrations.Add("claude-code") }
        "3" { $selectedIntegrations.Add("cursor-continue") }
        "4" { $selectedIntegrations.Add("other") }
        "5" { $selectedIntegrations.Add("server-only") }
    }
}
if ($selectedIntegrations.Count -eq 0) { $selectedIntegrations.Add("server-only") }
$config.integrations = $selectedIntegrations.ToArray()

# Step 4: Proposed Configuration Preview
Write-Host "`nStep 4: Proposed Configuration Preview..." -ForegroundColor Cyan

# Display Setup Preview Summary
Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host "              PROPOSED SYSTEM CONFIGURATION" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Green
if ($hw) {
    Write-Host "  [System Hardware]" -ForegroundColor Cyan
    Write-Host "    * CPU : $($hw.CPU.Name) ($($hw.CPU.PhysicalCores) cores)" -ForegroundColor White
    Write-Host "    * RAM : $($hw.RAM.TotalGB) GB (Budget: $($hw.RAM.BudgetMB) MB)" -ForegroundColor White
    Write-Host "    * GPU : $($hw.GPU.Name) ($([math]::Round($hw.GPU.TotalVramMB/1024, 1)) GB VRAM)" -ForegroundColor White
    Write-Host "    * Threads: $($hw.CPU.OptimalThreads) (Recommended for inference)" -ForegroundColor White
}
Write-Host "`n  [Paths & Installation]" -ForegroundColor Cyan
Write-Host "    * Install Type: $($config.installation_type)" -ForegroundColor White
Write-Host "    * llama-server: $($config.llama_server_path)" -ForegroundColor White
if ($config.llama_repo_path) {
    Write-Host "    * Repo Path   : $($config.llama_repo_path)" -ForegroundColor White
}
Write-Host "    * Models Dir  : $($config.models_dir)" -ForegroundColor White
Write-Host "    * Templates Dir: $($config.templates_dir)" -ForegroundColor White
Write-Host "`n  [Optimizations & Performance]" -ForegroundColor Cyan
Write-Host "    * Flash Attention: $($config.flash_attn)" -ForegroundColor White
Write-Host "    * KV Cache Type  : $($config.cache_type_k)" -ForegroundColor White
Write-Host "    * Context Size   : $($config.default_context_size) tokens" -ForegroundColor White
Write-Host "    * Context Shift  : $(if ($config.context_shift) { 'Enabled' } else { 'Disabled' })" -ForegroundColor White
if ($config.custom_args) {
    Write-Host "    * Custom Args    : $($config.custom_args)" -ForegroundColor White
}
Write-Host "`n  [Selected Integrations]" -ForegroundColor Cyan
foreach ($int in $config.integrations) {
    Write-Host "    * $int" -ForegroundColor White
}
Write-Host "==========================================================" -ForegroundColor Green

$apply = Get-UserInput "Apply and save this configuration? (Y/N/Update)" -DefaultVal "Y"

if ($apply.ToUpper() -eq "Y") {
    # Save config to llo-config.json
    $config | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigFile -Encoding UTF8
    Write-Host "`n[OK] Configuration saved successfully to llo-config.json!" -ForegroundColor Green
    
    # Run SetupRouter.ps1 to write presets.ini
    Write-Host "Running router configuration setup..." -ForegroundColor Cyan
    $setupRouterScript = Join-Path $ManagerDir "llo-core\SetupRouter.ps1"
    if (Test-Path $setupRouterScript) {
        . $setupRouterScript | Out-Null
        Write-Host "[OK] Presets updated inside models-preset.ini." -ForegroundColor Green
    } else {
        Write-Host "[WARNING] SetupRouter.ps1 not found, presets were not generated." -ForegroundColor Yellow
    }

    # Integration specific guidance or writing
    if ($config.integrations -contains "vscode") {
        Write-Host "`n[VSCode Integration] Tasks and environment settings have been registered." -ForegroundColor Yellow
        Write-Host "  You can start and stop the server directly from VSCode (Ctrl+Shift+B -> Select Task)." -ForegroundColor DarkGray
    }
    if ($config.integrations -contains "claude-code") {
        Write-Host "`n[Claude Code Integration] Recommended Environment Variables:" -ForegroundColor Yellow
        Write-Host "  Set-Item env:OPENAI_API_KEY 'local-key'" -ForegroundColor DarkGray
        Write-Host "  Set-Item env:OPENAI_BASE_URL 'http://127.0.0.1:8080/v1'" -ForegroundColor DarkGray
    }
    
    # Run server prompt
    $startNow = Get-UserInput "`nWould you like to start the llama-server now? (Y/N)" -DefaultVal "Y"
    if ($startNow.ToUpper() -eq "Y") {
        Write-Host "`nStarting server..." -ForegroundColor Cyan
        $startServerScript = Join-Path $ManagerDir "script\start-server.ps1"
        if (Test-Path $startServerScript) {
            # Start-Process in new window so it runs persistently without blocking the setup console
            Start-Process powershell -ArgumentList "-NoExit", "-File", "`"$startServerScript`""
            Write-Host "[OK] llama-server has been launched in a new window." -ForegroundColor Green
        } else {
            Write-Host "[ERROR] start-server.ps1 not found in script/." -ForegroundColor Red
        }
    }
}
elseif ($apply.ToUpper() -eq "UPDATE" -or $apply.ToUpper() -eq "U") {
    Write-Host "`nRestarting setup wizard..." -ForegroundColor Yellow
    Start-Sleep -Seconds 1
    # Re-run the script
    . $MyInvocation.MyCommand.Path
}
else {
    Write-Host "`nSetup aborted. Configuration not saved." -ForegroundColor Yellow
}
