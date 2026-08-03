# CLAUDE.md

This file provides guidance to Claude Code when working in this repository.

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
*   **Tauri Desktop App (`ui/` & `ui-src-tauri/`)**:
    *   `ui-src-tauri/src/commands/`: Rust command handlers executing PowerShell backends and managing settings.
    *   `ui/src/`: React frontend displaying system status, diagnostic checks, preset models list, and performance tuning sliders.

## 🛠️ Common Commands

### Setup & Server (CLI)
* Run wizard: `powershell -File main.ps1` (Windows) or `pwsh -File main.ps1` (macOS/Linux)
* Start server: `powershell -File script/start-server.ps1`
* Stop server: `powershell -File script/stop-server.ps1`
* Run health checks: `powershell -File script/test-health.ps1`
* Verify compatibility: `powershell -File script/verify-scripts.ps1`

### Desktop UI Development
* Run UI in Dev mode: `npm run tauri dev` (inside `ui/` directory)
* Build release app: `npm run tauri build` (inside `ui/` directory)

## 🔗 Project Dependencies
* **llama.cpp**: Local compiled or pre-built binary (`llama-server`).
* **PowerShell 7+** (Cross-platform) or PowerShell 5.1 (Windows only).
* **Rust & Node.js**: Required for Tauri desktop application development.