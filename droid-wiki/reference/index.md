# Reference

**Active contributors:** vijay

Configuration reference, data models, and external dependencies.

## Reference pages

- [Configuration](configuration.md) — Complete `llo-config.json` schema
- [Data models](data-models.md) — TypeScript/Rust/PowerShell type definitions
- [Dependencies](dependencies.md) — External dependencies and versions

## Quick configuration lookup

### Required keys
| Key | Type | Description |
|-----|------|-------------|
| `installation_type` | string | `local` or `github` |
| `llama_server_path` | string | Absolute path to `llama-server` binary |
| `models_dir` | string | Directory containing `.gguf` files |

### Override keys (in `config.overrides`)
| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `ctx_size` | int | tier-derived | Context window size |
| `n_gpu_layers` | int | tier-derived | GPU offload layers (-1=all, 0=CPU) |
| `ubatch_size` | int | tier-derived | Physical batch size |
| `parallel` | int | tier-derived | Concurrent slots |
| `cache_type_k` | string | tier-derived | KV K cache quantization |
| `cache_type_v` | string | tier-derived | KV V cache quantization |
| `flash_attn` | string | tier-derived | Flash Attention on/off |
| `spec_type` | string | tier-derived | Speculative decoding type |

### Context Manager keys
| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `context_manager.enabled` | bool | false | Enable proxy |
| `context_manager.proxy_port` | int | 8090 | Proxy listen port |
| `context_manager.warn_threshold` | float | 0.70 | Compression trigger |
| `context_manager.keep_turns` | int | 6 | Turns preserved |
| `context_manager.ctx_limit` | int | 0 (auto) | Context limit |

### Integration keys
| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `integrations` | string[] | ["server-only"] | `vscode`, `claude-code`, `cursor`, `continue` |
| `fallback_provider` | string | `none` | `anthropic`, `openai`, `nim`, `ollama` |
| `fallback_api_key` | string | "" | Cloud API key |
| `fallback_model` | string | "" | Cloud model name |

## Data model summary

| Model | Language | Location |
|-------|----------|----------|
| `SystemHardwareProfile` | PowerShell/Rust/TypeScript | `Profile.ps1`, `profile.rs`, `hardwareStore.ts` |
| `InferenceParams` | PowerShell | `SetupRouter.ps1` |
| `ModelInfo` | Rust/TypeScript | `models.rs`, `modelsStore.ts` |
| `GgufMetadata` | Rust | `gguf.rs` |
| `AppConfig` | Rust/TypeScript | `config.rs`, `configStore.ts` |
| `ContextManagerConfig` | Python | `config.py` |
| `SessionState` | Python | `context_engine.py` |

## External dependencies

| Dependency | Version | Purpose |
|------------|---------|---------|
| llama.cpp | Latest | Upstream inference engine |
| PowerShell | 7.4+ / 5.1 | Core scripting |
| Python | 3.10+ | Context Manager Proxy |
| Rust | 1.78+ | Tauri backend |
| Node.js | 20+ | Tauri frontend |
| Tauri | 2.x | Desktop app framework |
| React | 18.x | Frontend UI |
| Zustand | 4.x | State management |
| FastAPI | 0.110+ | Proxy server |
| httpx | 0.27+ | Async HTTP client |
| HuggingFace tokenizers | 0.19+ | Token counting |
| Pydantic | 2.7+ | Settings validation |
