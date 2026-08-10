# LLO stop-server.ps1
# Gracefully stops any active llama-server instances running on the target port.
# Supports Windows, macOS, and Linux.

param(
    [int]$Port = 8080,
    [string]$ConfigFile = ""
)

$ErrorActionPreference = "Stop"

Write-Host "Searching for active llama-server processes..." -ForegroundColor Cyan

if ($env:OS -match "Windows" -or $IsWindows) {
    # Windows: find all llama-server.exe processes
    $running = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq "llama-server.exe"
    })

    if ($running) {
        Write-Host "Found $($running.Count) running server process(es). Terminating..." -ForegroundColor Yellow
        $running | ForEach-Object {
            try {
                Stop-Process -Id $_.ProcessId -Force
                Write-Host "  Terminated PID: $($_.ProcessId)" -ForegroundColor DarkGray
            } catch {
                Write-Host "  Failed to stop process ID: $($_.ProcessId)" -ForegroundColor Red
            }
        }
        Start-Sleep -Seconds 1
        Write-Host "llama-server stopped successfully." -ForegroundColor Green
    } else {
        Write-Host "No active llama-server found listening on port $Port." -ForegroundColor Green
    }

    # Stop Context Manager Proxy process if active
    $cmProcs = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq "python.exe" -and ($_.ExecutablePath -like "*context_manager*" -or $_.CommandLine -like "*context_manager*")
    })
    if ($cmProcs -and $cmProcs.Count -gt 0) {
        Write-Host "Stopping Context Manager Proxy process..." -ForegroundColor Yellow
        $cmProcs | ForEach-Object {
            try {
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                Write-Host "  Terminated Context Manager PID: $($_.ProcessId)" -ForegroundColor DarkGray
            } catch {}
        }
    }
} else {
    # macOS / Linux: find the PID bound to the target port using lsof or ss/fuser
    $pids = @()

    if ($IsMacOS) {
        # lsof is available on macOS by default
        try {
            $lsofOut = & lsof -ti ":$Port" 2>$null
            if ($lsofOut) {
                $pids = @($lsofOut -split "`n" | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
            }
        } catch {}
    } elseif ($IsLinux) {
        # Try ss (modern Linux, replaces netstat)
        try {
            $ssOut = & ss -tlnp "sport = :$Port" 2>$null
            if ($ssOut) {
                $pidMatches = [regex]::Matches($ssOut, 'pid=(\d+)')
                $pids = @($pidMatches | ForEach-Object { [int]$_.Groups[1].Value })
            }
        } catch {}

        # Fallback: fuser
        if ($pids.Count -eq 0) {
            try {
                $fuserOut = & fuser "${Port}/tcp" 2>$null
                if ($fuserOut) {
                    $pids = @($fuserOut.Trim() -split '\s+' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
                }
            } catch {}
        }
    }

    # Filter to only llama-server processes (avoid killing unrelated port users)
    $targetPids = @()
    foreach ($p in $pids) {
        try {
            $proc = Get-Process -Id $p -ErrorAction SilentlyContinue
            if ($proc -and $proc.Name -match 'llama.?server') {
                $targetPids += $p
            }
        } catch {}
    }

    # Fallback: search by process name if port tools found nothing
    if ($targetPids.Count -eq 0) {
        $byName = @(Get-Process | Where-Object { $_.Name -match 'llama.?server' } -ErrorAction SilentlyContinue)
        $targetPids = @($byName | ForEach-Object { $_.Id })
    }

    if ($targetPids.Count -gt 0) {
        Write-Host "Found $($targetPids.Count) running server process(es). Terminating..." -ForegroundColor Yellow
        foreach ($p in $targetPids) {
            try {
                Stop-Process -Id $p -Force
                Write-Host "  Terminated PID: $p" -ForegroundColor DarkGray
            } catch {
                Write-Host "  Failed to stop PID ${p}: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        Start-Sleep -Seconds 1
        Write-Host "llama-server stopped successfully." -ForegroundColor Green
    } else {
        Write-Host "No active llama-server found listening on port $Port." -ForegroundColor Green
    }

    try {
        $cmProcs = @(Get-Process | Where-Object { $_.CommandLine -match 'proxy:app' } -ErrorAction SilentlyContinue)
        $cmProcs | Stop-Process -Force -ErrorAction SilentlyContinue
    } catch {}
}
