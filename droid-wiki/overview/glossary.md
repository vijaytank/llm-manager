# Glossary

**Active contributors:** vijay

Project-specific terms and domain vocabulary used throughout LLM Manager.

## A

**AdapterClass**
Hardware identity classification for the GPU. Values: `none` (no GPU), `integrated` (shared-memory/iGPU), `dedicated` (discrete GPU with onboard VRAM). Determined by `Profile.ps1` via `nvidia-smi`, WMI, `system_profiler`, `rocm-smi`, or sysfs.

**AppData directory**
Per-user writable configuration directory. Windows: `%APPDATA%\LLM Manager\`; macOS/Linux: `~/.config/LLM Manager/`. The Tauri app and PowerShell scripts read/write `llo-config.json`, `models-preset.ini`, logs, and checkpoints here — not the workspace root.

## B

**Bootstrap model**
Lightweight Hugging Face model (`Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF`) downloaded automatically when no local GGUF models are found and no cloud fallback is configured. Launched via `llama-server -hf`.

## C

**Cache-type (K/V)**
KV cache quantization format. `f16` (full precision), `q8_0` (8-bit), `q4_0` (4-bit). Quantized KV cache **requires** Flash Attention enabled. CPU/integrated tiers force `f16` because Flash Attention is off.

**Chat template (Jinja)**
Prompt formatting template for system/user/assistant roles. Stored as `.jinja` files in `templates/`. Matched to models by: exact name → token overlap → `default.jinja` (if enabled) → GGUF internal metadata.

**Context Manager Proxy**
Optional Python FastAPI service (`llo-core/context_manager/`) that sits between clients and `llama-server`. Translates Anthropic protocol → OpenAI, compresses long sessions via summarization, enforces `ctx_limit`. Enabled via `context_manager.enabled = true`.

**Context size (ctx_size)**
Maximum tokens in the context window. Computed per-model as a RAM-bound ceiling: start from hardware maximum, clamp down based on available RAM after model weights + KV cache estimate. Formula in [Architecture](architecture.md#context-size-formula-per-model).

**CUDA backend**
NVIDIA GPU compute backend for llama.cpp. Detected via `nvidia-smi` presence and driver version. Required for GPU offload on NVIDIA hardware.

## D

**Dedicated GPU**
Discrete graphics card with its own VRAM (not shared system memory). Classified by `AdapterClass = dedicated` when VRAM differs from system RAM by > 256 MB (WMI) or `nvidia-smi` reports it.

**Default.jinja**
Universal fallback chat template bundled in `templates/default.jinja`. Fixes Jinja system-role exceptions across custom GGUF models. Enabled via `use_default_template = true` in config.

## E

**Eviction interval / Session TTL**
Context Manager settings: `eviction_interval_sec` (default 300s) — how often to scan for stale sessions; `session_ttl_sec` (default 86400s) — inactivity timeout before session state is evicted.

## F

**Fit / Fit-target**
llama.cpp flags `--fit` and `--fit-target <MB>` that automatically throttle `n_gpu_layers` downward until the model fits within the VRAM budget. Enabled for GPU tiers (`low`/`mid`/`high`); omitted for `cpu` tier.

**Flash Attention**
Optimized attention kernel in llama.cpp (`--flash-attn` / `-fa`). Required for quantized KV cache (`q8_0`, `q4_0`). Enabled for all GPU tiers; disabled for `cpu` tier.

## G

**GGUF**
Tensor format for quantized LLM weights (successor to GGML). File extension `.gguf`. Contains architecture metadata, quantization info, context length, and optional chat template in metadata.

**GPU offload layers (n_gpu_layers)**
Number of transformer layers to place in GPU VRAM. `-1` = all layers (full offload). `0` = CPU only. Derived per tier: `cpu`=0, `low/mid/high`=-1 (subject to `--fit` throttling).

## H

**Hardware profile**
JSON output of `Profile.ps1` containing CPU (name, physical/logical cores, optimal threads), RAM (total GB, safe budget MB), GPU (name, VRAM MB, adapter class, performance tier, tier reason).

## I

**Integrated GPU (iGPU)**
GPU that shares system RAM (Intel UHD/Iris/HD, AMD non-RX Radeon). Classified as `AdapterClass = integrated`. Performance tier forced to `cpu` because CPU inference is faster than shared-memory GPU path.

## K

**KV cache**
Key-Value cache storing attention states for each token. Grows linearly with context size. Quantization (`cache_type_k/v`) reduces VRAM/RAM pressure. Size estimate: ~12 MB per 1K tokens per billion parameters at f16.

## L

**llama.cpp**
Upstream C++ inference engine (ggml-org/llama.cpp). LLM Manager wraps `llama-server` binary and tracks its CLI flags for compatibility.

**llama-server**
HTTP server binary from llama.cpp exposing OpenAI-compatible `/v1/chat/completions` and `/v1/completions` endpoints. Supports `--models-preset` for multi-model hosting.

## M

**Models-preset.ini**
Generated configuration file consumed by `llama-server --models-preset`. Contains per-model entries: path, alias, chat template, context size, GPU layers, and other inference params. Regenerated at every server start.

**Mmproj (multimodal projector)**
Vision adapter file (e.g., `mmproj-model-f16.gguf`) enabling image input for vision models (LLaVA, Qwen-VL, etc.). Detected by filename containing `mmproj` or `vision-projector`. Paired with base model via `mmproj_path` config.

## N

**ngram-simple**
Speculative decoding method in llama.cpp predicting future tokens from context n-grams. ~10–15% throughput boost. Enabled for `cpu`/`mid`/`high` tiers; disabled for `low` tier (OOM risk). Validated per-model against incompatible architectures (MoE, vision, etc.).

## O

**Overrides (config.overrides)**
Explicit user intent block in `llo-config.json`. Keys here take **absolute priority** over all hardware-derived values. Example: `"overrides": { "ctx_size": 32768, "n_gpu_layers": 0 }`. Legacy flat keys (`cache_type_k`, `flash_attn`, etc.) are auto-promoted here by `SetupRouter.ps1`.

## P

**PerformanceTier**
Inference policy classification derived from AdapterClass + VRAM + backend availability. Values: `cpu`, `low`, `mid`, `high`. Each tier has a base parameter table in `SetupRouter.ps1`.

**Port collision protection**
`start-server.ps1` scans active TCP listeners via .NET `IPGlobalProperties`. If configured port (default 8080) is occupied, increments until free. All exported client env vars updated to resolved port.

## Q

**Quantization (model)**
Weight compression format in GGUF filename (e.g., `Q4_K_M`, `Q8_0`, `NVFP4`, `IQ4_XS`). Affects model size, quality, and speed. `Q4_K_M` / `NVFP4` recommended for balance.

## R

**ROCm backend**
AMD GPU compute backend for llama.cpp on Linux. Detected via `rocm-smi` in PATH.

## S

**Safe RAM budget**
Total system RAM minus 6 GB OS reservation, floored at 4 GB minimum. Used as the binding constraint for context size calculation (since llama.cpp supports CPU offload + mmap).

**Speculative decoding**
Technique where a small draft model (or ngram) predicts tokens, verified by main model. In LLM Manager: `ngram-simple` only. Controlled by `spec_type` parameter.

**System-hardware-profile**
See [Hardware profile](#h).

## T

**Tier reason**
Human-readable string printed at startup explaining why a particular PerformanceTier was assigned. Example: "Dedicated GPU ~6 GB VRAM - full offload for small-mid models".

**Tokenizer cache**
Shared HuggingFace tokenizer (`tokenizer_cache.py`) with alias normalization (e.g., `claude-3-5-sonnet-20241022` → correct tokenizer). Persistent token-count cache per model. Used by Context Manager for compression decisions.

## U

**UBatch size (ubatch_size)**
Physical batch size for prompt processing. Larger values increase throughput but consume more memory. Derived per tier: `cpu`=128, `low`=256, `mid`=512, `high`=1024.

**Upstream compatibility guard**
`ParseHelp.ps1` + `GitDiff.ps1` system that parses `llama-server --help` and scans upstream git commits for breaking changes, deprecated flags, or new features affecting LLM Manager.

## V

**VRAM budget (fit-target)**
VRAM ceiling for model weights enforced by `--fit --fit-target`. `low` tier: 512 MB; `mid`/`high`: 1024 MB. Prevents silent VRAM spill to system RAM (90% throughput drop).

## W

**Workspace root**
Repository root directory containing `llo-core/`, `script/`, `ui/`, `templates/`, `grammars/`. Resolved at runtime by `scripts.rs` (dev: `CARGO_MANIFEST_DIR`; release: exe parent + resource paths; fallback: cwd walk-up).
