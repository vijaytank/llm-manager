# Context Manager Proxy

**Active contributors:** Vijay

## Purpose

Optional Python FastAPI service sitting between clients and `llama-server`. It translates the Anthropic Messages API to OpenAI's Chat Completions API, compresses long conversation histories via summarization, and enforces a context size limit (`ctx_limit`). Lives in `llo-core/context_manager/` (`proxy.py`, `context_engine.py`, `tokenizer_cache.py`, `preset_reader.py`, `config.py`). Launched via `script/StartContextManager.ps1` when `context_manager.enabled = true` in `llo-config.json`.

## Directory layout

```
llo-core/context_manager/
├── proxy.py              # FastAPI server, Anthropic→OpenAI translation, streaming
├── context_engine.py     # Compression logic, token counting, checkpoint persistence
├── tokenizer_cache.py    # Shared HF tokenizer with alias normalization
├── preset_reader.py      # models-preset.ini parser for ctx_limit
├── config.py             # Pydantic settings (ContextManagerConfig)
├── __init__.py
├── requirements.txt
├── requirements-dev.txt
├── tests/                # 11 pytest modules
│   ├── test_compression.py
│   ├── test_token_counting.py
│   ├── test_session_tracking.py
│   ├── test_protocol_conversion.py
│   ├── test_http_roundtrip.py
│   ├── test_checkpoint_persistence.py
│   ├── test_needs_compression.py
│   ├── test_tokenizer_cache.py
│   ├── test_preset_reader.py
│   ├── test_config.py
│   └── test_proxy_lifespan.py
└── benchmarks/
```

## Key abstractions

| Abstraction | Description |
|-------------|-------------|
| **proxy.py** | FastAPI server (`app`), HTTP round-trip, protocol translation (Anthropic ↔ OpenAI), session ID extraction, SSE streaming, tool-call passthrough |
| **context_engine.py** | `ContextEngine` class: per-session `SessionState`, token counting, compression heuristics (`needs_compression`), summarization via llama-server, token clamping, disk checkpoints, eviction loop |
| **tokenizer_cache.py** | Shared HuggingFace tokenizer, alias normalization (e.g. `claude-3-5-sonnet-20241022` → `anthropic/claude-3.5-sonnet`), persistent token-count cache |
| **preset_reader.py** | Parses `models-preset.ini` to resolve active model's `ctx_size` (ctx_limit) |
| **config.py** | `ContextManagerConfig` Pydantic settings model loaded from `llo-config.json` |
| **StartContextManager.ps1** | PowerShell launcher: venv setup (uv/python), port scan, uvicorn launch, health verification |

## How it works

```mermaid
graph TB
    subgraph Client[Client]
        C[Client\nAnthropic SDK / HTTP]
    end
    subgraph Proxy[proxy.py :8090]
        P[FastAPI app] | Extract session_id | S[SessionState]
        P -->|Translate| T1[Anthropic → OpenAI]
    end
    subgraph Engine[context_engine.py]
        E[ContextEngine] -->|Token count| Tok[tokenizer_cache.py\nHF Tokenizer]
        E -->|Compression| Comp[Summarize older turns]
        E -->|Read ctx_limit| R[preset_reader.py\nmodels-preset.ini]
        E -->|Persist| Cp[AppData/checkpoints/\nsession_id.json]
    end
    subgraph Upstream[llama-server :8080]
        U[llama-server]
    end
    C -->|POST /v1/messages| P
    P --> E
    E --> U
    U -->|Response| P
    P -->|Translate back| C
    E -->|Summarize via| U
```

```mermaid
sequenceDiagram
    Client->>Proxy: POST /v1/messages (Anthropic)
    Proxy->>Proxy: Extract session_id
    Proxy->>Engine: get_or_create_session(session_id)
    Engine->>Engine: count_tokens_messages(messages)
    alt needs_compression
        Engine->>Engine: _compute_hash(to_summarize)
        alt hash unchanged (idempotent)
            Engine-->>Proxy: Return existing compressed_history
        else
            Engine->>Upstream: POST /v1/chat/completions (summarization)
            Upstream-->>Engine: Summary response
            Engine->>Engine: Build compressed_history + [Compressed Summary] block
            Engine->>Engine: _clamp_message_tokens(85% ctx_limit)
            Engine->>Disk: Save checkpoint
    end
    Engine-->>Proxy: Compressed message list
    Proxy->>Proxy: Convert Anthropic → OpenAI format
    Proxy->>Upstream: POST /v1/chat/completions (OpenAI)
    Upstream-->>Proxy: Response
    Proxy->>Proxy: Convert OpenAI → Anthropic format
    Proxy-->>Client: Response
```

## Integration points

- **[overview/architecture.md](../overview/architecture.md)** — hardware classification, decision flow, core formulas
- **[systems/hardware-profiling.md](../systems/hardware-profiling.md)** — CPU/RAM/GPU detection and tier classification
- **[systems/parameter-derivation.md](../systems/parameter-derivation.md)** — models-preset.ini generation
- **[systems/server-lifecycle.md](../systems/server-lifecycle.md)** — start/stop server, port collision
- **[features/context-compression.md](../features/context-compression.md)** — session compression and ctx_limit
- **[features/client-integrations.md](../features/client-integrations.md)** — VSCode, Claude Code, Cursor, Continue provisioning

## Entry points for modification

| Entry point | What to modify |
|-------------|----------------|
| `llo-core/context_manager/proxy.py` | FastAPI routes, protocol translation, streaming, session ID logic |
| `llo-core/context_manager/context_engine.py` | Compression policy, token clamping, checkpoint persistence, eviction |
| `llo-core/context_manager/tokenizer_cache.py` | Alias normalization, tokenizer loading, cache behavior |
| `llo-core/context_manager/preset_reader.py` | models-preset.ini parsing, ctx_limit fallback |
| `llo-core/context_manager/config.py` | Pydantic settings fields and defaults |
| `llo-core/context_manager/tests/` | Add/extend pytest coverage |
| `script/StartContextManager.ps1` | Venv setup, port scan, uvicorn launch, health check |

## Key source files

| File | Purpose |
|------|---------|
| `llo-core/context_manager/proxy.py` | FastAPI server, protocol translation, streaming |
| `llo-core/context_manager/context_engine.py` | Compression, token counting, checkpoints, eviction |
| `llo-core/context_manager/tokenizer_cache.py` | Shared HF tokenizer, alias normalization, cache |
| `llo-core/context_manager/preset_reader.py` | models-preset.ini parser for ctx_limit |
| `llo-core/context_manager/config.py` | Pydantic settings model |
| `llo-core/context_manager/tests/` | 11 pytest modules |
| `script/StartContextManager.ps1` | PowerShell launcher |
| `ui/src-tauri/src/commands/config.rs` | Reads CM config for Claude Code launch |
