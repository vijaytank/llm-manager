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
    $appDataConfig = if ($env:APPDATA) {
        Join-Path $env:APPDATA "LLM Manager\llo-config.json"
    } elseif ($env:USERPROFILE) {
        Join-Path $env:USERPROFILE ".config\LLM Manager\llo-config.json"
    } elseif ($env:HOME) {
        Join-Path $env:HOME ".config/LLM Manager/llo-config.json"
    } else { $null }

    $configFile = if ($appDataConfig -and (Test-Path $appDataConfig)) {
        $appDataConfig
    } else {
        Join-Path $ManagerDir "llo-config.json"
    }
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
        $binaryName = if ($IsWindows) { "llama-server.exe" } else { "llama-server" }
        Write-Host "[WARNING] $binaryName not found at: $ServerPath. Skipping live help parsing." -ForegroundColor Yellow
        return @()
    }

    Write-Host "Running $ServerPath --help to extract options..." -ForegroundColor Cyan

    # Execute and capture stdout+stderr. Some llama-server versions write help to stderr.
    # Use ErrorActionPreference = Continue and ForEach-Object to capture stderr as strings without triggering Stop errors or formatting them as Multi-line ErrorRecords.
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $helpLines = & $ServerPath --help 2>&1 | ForEach-Object { $_.ToString() } | Out-String
    $ErrorActionPreference = $oldEAP
    $lines = $helpLines -split "`r?`n"

    $flags = New-Object System.Collections.Generic.List[object]

    # A help line with options looks like one of:
    #   -t,    --threads N                       number of CPU threads to use...
    #   --version                                show version and build info
    #   -ngl,  --gpu-layers, --n-gpu-layers N    max layers in VRAM...
    #   --jinja, --no-jinja                      whether to use jinja template...
    #   --webui-mcp-proxy, --no-webui-mcp-proxy
    # We match any line that starts with optional whitespace + a short/long flag.
    $optionLineRegex = '^\s{0,12}((?:-[\w?]+,\s+)?(?:--[\w-]+(?:,\s+)?)+)'

    $currentFlag = $null

    foreach ($line in $lines) {
        if ($line -match $optionLineRegex) {
            # Flush the previous flag entry
            if ($currentFlag) { $flags.Add($currentFlag) }

            # Extract all long flags (--word) from this line
            $longAliases = @([regex]::Matches($line, '--[\w-]+') | ForEach-Object { $_.Value })
            if ($longAliases.Count -eq 0) {
                $currentFlag = $null
                continue
            }

            # Extract short alias if present (leading -x,)
            $shortAlias = $null
            if ($line -match '^\s*(-[\w?]+),') { $shortAlias = $Matches[1] }

            # Extract value token: an ALL-CAPS word/bracket token after the flags section
            $valueToken = $null
            if ($line -match '(?:--[\w-]+(?:,\s+)?)+\s+([A-Z0-9_\[\]{}/|.*-]{1,40})\s{2,}') {
                $valueToken = $Matches[1].Trim()
            }

            # Extract description: two or more spaces after the flags+value section
            $desc = ""
            if ($line -match '\s{2,}(.+)$') { $desc = $Matches[1].Trim() }

            # Detect env variable override
            $envVar = $null
            if ($desc -match '\(env:\s*([\w_]+)\)') { $envVar = $Matches[1] }

            # Primary flag entry
            $primaryLong = $longAliases[0]
            $currentFlag = [pscustomobject]@{
                Short       = $shortAlias
                Long        = $primaryLong
                Aliases     = $longAliases
                ValueToken  = $valueToken
                Description = $desc
                EnvVar      = $envVar
            }

            # Register every additional alias as its own entry (allows allow-list lookups by any alias)
            foreach ($alias in ($longAliases | Select-Object -Skip 1)) {
                $flags.Add([pscustomobject]@{
                    Short       = $null
                    Long        = $alias
                    Aliases     = $longAliases
                    ValueToken  = $valueToken
                    Description = "(alias) $desc"
                    EnvVar      = $envVar
                })
            }
        } else {
            # Continuation description line
            if ($currentFlag -and $line.Trim() -and -not ($line -match '^---')) {
                $trimmedLine = $line.Trim()
                if ($trimmedLine -match '\(env:\s*([\w_]+)\)') {
                    $currentFlag.EnvVar = $Matches[1]
                }
                $currentFlag.Description += " " + $trimmedLine
            }
        }
    }

    # Add the last flag
    if ($currentFlag) { $flags.Add($currentFlag) }

    return $flags.ToArray()
}


function Update-CachedFlags {
    param(
        [string]$ServerPath = $LlamaServerPath,
        [string]$CachePath = $CacheFile
    )

    $currentFlags = try { Get-LlamaServerFlags -ServerPath $ServerPath } catch { @() }
    if ($currentFlags.Count -eq 0) {
        Write-Host "Warning: No flags parsed from llama-server --help (binary missing or unreadable)." -ForegroundColor Yellow
        if (Test-Path $CachePath) {
            Write-Host "Preserving existing cached flags at $CachePath." -ForegroundColor Cyan
        }
        return [pscustomobject]@{
            Added = @()
            Removed = @()
            TotalCurrent = 0
        }
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
