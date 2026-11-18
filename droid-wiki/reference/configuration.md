# Configuration reference

**Active contributors:** vijay

Complete `llo-config.json` schema with all keys, types, defaults, and descriptions.

## File location

**Primary (runtime):** `%APPDATA%\LLM Manager\llo-config.json` (Windows) / `~/.config/LLM Manager/llo-config.json` (macOS/Linux)

**Template (workspace):** `llo-config.json` (copied to AppData on first launch)

## Complete schema

```json
{
  "installation_type": "local",
  "llama_server_path": "",
  "llama_repo_path": "",
  "models_dir": "",
  "templates_dir": "",
  "grammars_dir": "",
  "active_model": "",
  "use_default_template": false,
  "fit_ctx_min": 8192,
  "cache_type_k": "q8_0",
  "cache_type_v": "q8_0",
  "flash_attn": "on",
  "context_shift": true,
  "default_context_size": 32768,
  "ubatch_size": 512,
  "parallel_slots": -1,
  "threads": 8,
  "prio": 0,
  "mlock": false,
  "spec_type": "ngram-simple",
  "spec_ngram_simple_size_n": 12,
  "cache_prompt": false,
  "cache_reuse": 256,
  "cache_ram": 0,
  "sleep_idle_seconds": 60,
  "reasoning": "",
  "reasoning_format": "parsed",
  "reasoning_budget": 0,
  "overrides": {},
  "integrations": ["server-only"],
  "idle_timeout_sec": 60,
  "fallback_provider": "none",
  "fallback_api_key": "",
  "fallback_endpoint": "",
  "fallback_model": "",
  "mmproj_path": "",
  "mmproj_no_offload": false,
  "active_template": "",
  "context_manager": {
    "enabled": false,
    "warn_threshold": 0.70,
    "keep_turns": 6,
    "proxy_port": 8090,
    "llama_server_url": "http://127.0.0.1:8080",
    "ctx_limit": 0,
    "tokenizer_repo": "",
    "summary_max_tokens": 768,
    "summarize_with_model": "same",
    "eviction_interval_sec": 300,
    "session_ttl_sec": 86400
  }
}
```

## Key definitions

### Core paths

| Key | Type | Required | Default | Description |
|-----|------|----------|---------|-------------|
| `installation_type` | string | Yes | `"local"` | `"local"` or `"github"` (affects VSCode task shell) |
| `llama_server_path` | string | Yes | `""` | Absolute path to `llama-server` binary |
| `llama_repo_path` | string | No | `""` | Path to llama.cpp repo (for GitDiff, asset sync) |
| `models_dir` | string | Yes | `""` | Directory containing `.gguf` files (recursive scan) |
| `templates_dir` | string | No | `""` | Directory containing `.jinja` chat templates |
| `grammars_dir` | string | No | `""` | Directory containing `.gbnf` grammar files |

### Model selection

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `active_model` | string | `""` | Model alias from preset (empty = first discovered) |
| `use_default_template` | bool | `false` | Use bundled `default.jinja` for all models |
| `active_template` | string | `""` | Explicit template file (overrides auto-match) |
| `mmproj_path` | string | `""` | Vision projector path (paired with active_model) |
| `mmproj_no_offload` | bool | `false` | CPU offload for mmproj (saves VRAM) |

### Inference parameters (legacy flat keys — auto-promoted to overrides)

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `fit_ctx_min` | int | `8192` | Minimum context for `--fit` |
| `cache_type_k` | string | `"q8_0"` | KV K cache quantization (`f16`, `q8_0`, `q4_0`) |
| `cache_type_v` | string | `"q8_0"` | KV V cache quantization |
| `flash_attn` | string | `"on"` | Flash Attention (`on`, `off`) |
| `context_shift` | bool | `true` | Enable context shifting |
| `default_context_size` | int | `32768` | Fallback context size |
| `ubatch_size` | int | `512` | Physical batch size |
| `parallel_slots` | int | `-1` | `-1`=auto, `>0`=explicit parallel slots |

### Advanced llama.cpp parameters (SYSTEM_COMMANDS.md)

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `threads` | int | `8` | CPU threads (`-t`) |
| `prio` | int | `0` | Process priority |
| `mlock` | bool | `false` | Lock memory (`--mlock`) |
| `spec_type` | string | `"ngram-simple"` | Speculative decoding type |
| `spec_ngram_simple_size_n` | int | `12` | N-gram size |
| `cache_prompt` | bool | `false` | Cache prompt (`--cache-prompt`) |
| `cache_reuse` | int | `256` | Cache reuse tokens |
| `cache_ram` | int | `0` | Cache in RAM (MB) |
| `sleep_idle_seconds` | int | `60` | Idle timeout (`--sleep-idle-seconds`) |
| `reasoning` | string | `""` | Reasoning format |
| `reasoning_format` | string | `"parsed"` | Reasoning format |
| `reasoning_budget` | int | `0` | Reasoning token budget |

