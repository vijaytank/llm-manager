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

if ($uvExe) {
    $uvRunnable = $false
    try {
        $uvCheck = & $uvExe --version 2>&1
        if ($LASTEXITCODE -eq 0 -and $uvCheck -notmatch "Application Control|blocked|Access is denied") {
            $uvRunnable = $true
        }
    } catch {}
    if (-not $uvRunnable) {
        Write-Host "  Notice: uv ($uvExe) is unavailable or restricted by security policy; falling back to python." -ForegroundColor DarkGray
        $uvExe = $null
    }
}

if ($pyExe) {
    $pyRunnable = $false
    try {
        $pyCheck = & $pyExe --version 2>&1
        if ($LASTEXITCODE -eq 0 -and $pyCheck -notmatch "Application Control|blocked|Access is denied") {
            $pyRunnable = $true
        }
    } catch {}
    if (-not $pyRunnable) {
        $pyExe = $null
    }
}

if (-not $uvExe -and -not $pyExe) {
    Write-Host "[ContextManager] ERROR: Neither 'uv' nor 'python' was found or runnable on your system." -ForegroundColor Red
    Write-Host "  Please ensure Python 3.10+ or uv is installed and permitted by system policy to enable Context Manager." -ForegroundColor Yellow
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

$userAppDir = if (Get-Command "Get-LLMManagerUserDataDir" -ErrorAction SilentlyContinue) {
    Get-LLMManagerUserDataDir
} else {
    if ($env:APPDATA) {
        Join-Path $env:APPDATA "LLM Manager"
    } elseif ($env:USERPROFILE) {
        Join-Path $env:USERPROFILE ".config\LLM Manager"
    } else { $ManagerDir }
}

if (-not (Test-Path $userAppDir)) { New-Item -ItemType Directory -Force -Path $userAppDir | Out-Null }

# Store venv in writable user AppData to allow non-admin execution in Program Files
$venvDir = Join-Path $userAppDir "context_manager_venv"
$reqFile = Join-Path $cmDir "requirements.txt"

Write-Host "==========================================================" -ForegroundColor Green
Write-Host "  LLM MANAGER CONTEXT PROXY" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "  Port : $proxyPort" -ForegroundColor White

$venvPy = if ($env:OS -match "Windows") { Join-Path $venvDir "Scripts\python.exe" } else { Join-Path $venvDir "bin/python" }
$useVenv = $false

if ($uvExe) {
    Write-Host "  Runner: uv ($uvExe)" -ForegroundColor DarkGray
    if (-not (Test-Path $venvDir) -or -not (Test-Path $venvPy)) {
        Write-Host "  Creating venv with uv..." -ForegroundColor Cyan
        try { & $uvExe venv $venvDir --quiet } catch {}
    }
    Write-Host "  Installing dependencies..." -ForegroundColor Cyan
    try { & $uvExe pip install -r $reqFile --quiet --python $venvPy } catch {}

    if (Test-Path $venvPy) {
        try {
            $vCheck = & $venvPy --version 2>&1
            if ($LASTEXITCODE -eq 0 -and $vCheck -notmatch "Application Control|blocked|Access is denied") {
                $useVenv = $true
            }
        } catch {}
    }
} elseif ($pyExe) {
    if (Test-Path $venvPy) {
        try {
            $vCheck = & $venvPy --version 2>&1
            if ($LASTEXITCODE -eq 0 -and $vCheck -notmatch "Application Control|blocked|Access is denied") {
                $useVenv = $true
            }
        } catch {}
    }

    if (-not (Test-Path $venvDir)) {
        Write-Host "  Creating venv..." -ForegroundColor Cyan
        try {
            & $pyExe -m venv $venvDir
            if (Test-Path $venvPy) {
                $vCheck = & $venvPy --version 2>&1
                if ($LASTEXITCODE -eq 0 -and $vCheck -notmatch "Application Control|blocked|Access is denied") {
                    $useVenv = $true
                }
            }
        } catch {}
    }

    if ($useVenv) {
        Write-Host "  Runner: venv python ($venvPy)" -ForegroundColor DarkGray
        Write-Host "  Installing dependencies..." -ForegroundColor Cyan
        try { & $venvPy -m pip install -r $reqFile --quiet } catch {}
    } else {
        Write-Host "  Runner: host python ($pyExe)" -ForegroundColor DarkGray
    }
}

# Resolve active Python executable
$activePy = if ($useVenv -and (Test-Path $venvPy)) { $venvPy } else { $pyExe }

if (-not $activePy) {
    Write-Host "[ContextManager] ERROR: No working Python executable found." -ForegroundColor Red
    exit 1
}

# Check that core dependencies are available in active Python
$hasDeps = $false
try {
    $depCheck = & $activePy -c "import uvicorn, fastapi, pydantic, httpx; print('DEPS_OK')" 2>&1
    if ($depCheck -match "DEPS_OK") {
        $hasDeps = $true
    }
} catch {}

if (-not $hasDeps) {
    Write-Host "  Installing dependencies to python environment..." -ForegroundColor Cyan
    try {
        & $activePy -m pip install -r $reqFile --quiet
    } catch {
        Write-Host "  [ContextManager] Warning: pip install encountered: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# 4. Prepare logs directory
$logDir = if ($userAppDir) {
    Join-Path $userAppDir "logs"
} else { Join-Path $ManagerDir "logs" }

if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$cmLog = Join-Path $logDir "context-manager.log"
$cmErrLog = Join-Path $logDir "context-manager.err.log"

if (Test-Path $cmLog) { try { Remove-Item $cmLog -Force -ErrorAction SilentlyContinue } catch {} }
if (Test-Path $cmErrLog) { try { Remove-Item $cmErrLog -Force -ErrorAction SilentlyContinue } catch {} }

Write-Host "  Logs : $cmLog" -ForegroundColor DarkGray
Write-Host "==========================================================" -ForegroundColor Green

# 5. Launch Proxy
$lloCoreDir = Split-Path -Parent $cmDir
$pidFile = Join-Path $userAppDir "context-manager.pid"
$uvicornArgs = @("-m", "uvicorn", "context_manager.proxy:app", "--host", "0.0.0.0", "--port", "$proxyPort")

if ($Foreground) {
    Write-Host "Starting Context Manager proxy in foreground on port $proxyPort..." -ForegroundColor Cyan
    & $activePy @uvicornArgs
} else {
    Write-Host "Launching Context Manager proxy in background (port $proxyPort)..." -ForegroundColor Cyan
    $launchedPid = $null

    if ($env:OS -match "Windows" -or $IsWindows) {
        $cmdLine = "cmd.exe /c `"`"$activePy`" -m uvicorn context_manager.proxy:app --host 0.0.0.0 --port $proxyPort > `"$cmLog`" 2> `"$cmErrLog`"`""
        try {
            $res = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmdLine; CurrentDirectory = $lloCoreDir }
            if ($res.ReturnValue -eq 0) {
                $launchedPid = $res.ProcessId
                Write-Host "  Context Manager Proxy process started (PID: $launchedPid)" -ForegroundColor Green
            } else {
                Write-Host "  [ContextManager] CIM launch code $($res.ReturnValue), falling back to Start-Process..." -ForegroundColor Yellow
                $proc = Start-Process -FilePath $activePy -ArgumentList $uvicornArgs -WorkingDirectory $lloCoreDir -WindowStyle Hidden -PassThru
                $launchedPid = $proc.Id
            }
        } catch {
            Write-Host "  [ContextManager] CIM launch exception: $($_.Exception.Message), falling back to Start-Process..." -ForegroundColor Yellow
            $proc = Start-Process -FilePath $activePy -ArgumentList $uvicornArgs -WorkingDirectory $lloCoreDir -WindowStyle Hidden -PassThru
            $launchedPid = $proc.Id
        }
    } else {
        $proc = Start-Process -FilePath $activePy -ArgumentList $uvicornArgs -WorkingDirectory $lloCoreDir -RedirectStandardOutput $cmLog -RedirectStandardError $cmErrLog -PassThru
        $launchedPid = $proc.Id
    }

    # Verify endpoint health before returning
    Write-Host "  Verifying Context Manager health on port $proxyPort..." -NoNewline -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds(8)
    $healthy = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 400
        try {
            $hResp = Invoke-RestMethod -Uri "http://127.0.0.1:$proxyPort/health" -TimeoutSec 2 -ErrorAction SilentlyContinue
            if ($hResp -and $hResp.status -eq "ok") {
                $healthy = $true
                break
            }
        } catch {}
        Write-Host "." -NoNewline -ForegroundColor Cyan
    }
    Write-Host ""

    if ($healthy) {
        Write-Host "  Context Manager Proxy verified live at http://127.0.0.1:$proxyPort" -ForegroundColor Green
        # Locate python worker process PID for accurate lifecycle management
        $workerProcs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -eq "python.exe" -and $_.CommandLine -like "*context_manager.proxy*"
        })
        $targetPid = if ($workerProcs.Count -gt 0) { $workerProcs[0].ProcessId } else { $launchedPid }
        if ($targetPid) {
            Set-Content -Path $pidFile -Value $targetPid -Encoding UTF8 -ErrorAction SilentlyContinue
        }
    } else {
        $errSnippet = if (Test-Path $cmErrLog) { (Get-Content $cmErrLog -Raw -ErrorAction SilentlyContinue) } else { "" }
        Write-Host "  [ContextManager] Health check timed out on port $proxyPort. $errSnippet" -ForegroundColor Red
        exit 1
    }
}
