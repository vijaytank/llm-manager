# Features

**Active contributors:** vijay

Cross-cutting capabilities that span multiple systems.

## Feature overview

| Feature | Description | Systems Involved |
|---------|-------------|------------------|
| **Hardware-Adaptive Inference** | Auto-derives all llama.cpp flags from live hardware state | Hardware Profiling, Parameter Derivation, Server Lifecycle |
| **Dynamic Client Routing** | Multi-model hosting via preset, client env export, port collision protection | Server Lifecycle, Configuration, Parameter Derivation |
| **Context Compression** | Anthropic→OpenAI translation, session summarization, checkpoint persistence | Context Manager Proxy, Configuration |
| **Client Integrations** | VSCode tasks, Claude Code CLI, Cursor, Continue, Continue | Configuration, Server Lifecycle, Wizard |
| **Upstream Compatibility** | Flag parsing, git change detection, asset sync | Compatibility Guard, Parameter Derivation |

## Hardware-Adaptive Inference

The core value proposition: zero-config llama.cpp deployment that adapts to any hardware.

**Flow:**
1. `Profile.ps1` detects CPU/RAM/GPU → `SystemHardwareProfile`
2. `SetupRouter.ps1` classifies `PerformanceTier` (cpu/low/mid/high)
3. Selects base parameter table per tier
4. Applies conditional upgrades (`parallel=2`)
5. Applies `config.overrides` (absolute priority)
6. Computes per-model `ctx_size` (RAM-bound ceiling)
7. Validates speculative decoding compatibility
8. Writes `models-preset.ini` → `llama-server`

[Details →](hardware-adaptive-inference.md)

## Dynamic Client Routing

Multi-model hosting with automatic client configuration.

**Components:**
- `models-preset.ini` — consumed by `llama-server --models-preset`
- Port collision protection — auto-scans and shifts port
- Client env export — `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN=local`, etc.
- VSCode tasks — `.vscode/tasks.json` + OS-specific terminal env
- Claude Code launch — interactive terminal with env pre-set

[Details →](dynamic-client-routing.md)

## Context Compression

Optional Python proxy for long-context sessions.

**Features:**
- Anthropic Messages API → OpenAI Chat Completions translation
- Compression trigger: `tokens + max_tokens >= ctx_limit * 0.70`
- Preserves last 6 turns, summarizes older via `llama-server`
- Idempotent via SHA256 of turns-to-summarize
- Checkpoint persistence to AppData
- Tokenizer cache with alias normalization

[Details →](context-compression.md)

## Client Integrations

Seamless setup for popular development tools.

| Integration | Configuration | Launch Method |
|-------------|---------------|---------------|
| **VSCode** | `.vscode/tasks.json`, `.vscode/settings.json` | Ctrl+Shift+B → "Start LLM Server" |
| **Claude Code** | `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN=local` | Wizard offer / Tauri button / manual |
| **Cursor** | `http://127.0.0.1:8080/v1` as OpenAI base | Manual config |
| **Continue** | `http://127.0.0.1:8080/v1` as OpenAI base | Manual config |
| **Continue** | `http://127.0.0.1:8080/v1` as OpenAI base | Manual config |

[Details →](client-integrations.md)

## Upstream Compatibility

Proactive protection against llama.cpp breaking changes.

**Three layers:**
1. **Flag parser** — `llama-server --help` → alias registry → diff vs cache
2. **Git scanner** — `git fetch` + commit keyword classification
3. **Asset sync** — SHA-cached template/grammar download

[Details →](upstream-compatibility.md)
