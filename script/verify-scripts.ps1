# LLO verify-scripts.ps1
# Audits custom runner scripts for flag compatibility and checks llama.cpp repository branch freshness.

param(
    [string]$LlamaRepoPath = "",
    [string]$LlamaServerPath = ""
)

$ErrorActionPreference = "Stop"

$ManagerDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$CacheFile = Join-Path $ManagerDir ".cached_flags.json"
$DocsDir = Join-Path $ManagerDir "docs"
$SystemCommandsDoc = Join-Path $DocsDir "SYSTEM_COMMANDS.md"
$ConfigFile = Join-Path $ManagerDir "llo-config.json"

# Load config to get paths if parameters are not provided
$config = @{}
if (Test-Path $ConfigFile) {
    try {
        $loaded = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        foreach ($k in $loaded.PSObject.Properties.Name) {
            $config[$k] = $loaded.$k
        }
    } catch {}
}

if ([string]::IsNullOrWhiteSpace($LlamaServerPath)) {
    if ($config.llama_server_path) {
        $LlamaServerPath = $config.llama_server_path
    } else {
        $LlamaServerPath = "llama-server"
    }
}
if ([string]::IsNullOrWhiteSpace($LlamaRepoPath)) {
    if ($config.llama_repo_path) {
        $LlamaRepoPath = $config.llama_repo_path
    }
}

# 1. Load Core Diffs and Status
$gitDiffScript = Join-Path $ManagerDir "llo-core\GitDiff.ps1"
$helpParserScript = Join-Path $ManagerDir "llo-core\ParseHelp.ps1"

if (-not (Test-Path $gitDiffScript) -or -not (Test-Path $helpParserScript)) {
    throw "Core scripts GitDiff.ps1 or ParseHelp.ps1 not found in llo-core/"
}

# Run Git branch check
$gitStatus = $null
if ($LlamaRepoPath -and (Test-Path $LlamaRepoPath)) {
    . $gitDiffScript
    $gitStatus = Get-LlamaGitStatus -RepoPath $LlamaRepoPath
} else {
    Write-Host "[INFO] llama.cpp repository path not configured or not found. Skipping upstream Git check." -ForegroundColor Cyan
    $gitStatus = [pscustomobject]@{
        Branch = "N/A"
        IsLatest = $true
        StatusMessage = "Repository path not configured or not found (Pre-built binary mode)"
        Commits = @()
    }
}

# Run Help option diff checker
. $helpParserScript
$optionDiff = Update-CachedFlags -ServerPath $LlamaServerPath -CachePath $CacheFile
$cachedFlags = Get-Content $CacheFile -Raw | ConvertFrom-Json
$allowedLongFlags = @($cachedFlags | ForEach-Object { $_.Long })

Write-Host "`n--- System Script Compatibility Audit ---" -ForegroundColor Cyan

# 2. Check Branch Status
if (-not $gitStatus.IsLatest) {
    Write-Host "[WARNING] llama.cpp branch '$($gitStatus.Branch)' is NOT up to date!" -ForegroundColor Yellow
    Write-Host "  Reason: $($gitStatus.StatusMessage)" -ForegroundColor Yellow
    Write-Host "  Action: We recommend running 'git pull' in $($LlamaRepoPath) and rebuilding to get updates." -ForegroundColor Yellow
} else {
    Write-Host "[OK] llama.cpp repository is up-to-date on branch '$($gitStatus.Branch)'." -ForegroundColor Green
}

# 3. Check for New/Deprecated Options
if ($optionDiff.Added.Count -gt 0) {
    Write-Host "[INFO] $($optionDiff.Added.Count) new option(s) are available in the current llama-server build." -ForegroundColor Cyan
    $optionDiff.Added | ForEach-Object { Write-Host "  + $($_.Long) : $($_.Description)" -ForegroundColor DarkGray }
}
if ($optionDiff.Removed.Count -gt 0) {
    Write-Host "[WARNING] $($optionDiff.Removed.Count) option(s) have been deprecated or removed in the current build." -ForegroundColor Yellow
    $optionDiff.Removed | ForEach-Object { Write-Host "  - $($_.Long)" -ForegroundColor Red }
}

# 4. Scan PowerShell scripts in manager folders for invalid flags
$scriptsDir = Join-Path $ManagerDir "script"
$scriptsToScan = Get-ChildItem -Path $scriptsDir -Filter *.ps1 -File
$siblingScriptDir = [System.IO.Path]::GetFullPath((Join-Path $ManagerDir "..\script"))
if (Test-Path $siblingScriptDir) {
    $scriptsToScan += Get-ChildItem -Path $siblingScriptDir -Filter *.ps1 -File -ErrorAction SilentlyContinue
}

