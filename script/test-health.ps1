# LLO test-health.ps1
# Verifies the health and integrity of all llm-manager scripts, configs, and hardware profile APIs.

param(
    [string]$ConfigFile = ""
)

$ErrorActionPreference = "Stop"

$ScriptDir = $PSScriptRoot
$ManagerDir = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir ".."))
if ([string]::IsNullOrWhiteSpace($ConfigFile)) {
    $ConfigFile = Join-Path $ManagerDir "llo-config.json"
}
$PresetFile = Join-Path $ManagerDir "models-preset.ini"

Write-Host "==========================================================" -ForegroundColor Green
Write-Host "            LLM MANAGER INTEGRITY & HEALTH TEST" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Green

$globalPass = $true

function Report-Result {
    param(
        [string]$TestName,
        [boolean]$Success,
        [string]$Detail = ""
    )
    if ($Success) {
        Write-Host "[PASS] $TestName" -ForegroundColor Green
        if ($Detail) { Write-Host "       $Detail" -ForegroundColor DarkGray }
    } else {
        Write-Host "[FAIL] $TestName" -ForegroundColor Red
        if ($Detail) { Write-Host "       Error: $Detail" -ForegroundColor Red }
        $script:globalPass = $false
    }
}

# Check 1: PowerShell Syntax Validity (AST Parser)
Write-Host "`n[Check 1] Auditing PowerShell Syntax..." -ForegroundColor Cyan
$scripts = Get-ChildItem -Path $ManagerDir -Filter *.ps1 -Recurse
$syntaxFailures = 0
foreach ($s in $scripts) {
    if ($s.Name -eq "test-health.ps1") { continue }
    $errors = $null
    $tokens = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($s.FullName, [ref]$tokens, [ref]$errors)
    if ($errors) {
        $syntaxFailures++
        Write-Host "  ! Syntax Error in $($s.FullName):" -ForegroundColor Red
        foreach ($e in $errors) {
            Write-Host "    Line $($e.Extent.StartLineNumber): $($e.Message)" -ForegroundColor Red
        }
    } else {
        Write-Host "  -> Checked: $($s.Name)" -ForegroundColor DarkGray
    }
}
Report-Result -TestName "PowerShell Script Syntax Validation" -Success ($syntaxFailures -eq 0) -Detail $(if ($syntaxFailures -eq 0) { "All scripts parsed successfully." } else { "$syntaxFailures syntax error(s) found." })

# Check 2: Configuration Integrity
Write-Host "`n[Check 2] Verifying Configuration Schema..." -ForegroundColor Cyan
if (Test-Path $ConfigFile) {
    try {
        $loaded = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        $keys = $loaded.PSObject.Properties.Name
        $requiredKeys = @("installation_type", "llama_server_path", "models_dir", "cache_type_k", "flash_attn")
        $missing = @()
        foreach ($rk in $requiredKeys) {
            if ($rk -notin $keys) { $missing += $rk }
        }
        Report-Result -TestName "Config JSON Format & Keys Check" -Success ($missing.Count -eq 0) -Detail $(if ($missing.Count -eq 0) { "Schema is valid and complete." } else { "Missing keys: $($missing -join ', ')" })
    } catch {
        Report-Result -TestName "Config JSON Format & Keys Check" -Success $false -Detail $_.Exception.Message
    }
} else {
    Report-Result -TestName "Config JSON Format & Keys Check" -Success $true -Detail "llo-config.json not initialized yet (normal before first setup)."
}

