# llo-core/FetchAssets.ps1
# Module to handle downloading and caching chat templates and grammar files from llama.cpp

function Read-AssetsManifest {
    param(
        [string]$ManifestPath
    )
    if (Test-Path $ManifestPath) {
        try {
            $raw = Get-Content -Path $ManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
            $manifest = @{
                last_updated = $raw.last_updated
                templates    = @{}
                grammars     = @{}
            }
            if ($raw.templates) {
                foreach ($prop in $raw.templates.PSObject.Properties) {
                    $manifest.templates[$prop.Name] = $prop.Value
                }
            }
            if ($raw.grammars) {
                foreach ($prop in $raw.grammars.PSObject.Properties) {
                    $manifest.grammars[$prop.Name] = $prop.Value
                }
            }
            return $manifest
        } catch {
            Write-Host "  [!] Manifest corrupted or unreadable. Will re-create manifest." -ForegroundColor DarkYellow
        }
    }
    return @{
        last_updated = ""
        templates    = @{}
        grammars     = @{}
    }
}

function Write-AssetsManifest {
    param(
        [string]$ManifestPath,
        [hashtable]$Manifest
    )
    $Manifest.last_updated = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
    try {
        $json = $Manifest | ConvertTo-Json -Depth 5
        Set-Content -Path $ManifestPath -Value $json -Encoding UTF8 -Force
    } catch {
        $errMsg = $_.Exception.Message
        Write-Host "  [WARNING] Failed to write manifest: $errMsg" -ForegroundColor Yellow
    }
}

function Sync-GitHubFolder {
    param(
        [string]$ApiUrl,
        [string]$DestDir,
        [string]$ManifestKey,
        [hashtable]$Manifest,
        [string[]]$SkipNames = @("README.md"),
        [int]$TimeoutSec = 30
    )

    if (-not (Test-Path $DestDir)) {
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
    }

    if (-not $Manifest.ContainsKey($ManifestKey)) {
        $Manifest[$ManifestKey] = @{}
    }
    $currentManifestMap = $Manifest[$ManifestKey]

    Write-Host "  Checking upstream GitHub directory ($ManifestKey)..." -ForegroundColor DarkGray

    # Set TLS 1.2 / 1.3 for PowerShell compatibility
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    } catch {}

    $remoteItems = $null
    $headers = @{ "User-Agent" = "llm-manager-asset-fetcher" }
    if ($env:GITHUB_TOKEN) {
        $headers["Authorization"] = "Bearer $env:GITHUB_TOKEN"
    }

    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            $response = Invoke-RestMethod -Uri $ApiUrl -Headers $headers -TimeoutSec $TimeoutSec -ErrorAction Stop
            $remoteItems = @($response)
            break
        } catch {
            $errText = $_.Exception.Message
            if ($attempt -lt $maxAttempts) {
                Start-Sleep -Seconds ($attempt * 2)
            } else {
                Write-Host "  [!] Could not reach GitHub API ($errText). Skipping remote sync for $ManifestKey." -ForegroundColor Yellow
                return @{ Success = $false; Downloaded = 0; Skipped = 0; Removed = 0; NetworkError = $true }
            }
        }
    }

    $downloaded = 0
    $skipped = 0
    $removed = 0
    $remoteFileNames = @{}

    foreach ($item in $remoteItems) {
        if ($item.type -ne "file") { continue }
        if ($SkipNames -contains $item.name) { continue }

        $itemName = $item.name
        $remoteFileNames[$itemName] = $true
        $targetFile = Join-Path $DestDir $itemName

        $knownSha = if ($currentManifestMap.ContainsKey($itemName)) { $currentManifestMap[$itemName] } else { "" }
        $fileExists = Test-Path $targetFile

        if ($fileExists -and $knownSha -eq $item.sha) {
            $skipped++
            continue
        }

        # Download file with retry and validation
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            try {
                if ($attempt -eq 1) { Write-Host "  [+] Downloading $itemName..." -ForegroundColor Cyan }
                Invoke-WebRequest -Uri $item.download_url -OutFile $targetFile -TimeoutSec $TimeoutSec -ErrorAction Stop
                
                # Basic validation: ensure downloaded file exists and is non-empty
                if ((Test-Path $targetFile) -and (Get-Item $targetFile).Length -gt 0) {
                    $currentManifestMap[$itemName] = $item.sha
                    $downloaded++
                    break
                } else {
                    throw "Downloaded file is empty (0 bytes)"
                }
            } catch {
                $errText = $_.Exception.Message
                if ($attempt -lt $maxAttempts) {
                    Start-Sleep -Seconds ($attempt * 2)
                } else {
                    Write-Host "  [WARNING] Failed to download $($itemName) after $maxAttempts attempts: $errText" -ForegroundColor Yellow
                    if (Test-Path $targetFile) { Remove-Item $targetFile -Force -ErrorAction SilentlyContinue }
                }
            }
        }
    }

    # Clean up stale files that are tracked in manifest but removed upstream
    $keysToCheck = @($currentManifestMap.Keys)
    foreach ($k in $keysToCheck) {
        if (-not $remoteFileNames.ContainsKey($k)) {
            $staleFile = Join-Path $DestDir $k
            if (Test-Path $staleFile) {
                Remove-Item -Path $staleFile -Force -ErrorAction SilentlyContinue
            }
            $currentManifestMap.Remove($k)
            $removed++
        }
    }

    return @{
        Success      = $true
        Downloaded   = $downloaded
        Skipped      = $skipped
        Removed      = $removed
        NetworkError = $false
    }
}
