# LLM Manager Main Setup Wizard (main.ps1)
# Interactive setup entry point.

$ErrorActionPreference = "Stop"
$ManagerDir = $PSScriptRoot
$Version = "1.1.0"

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
Write-Host "      LLM MANAGER - INTERACTIVE SETUP WIZARD (v$Version)" -ForegroundColor Cyan
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
    $idx = 0
    if ($choice -match '^\d+$') {
        $idx = [int]$choice - 1
    } else {
        $idx = $DefaultChoice - 1
    }
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
    templates_dir = ""                 # resolved dynamically during setup
    use_default_template = $false
    cache_type_k = "f16"
    cache_type_v = "f16"
    flash_attn = "auto"
    context_shift = $true
    # Optimization parameters (auto-tuned by wizard; overridable in llo-config.json)
    fit_ctx_min = 8192          # minimum context --fit is allowed to reduce to
    cache_reuse_chunk = 256     # min prefix chunk size for KV cache reuse (0=off)
    ubatch_size = 512           # physical GPU batch size per kernel call
    parallel_slots = 1          # max concurrent request slots
    cache_idle_slots = $true    # cache KV state of idle slots between requests
    spec_type = "none"          # speculative decoding type (none | ngram-simple)
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
    claude_disable_telemetry = $true
}