# Check 3: Profile System API Compatibility
Write-Host "`n[Check 3] Testing Hardware Profiler..." -ForegroundColor Cyan
$profileScript = Join-Path $ManagerDir "llo-core\Profile.ps1"
if (Test-Path $profileScript) {
    try {
        . $profileScript
        $hw = Get-SystemHardwareProfile
        $success = $null -ne $hw.CPU -and $null -ne $hw.RAM
        $detail = "CPU: $($hw.CPU.Name), RAM: $($hw.RAM.TotalGB) GB"
        if ($hw.GPU) { $detail += ", GPU: $($hw.GPU.Name) ($($hw.GPU.TotalVramMB) MB VRAM)" }
        Report-Result -TestName "Hardware Profiling Execution" -Success $success -Detail $detail
    } catch {
        Report-Result -TestName "Hardware Profiling Execution" -Success $false -Detail $_.Exception.Message
    }
} else {
    Report-Result -TestName "Hardware Profiling Execution" -Success $false -Detail "Profile.ps1 script is missing."
}

# Check 4: Preset Configuration Generator Check
Write-Host "`n[Check 4] Testing SetupRouter Execution..." -ForegroundColor Cyan
$setupRouterScript = Join-Path $ManagerDir "llo-core\SetupRouter.ps1"
if (Test-Path $setupRouterScript) {
    try {
        # Run SetupRouter inside a dry-run/mock context (temporary outputs)
        $tempDir = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { '/tmp' }
        $tempPreset = Join-Path $tempDir "models-preset-test.ini"
        $tempConfig = Join-Path $tempDir "llo-config-test.json"
        if (Test-Path $ConfigFile) { Copy-Item $ConfigFile $tempConfig }
        
        $modelsList = & $setupRouterScript -PresetFile $tempPreset -ConfigFile $tempConfig
        $success = $null -ne $modelsList
        Report-Result -TestName "SetupRouter Execution Test" -Success $success -Detail "Router generated models list successfully. Found $($modelsList.Count) models."
        
        # Clean up temporary test files
        if (Test-Path $tempPreset) { Remove-Item $tempPreset -Force }
        if (Test-Path $tempConfig) { Remove-Item $tempConfig -Force -ErrorAction SilentlyContinue }
    } catch {
        Report-Result -TestName "SetupRouter Execution Test" -Success $false -Detail $_.Exception.Message
    }
} else {
    Report-Result -TestName "SetupRouter Execution Test" -Success $false -Detail "SetupRouter.ps1 script is missing."
}

# Check 5: Live Server API Connectivity Check (Optional/Informational)
Write-Host "`n[Check 5] Testing Active llama-server Connectivity..." -ForegroundColor Cyan
$targetPort = 8080
$openaiBaseUrl = "http://127.0.0.1:$targetPort/v1"
$pingSuccess = $true
$pingDetail = "Server is not running on port $targetPort (offline/normal)."

try {
    $tcpConnection = New-Object System.Net.Sockets.TcpClient
    $connectionTask = $tcpConnection.BeginConnect("127.0.0.1", $targetPort, $null, $null)
    $success = $connectionTask.AsyncWaitHandle.WaitOne(1000, $false)
    if ($success) {
        $tcpConnection.EndConnect($connectionTask)
        $tcpConnection.Close()
        
        # Port is open, test API
        $resp = Invoke-RestMethod -Uri "$openaiBaseUrl/models" -TimeoutSec 3
        if ($resp -and $resp.data) {
            $modelList = @($resp.data | ForEach-Object { $_.id }) -join ", "
            $pingDetail = "Server is live! Available models: $modelList"
        } else {
            $pingDetail = "Port $targetPort is open, but API returned invalid response."
            $pingSuccess = $false
        }
    }
} catch {
    $pingDetail = "Failed to query server: $($_.Exception.Message)"
    $pingSuccess = $false
}
Report-Result -TestName "Live Server API Ping Check" -Success $pingSuccess -Detail $pingDetail

# Final Health Verdict
Write-Host "`n==========================================================" -ForegroundColor Green
if ($globalPass) {
    Write-Host "         VERDICT: ALL SYSTEMS HEALTHY & VALID" -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Green
    exit 0
} else {
    Write-Host "         VERDICT: HEALTH CHECKS FAILED (SEE LOGS)" -ForegroundColor Red
    Write-Host "==========================================================" -ForegroundColor Red
    exit 1
}
