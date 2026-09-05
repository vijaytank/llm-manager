# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## ⚙️ Core Architecture
This project is a **hardware-adaptive inference orchestrator** built on top of `llama.cpp` (hosted locally) with a desktop GUI built using **Tauri + React + TypeScript** and a CLI scripting backend built using **PowerShell**.

The system profiles host hardware at startup, classifies the GPU and system memory, and dynamically computes optimal LLM inference parameters (layers, KV cache precision, context window, batch size, speculative decoding) to maximize token throughput and prevent Out-Of-Memory crashes.

**Key Architectural Components:**
*   **PowerShell Core (`llo-core/`)**:
    *   `Profile.ps1`: Probes CPU, RAM, and GPU capabilities across OS platforms.
    *   `SetupRouter.ps1`: Derives optimal inference arguments and generates the router preset `models-preset.ini`.
    *   `ParseHelp.ps1` / `GitDiff.ps1`: Scans upstream `llama-server --help` outputs and repository commits to check for breaking changes or new features.
    *   `FetchAssets.ps1`: Downloads and caches upstream templates and grammars.
*   **Operational Scripts (`script/`)**:
    *   `start-server.ps1` / `stop-server.ps1`: Server lifecycle controls. Includes Port Collision Protection (scans and shifts port).
    *   `test-health.ps1`: Performs script syntax checks and config validation.
    *   `verify-scripts.ps1`: Verifies CLI flags compatibility against the compiled binary.
    *   `StartContextManager.ps1`: Launches the Python context-manager proxy (only when `context_manager.enabled` is true in config).
*   **Context Manager Proxy (`llo-core/context_manager/`)**: A Python module that sits between clients and the llama-server, translating the Anthropic protocol to OpenAI's, compressing/replaying sessions, and enforcing a context-size cap (`ctx_limit`). Key files: `proxy.py` (HTTP round-trip + protocol translation), `context_engine.py` (compression, token counting, needs-compression heuristics), `tokenizer_cache.py` (shared HF tokenizer), `preset_reader.py` (parses `models-preset.ini`), `config.py` (settings model). Run via pytest — see Testing below.
*   **Tauri Desktop App (`ui/src-tauri/` & `ui/src/`)**:
    *   `ui/src-tauri/src/commands/`: Rust command handlers executing PowerShell backends and managing settings.
    *   `ui/src-tauri/src/scripts.rs`: Resolves the workspace root (dev vs. installed binary) and dispatches PowerShell scripts with `-File`.
    *   `ui/src/`: React frontend (pages/, store/ (zustand), lib/, components/) displaying system status, diagnostics, preset models list, performance tuning sliders, and live logs.

## 🛠️ Common Commands

### Setup & Server (CLI)
* Run wizard: `powershell -File main.ps1` (Windows) or `pwsh -File main.ps1` (macOS/Linux)
* Start server: `powershell -File script/start-server.ps1`
* Stop server: `powershell -File script/stop-server.ps1`
* Run health checks: `powershell -File script/test-health.ps1`
* Verify compatibility: `powershell -File script/verify-scripts.ps1`

### Context Manager (CLI)
* Launch proxy: `powershell -File script/StartContextManager.ps1 -Port 8090` (enabled only when `context_manager.enabled = true` in `llo-config.json`).
* Run tests: `pytest llo-core/context_manager/tests` (use the project venv at `llo-core/.venv` if no global pytest is available).

### Desktop UI Development
* Run UI in Dev mode: `npm run tauri dev` (inside `ui/` directory)
* Build release app: `npm run tauri build --release` (inside `ui/` directory)
* Frontend tests: `npm run test` (inside `ui/`)
* Rust backend: `cd ui/src-tauri && cargo test` (unit tests) and `cargo clippy` (lints)

## 🔗 Project Dependencies
* **llama.cpp**: Local compiled or pre-built binary (`llama-server`).
* **PowerShell 7+** (Cross-platform) or PowerShell 5.1 (Windows only).
* **Rust & Node.js**: Required for Tauri desktop application development.

## 🧭 Conventions & Gotchas

### Cross-platform PowerShell
Every OS-specific branch must be guarded by `$IsWindows`, `$IsMacOS`, or `$IsLinux` — never sprinkle Windows-only APIs (e.g. `Get-CimInstance Win32_*`) without an equivalent macOS/Linux branch. Resolve all file paths relative to `$PSScriptRoot`; never hardcode absolute drives like `C:\`.

### Configuration directory split
The Tauri app reads/writes its config from the user's AppData directory (`%APPDATA%\LLM Manager\llo-config.json` on Windows, `~/.config/LLM Manager` on macOS/Linux), not the workspace root. When the GUI launches a PowerShell script, it passes its AppData path via `-ConfigFile` so the backend acts on the GUI's config. The `llo-core` helper `Paths.ps1` (`Get-LLMManagerConfigPath`) implements this lookup.

### Integration provisioning
The wizard (`main.ps1`) generates a `.vscode/` folder with `tasks.json` (start/stop/audit tasks) and `settings.json` (injects env keys into the VSCode terminal env for each OS). When the `claude-code` integration is active it sets `ANTHROPIC_BASE_URL` to the server endpoint, `ANTHROPIC_AUTH_TOKEN = local`, and `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = 1`.

### Legacy config promotions
`SetupRouter.ps1` promotes any flat legacy keys found in `llo-config.json` (e.g. `cache_type_k`, `flash_attn`) into the `overrides` block. Because overrides take absolute priority over hardware detection, these promoted keys can lock derived parameters to historical values.

## 📝 Commit & PR Conventions
* **Conventional Commits** — `<type>(<scope>): <subject>` (types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`).
* **Mandatory health check before a PR**: `powershell -File script/test-health.ps1` (or the `.sh` wrapper on macOS/Linux).
* The repo's default/primary branch is **`develop`** (CONTRIBUTING.md mentions `master`/`main`, but the project targets `develop`).
