# LLM Manager

LLM Manager is a hardware-adaptive inference orchestrator built on top of [llama.cpp](https://github.com/ggerganov/llama.cpp). It profiles your host hardware (CPU cores, system RAM, and GPU VRAM) at startup, classifies the GPU into a performance tier, and derives every llama-server inference parameter — GPU offload layers, KV cache precision, context size, batch size, speculative decoding — automatically from the live hardware state. No manual configuration is needed for a typical deployment.

The project ships three runtime surfaces:

* **PowerShell CLI** (`llo-core/` and `script/`) — the setup wizard, hardware profiler, parameter derivation engine, server lifecycle scripts, and upstream compatibility guard.
* **Python Context Manager Proxy** (`llo-core/context_manager/`) — an optional proxy between clients and llama-server that translates the Anthropic protocol to OpenAI, compresses long sessions, and enforces a context-size budget.
* **Tauri Desktop App** (`ui/`) — a React + TypeScript frontend backed by Rust that mirrors the CLI functionality visually, with live server logging, health audits, model switching, and dynamic tuning sliders.

Configuration lives in the user's AppData directory (`%APPDATA%\LLM Manager\llo-config.json` on Windows, `~/.config/LLM Manager` on macOS/Linux), not in the workspace root. When the GUI launches a PowerShell script it passes its AppData config path via `-ConfigFile` so the backend acts on the GUI's configuration.

## Quick links

- [Architecture](architecture.md) — hardware classification, decision flow, core formulas
- [Getting started](getting-started.md) — prerequisites, install, build, test, run
- [Glossary](glossary.md) — project-specific terms
- [Applications](../applications/index.md) — CLI, desktop app, context manager proxy
- [Systems](../systems/index.md) — profiling, parameter derivation, server lifecycle, GGUF management, configuration, compatibility guard
- [Features](../features/index.md) — adaptive inference, client routing, context compression, integrations, upstream compatibility
- [Contributing](../how-to-contribute/index.md) — development workflow, testing, debugging
