# StartContextManager.ps1 — Launches the LLO Context Manager Proxy
param(
    [string]$ConfigFile = "",
    [int]$Port = 8090,
    [int]$UpstreamPort = 8080,
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

# 1. Read Config & Resolve Ports
$proxyPort = if ($PSBoundParameters.ContainsKey('Port')) { $Port } else { 8090 }
$cmEnabled = $true

if (Test-Path $ConfigFile) {
    try {
        $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        if ($cfg.PSObject.Properties.Name -contains "context_manager") {
            $cm = $cfg.context_manager
            if ($null -ne $cm.enabled) { $cmEnabled = [bool]$cm.enabled }
            if (-not $PSBoundParameters.ContainsKey('Port') -and $null -ne $cm.proxy_port -and [int]$cm.proxy_port -gt 0) {
                $proxyPort = [int]$cm.proxy_port
            }
        }
    } catch {
        Write-Host "[ContextManager] Warning: could not parse $ConfigFile; using defaults." -ForegroundColor Yellow
    }
}

if (-not $cmEnabled) {
    Write-Host "[ContextManager] Notice: context_manager.enabled is false in config. Proxy launch skipped." -ForegroundColor Yellow
    exit 0
}

# Scan for available proxy port if occupied
$listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
$usedPorts = $listeners.Port
if ($usedPorts -contains $proxyPort) {
    Write-Host "[ContextManager] Port $proxyPort is occupied. Scanning for next available proxy port..." -ForegroundColor Yellow
    while ($usedPorts -contains $proxyPort) {
        $proxyPort++
    }
    Write-Host "[ContextManager] Shifted proxy port to $proxyPort." -ForegroundColor Green
}

# Update llo-config.json with latest active llama_server_url and proxy_port
if (Test-Path $ConfigFile) {
    try {
        $cfgJson = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        if ($cfgJson.context_manager) {
            $cfgJson.context_manager | Add-Member -Force -NotePropertyName "llama_server_url" -NotePropertyValue "http://127.0.0.1:$UpstreamPort"
            $cfgJson.context_manager | Add-Member -Force -NotePropertyName "proxy_port" -NotePropertyValue $proxyPort
            $cfgJson | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigFile -Encoding UTF8
        }
    } catch {
        Write-Host "[ContextManager] Warning: could not update config with active upstream URL: $($_.Exception.Message)" -ForegroundColor Yellow
    }
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
$lloCoreDir = Split-Path -Parent $cmDir
$pidFile = Join-Path $userAppDir "context-manager.pid"

if ($Foreground) {
    Write-Host "Starting Context Manager proxy in foreground on port $proxyPort..." -ForegroundColor Cyan
    & $venvPy -m uvicorn context_manager.proxy:app --host 0.0.0.0 --port $proxyPort
} else {
    Write-Host "Launching Context Manager proxy in background (port $proxyPort)..." -ForegroundColor Cyan
    $launchedPid = $null

    if ($env:OS -match "Windows") {
        $cmdLine = "`"$uvicornExe`" context_manager.proxy:app --host 0.0.0.0 --port $proxyPort"
        try {
            $res = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmdLine; CurrentDirectory = $lloCoreDir }
            if ($res.ReturnValue -eq 0) {
                $launchedPid = $res.ProcessId
                Write-Host "  Context Manager Proxy running (PID: $launchedPid)" -ForegroundColor Green
            } else {
                Write-Host "  [ContextManager] CIM launch code $($res.ReturnValue), falling back to Start-Process..." -ForegroundColor Yellow
                $argList = @("context_manager.proxy:app", "--host", "0.0.0.0", "--port", "$proxyPort")
                $proc = Start-Process -FilePath $uvicornExe -ArgumentList $argList -WorkingDirectory $lloCoreDir -RedirectStandardOutput $cmLog -RedirectStandardError $cmErrLog -WindowStyle Hidden -PassThru
                $launchedPid = $proc.Id
                Write-Host "  Context Manager Proxy running (PID: $launchedPid)" -ForegroundColor Green
            }
        } catch {
            Write-Host "  [ContextManager] CIM launch exception: $($_.Exception.Message), falling back to Start-Process..." -ForegroundColor Yellow
            $argList = @("context_manager.proxy:app", "--host", "0.0.0.0", "--port", "$proxyPort")
            $proc = Start-Process -FilePath $uvicornExe -ArgumentList $argList -WorkingDirectory $lloCoreDir -RedirectStandardOutput $cmLog -RedirectStandardError $cmErrLog -WindowStyle Hidden -PassThru
            $launchedPid = $proc.Id
            Write-Host "  Context Manager Proxy running (PID: $launchedPid)" -ForegroundColor Green
        }
    } else {
        $argList = @("context_manager.proxy:app", "--host", "0.0.0.0", "--port", "$proxyPort")
        $proc = Start-Process -FilePath $uvicornExe -ArgumentList $argList -WorkingDirectory $lloCoreDir -RedirectStandardOutput $cmLog -RedirectStandardError $cmErrLog -WindowStyle Hidden -PassThru
        $launchedPid = $proc.Id
        Write-Host "  Context Manager Proxy running (PID: $launchedPid)" -ForegroundColor Green
    }

    if ($launchedPid) {
        Set-Content -Path $pidFile -Value $launchedPid -Encoding UTF8 -ErrorAction SilentlyContinue
    }
}
