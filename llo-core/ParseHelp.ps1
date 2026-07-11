# LLO Help Output Parser
# Runs llama-server.exe --help, parses flags, caches them, and computes diffs to detect upstream changes.

param(
    [string]$LlamaServerPath = "",
    [string]$CacheFile = ""
)

$ErrorActionPreference = "Stop"

$ManagerDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
if ([string]::IsNullOrWhiteSpace($CacheFile)) {
    $CacheFile = Join-Path $ManagerDir ".cached_flags.json"
}
if ([string]::IsNullOrWhiteSpace($LlamaServerPath)) {
    $configFile = Join-Path $ManagerDir "llo-config.json"
    if (Test-Path $configFile) {
        try {
            $config = Get-Content $configFile -Raw | ConvertFrom-Json
            if ($config.llama_server_path) {
                $LlamaServerPath = $config.llama_server_path
            }
        } catch {}
    }
    if ([string]::IsNullOrWhiteSpace($LlamaServerPath)) {
        $LlamaServerPath = "llama-server"
    }
}

function Get-LlamaServerFlags {
    param([string]$ServerPath)

    if (-not (Test-Path $ServerPath)) {
        throw "llama-server.exe not found at: $ServerPath"
    }

    Write-Host "Running $ServerPath --help to extract options..." -ForegroundColor Cyan

    # Execute and capture stdout/stderr. Redirect stderr because llama-server may print help to stderr in some versions.
    $helpLines = & $ServerPath --help 2>&1 | Out-String
    $lines = $helpLines -split "`r?`n"

    $flags = New-Object System.Collections.Generic.List[object]
    
    # Matches options like:
    #   -t,    --threads N                      number of CPU threads to use...
    #   --version                               show version and build info
    #   -rea,  --reasoning [on|off|auto]        Use reasoning/thinking...
    $regex = '^\s*(?:(-[\w?]+),\s+)?(--[\w-]+)(?:\s+([A-Z0-9_\-\[\]|{}]+))?\s+(.+)$'

    $currentFlag = $null

    foreach ($line in $lines) {
        # Check if line contains a flag match
        if ($line -match $regex) {
            # If we had a previous flag, add it
            if ($currentFlag) {
                $flags.Add($currentFlag)
            }

            $short = $Matches[1]
            $long = $Matches[2]
            $valueToken = $Matches[3]
            $desc = $Matches[4].Trim()

            # Clean up value token and desc if value token was mistakenly captured in desc or vice versa
            if ([string]::IsNullOrEmpty($valueToken) -and $desc -match '^([A-Z0-9_]{2,})\s+(.+)$') {
                $valueToken = $Matches[1]
                $desc = $Matches[2].Trim()
            }

            # Detect env variable override
            $envVar = $null
            if ($desc -match '\(env:\s*([\w_]+)\)') {
                $envVar = $Matches[1]
            }

            $currentFlag = [pscustomobject]@{
                Short       = if ($short) { $short.Trim() } else { $null }
                Long        = $long.Trim()
                ValueToken  = if ($valueToken) { $valueToken.Trim() } else { $null }
                Description = $desc
                EnvVar      = $envVar
            }
        } else {
            # It's a continuation of the description for the current flag
            if ($currentFlag -and $line.Trim() -and -not ($line -match '^---')) {
                # Append description
                $trimmedLine = $line.Trim()
                
                # Check for env variable in continuation line
                if ($trimmedLine -match '\(env:\s*([\w_]+)\)') {
                    $currentFlag.EnvVar = $Matches[1]
                }
                
                $currentFlag.Description += " " + $trimmedLine
            }
        }
    }

    # Add the last flag
    if ($currentFlag) {
        $flags.Add($currentFlag)
    }

    return $flags.ToArray()
}

function Update-CachedFlags {
    param(
        [string]$ServerPath = $LlamaServerPath,
        [string]$CachePath = $CacheFile
    )

    $currentFlags = Get-LlamaServerFlags -ServerPath $ServerPath
    if ($currentFlags.Count -eq 0) {
        Write-Host "Warning: No flags parsed from llama-server.exe --help." -ForegroundColor Yellow
        return $null
    }

    $diffResult = [pscustomobject]@{
        Added = @()
        Removed = @()
        TotalCurrent = $currentFlags.Count
    }

    if (Test-Path $CachePath) {
        try {
            $cachedFlags = Get-Content $CachePath -Raw | ConvertFrom-Json
            
            # Extract list of long flags for quick comparison
            $currentLongFlags = @($currentFlags | ForEach-Object { $_.Long })
            $cachedLongFlags = @($cachedFlags | ForEach-Object { $_.Long })

            # 1. Detect Added Flags
            foreach ($flag in $currentFlags) {
                if ($cachedLongFlags -notcontains $flag.Long) {
                    $diffResult.Added += $flag
                }
            }

            # 2. Detect Removed/Deprecated Flags
            foreach ($flag in $cachedFlags) {
                if ($currentLongFlags -notcontains $flag.Long) {
                    $diffResult.Removed += $flag
                }
            }
        } catch {
            Write-Host "Error reading cached flags file. Overwriting cache..." -ForegroundColor Yellow
        }
    } else {
        Write-Host "No cached flags found. Initializing cache registry..." -ForegroundColor Cyan
    }

    # Write current flags to cache
    $json = $currentFlags | ConvertTo-Json -Depth 5
    Set-Content -Path $CachePath -Value $json -Encoding UTF8
    Write-Host "Option registry updated at $CachePath (Total flags: $($currentFlags.Count))" -ForegroundColor Green

    return $diffResult
}

# If run directly
if ($MyInvocation.InvocationName -eq '.' -or $MyInvocation.InvocationName -eq '&' -or $MyInvocation.MyCommand.Name -eq 'ParseHelp.ps1') {
    $diff = Update-CachedFlags
    if ($diff) {
        Write-Host "--- Help Parser Diff Results ---" -ForegroundColor Green
        Write-Host "Total flags in current binary: $($diff.TotalCurrent)"
        Write-Host "New flags added: $($diff.Added.Count)"
        if ($diff.Added.Count -gt 0) {
            $diff.Added | ForEach-Object { Write-Host "  + $($_.Long) ($($_.Description))" -ForegroundColor Green }
        }
        Write-Host "Deprecated/removed flags: $($diff.Removed.Count)"
        if ($diff.Removed.Count -gt 0) {
            $diff.Removed | ForEach-Object { Write-Host "  - $($_.Long) ($($_.Description))" -ForegroundColor Red }
        }
        Write-Host "--------------------------------"
    }
}
