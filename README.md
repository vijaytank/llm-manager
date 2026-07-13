# LLM Manager

[![PowerShell Version](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-blue.svg)](https://learn.microsoft.com/en-us/powershell/)
[![Platform](https://img.shields.io/badge/platform-windows-lightgrey.svg)](https://www.microsoft.com/windows)
[![llama.cpp Compatibility](https://img.shields.io/badge/llama.cpp-compatible-blueviolet.svg)](https://github.com/ggerganov/llama.cpp)
[![Optimization Status](https://img.shields.io/badge/optimization-hardware--adaptive-orange.svg)](#)

LLM Manager is a hardware-adaptive inference orchestrator built on top of **llama.cpp**. It profiles your system at startup, classifies your GPU, and derives every inference parameter — GPU offload layers, KV cache precision, context size, batch size, speculative decoding — automatically from the live hardware state. No manual configuration is needed for a typical deployment.

---

## 📖 Quick Start & User Guide
If you want to get started immediately, set up your model paths, and run your local model server, refer to the **[USER_GUIDE.md](USER_GUIDE.md)**.

---

## 🛠️ What It Does

### 1. Hardware-Adaptive Inference Configuration
Profiles your CPU, RAM, and GPU at every startup. GPU adapters are classified into two orthogonal dimensions:

- **AdapterClass** — `none | integrated | dedicated`  
  Describes the hardware type: is this a discrete card with onboard VRAM, or a shared-memory integrated adapter?

- **PerformanceTier** — `cpu | low | mid | high`  
  Drives the inference parameter policy: what values should every llama.cpp argument take?

From those two facts, the system derives every parameter automatically:

| Parameter | CPU / Integrated | Low (2–4 GB) | Mid (4–8 GB) | High (>8 GB) |
|---|---|---|---|---|
| `n-gpu-layers` | `0` | `-1` + fit | `-1` + fit | `-1` + fit |
| `flash-attn` | `off` | `on` | `on` | `on` |
| `fit` | `off` | `on` | `on` | `on` |
| `cache-type-k/v` | `f16` | `q8_0` | `q8_0` | `q8_0` / `f16 >12 GB` |
| `ubatch-size` | `128` | `256` | `512` | `1024` |
| `spec-type` | `ngram-simple`* | `none` | `ngram-simple`* | `ngram-simple`* |
| `parallel` | `1` | `1` | `1–2`† | `1–2`† |

\* Validated per-model (skipped for MoE / multimodal architectures)  
† Upgraded to `2` only when both VRAM budget and system RAM confirm headroom

**Context size** is also computed per-model using a formula that accounts for model weight footprint, KV cache pressure at the target context and concurrency level, and available RAM/VRAM — always treated as a ceiling, never a floor.

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

---

## 🔌 Integrations & Workspace Tools

LLM Manager automatically configures environment parameters and settings files to bridge local models to popular development tools:

- **VSCode Task Integration**: Automatically generates `.vscode/tasks.json` and `.vscode/settings.json` during wizard execution to let you start, stop, and audit the LLM server directly via `Ctrl+Shift+B` (Build Task) inside the workspace directory.
- **Claude Code CLI Integration**: Start the server and launch the interactive Claude Code CLI launcher. It auto-configures `ANTHROPIC_BASE_URL`, sets `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = 1` to prevent unnecessary remote telemetry/routing, and sets `ANTHROPIC_AUTH_TOKEN = local` for a fully offline loop.
- **Cursor & Continue Setup**: Dynamically outputs configured JSON blocks and API endpoints (`http://127.0.0.1:<PORT>/v1`) for easy copy-paste setup in your client configuration.
- **Auditing & Test Suite**: The health script (`script/test-health.ps1`) verifies local PowerShell syntax, config schemas, hardware profiling limits, and conducts live TCP/REST API connectivity checks to ensure llama-server is healthy.

---

## 📐 System Architecture & Decision Engine
For the full decision tree, GPU classification logic, context-size formula, and parameter policy tables, read **[ARCHITECTURE.md](ARCHITECTURE.md)**.

---

**Tags**: `#llama.cpp-optimization` `#local-llm-router` `#hardware-adaptive` `#gpu-tier-classification` `#kv-cache-quantization` `#context-size-formula` `#cpu-thread-scheduling` `#offline-llm-hosting` `#local-ai-api`
