# Dynamic Client Routing

**Active contributors:** Vijay

Multi-model hosting through a generated `models-preset.ini`, automatic client configuration, and seamless routing of IDE and CLI clients to the local `llama-server` by model alias.

## Purpose

`llo-core/SetupRouter.ps1` recursively scans `models_dir` for `.gguf` files, derives per-model inference parameters, and writes `models-preset.ini` — consumed by `llama-server --models-preset`. Clients (Claude Code, Cursor, Continue, any OpenAI-compatible SDK) request a model by its alias, and `llama-server` swaps the resident model within the VRAM budget enforced by `--fit`/`fit-target`. `script/start-server.ps1` runs port collision protection and exports the resolved port to all client environment variables. See [systems/parameter-derivation.md](../systems/parameter-derivation.md) for preset generation and [overview/architecture.md](../overview/architecture.md) for the pipeline overview.

## Directory layout

```
llo-core/
├── SetupRouter.ps1   # Recursive GGUF scan, per-model params, preset generation, alias assignment
script/
├── start-server.ps1  # Port collision scan, llama-server launch, env var export
├── stop-server.ps1   # Graceful shutdown
main.ps1              # Wizard: client integration offers + .vscode provisioning
ui/src-tauri/src/
└── commands/server.rs # Tauri bridge: launch_claude_terminal, server lifecycle
```

## Key Abstractions

| Abstraction | Responsibility | Primary interface |
|-------------|---------------|-------------------|
| `models-preset.ini` entry | Per-model block: `model`, `alias`, `chat_template`, `n_gpu_layers`, `ctx_size`, `cache_type`, `flash_attn`, `parallel`, `spec_type`, `fit` | Consumed by `llama-server --models-preset` |
| Model alias | Short name clients use to address a hosted model (e.g. `my-model`) | Assigned during preset generation |
| `models_dir` scan | Recursive discovery of `.gguf` files with metadata parsing and template matching | `llo-core/SetupRouter.ps1` |
| Port collision protection | TCP listener scan that shifts the port upward until a free socket is found | `script/start-server.ps1` |
| Client env vars | `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN=local`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`, etc. | Exported to shell/IDE terminals |

## How it works

```mermaid
sequenceDiagram
    participant MD as models_dir (GGUF files)
    participant R as llo-core/SetupRouter.ps1
    participant PI as models-preset.ini
    participant LS as llama-server
    participant C as Client (Claude Code / Cursor / Continue)
    participant SS as script/start-server.ps1
    MD->>R: Recursive .gguf scan + metadata
    R->>R: Per-model ctx_size, spec_type, template match
    R->>PI: Write models-preset.ini (alias → model path + params)
    SS->>SS: Port collision scan (increment until free)
    SS->>LS: llama-server --models-preset models-preset.ini --port <resolved>
    LS-->>SS: Ready; models resident within VRAM budget (fit-throttle)
    SS->>C: Export env vars with resolved port
    C->>LS: POST /v1/chat/completions {"model": "alias", ...}
    LS->>LS: Swap resident model within fit-target VRAM budget
    LS-->>C: Streamed completion
```

### Models preset format

```ini
; models-preset.ini (regenerated at each server start)
[model-alias]
model = /absolute/path/to/model.gguf
alias = model-alias
chat_template = /absolute/path/to/template.jinja
n_gpu_layers = -1
ctx_size = 32768
ubatch_size = 512
cache_type_k = q8_0
cache_type_v = q8_0
flash_attn = on
parallel = 1
spec_type = ngram-simple
context_shift = true
cache_reuse = 256
mmap = 1
```

Clients request by alias:

```bash
curl -H "Authorization: Bearer local" http://127.0.0.1:8080/v1/chat/completions \
  -d '{"model":"model-alias","messages":[{"role":"user","content":"Hello"}]}'
```

### VRAM-bounded model swapping

`llama-server` loads the models declared in the preset and the `--fit` throttle (see [Hardware-Adaptive Inference](hardware-adaptive-inference.md#vram-budget-and-fit-throttle)) reduces `n_gpu_layers` until each model fits the tier's VRAM budget (`fit-target` 512 MB for `low`, 1024 MB for `mid`/`high`). This prevents silent VRAM spill — a ~90% throughput collapse — when multiple models share one GPU.

### Port collision protection

```powershell
# In script/start-server.ps1
$properties = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties()
$listeners = $properties.GetActiveTcpListeners()

while ($listeners | Where-Object { $_.Port -eq $Port }) {
    $Port++
    $listeners = $properties.GetActiveTcpListeners()
}
```

Scans active TCP listeners via .NET `IPGlobalProperties`, increments the port until a free socket is found, and propagates the resolved port into every exported client env URL.

### Client environment variables

Exported by `script/start-server.ps1` and provisioned to IDEs via the wizard:

| Variable | Example value | Purpose |
|----------|---------------|---------|
| `ANTHROPIC_BASE_URL` | `http://127.0.0.1:8080` | Routes Anthropic SDK to the local server |
| `ANTHROPIC_AUTH_TOKEN` | `local` | Bypasses auth (llama-server accepts any token) |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | `1` | Disables remote telemetry/routing |
| `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY` | `1` | Enables model discovery via gateway |

When the Context Manager Proxy is enabled, clients point at port `8090` instead of `8080` — see [applications/context-manager-proxy.md](../applications/context-manager-proxy.md).

### Client configuration

#### VSCode (generated by `main.ps1` wizard)