### Overrides block (absolute priority)

```json
"overrides": {
  "ctx_size": 65536,
  "n_gpu_layers": -1,
  "ubatch_size": 1024,
  "parallel": 2,
  "cache_type_k": "f16",
  "cache_type_v": "f16",
  "flash_attn": "on",
  "spec_type": "ngram-simple"
}
```

**Any key here bypasses hardware derivation entirely.**

### Integrations

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `integrations` | string[] | `["server-only"]` | Active integrations |
| `idle_timeout_sec` | int | `60` | Server idle timeout (seconds) |

**Integration values:**
- `"server-only"` — No client integration (default)
- `"vscode"` — VSCode tasks + terminal env
- `"claude-code"` — Claude Code CLI (forces `parallel>=2`, `idle_timeout_sec>=600`)
- `"cursor"` — Cursor IDE config helper
- `"continue"` — Continue extension config helper

### Cloud fallback

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `fallback_provider` | string | `"none"` | `"none"`, `"anthropic"`, `"openai"`, `"nim"`, `"ollama"` |
| `fallback_api_key` | string | `""` | API key for cloud provider |
| `fallback_endpoint` | string | `""` | Custom endpoint (optional) |
| `fallback_model` | string | `""` | Model name for cloud provider |

**Behavior:** When no local models found, routes client traffic to cloud provider instead of starting `llama-server`.

### Context Manager Proxy

```json
"context_manager": {
  "enabled": false,
  "warn_threshold": 0.70,
  "keep_turns": 6,
  "proxy_port": 8090,
  "llama_server_url": "http://127.0.0.1:8080",
  "ctx_limit": 0,
  "tokenizer_repo": "",
  "summary_max_tokens": 768,
  "summarize_with_model": "same",
  "eviction_interval_sec": 300,
  "session_ttl_sec": 86400
}
```

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `enabled` | bool | `false` | Master switch |
| `warn_threshold` | float | `0.70` | Compression trigger (0.0–1.0) |
| `keep_turns` | int | `6` | Recent turns preserved |
| `proxy_port` | int | `8090` | Proxy listen port |
| `llama_server_url` | string | `"http://127.0.0.1:8080"` | Upstream llama-server |
| `ctx_limit` | int | `0` | Context limit; 0 = auto from preset |
| `tokenizer_repo` | string | `""` | Explicit HF tokenizer repo |
| `summary_max_tokens` | int | `768` | Max summary tokens |
| `summarize_with_model` | string | `"same"` | Model alias for summarization |
| `eviction_interval_sec` | int | `300` | Stale session scan interval |
| `session_ttl_sec` | int | `86400` | Session inactivity TTL |

## Override precedence

1. **`config.overrides`** — Absolute priority (explicit user intent)
2. **Hardware-derived** — Tier-based defaults from `SetupRouter.ps1`
3. **Legacy flat keys** — Auto-promoted to overrides (backward compat)
4. **Hardcoded defaults** — `Get-InferenceParams` default table

## Example: Minimal config

```json
{
  "installation_type": "local",
  "llama_server_path": "C:\\llama.cpp\\llama-server.exe",
  "models_dir": "C:\\Models",
  "overrides": {
    "ctx_size": 32768
  }
}
```

## Example: Full config with integrations

```json
{
  "installation_type": "local",
  "llama_server_path": "/usr/local/bin/llama-server",
  "llama_repo_path": "/home/user/llama.cpp",
  "models_dir": "/home/user/Models",
  "templates_dir": "/home/user/llama.cpp/models/templates",
  "grammars_dir": "/home/user/llama.cpp/grammars",
  "active_model": "qwen2.5-coder-7b",
  "use_default_template": true,
  "overrides": {
    "ctx_size": 65536,
    "n_gpu_layers": -1,
    "cache_type_k": "f16",
    "cache_type_v": "f16"
  },
  "integrations": ["vscode", "claude-code", "cursor"],
  "idle_timeout_sec": 600,
  "fallback_provider": "anthropic",
  "fallback_api_key": "sk-ant-...",
  "fallback_model": "claude-3-5-sonnet-20241022",
  "context_manager": {
    "enabled": true,
    "proxy_port": 8090,
    "warn_threshold": 0.75
  }
}
```
