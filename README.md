# LLM Manager

[![PowerShell Version](https://img.shields.io/badge/PowerShell-7%2B-blue.svg)](https://learn.microsoft.com/en-us/powershell/)
[![Platform](https://img.shields.io/badge/platform-windows%20%7C%20macOS%20%7C%20linux-lightgrey.svg)](#platform-requirements)
[![llama.cpp Compatibility](https://img.shields.io/badge/llama.cpp-compatible-blueviolet.svg)](https://github.com/ggerganov/llama.cpp)
[![Optimization Status](https://img.shields.io/badge/optimization-hardware--adaptive-orange.svg)](#)

LLM Manager is a hardware-adaptive inference orchestrator built on top of **llama.cpp**. It profiles your system at startup, classifies your GPU, and derives every inference parameter — GPU offload layers, KV cache precision, context size, batch size, speculative decoding — automatically from the live hardware state. No manual configuration is needed for a typical deployment.

---

## 🖥️ Platform Requirements

LLM Manager supports cross-platform operations on **Windows, macOS, and Linux**. For detailed prerequisite setup instructions, installation commands, and shell setup scripts, please refer to the **[USER_GUIDE.md: Prerequisites by Platform](USER_GUIDE.md#0-prerequisites-by-platform)**.


---

## 📖 Quick Start & User Guide
If you want to get started immediately, set up your model paths, and run your local model server, refer to the **[USER_GUIDE.md](USER_GUIDE.md)**.

---

## 🛠️ What It Does

Profiles your host hardware (CPU cores, System RAM, GPU VRAM, CUDA/Metal support) at startup and automatically groups systems into performance tiers (`cpu`, `low`, `mid`, `high`). From these classifications, the decision engine automatically derives all tuning arguments (offload layers, Flash Attention, quantization precision, batch size, thread cap, etc.).

For the complete parameter policies table, decision flow diagram, and mathematical context allocation formulas, please refer to **[ARCHITECTURE.md: Core Formulas](ARCHITECTURE.md#3-core-formulas)**.

### 2. Explicit Override Support
Any auto-derived value can be overridden by adding an `overrides` block to `llo-config.json`:

```json
{
  "overrides": {
    "ctx_size": 32768,
    "ubatch_size": 512,
    "parallel": 1
  }
}
```

Override keys take absolute priority over hardware detection. All other parameters continue to be auto-derived.

### 3. Dynamic Client Routing
Configures multi-model hosting via `models-preset.ini`. Third-party clients (Claude Code, VSCode, Cursor, Continue) request models by alias, and the llama.cpp router automatically loads and swaps models within the VRAM budget.

### 4. Upstream Compatibility Guard
Tracks `llama.cpp` argument changes on `git pull`, validating script options against the current binary's `--help` output to prevent startup failures from deprecated or renamed flags.

### 5. Fallback & Bootstrapping
When no local GGUF models are found and no GPU is available, falls back to a lightweight Hugging Face bootstrap model. When a cloud fallback provider is configured, routes client traffic to Ollama, OpenAI, Anthropic, or NVIDIA NIM instead.

### 6. Desktop GUI Application
Provides a premium desktop GUI built with **Tauri + React + TypeScript** that visually mirrors all CLI functionality. It offers real-time server logging, system health audits, active model switching, and dynamic sliders for custom memory tuning and config overrides. Details are located in the user guide.

---

## 🔌 Integrations & Workspace Tools

LLM Manager automatically configures environment parameters and settings files to bridge local models to popular development tools:

- **VSCode Task Integration**: Automatically generates `.vscode/tasks.json` and `.vscode/settings.json` during wizard execution to let you start, stop, and audit the LLM server directly via `Ctrl+Shift+B` (Build Task) inside the workspace directory. Environment variables are injected for **Windows** (`terminal.integrated.env.windows`), **macOS** (`terminal.integrated.env.osx`), and **Linux** (`terminal.integrated.env.linux`) terminals.
- **Claude Code CLI Integration**: Start the server and launch the interactive Claude Code CLI launcher. It auto-configures `ANTHROPIC_BASE_URL`, sets `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = 1` to prevent unnecessary remote telemetry/routing, and sets `ANTHROPIC_AUTH_TOKEN = local` for a fully offline loop.
- **Cursor & Continue Setup**: Dynamically outputs configured JSON blocks and API endpoints (`http://127.0.0.1:<PORT>/v1`) for easy copy-paste setup in your client configuration.
- **Auditing & Test Suite**: The health script (`script/test-health.ps1`) verifies local PowerShell syntax, config schemas, hardware profiling limits, and conducts live TCP/REST API connectivity checks to ensure llama-server is healthy. Run via `powershell -File script\test-health.ps1` (Windows), `pwsh -File script/test-health.ps1` (macOS/Linux), or use the convenience wrapper `./script/test-health.sh` (macOS/Linux). Compatibility checks can also be run via `./script/verify-scripts.sh` (macOS/Linux) or `.\script\verify-scripts.ps1` (Windows).

---

## 🧪 Automated Testing & Verification

LLM Manager contains automated test suites and validation scripts covering its CLI scripts, Python context proxy, Rust Tauri backend, and React frontend.

### 1. PowerShell Script & System Health Audits
Run script syntax checks, compatibility audits, and full system health checks from the repository root:
```powershell
# Windows
.\script\verify-scripts.ps1
.\script\test-health.ps1

# macOS / Linux
./script/verify-scripts.sh
./script/test-health.sh
```

### 2. Python Context Manager Tests
Run the pytest test suite covering message compression, token counting, and Anthropic $\leftrightarrow$ OpenAI protocol conversion:
```powershell
# Using global pytest or active environment
pytest llo-core/context_manager/tests

# Or using the auto-created user venv
& "$env:APPDATA\LLM Manager\context_manager_venv\Scripts\python.exe" -m pytest llo-core/context_manager/tests
```

### 3. Tauri Desktop GUI (Rust Backend & React Frontend)
Navigate to the GUI directory to run type checking, unit tests, lints, and production installer packaging:
```powershell
# --- Frontend Testing & TypeScript Validation (ui/) ---
cd ui
npm run test           # 44 Vitest tests across stores, components, & flows
npm run build          # TypeScript type checking (tsc) + Vite production build

# --- Rust Backend Testing & Packaging (ui/src-tauri/) ---
cd src-tauri
cargo clippy           # Static analysis and lint checks
cargo test             # 12 Rust unit tests (GGUF parser, models, server)
npm run tauri build --release  # Packages full desktop installer (NSIS .exe / .dmg / .AppImage)
```

---

## 📐 System Architecture & Decision Engine
For the full decision tree, GPU classification logic, context-size formula, and parameter policy tables, read **[ARCHITECTURE.md](ARCHITECTURE.md)**.

---

**Tags**: `#llama.cpp-optimization` `#local-llm-router` `#hardware-adaptive` `#gpu-tier-classification` `#kv-cache-quantization` `#context-size-formula` `#cpu-thread-scheduling` `#offline-llm-hosting` `#local-ai-api`
