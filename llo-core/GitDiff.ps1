# LLO Git Change Log and Compatibility Diff Tool
# Checks upstream llama.cpp branch status and parses commit logs for system impact.

param(
    [string]$LlamaRepoPath = ""
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($LlamaRepoPath)) {
    $ManagerDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
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
            if ($config.llama_repo_path) {
                $LlamaRepoPath = $config.llama_repo_path
            }
        } catch {}
    }
}

function Get-LlamaGitStatus {
    param([string]$RepoPath)

    if (-not (Test-Path $RepoPath)) {
        throw "llama.cpp repository not found at: $RepoPath"
    }

    # Save current directory and go to repo
    $oldDir = Get-Location
    Set-Location $RepoPath

    try {
        Write-Host "Fetching latest updates from llama.cpp remote..." -ForegroundColor Cyan
        # Run git fetch silently (suppress NativeCommandError under ErrorActionPreference = Stop)
        $oldEAP = $ErrorActionPreference
        $ErrorActionPreference = "SilentlyContinue"
        git fetch origin 2>$null | Out-Null
        $ErrorActionPreference = $oldEAP

        # Check branch status machine-readably via git rev-list
        $isLatest = $true
        $statusMessage = "Up-to-date with remote."
        $aheadBy = 0
        $behindBy = 0

        $oldEAP = $ErrorActionPreference
        $ErrorActionPreference = "SilentlyContinue"
        $revCount = & git rev-list --left-right --count HEAD...@{u} 2>$null
        $revSuccess = ($LastExitCode -eq 0)
        $ErrorActionPreference = $oldEAP

        if ($revSuccess -and $revCount) {
            $parts = $revCount.Trim() -split '\s+'
            if ($parts.Count -eq 2) {
                $aheadBy = [int]$parts[0]
                $behindBy = [int]$parts[1]

                if ($aheadBy -gt 0 -and $behindBy -gt 0) {
                    $isLatest = $false
                    $statusMessage = "Diverged from remote (ahead by $aheadBy, behind by $behindBy). Clean manual merge or rebase required."
                } elseif ($behindBy -gt 0) {
                    $isLatest = $false
                    $statusMessage = "Behind remote by $behindBy commit(s). You should do a 'git pull'."
                } elseif ($aheadBy -gt 0) {
                    $statusMessage = "Ahead of remote by $aheadBy commit(s)."
                }
            }
        } else {
            # Fallback to status parsing if upstream tracking branch is missing
            $status = (git status -uno) -join "`n"
            if ($status -match "Your branch is behind '([^']+)' by (\d+) commit") {
                $isLatest = $false
                $behindBy = [int]$Matches[2]
                $statusMessage = "Behind remote by $behindBy commit(s). You should do a 'git pull'."
            } elseif ($status -match "Your branch is ahead of '([^']+)' by (\d+) commit") {
                $aheadBy = [int]$Matches[2]
                $statusMessage = "Ahead of remote by $aheadBy commit(s)."
            } elseif ($status -match "Your branch and '([^']+)' have diverged") {
                $isLatest = $false
                $statusMessage = "Diverged from remote. Clean manual merge or rebase required."
            }
        }

        # Get active branch name
        $branch = (git branch --show-current).Trim()

        # Get recent commit details (either pull updates or last 15 commits if up-to-date)
        $logRange = "HEAD~15..HEAD"
        $isPullDiff = $false

        # Check if we have ORIG_HEAD (meaning we just pulled/merged)
        $oldEAP = $ErrorActionPreference
        $ErrorActionPreference = "SilentlyContinue"
        git rev-parse --verify ORIG_HEAD 2>$null | Out-Null
        $hasOrigHead = ($LastExitCode -eq 0)
        $ErrorActionPreference = $oldEAP

        if ($hasOrigHead) {
            $origHead = (git rev-parse ORIG_HEAD).Substring(0, 8)
            $head = (git rev-parse HEAD).Substring(0, 8)
            if ($origHead -ne $head) {
                $logRange = "ORIG_HEAD..HEAD"
                $isPullDiff = $true
            }
        }

        Write-Host "Parsing commit history ($logRange)..." -ForegroundColor Cyan
        $commitsRaw = git log $logRange --oneline --no-merges
        $commits = New-Object System.Collections.Generic.List[object]

        foreach ($line in $commitsRaw) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            
            $hash = $line.Substring(0, 8)
            $subject = $line.Substring(9)
            
            # Check for keyword matches to flag hardware compatibility / optimization interest
            $impacts = @()
            if ($subject -match "(?i)cuda|nvidia|gpu|vram") { $impacts += "CUDA/GPU" }
            if ($subject -match "(?i)cpu|thread|numa") { $impacts += "CPU" }
            if ($subject -match "(?i)perf|speed|token/s|throughput") { $impacts += "Performance" }
            if ($subject -match "(?i)breaking|deprecate|remove") { $impacts += "Breaking Change" }
            if ($subject -match "(?i)server|preset|api") { $impacts += "Server/API" }
            if ($subject -match "(?i)flash-attn|flashattn") { $impacts += "Flash Attention" }

            $commits.Add([pscustomobject]@{
                Hash = $hash
                Subject = $subject
                ImpactKeywords = $impacts
            })
        }

        return [pscustomobject]@{
            Branch = $branch
            IsLatest = $isLatest
            StatusMessage = $statusMessage
            BehindCount = $behindBy
            IsPullDiff = $isPullDiff
            LogRange = $logRange
            Commits = $commits.ToArray()
        }
    } finally {
        Set-Location $oldDir
    }
}

# If run directly
if ($MyInvocation.InvocationName -eq '.' -or $MyInvocation.InvocationName -eq '&' -or $MyInvocation.MyCommand.Name -eq 'GitDiff.ps1') {
    $diff = Get-LlamaGitStatus -RepoPath $LlamaRepoPath
    Write-Host "--- Git Status Report ---" -ForegroundColor Green
    Write-Host "Branch: $($diff.Branch)"
    Write-Host "Status: $($diff.StatusMessage)"
    Write-Host "Scanned commits ($($diff.LogRange)): $($diff.Commits.Count)"
    Write-Host ""
    Write-Host "Recent Highlights:" -ForegroundColor Cyan
    foreach ($c in $diff.Commits) {
        $impactStr = if ($c.ImpactKeywords.Count -gt 0) { "[" + ($c.ImpactKeywords -join ", ") + "]" } else { "" }
        $color = if ($c.ImpactKeywords -contains "Breaking Change") { "Red" } elseif ($c.ImpactKeywords.Count -gt 0) { "Yellow" } else { "DarkGray" }
        Write-Host "  $($c.Hash) - $($c.Subject) " -NoNewline -ForegroundColor White
        if ($impactStr) {
            Write-Host $impactStr -ForegroundColor $color
        } else {
            Write-Host ""
        }
    }
    Write-Host "-------------------------"
}
