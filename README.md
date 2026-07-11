# LLM Manager

[![PowerShell Version](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-blue.svg)](https://learn.microsoft.com/en-us/powershell/)
[![Platform](https://img.shields.io/badge/platform-windows-lightgrey.svg)](https://www.microsoft.com/windows)
[![llama.cpp Compatibility](https://img.shields.io/badge/llama.cpp-compatible-blueviolet.svg)](https://github.com/ggerganov/llama.cpp)
[![Optimization Status](https://img.shields.io/badge/optimization-automated-orange.svg)](#)

> **Tags & Keywords**: `llama.cpp-optimization` `local-llm-router` `gpu-vram-fitting` `cpu-thread-scheduling` `kv-cache-quantization` `chat-template-mapping` `port-collision-scanner` `offline-llm-hosting` `local-ai-api`

LLM Manager is an automated system-specific performance optimization tool and client integration router built on top of **llama.cpp**. It simplifies the configuration, hardware tuning, and deployment of local Large Language Models (LLMs) to ensure your local server runs at maximum speed and efficiency without manual configuration errors.

---

## 📖 Quick Start & User Guide
If you want to get started immediately, set up your model paths, and optimize your local model server, please refer to the **[USER_GUIDE.md](USER_GUIDE.md)** at the root of the repository.

---

## 🛠️ Project Goals & Optimization Scope

1. **Automated Hardware Profiling & Tuning**: Profiles your system specifications (CPU P-cores, RAM capacity, GPU architecture, VRAM size) to auto-tune parameters such as thread count, GPU offload layers (`n-gpu-layers`), KV cache precision, and context window sizing without user intervention.
2. **Dynamic Client Routing**: Configures multi-model hosting. Third-party clients (VSCode, Claude Code, Cursor, Continue) request models by file alias, and the server router automatically loads and swaps them dynamically within your VRAM budget.
3. **Upstream Compatibility Guard**: Automatically tracks updates, deprecations, and additions in the `llama.cpp` repository upon `git pull`, validating script options to prevent startup failures.
4. **Bootstrapping & Fallback Routing**: Dynamically routes client traffic to Ollama or public cloud endpoints (OpenAI, Anthropic, NVIDIA NIM) when no local GGUF models are loaded.

---

## 📐 System Architecture & Decision Engine
To see the internal decision trees, mathematical budgets, and technical workflows of the manager's auto-tuning engine, read the **[ARCHITECTURE.md](ARCHITECTURE.md)** guide.
