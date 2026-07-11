# LLO stop-server.ps1
# Gracefully stops any active llama-server instances running on the target port.

param(
    [int]$Port = 8080
)

$ErrorActionPreference = "Stop"

Write-Host "Searching for active llama-server processes on port $Port..." -ForegroundColor Cyan

$running = @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -eq "llama-server.exe" -and $_.CommandLine -match [regex]::Escape("--port $Port")
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
