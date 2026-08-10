# StartContextManager.ps1 — Launches the LLO Context Manager Proxy
param(
    [string]$ConfigFile = "",
    [int]$Port = 8090,
    [switch]$Foreground
)

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot
$ManagerDir = [System.IO.Path]::GetFullPath((Join-Path $ScriptDir ".."))

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

# 1. Read Config
$proxyPort = 8090
$cmEnabled = $true

if (Test-Path $ConfigFile) {
    try {
        $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        if ($cfg.PSObject.Properties.Name -contains "context_manager") {
            $cm = $cfg.context_manager
            if ($null -ne $cm.enabled) { $cmEnabled = [bool]$cm.enabled }
            if ($null -ne $cm.proxy_port -and [int]$cm.proxy_port -gt 0) { $proxyPort = [int]$cm.proxy_port }
        }
    } catch {
        Write-Host "[ContextManager] Warning: could not parse $ConfigFile; using defaults." -ForegroundColor Yellow
    }
}

if (-not $cmEnabled) {
    Write-Host "[ContextManager] Notice: context_manager.enabled is false in config. Proxy launch skipped." -ForegroundColor Yellow
    exit 0
}

# 2. Locate uv or python
$uvExe = Get-Command "uv" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
if (-not $uvExe) {
    $uvCandidates = @(
        (Join-Path $ManagerDir "uv.exe"),
        (Join-Path $ManagerDir "resources\uv.exe"),
        (Join-Path (Split-Path -Parent $ManagerDir) "uv.exe"),
        "$env:USERPROFILE\.cargo\bin\uv.exe",
        "$env:LOCALAPPDATA\uv\bin\uv.exe",
        "$env:USERPROFILE\.local\bin\uv.exe",
        "$env:USERPROFILE\.local\bin\uv",
        "$env:ProgramFiles\uv\uv.exe",
        "C:\tools\uv\uv.exe",
        "D:\tools\uv\uv.exe"
    )
    foreach ($c in $uvCandidates) {
        if ($c -and (Test-Path $c)) { $uvExe = $c; break }
    }
}

$pyExe = Get-Command "python" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
if (-not $pyExe) {
    $pyExe = Get-Command "python3" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
}

if (-not $pyExe) {
    $pyPatterns = @(
        (Join-Path $ManagerDir "python.exe"),
        (Join-Path $ManagerDir "resources\python.exe"),
        (Join-Path (Split-Path -Parent $ManagerDir) "python.exe"),
        "$env:LOCALAPPDATA\Programs\Python\Python*\python.exe",
        "$env:ProgramFiles\Python*\python.exe",
        "${env:ProgramFiles(x86)}\Python*\python.exe",
        "C:\Python*\python.exe",
        "D:\Python*\python.exe",
        "D:\tools\Python*\python.exe",
        "D:\tools\*\python.exe"
    )
    foreach ($pat in $pyPatterns) {
        $found = Get-Item $pat -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
        if ($found -and (Test-Path $found)) {
            $pyExe = $found
            break
        }
    }
}

if (-not $uvExe -and -not $pyExe) {
    Write-Host "[ContextManager] ERROR: Neither 'uv' nor 'python' was found on your system." -ForegroundColor Red
    Write-Host "  Please install uv (`winget install astral-sh.uv`) or Python 3.10+ to enable Context Manager." -ForegroundColor Yellow
    exit 1
}

# 3. Virtual Environment Setup
$cmCandidates = @(
    (Join-Path $ManagerDir "llo-core\context_manager"),
    (Join-Path $ManagerDir "resources\llo-core\context_manager"),
    (Join-Path (Split-Path -Parent $ManagerDir) "llo-core\context_manager"),
    (Join-Path (Split-Path -Parent $ManagerDir) "resources\llo-core\context_manager"),
    (Join-Path $ScriptDir "..\llo-core\context_manager"),
    (Join-Path $ScriptDir "..\resources\llo-core\context_manager"),
    (Join-Path (Split-Path -Parent (Split-Path -Parent $ScriptDir)) "llo-core\context_manager"),
    (Join-Path (Split-Path -Parent (Split-Path -Parent $ScriptDir)) "resources\llo-core\context_manager")
)

$cmDir = $null
foreach ($cand in $cmCandidates) {
    if ($cand -and (Test-Path $cand)) {
        $cmDir = [System.IO.Path]::GetFullPath($cand)
        break
    }
}

if (-not $cmDir) {
    Write-Host "[ContextManager] ERROR: Could not locate 'llo-core\context_manager' directory." -ForegroundColor Red
    exit 1
}

$userAppDir = if ($env:APPDATA) {
    Join-Path $env:APPDATA "LLM Manager"
} elseif ($env:USERPROFILE) {
    Join-Path $env:USERPROFILE ".config\LLM Manager"
} else { $ManagerDir }

if (-not (Test-Path $userAppDir)) { New-Item -ItemType Directory -Force -Path $userAppDir | Out-Null }