**`.vscode/tasks.json`:**
```json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Start LLM Server",
      "type": "shell",
      "command": "powershell.exe",
      "args": ["-File", "script/start-server.ps1"],
      "group": "build",
      "presentation": { "reveal": "always" }
    },
    {
      "label": "Stop LLM Server",
      "type": "shell",
      "command": "powershell.exe",
      "args": ["-File", "script/stop-server.ps1"]
    },
    {
      "label": "Audit LLM Manager",
      "type": "shell",
      "command": "powershell.exe",
      "args": ["-File", "script/test-health.ps1"],
      "group": "test"
    }
  ]
}
```

**`.vscode/settings.json`** (OS-specific terminal env, one block each for `windows`, `osx`, `linux`):
```json
{
  "terminal.integrated.env.windows": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8080",
    "ANTHROPIC_AUTH_TOKEN": "local",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1"
  }
}
```

Usage: `Ctrl+Shift+B` → "Start LLM Server" (group: build). Shell: `powershell.exe` on Windows, `pwsh` on macOS/Linux.

#### Claude Code CLI

```bash
# Windows (PowerShell)
$env:ANTHROPIC_BASE_URL="http://127.0.0.1:8080"
$env:ANTHROPIC_AUTH_TOKEN="local"
$env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1"
$env:CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY="1"
claude --model local

# macOS/Linux (bash/zsh)
export ANTHROPIC_BASE_URL=http://127.0.0.1:8080
export ANTHROPIC_AUTH_TOKEN=local
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
claude --model local
```

`--model local` uses the alias from `models-preset.ini` (first model by default); the active model can be changed from the Tauri Overview page, which updates `active_model` in config.

#### Cursor

`~/.cursor/settings.json` or Settings UI:
```json
{
  "openaiApiBase": "http://127.0.0.1:8080/v1",
  "openaiApiKey": "local"
}
```
With the Context Manager Proxy enabled, use `http://127.0.0.1:8090/v1`.

#### Continue

`~/.continue/config.json`:
```json
{
  "models": [
    {
      "title": "Local LLM Manager",
      "provider": "openai",
      "model": "my-model",
      "apiBase": "http://127.0.0.1:8080/v1",
      "apiKey": "local",
      "contextLength": 32768
    }
  ]
}
```
The model title must match a `models-preset.ini` alias. With the proxy enabled, use `http://127.0.0.1:8090/v1`.

#### Generic OpenAI-compatible client

```python
from openai import OpenAI
client = OpenAI(base_url="http://127.0.0.1:8080/v1", api_key="local")
response = client.chat.completions.create(
    model="model-alias-from-preset",
    messages=[{"role": "user", "content": "Hello"}]
)
```

### Fallback routing and bootstrap model

When no local GGUF models are found (`$models.Count -eq 0`):
- Skips `llama-server` launch entirely
- Exports client env vars pointing to a cloud fallback provider (`anthropic`, `openai`, `nim` NVIDIA NIM, or `ollama`)

When no models and no fallback are configured, the wizard can download a lightweight bootstrap model (`Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF` from Hugging Face) and launch it via `llama-server -hf Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF` for immediate usability.

## Integration points

- [overview/architecture.md](../overview/architecture.md) — hardware classification and decision flow that feeds per-model parameters.
- [systems/parameter-derivation.md](../systems/parameter-derivation.md) — `models-preset.ini` generation, template matching, per-model ctx size.
- [systems/compatibility-guard.md](../systems/compatibility-guard.md) — preset flags validated against the `llama-server` binary.
- [applications/context-manager-proxy.md](../applications/context-manager-proxy.md) — proxy port routing when context compression is enabled.
- [applications/powershell-cli.md](../applications/powershell-cli.md) — server start/stop lifecycle and CLI wizard integration offers.

## Entry points for modification

| Task | Entry point | File |
|------|-------------|------|
| Change model discovery (extensions, depth) | Recursive `.gguf` scan | `llo-core/SetupRouter.ps1` |
| Change preset entry fields or defaults | Preset writer block | `llo-core/SetupRouter.ps1` |
| Change port scan behavior | `IPGlobalProperties` listener loop | `script/start-server.ps1` |
| Change exported env vars | Env export block | `script/start-server.ps1` |
| Change VSCode tasks/settings shapes | Wizard file writers | `main.ps1` |
| Change Tauri launch command | `launch_claude_terminal` | `ui/src-tauri/src/commands/server.rs` |

## Key source files

| File | Purpose |
|------|---------|
| `script/start-server.ps1` | Port scan, `llama-server` launch, env var export |
| `llo-core/SetupRouter.ps1` | Preset generation, model alias assignment, GGUF scan |
| `main.ps1` | VSCode tasks/settings generation, client integration offers |
| `script/stop-server.ps1` | Cross-platform process termination |
| `ui/src-tauri/src/commands/server.rs` | `launch_claude_terminal` Tauri command |
| `ui/src/pages/Integrations.tsx` | Copy-paste config block generators |
| `ui/src/pages/Overview.tsx` | Model dropdown with aliases |

## Related Pages

- [overview/architecture.md](../overview/architecture.md) — hardware classification, decision flow, core formulas
- [systems/parameter-derivation.md](../systems/parameter-derivation.md) — models-preset.ini generation
- [systems/compatibility-guard.md](../systems/compatibility-guard.md) — llama-server argument compatibility
- [applications/context-manager-proxy.md](../applications/context-manager-proxy.md) — context manager proxy
- [applications/powershell-cli.md](../applications/powershell-cli.md) — PowerShell CLI wizard