$auditClean = $true

foreach ($s in $scriptsToScan) {
    Write-Host "Auditing script: $($s.Name)..." -ForegroundColor Cyan
    $content = Get-Content $s.FullName -Raw
    
    # Extract flags matching --[a-zA-Z0-9-]+
    $flagsFound = [regex]::Matches($content, '--[a-zA-Z0-9-]+') | ForEach-Object { $_.Value } | Select-Object -Unique
    
    # Exclude standard double-hyphen non-arguments (like --format in query-gpu etc.)
    $excludeList = @("--query-gpu", "--format", "--oneline", "--no-merges", "--show-current")
    
    $incompatibles = New-Object System.Collections.Generic.List[string]

    foreach ($f in $flagsFound) {
        if ($excludeList -contains $f) { continue }
        
        # Verify if flag is present in compiled binary's parsed options
        if ($allowedLongFlags -notcontains $f) {
            $incompatibles.Add($f)
        }
    }

    if ($incompatibles.Count -gt 0) {
        $auditClean = $false
        Write-Host "  [FAIL] Script uses incompatible or removed arguments:" -ForegroundColor Red
        foreach ($inc in $incompatibles) {
            Write-Host "    * $inc" -ForegroundColor Red
        }
    } else {
        Write-Host "  [OK] Script is fully compatible." -ForegroundColor Green
    }
}

# 5. Generate / Update docs/SYSTEM_COMMANDS.md
if (-not (Test-Path $DocsDir)) {
    New-Item -ItemType Directory -Force -Path $DocsDir | Out-Null
}

$hardwareScript = Join-Path $ManagerDir "llo-core\Profile.ps1"
. $hardwareScript
$hw = Get-SystemHardwareProfile

$docLines = @(
    "# LLM Manager System Compatibility Documentation",
    "",
    "Generated on: $($hw.Timestamp)",
    "",
    "## 1. System Hardware Profile",
    "",
    "- **CPU**: $($hw.CPU.Name)",
    "  - Cores: $($hw.CPU.PhysicalCores) Physical / $($hw.CPU.LogicalCores) Logical",
    "  - Recommended Inference Threads: $($hw.CPU.OptimalThreads)",
    "- **System Memory (RAM)**: $($hw.RAM.TotalGB) GB",
    "  - Safe RAM Budget: $($hw.RAM.BudgetMB) MB",
    "- **GPU**: $($hw.GPU.Name)",
    "  - VRAM: $([math]::Round($hw.GPU.TotalVramMB/1024, 1)) GB",
    "  - Safe VRAM Budget: $($hw.GPU.BudgetVramMB) MB",
    "  - Driver / CUDA Version: $($hw.GPU.CudaDriver)",
    "",
    "## 2. Upstream Git & Build Status",
    "",
    "- **Repository**: ``llama.cpp``",
    "- **Branch**: ``$($gitStatus.Branch)``",
    "- **Status**: ``$($gitStatus.StatusMessage)``",
    "",
    "### Recent Changes Scan",
    "Below are recent commits with keywords that may affect performance or setup on your system:",
    ""
)

foreach ($c in $gitStatus.Commits) {
    $impactStr = if ($c.ImpactKeywords.Count -gt 0) { " *(Impact: " + ($c.ImpactKeywords -join ", ") + ")*" } else { "" }
    $docLines += "- ``$($c.Hash)``: $($c.Subject)$($impactStr)"
}

$docLines += @(
    "",
    "## 3. Options and Arguments Registry",
    "",
    "Below is the list of currently supported options retrieved from `llama-server --help`:",
    "",
    "| Flag | Value Token | Env Override | Description |",
    "| --- | --- | --- | --- |"
)

foreach ($f in $cachedFlags) {
    $short = if ($f.Short) { "``$($f.Short)``" } else { "-" }
    $env = if ($f.EnvVar) { "``$($f.EnvVar)``" } else { "-" }
    $val = if ($f.ValueToken) { "``$($f.ValueToken)``" } else { "-" }
    $docLines += "| ``$($f.Long)`` ($short) | $val | $env | $($f.Description) |"
}

Set-Content -Path $SystemCommandsDoc -Value $docLines -Encoding UTF8
Write-Host "Documentation updated at: $SystemCommandsDoc" -ForegroundColor Green

if ($auditClean) {
    Write-Host "Audit completed. System is fully compatible and clean.`n" -ForegroundColor Green
} else {
    Write-Host "Audit completed with warnings. Some runner scripts need updates.`n" -ForegroundColor Yellow
}
