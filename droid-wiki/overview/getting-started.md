# Getting started

LLM Manager runs on Windows, macOS, and Linux. It requires PowerShell 7+ (cross-platform) or PowerShell 5.1 (Windows only), a compiled or pre-built `llama-server` binary from llama.cpp, and (for the desktop UI) Rust and Node.js.

## Prerequisites

* PowerShell 7+
* `llama-server` binary (from [llama.cpp](https://github.com/ggerganov/llama.cpp))
* Rust and Node.js — only needed to build or run the Tauri desktop app
* Python 3 + pytest — only needed to run the context manager proxy tests

## Install and run the CLI wizard

From the repository root:

```powershell
pwsh -File main.ps1
```

The interactive wizard collects your model paths, cloud fallback settings, and integration preferences, then writes `llo-config.json` and runs `SetupRouter.ps1` to generate `models-preset.ini`.

## Start and stop the server

```powershell
# Start llama-server (auto-derives parameters, scans for port collisions)
pwsh -File script/start-server.ps1

# Stop the running server
pwsh -File script/stop-server.ps1
```

## Run health and compatibility checks

```powershell
# Syntax checks, config validation, live server ping
pwsh -File script/test-health.ps1

# Verify CLI flags against the compiled llama-server binary
pwsh -File script/verify-scripts.ps1
```

Bash wrappers exist for macOS/Linux: `./script/test-health.sh` and `./script/verify-scripts.sh`.

## Run tests

PowerShell health scripts cover CLI syntax and config schemas. The Python context manager proxy has 11 pytest modules:

```powershell
pytest llo-core/context_manager/tests
```

Or using the project virtualenv:

```powershell
& "llo-core/.venv\Scripts\python.exe" -m pytest llo-core/context_manager/tests
```

## Build and run the desktop UI

Inside `ui/`:

```powershell
# Dev mode
npm run tauri dev

# Production build (NSIS .exe / .dmg / .AppImage)
npm run tauri build --release

# Frontend type check + build
npm run build

# Rust backend tests and lints
cd src-tauri
cargo test
cargo clippy
```

## Configuration directory split

The Tauri app reads and writes `llo-config.json` from the user's AppData directory (`%APPDATA%\LLM Manager\llo-config.json` on Windows, `~/.config/LLM Manager` on macOS/Linux), not the workspace root. When the GUI launches `start-server.ps1` or `stop-server.ps1`, it passes its AppData config path via `-ConfigFile`. The `llo-core` helper `Paths.ps1` (`Get-LLMManagerConfigPath`) implements this lookup.

## Related pages

- [Architecture](architecture.md) — hardware classification, decision flow, core formulas
- [Systems](../systems/index.md) — profiling, parameter derivation, server lifecycle, GGUF management, configuration, compatibility guard
- [Testing](../how-to-contribute/testing.md) — how to run each test suite
- [Debugging](../how-to-contribute/debugging.md) — logs, common errors, troubleshooting
