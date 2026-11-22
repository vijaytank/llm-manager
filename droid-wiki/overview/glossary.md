# Glossary

| Term | Definition |
|---|---|
| `AdapterClass` | Hardware-identity classification of a GPU: `none`, `integrated`, or `dedicated`. |
| `PerformanceTier` | Inference-policy tier derived from GPU class and VRAM: `cpu`, `low`, `mid`, `high`. |
| `llama-server` | The llama.cpp HTTP server that loads GGUF models and serves inference requests. |
| `models-preset.ini` | Generated at startup by `SetupRouter.ps1`; consumed by llama-server via `--models-preset` to route clients to models by alias. |
| `llo-config.json` | Persistent configuration: model paths, cloud fallback, `overrides` block, integrations. Stored in the user's AppData directory by the GUI. |
| `GGUF` | The model file format used by llama.cpp (`.gguf`). |
| `Chat template` | A Jinja (`.jinja`) template that formats prompts for a specific model architecture. Synced from upstream llama.cpp. |
| `Grammar` | A GBNF (`.gbnf`) constraint file that shapes structured model output. Stored in `grammars/`. |
| `Performance tier` | One of `cpu`, `low`, `mid`, `high`, controlling offload, cache precision, batch size, and speculative decoding. |
| `KV cache` | Key-value cache for model context; its size grows linearly with context length. |
| `Flash Attention` | llama.cpp feature required for quantized KV-cache formats; off on CPU/integrated tiers. |
| `Speculative decoding` | `ngram-simple` prediction of future tokens; disabled on `low` tier and for vision/MoE models. |
| `Context Manager Proxy` | Optional Python proxy translating Anthropic to OpenAI protocol, compressing sessions, enforcing `ctx_limit`. |
| `Overrides` | `config.overrides` keys take absolute priority over hardware-derived values. |
| `Legacy promotion` | Flat legacy config keys (e.g. `cache_type_k`, `flash_attn`) promoted into `overrides` by `SetupRouter.ps1`, locking derived parameters to historical values. |
| `Port collision` | `start-server.ps1` scans upward from port 8080 when occupied and propagates the resolved port to client env vars. |
| `AppData config split` | GUI config lives in `%APPDATA%\LLM Manager` (Windows) or `~/.config/LLM Manager` (macOS/Linux), passed to PowerShell scripts via `-ConfigFile`. |
