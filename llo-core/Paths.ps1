# LLO Paths.ps1
# Shared helper functions for cross-platform AppData, Config, and User data directory resolution.

function Get-LLMManagerAppDataDir {
    if ($IsWindows) {
        if ($env:APPDATA) {
            return $env:APPDATA
        } elseif ($env:USERPROFILE) {
            return Join-Path $env:USERPROFILE "AppData/Roaming"
        }
    } else {
        if ($env:XDG_CONFIG_HOME) {
            return $env:XDG_CONFIG_HOME
        } elseif ($env:HOME) {
            return Join-Path $env:HOME ".config"
        }
    }
    return $null
}

function Get-LLMManagerUserDataDir {
    $base = Get-LLMManagerAppDataDir
    if ($base) {
        return Join-Path $base "LLM Manager"
    }
    return $null
}

function Get-LLMManagerConfigPath {
    param([string]$ManagerDir = "")
    $userDir = Get-LLMManagerUserDataDir
    if ($userDir) {
        $appDataConfig = Join-Path $userDir "llo-config.json"
        if (Test-Path $appDataConfig -ErrorAction SilentlyContinue) {
            return $appDataConfig
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ManagerDir)) {
        return Join-Path $ManagerDir "llo-config.json"
    }
    return $null
}