# Load existing configuration if available
if (Test-Path $ConfigFile) {
    try {
        $loaded = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        foreach ($k in $loaded.PSObject.Properties.Name) {
            $config[$k] = $loaded.$k
        }
        Write-Host "[INFO] Loaded existing configuration from llo-config.json.`n" -ForegroundColor DarkGray
    } catch {
        Write-Host "[WARNING] Failed to load configuration from llo-config.json: $($_.Exception.Message)" -ForegroundColor Yellow
    }
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

# Step 2.1: Jinja Chat Template Configuration
Write-Host "`nStep 2.1: Jinja Chat Template Configuration..." -ForegroundColor Cyan
# Templates live alongside the llm-manager folder, not derived from the models directory
$templatesDir = Join-Path $ManagerDir "templates"
if (-not (Test-Path $templatesDir)) {
    try {
        New-Item -ItemType Directory -Path $templatesDir -Force | Out-Null
    } catch {}
}
$config.templates_dir = $templatesDir

# Copy packaged default.jinja to active templates folder if missing
$defaultTemplateDest = Join-Path $templatesDir "default.jinja"
$packagedTemplateSource = Join-Path $ManagerDir "templates\default.jinja"
if (-not (Test-Path $defaultTemplateDest) -and (Test-Path $packagedTemplateSource)) {
    try {
        Copy-Item -Path $packagedTemplateSource -Destination $defaultTemplateDest -Force | Out-Null
        Write-Host "  [OK] Copied default template to: $defaultTemplateDest" -ForegroundColor Green
    } catch {
        Write-Host "  [WARNING] Failed to copy default template: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

$defaultUseTemplate = if ($null -ne $config.use_default_template) { if ($config.use_default_template) { "Y" } else { "N" } } else { "N" }
Write-Host "A default chat template (default.jinja) is available in $templatesDir." -ForegroundColor White
Write-Host "[WARNING] Using a custom default template is optional. If you see chat formatting or system instruction issues, select 'N' to fall back to the models' built-in GGUF internal templates." -ForegroundColor Yellow
$useDefaultTemplateInput = Get-UserInput "Apply default.jinja template to all local models? (Y/N)" -DefaultVal $defaultUseTemplate
$config.use_default_template = ($useDefaultTemplateInput.ToUpper() -eq "Y")

# Step 2.2: Automated Memory & Performance Optimization
Write-Host "`nStep 2.2: Automatically tuning performance parameters for your system..." -ForegroundColor Cyan

$flashAttn = "auto"
$cacheType = "f16"
$contextShift = $true
$fitCtxMin = 8192
$cacheReuseChunk = 256
$ubatchSize = 512
$parallelSlots = 1

if ($hw) {
    $vramGB = if ($hw.GPU -and $hw.GPU.TotalVramMB -gt 0) { $hw.GPU.TotalVramMB / 1024 } else { 0 }

    # 1. Enable Flash Attention if GPU is present
    if ($vramGB -gt 0) { $flashAttn = "on" }

    # 2. Heuristically select KV Cache quantization to prevent VRAM bottlenecks
    if ($vramGB -gt 0) {
        if ($vramGB -lt 6.0) {
            $cacheType = "q4_0"   # Max VRAM savings for low-end GPUs
        } elseif ($vramGB -lt 12.0) {
            $cacheType = "q8_0"   # Balanced savings for mid-range GPUs (like RTX 5060)
        } else {
            $cacheType = "f16"    # High precision for high-end GPUs
        }
    } else {
        # CPU-only: Flash Attention is off on CPU, which strictly prevents KV cache quantization
        $cacheType = "f16"
    }

    # 3. Heuristically select context size to balance VRAM and capacity
    $defaultCtxSize = 65536
    if ($vramGB -gt 0) {
        if ($vramGB -le 8.0) {
            $defaultCtxSize = 32768    # 32k limits VRAM footprint for <= 8GB cards
        } elseif ($vramGB -ge 16.0) {
            $defaultCtxSize = 131072   # 128k for high-end GPUs
        }
    }

    # 4. Safe minimum context floor for --fit (prevents silent truncation)
    if ($vramGB -le 8.0) {
        $fitCtxMin = 8192   # 8K floor: keeps models usable on tight VRAM
    } else {
        $fitCtxMin = 16384  # 16K floor for larger cards
    }

    # 5. Physical GPU micro-batch size (higher = better throughput, more VRAM peak)
    if ($vramGB -lt 6.0) {
        $ubatchSize = 256    # Reduce memory spikes on very small GPUs
    } elseif ($vramGB -lt 12.0) {
        $ubatchSize = 512    # Safe balance for 8GB class GPUs
    } else {
        $ubatchSize = 1024   # Maximize throughput on 12GB+ cards
    }

    # 6. Parallel slots: cap to 1 on VRAM-limited GPUs to prevent OOM
    if ($vramGB -le 8.0) {
        $parallelSlots = 1   # Single-slot safe mode for 8GB VRAM
    } else {
        $parallelSlots = -1  # Auto (let llama-server decide) for larger cards
    }
}

$config.cache_type_k = $cacheType
$config.cache_type_v = $cacheType
$config.flash_attn = $flashAttn
$config.context_shift = $contextShift
$config.default_context_size = $defaultCtxSize
$config.fit_ctx_min = $fitCtxMin
$config.cache_reuse_chunk = $cacheReuseChunk
$config.ubatch_size = $ubatchSize
$config.parallel_slots = $parallelSlots
$config.cache_idle_slots = $true   # always safe to enable

Write-Host "  -> Flash Attention    : $flashAttn" -ForegroundColor Green
Write-Host "  -> KV Cache Type      : $cacheType" -ForegroundColor Green
Write-Host "  -> Context Size       : $defaultCtxSize tokens" -ForegroundColor Green
Write-Host "  -> Context Shift      : Enabled" -ForegroundColor Green
Write-Host "  -> Fit Ctx Floor      : $fitCtxMin tokens (--fit will not go below this)" -ForegroundColor Green
Write-Host "  -> UBatch Size        : $ubatchSize tokens/kernel" -ForegroundColor Green
Write-Host "  -> Parallel Slots     : $(if ($parallelSlots -eq -1) { 'Auto' } else { $parallelSlots })" -ForegroundColor Green
Write-Host "  -> KV Cache Reuse     : Enabled ($cacheReuseChunk token prefix threshold)" -ForegroundColor Green
Write-Host "  -> Idle Slot Caching  : Enabled" -ForegroundColor Green

# Optional: Speculative decoding via n-gram (no draft model required)
Write-Host "`n[Optional] N-Gram Speculative Decoding" -ForegroundColor Yellow
Write-Host "  Enabling 'ngram-simple' can improve generation speed by ~10-15%." -ForegroundColor DarkGray
Write-Host "  It works purely from token history - no secondary draft model needed." -ForegroundColor DarkGray
Write-Host "  Works well with coding models (Qwen, etc.). May be less effective on reasoning models." -ForegroundColor DarkGray
$defaultSpecChoice = if ($config.spec_type -and $config.spec_type -ne "none") { "Y" } else { "N" }
$enableSpec = Get-UserInput "Enable ngram-simple speculative decoding? (Y/N)" -DefaultVal $defaultSpecChoice
$config.spec_type = if ($enableSpec.ToUpper() -eq "Y") { "ngram-simple" } else { "none" }

# 4. Optional Custom Arguments Override
$defaultCustom = if ($config.custom_args) { $config.custom_args } else { "" }
Write-Host "`nAdvanced users: You can add specific parameters to pass to llama-server (e.g. -ngl 70 -c 65536)." -ForegroundColor White
if ($defaultCustom) {
    Write-Host "Current custom args: $defaultCustom" -ForegroundColor DarkGray
    Write-Host "Press Enter to keep current value, type 'none' to clear, or enter new arguments." -ForegroundColor DarkGray
}
$customArgsInput = Get-UserInput "Enter any custom arguments to append (press Enter for none)" -DefaultVal $defaultCustom
# Allow user to explicitly clear custom args by typing 'none' or 'clear'
if ($customArgsInput -and $customArgsInput.Trim().ToLower() -in @("none", "clear")) {
    $customArgsInput = ""
}
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

# 4.1 Prompt for Claude Code Telemetry option if selected
if ($config.integrations -contains "claude-code") {
    Write-Host "`n[Claude Code Model Switching & Telemetry Option]" -ForegroundColor Cyan
    Write-Host "To allow switching models dynamically via the '/model' command, Claude Code requires telemetry (non-essential traffic) to be enabled." -ForegroundColor White
    $defaultSwitch = if ($config.ContainsKey("claude_disable_telemetry") -and $config.claude_disable_telemetry -eq $false) { "Y" } else { "N" }
    $switchChoice = Get-UserInput "Enable dynamic local model switching (enables telemetry)? (Y/N)" -DefaultVal $defaultSwitch
    $config.claude_disable_telemetry = if ($switchChoice.ToUpper() -eq "Y") { $false } else { $true }
}

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
Write-Host "    * Default Template: $(if ($config.use_default_template) { 'Applied (default.jinja)' } else { 'Disabled (Using GGUF internal templates)' })" -ForegroundColor White
Write-Host "`n  [Optimizations & Performance]" -ForegroundColor Cyan
Write-Host "    * Flash Attention : $($config.flash_attn)" -ForegroundColor White
Write-Host "    * KV Cache Type   : $($config.cache_type_k)" -ForegroundColor White
Write-Host "    * Context Size    : $($config.default_context_size) tokens" -ForegroundColor White
Write-Host "    * Context Shift   : $(if ($config.context_shift) { 'Enabled' } else { 'Disabled' })" -ForegroundColor White
Write-Host "    * Fit Ctx Floor   : $($config.fit_ctx_min) tokens" -ForegroundColor White
Write-Host "    * UBatch Size     : $($config.ubatch_size) tokens" -ForegroundColor White
Write-Host "    * Parallel Slots  : $(if ($config.parallel_slots -eq -1) { 'Auto' } elseif ($config.parallel_slots -eq 1) { '1 (Safe mode - prevents OOM)' } else { $config.parallel_slots })" -ForegroundColor White
Write-Host "    * KV Cache Reuse  : $(if ($config.cache_reuse_chunk -gt 0) { "Enabled ($($config.cache_reuse_chunk) token chunks)" } else { 'Disabled' })" -ForegroundColor White
Write-Host "    * Idle Slot Cache : $(if ($config.cache_idle_slots) { 'Enabled' } else { 'Disabled' })" -ForegroundColor White
Write-Host "    * Speculative Dec : $(if ($config.spec_type -ne 'none') { $config.spec_type } else { 'Disabled' })" -ForegroundColor White
if ($config.custom_args) {
    Write-Host "    * Custom Args     : $($config.custom_args)" -ForegroundColor White
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
        Write-Host "`n[VSCode Integration] Registering tasks and environment settings..." -ForegroundColor Yellow
        try {
            $vsCodeDir = Join-Path $ManagerDir ".vscode"
            if (-not (Test-Path $vsCodeDir)) {
                New-Item -ItemType Directory -Force -Path $vsCodeDir | Out-Null
            }
            
            # Write tasks.json if not present
            $tasksFile = Join-Path $vsCodeDir "tasks.json"
            if (-not (Test-Path $tasksFile)) {
                $tasksJson = @{
                    version = "2.0.0"
                    tasks = @(
                        @{
                            label = "Start LLM Server"
                            type = "shell"
                            command = "powershell.exe"
                            args = @("-ExecutionPolicy", "Bypass", "-File", "${workspaceFolder}/script/start-server.ps1")
                            group = "none"
                            presentation = @{ reveal = "always"; panel = "new"; focus = $true; close = $false }
                            problemMatcher = @()
                        },
                        @{
                            label = "Stop LLM Server"
                            type = "shell"
                            command = "powershell.exe"
                            args = @("-ExecutionPolicy", "Bypass", "-File", "${workspaceFolder}/script/stop-server.ps1")
                            group = "none"
                            presentation = @{ reveal = "always"; panel = "dedicated"; focus = $false; close = $true }
                            problemMatcher = @()
                        },
                        @{
                            label = "Audit Script Compatibility"
                            type = "shell"
                            command = "powershell.exe"
                            args = @("-ExecutionPolicy", "Bypass", "-File", "${workspaceFolder}/script/verify-scripts.ps1")
                            group = "none"
                            presentation = @{ reveal = "always"; panel = "new"; focus = $true; close = $false }
                            problemMatcher = @()
                        }
                    )
                }
                $tasksJson | ConvertTo-Json -Depth 5 | Set-Content -Path $tasksFile -Encoding UTF8
            }
            
            # Write/Update settings.json
            $settingsFile = Join-Path $vsCodeDir "settings.json"
            $settings = @{
                "terminal.integrated.env.windows" = @{
                    "LLAMA_BASE_URL" = "http://127.0.0.1:8080"
                    "LLAMA_OPENAI_BASE_URL" = "http://127.0.0.1:8080/v1"
                    "OPENAI_BASE_URL" = "http://127.0.0.1:8080/v1"
                    "OPENAI_API_BASE" = "http://127.0.0.1:8080/v1"
                    "OPENAI_API_KEY" = "local-key"
                    "ANTHROPIC_BASE_URL" = "http://127.0.0.1:8080"
                    "ANTHROPIC_AUTH_TOKEN" = "local"
                    "ANTHROPIC_API_KEY" = "local-key"
                    "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY" = "1"
                    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" = "1"
                }
                "llmManager.integrationGuide" = @{
                    "claudeCode" = "Run: `$env:ANTHROPIC_BASE_URL='http://127.0.0.1:8080'; `$env:ANTHROPIC_AUTH_TOKEN='local'; `$env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1'; claude"
                    "continueExtension" = "Configure config.json with a provider of type 'openai' and apiBase 'http://127.0.0.1:8080/v1'"
                    "cursor" = "Go to settings -> Models -> OpenAI -> Base URL: http://localhost:8080/v1, API Key: local-key"
                }
            }
            $settings | ConvertTo-Json -Depth 5 | Set-Content -Path $settingsFile -Encoding UTF8
            Write-Host "  [OK] VSCode workspace configuration updated successfully." -ForegroundColor Green
            Write-Host "  You can start and stop the server directly from VSCode (Ctrl+Shift+B -> Select Task)." -ForegroundColor DarkGray
        } catch {
            Write-Host "  [WARNING] Failed to write VSCode workspace files: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    if ($config.integrations -contains "claude-code") {
        Write-Host "`n[Claude Code Integration] Recommended Environment Variables:" -ForegroundColor Yellow
        Write-Host "  Set-Item env:ANTHROPIC_BASE_URL 'http://127.0.0.1:8080'" -ForegroundColor DarkGray
        Write-Host "  Set-Item env:ANTHROPIC_AUTH_TOKEN 'local'" -ForegroundColor DarkGray
        $disableTeleVal = if ($config.claude_disable_telemetry -eq $false) { "0" } else { "1" }
        Write-Host "  Set-Item env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC '$disableTeleVal'" -ForegroundColor DarkGray
        if ($disableTeleVal -eq "0") {
            Write-Host "  Set-Item env:CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY '1'" -ForegroundColor DarkGray
            Write-Host "    * Note: Telemetry is enabled (needed to use '/model' to switch models dynamically)." -ForegroundColor DarkYellow
        } else {
            Write-Host "    * Note: Telemetry is disabled (blocks dynamic model discovery/switching via '/model')." -ForegroundColor DarkYellow
        }
    }
    if ($config.integrations -contains "cursor-continue") {
        Write-Host "`n[Cursor / Continue Integration] Configuration Guidance:" -ForegroundColor Yellow
        Write-Host "  * Cursor: Go to Settings -> Models -> OpenAI compatible:" -ForegroundColor DarkGray
        Write-Host "    - Base URL: http://127.0.0.1:8080/v1" -ForegroundColor DarkGray
        Write-Host "    - API Key:  local-key" -ForegroundColor DarkGray
        Write-Host "  * Continue: Add the following block to your config.json 'models' array:" -ForegroundColor DarkGray
        Write-Host "    {`n      `"title`": `"Local GGUF Model`",`n      `"provider`": `"openai`",`n      `"model`": `"any-model-name`",`n      `"apiBase`": `"http://127.0.0.1:8080/v1`",`n      `"apiKey`": `"local-key`"`n    }" -ForegroundColor DarkGray
    }
    if ($config.integrations -contains "other") {
        Write-Host "`n[GitHub CLI & Other Client Integration] Recommended Environment Variables:" -ForegroundColor Yellow
        Write-Host "  Set-Item env:OPENAI_BASE_URL 'http://127.0.0.1:8080/v1'" -ForegroundColor DarkGray
        Write-Host "  Set-Item env:OPENAI_API_KEY 'local-key'" -ForegroundColor DarkGray
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
    # Re-run the script in a fresh child scope using the call operator
    & $MyInvocation.MyCommand.Path
}
else {
    Write-Host "`nSetup aborted. Configuration not saved." -ForegroundColor Yellow
}