# Store venv in writable user AppData to allow non-admin execution in Program Files
$venvDir = Join-Path $userAppDir "context_manager_venv"
$reqFile = Join-Path $cmDir "requirements.txt"

Write-Host "==========================================================" -ForegroundColor Green
Write-Host "  LLM MANAGER CONTEXT PROXY" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "  Port : $proxyPort" -ForegroundColor White

$venvPy = if ($env:OS -match "Windows") { Join-Path $venvDir "Scripts\python.exe" } else { Join-Path $venvDir "bin/python" }

if ($uvExe) {
    Write-Host "  Runner: uv ($uvExe)" -ForegroundColor DarkGray
    if (-not (Test-Path $venvDir) -or -not (Test-Path $venvPy)) {
        Write-Host "  Creating venv with uv..." -ForegroundColor Cyan
        & $uvExe venv $venvDir --quiet
    }
    Write-Host "  Installing dependencies..." -ForegroundColor Cyan
    & $uvExe pip install -r $reqFile --quiet --python $venvPy
} else {
    Write-Host "  Runner: python ($pyExe)" -ForegroundColor DarkGray
    if (-not (Test-Path $venvDir) -or -not (Test-Path $venvPy)) {
        Write-Host "  Creating venv..." -ForegroundColor Cyan
        & $pyExe -m venv $venvDir
    }
    Write-Host "  Installing dependencies..." -ForegroundColor Cyan
    & $venvPy -m pip install -r $reqFile --quiet
}

# 4. Prepare logs directory
$logDir = if ($env:APPDATA) {
    Join-Path $env:APPDATA "LLM Manager\logs"
} elseif ($env:USERPROFILE) {
    Join-Path $env:USERPROFILE ".config/LLM Manager/logs"
} else { Join-Path $ManagerDir "logs" }

if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$cmLog = Join-Path $logDir "context-manager.log"
$cmErrLog = Join-Path $logDir "context-manager.err.log"

if (Test-Path $cmLog) { try { Remove-Item $cmLog -Force -ErrorAction SilentlyContinue } catch {} }
if (Test-Path $cmErrLog) { try { Remove-Item $cmErrLog -Force -ErrorAction SilentlyContinue } catch {} }

Write-Host "  Logs : $cmLog" -ForegroundColor DarkGray
Write-Host "==========================================================" -ForegroundColor Green

# 5. Launch Proxy
$venvPy = if ($env:OS -match "Windows") { Join-Path $venvDir "Scripts\python.exe" } else { Join-Path $venvDir "bin/python" }
$uvicornExe = if ($env:OS -match "Windows") { Join-Path $venvDir "Scripts\uvicorn.exe" } else { Join-Path $venvDir "bin/uvicorn" }

if ($Foreground) {
    Write-Host "Starting Context Manager proxy in foreground on port $proxyPort..." -ForegroundColor Cyan
    & $venvPy -m uvicorn proxy:app --host 0.0.0.0 --port $proxyPort
} else {
    Write-Host "Launching Context Manager proxy in background (port $proxyPort)..." -ForegroundColor Cyan
    if ($env:OS -match "Windows") {
        $cmdLine = "`"$uvicornExe`" proxy:app --host 0.0.0.0 --port $proxyPort"
        try {
            $res = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmdLine; CurrentDirectory = $cmDir }
            if ($res.ReturnValue -eq 0) {
                Write-Host "  Context Manager Proxy running (PID: $($res.ProcessId))" -ForegroundColor Green
            } else {
                Write-Host "  [ContextManager] CIM launch code $($res.ReturnValue), falling back to Start-Process..." -ForegroundColor Yellow
                $argList = @("proxy:app", "--host", "0.0.0.0", "--port", "$proxyPort")
                $proc = Start-Process -FilePath $uvicornExe -ArgumentList $argList -WorkingDirectory $cmDir -RedirectStandardOutput $cmLog -RedirectStandardError $cmErrLog -WindowStyle Hidden -PassThru
                Write-Host "  Context Manager Proxy running (PID: $($proc.Id))" -ForegroundColor Green
            }
        } catch {
            Write-Host "  [ContextManager] CIM launch exception: $($_.Exception.Message), falling back to Start-Process..." -ForegroundColor Yellow
            $argList = @("proxy:app", "--host", "0.0.0.0", "--port", "$proxyPort")
            $proc = Start-Process -FilePath $uvicornExe -ArgumentList $argList -WorkingDirectory $cmDir -RedirectStandardOutput $cmLog -RedirectStandardError $cmErrLog -WindowStyle Hidden -PassThru
            Write-Host "  Context Manager Proxy running (PID: $($proc.Id))" -ForegroundColor Green
        }
    } else {
        $argList = @("proxy:app", "--host", "0.0.0.0", "--port", "$proxyPort")
        $proc = Start-Process -FilePath $uvicornExe -ArgumentList $argList -WorkingDirectory $cmDir -RedirectStandardOutput $cmLog -RedirectStandardError $cmErrLog -WindowStyle Hidden -PassThru
        Write-Host "  Context Manager Proxy running (PID: $($proc.Id))" -ForegroundColor Green
    }
}
