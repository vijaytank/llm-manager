#!/usr/bin/env bash
# LLO test-health.sh
# Convenience wrapper for macOS and Linux.
# Requires PowerShell 7+ (pwsh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v pwsh &>/dev/null; then
    echo "[ERROR] PowerShell 7 (pwsh) is not installed or not in PATH."
    echo "  macOS  : brew install powershell"
    echo "  Ubuntu : sudo apt install powershell"
    exit 1
fi

exec pwsh -File "$SCRIPT_DIR/test-health.ps1" "$@"
