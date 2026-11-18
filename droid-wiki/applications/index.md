# Applications

**Active contributors:** vijay

Deployable runtime entry points in LLM Manager.

## Application overview

| Application | Type | Entry Point | Description |
|-------------|------|-------------|-------------|
| **PowerShell CLI** | Console | `main.ps1`, `script/*.ps1` | Wizard, server lifecycle, health checks |
| **Tauri Desktop App** | GUI | `ui/` (React + Rust) | Visual dashboard for all CLI functionality |
| **Context Manager Proxy** | HTTP Service | `llo-core/context_manager/proxy.py` | Anthropic→OpenAI translation, session compression |

## PowerShell CLI

The primary command-line interface. Cross-platform (PowerShell 7+ on all OS, PowerShell 5.1 on Windows).

### Entry points

| Script | Purpose |
|--------|---------|
| `main.ps1` | Interactive setup wizard — configures paths, integrations, writes AppData config |
| `script/start-server.ps1` | Terminates existing server, runs SetupRouter, launches `llama-server` |
| `script/stop-server.ps1` | Graceful shutdown via PID lookup (Windows: WMI; macOS/Linux: lsof/ss) |
| `script/test-health.ps1` | Full health audit: syntax, config, hardware, live ping |
| `script/verify-scripts.ps1` | Flag compatibility: validates script args against `llama-server --help` |
| `script/StartContextManager.ps1` | Launches Python proxy on port 8090 (when enabled) |

### Key characteristics

- **No build step** — edit `.ps1` files directly
- **Cross-platform** — `$IsWindows`/`$IsMacOS`/`$IsLinux` guards throughout
- **AppData config** — reads/writes `%APPDATA%\LLM Manager\llo-config.json`
- **JSON output** — `-Json` switch for machine consumption
- **Dot-source modules** — `llo-core/Profile.ps1`, `SetupRouter.ps1`, `Paths.ps1`, etc.

[PowerShell CLI details →](powershell-cli.md)

## Tauri Desktop App

Native desktop application wrapping the PowerShell core with a React/TypeScript frontend.

### Architecture

```
ui/
├── src/                    # React 18 + TypeScript + Vite
│   ├── pages/              # Overview, Models, Performance, Settings, Diagnostics, Logs, Integrations
│   ├── store/              # Zustand stores (hardware, config, server, models, validation)
│   ├── components/         # Reusable UI (PageShell, ImpactBanner, InfoTooltip, layout)
│   └── lib/validation.ts   # Exact KV cache calculator (UI-side)
├── src-tauri/              # Rust backend
│   ├── src/commands/       # Tauri command handlers
│   │   ├── config.rs       # Config load/save (AppData)
│   │   ├── profile.rs      # Hardware detection bridge
│   │   ├── server.rs       # Start/stop, log tailing
│   │   ├── models.rs       # GGUF scanner + binary parser
│   │   ├── gguf.rs         # GGUF metadata extraction
│   │   └── health.rs       # Health check dispatcher
│   └── src/scripts.rs      # Workspace root resolution, PS dispatch
```

### Key features

- **Real-time hardware diagnostics** — Live CPU/GPU/RAM profile with tier badge
- **Model management** — Recursive GGUF scan, binary header inspection, template matching
- **Performance tuning** — Sliders for overrides (ctx_size, n_gpu_layers, ubatch, cache_type, etc.)
- **Live log streaming** — Tails `llama-server.log` and `llama-server.err.log` via Rust file watchers
- **Integration helpers** — One-click Claude Code launch, VSCode task generation, Cursor/Continue config
- **Settings persistence** — All config saved to AppData `llo-config.json`

[Tauri Desktop App details →](tauri-desktop-app.md)

## Context Manager Proxy

Optional Python FastAPI service for protocol translation and context compression.

### Architecture

```
llo-core/context_manager/
├── proxy.py              # FastAPI server, Anthropic→OpenAI translation, streaming
├── context_engine.py     # Compression logic, token counting, checkpoint persistence
├── tokenizer_cache.py    # Shared HF tokenizer with alias normalization
├── preset_reader.py      # models-preset.ini parser for ctx_limit
├── config.py             # Pydantic settings (ContextManagerConfig)
└── tests/                # 11 pytest modules
```

### Key features

- **Protocol translation** — Anthropic `/v1/messages` → OpenAI `/v1/chat/completions`
- **Session compression** — Summarizes old turns when `tokens + max_tokens >= ctx_limit * 0.70`
- **Checkpoint persistence** — Session state saved to `%APPDATA%\LLM Manager\checkpoints\`
- **Tokenizer cache** — Normalizes aliases (`claude-3-5-sonnet-20241022` → correct HF repo)
- **Preset-aware** — Reads `ctx_limit` from `models-preset.ini` (fallback 65536)

[Context Manager Proxy details →](context-manager-proxy.md)
