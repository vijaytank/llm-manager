#!/usr/bin/env bash
# LLO run-setup.sh
# Convenience entry point for macOS and Linux users.
# Equivalent of: pwsh -File main.ps1
# Requires PowerShell 7+ (pwsh). Install via:
#   macOS  : brew install powershell
#   Ubuntu : sudo apt install powershell
#   Fedora : sudo dnf install powershell

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PWSH=""
for candidate in "$(command -v pwsh 2>/dev/null)" /usr/bin/pwsh /snap/bin/pwsh /usr/local/bin/pwsh; do
    if [ -n "$candidate" ] && [ -x "$candidate" ]; then
        PWSH="$candidate"
        break
    fi
done

if [ -z "$PWSH" ]; then
    echo "[ERROR] PowerShell 7 (pwsh) is not installed or not in PATH."
    echo "  macOS  : brew install powershell"
    echo "  Ubuntu : sudo apt install powershell"
    echo "  Fedora : sudo dnf install powershell"
    echo "  Other  : https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell"
    exit 1
fi

exec "$PWSH" -File "$SCRIPT_DIR/main.ps1" "$@"