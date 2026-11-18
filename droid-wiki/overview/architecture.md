# Architecture

**Active contributors:** vijay

This page documents the system architecture, data flows, and core algorithms of LLM Manager.

## Component diagram

```mermaid
graph TB
    subgraph "User Interface"
        CLI[PowerShell CLI\nmain.ps1 / script/*.ps1]
        GUI[Tauri Desktop App\nReact + Rust]
    end

    subgraph "Core Engine (PowerShell)"
        Profile[Profile.ps1\nHardware Profiler]
        Router[SetupRouter.ps1\nParameter Derivation]
        Assets[FetchAssets.ps1\nTemplate/Grammar Sync]
        Help[ParseHelp.ps1\nFlag Parser]
        Diff[GitDiff.ps1\nChange Detector]
        Paths[Paths.ps1\nConfig Resolution]
    end

    subgraph "Operational Scripts"
        Start[start-server.ps1]
        Stop[stop-server.ps1]
        Health[test-health.ps1]
        Verify[verify-scripts.ps1]
        CMStart[StartContextManager.ps1]
    end

    subgraph "Context Manager Proxy (Python)"
        CMProxy[proxy.py\nFastAPI Server]
        CMEngine[context_engine.py\nCompression Engine]
        CMTokenizer[tokenizer_cache.py\nHF Tokenizer Cache]
        CMPreset[preset_reader.py\nPreset Parser]
        CMConfig[config.py\nSettings Model]
    end

    subgraph "Tauri Backend (Rust)"
        TauriCmd[Tauri Commands\nconfig, profile, server,\nmodels, gguf, health]
        TauriScripts[scripts.rs\nWorkspace Resolution]
        TauriPS[PS Bridge\nrun_powershell_script]
    end

    subgraph "Tauri Frontend (React)"
        ReactPages[Pages\nOverview, Models,\nPerformance, Settings...]
        ReactStores[Zustand Stores\nhardware, config,\nserver, models, validation]
        ReactLib[lib/validation.ts\nExact KV Calculator]
    end

    subgraph "External"
        LlamaServer[llama-server\nllama.cpp binary]
        LlamaRepo[ggml-org/llama.cpp\nGitHub repo]
        HFModels[Hugging Face Hub\nBootstrap models]
    end

    CLI --> Profile
    CLI --> Router
    CLI --> Start
    CLI --> Stop
    CLI --> Health
    CLI --> Verify

    GUI --> TauriCmd
    TauriCmd --> TauriPS
    TauriPS --> Profile
    TauriPS --> Router
    TauriPS --> Start
    TauriPS --> Stop
    TauriPS --> Health
    TauriPS --> Verify
    TauriPS --> CMStart

    Profile --> Router
    Router --> Assets
    Router --> Help
    Router --> Diff

    Start --> Router
    Start --> LlamaServer
    Stop --> LlamaServer

    CMStart --> CMProxy
    CMProxy --> CMEngine
    CMEngine --> CMTokenizer
    CMEngine --> CMPreset
    CMEngine --> LlamaServer

    Assets --> LlamaRepo
    Help --> LlamaServer
    Diff --> LlamaRepo

    ReactPages --> ReactStores
    ReactStores --> TauriCmd
    ReactLib --> ReactStores
```

## Hardware profiling pipeline

```mermaid
sequenceDiagram
    participant User
    participant CLI/GUI
    participant Profile.ps1
    participant Platform APIs
    participant Hardware Profile JSON

    User->>CLI/GUI: Request hardware detection
    CLI/GUI->>Profile.ps1: Invoke with -Json
    Profile.ps1->>Platform APIs: Query CPU (WMI/sysctl/proc)
    Profile.ps1->>Platform APIs: Query RAM (WMI/sysctl/proc)
    Profile.ps1->>Platform APIs: Query GPU (nvidia-smi/WMI/system_profiler/rocm-smi/sysfs)
    Platform APIs-->>Profile.ps1: Raw hardware data
    Profile.ps1->>Profile.ps1: Classify AdapterClass
    Profile.ps1->>Profile.ps1: Determine PerformanceTier
    Profile.ps1->>Profile.ps1: Calculate optimal threads, safe RAM budget
    Profile.ps1-->>CLI/GUI: SystemHardwareProfile JSON
    CLI/GUI-->>User: Display hardware profile
```

## AdapterClass classification

| Value | Conditions |
|-------|------------|
| `none` | No GPU detected |
| `integrated` | Intel UHD/Iris/HD, AMD Radeon (non-RX), or `AdapterRAM ≈ TotalPhysicalMemory` |
| `dedicated` | Discrete GPU with confirmed onboard VRAM (nvidia-smi or WMI non-shared) |

**Detection priority:**
1. `nvidia-smi` — preferred for NVIDIA, picks GPU with most free VRAM
2. WMI `Win32_VideoController` — Windows fallback, filters shared-memory adapters
3. `system_profiler SPDisplaysDataType` — macOS, detects Apple Silicon and discrete GPUs
4. `rocm-smi` — Linux AMD GPUs via ROCm
5. `/sys/class/drm` sysfs — Linux fallback, reads `mem_info_vram_total`

## PerformanceTier classification

```mermaid
graph TD
    GPU[GPU Detected?] -->|No| CPU_None[Tier: cpu\nNo GPU detected]
    GPU -->|Yes| Adapter{AdapterClass?}
    Adapter -->|integrated| CPU_iGPU[Tier: cpu\niGPU - CPU path faster]
    Adapter -->|dedicated| Backend{UsableForInference?}
    Backend -->|No| CPU_NoBE[Tier: cpu\nNo CUDA/Vulkan backend]
    Backend -->|Yes| VRAM{Total VRAM?}
    VRAM -->|≤ 2 GB| CPU_LowV[Tier: cpu\nVRAM too small]
    VRAM -->|2–4 GB| Low[Tier: low\nPartial offload + fit-throttle]
    VRAM -->|4–8 GB| Mid[Tier: mid\nFull offload small/mid models]
    VRAM -->|> 8 GB| High[Tier: high\nFull offload + large context]
```

| Tier | VRAM Range | Reason Printed |
|------|------------|----------------|
| `cpu` | No GPU / integrated / no backend / ≤2 GB | "No GPU detected / Integrated GPU / No compatible backend / VRAM below 2 GB threshold" |
| `low` | 2049–4096 MB | "Dedicated GPU ~X GB VRAM - partial offload with fit-throttle" |
| `mid` | 4097–8192 MB | "Dedicated GPU ~X GB VRAM - full offload for small-mid models" |
| `high` | > 8192 MB | "Dedicated GPU ~X GB VRAM - full offload, large context available" |

## Parameter derivation flow

```mermaid
sequenceDiagram
    participant SetupRouter.ps1
    participant Hardware Profile
    participant config.overrides
    participant Model Scan
    participant models-preset.ini

    SetupRouter.ps1->>Hardware Profile: Get tier, RAM budget, VRAM budget
    SetupRouter.ps1->>SetupRouter.ps1: Select base param table per tier
    SetupRouter.ps1->>SetupRouter.ps1: Conditional parallel=2 upgrade (mid/high)
    SetupRouter.ps1->>config.overrides: Apply explicit overrides (absolute priority)
    SetupRouter.ps1->>SetupRouter.ps1: Post-override validation (flash_attn ↔ cache_type)
    SetupRouter.ps1->>Model Scan: Recursive GGUF scan in models_dir
    SetupRouter.ps1->>SetupRouter.ps1: Per-model: Get-SafeContextSize, Get-ValidatedSpecType
    SetupRouter.ps1->>SetupRouter.ps1: Match chat template (exact → token → default → GGUF internal)
    SetupRouter.ps1->>models-preset.ini: Write preset with all model entries
```

## Base parameter tables per tier

| Parameter | cpu | low | mid | high |
|-----------|-----|-----|-----|------|
| `n_gpu_layers` | 0 | -1 | -1 | -1 |
| `flash_attn` | off | on | on | on |
| `use_fit` | false | true | true | true |
| `fit_target` | 0 | 512 MB | 1024 MB | 1024 MB |
| `fit_ctx_min` | 0 | 4096 | 8192 | 8192 |
| `cache_type_k` | f16 | q8_0 | q8_0 | q8_0 / f16* |
| `cache_type_v` | f16 | q8_0 | q8_0 | q8_0 / f16* |
| `ubatch_size` | 128 | 256 | 512 | 1024 |
| `parallel` | 1 | 1 | 1 / 2† | 1 / 2† |
| `spec_type` | ngram-simple | none | ngram-simple | ngram-simple |
| `context_shift` | true | true | true | true |
| `cache_reuse` | 0 | 256 | 256 | 256 |
| `mmap` | 1 | 1 | 1 | 1 |

* `f16` when VRAM > 12 GB, otherwise `q8_0`
† Upgraded to 2 when RAM > 16 GB AND VRAM > 4 GB

## Context size formula (per-model)

```
modelGB = ModelSize_MB / 1024.0
baseKV = 12.0 × modelGB           (MB per 1K tokens at f16)

kvMBPerKToken = {
    f16:  baseKV × 2.0,
    q8_0: baseKV,
    q4_0: baseKV × 0.5
} × parallel_slots
floored at 5.0 MB minimum

availRAM = BudgetRAM_MB - ModelSize_MB - 512 MB (headroom)

maxCtxFromRam = floor(availRAM / kvMBPerKToken) × 1000

ctxSize = largest of {4096, 8192, 16384, 32768, 65536, 131072, 262144} ≤ maxCtxFromRam
```

**Integration-aware floors:**
- CPU tier + Claude Code: floor 32768
- GPU tiers + Claude Code: floor 65536

**CLI vs UI discrepancy:** CLI uses 50%/25% ratios for q8_0/q4_0 vs f16. UI (`lib/validation.ts`) uses exact byte sizes: f16=2.0, q8_0=1.0625, q4_0=0.5625 bytes/element → q8_0 is 53.1% of f16, q4_0 is 28.1%.

## Speculative decoding validation

```mermaid
graph TD
    Model[Model Alias] --> Check{Incompatible pattern?}
    Check -->|moe, mixture, vision,\nllava, clip, phi-3-v,\nqwen.*vl, minicpm-v, cogvlm| Disable[spec_type = none\n+ Warning]
    Check -->|Other| Enable[spec_type = ngram-simple]
    Disable --> LowTier{Low tier?}
    LowTier -->|Yes| ForceNone[Force spec_type = none]
    LowTier -->|No| Enable
```

## Server startup sequence

```mermaid
sequenceDiagram
    participant User
    participant start-server.ps1
    participant SetupRouter.ps1
    participant Port Scanner
    participant llama-server
    participant Env Export

    User->>start-server.ps1: Invoke (port, config, log dir)
    start-server.ps1->>SetupRouter.ps1: Run with config, output preset + models JSON
    SetupRouter.ps1-->>start-server.ps1: models-preset.ini + model list
    start-server.ps1->>Port Scanner: Check port 8080 (or configured)
    alt Port occupied
        Port Scanner->>Port Scanner: Increment until free
    end
    start-server.ps1->>llama-server: Launch with --models-preset, --port, --host
    llama-server-->>start-server.ps1: Process handle
    start-server.ps1->>Env Export: Write ANTHROPIC_BASE_URL, etc. to shell/profile
    start-server.ps1-->>User: Server running on resolved port
```

## Configuration directory split

```mermaid
graph LR
    subgraph "Workspace Root (Repo)"
        RepoConfig[llo-config.json\nTemplate / Initial]
    end

    subgraph "User AppData (Runtime)"
        AppDataConfig[%APPDATA%/LLM Manager/llo-config.json\nPrimary config]
        AppDataPreset[%APPDATA%/LLM Manager/models-preset.ini\nGenerated at startup]
        AppDataLogs[%APPDATA%/LLM Manager/logs/\nllama-server.log / err.log]
        AppDataCheckpoints[%APPDATA%/LLM Manager/checkpoints/\nSession compression state]
    end

    RepoConfig -.->|First launch copy| AppDataConfig
    TauriApp[Tauri App] -->|Read/Write| AppDataConfig
    TauriApp -->|Pass -ConfigFile| PowerShellScripts
    PowerShellScripts -->|Read/Write| AppDataConfig
    PowerShellScripts -->|Write| AppDataPreset
    PowerShellScripts -->|Write| AppDataLogs
    ContextManager[Python Proxy] -->|Read| AppDataConfig
    ContextManager -->|Read/Write| AppDataCheckpoints
```

## Upstream compatibility guard

```mermaid
sequenceDiagram
    participant ParseHelp.ps1
    participant llama-server
    participant .cached_flags.json
    participant GitDiff.ps1
    participant llama.cpp repo

    ParseHelp.ps1->>llama-server: Run --help
    llama-server-->>ParseHelp.ps1: Help text
    ParseHelp.ps1->>ParseHelp.ps1: Extract all flag aliases (two-pass regex)
    ParseHelp.ps1->>.cached_flags.json: Compare + update cache
    .cached_flags.json-->>ParseHelp.ps1: Added/Removed flags

    GitDiff.ps1->>llama.cpp repo: git fetch + rev-list HEAD...@{u}
    llama.cpp repo-->>GitDiff.ps1: Commit range
    GitDiff.ps1->>GitDiff.ps1: Parse commits for impact keywords
    GitDiff.ps1-->>User: Report: Breaking Changes, GPU, CPU, Performance, Server/API, Flash Attention
```

## Key source files

| File | Purpose |
|------|---------|
| `llo-core/Profile.ps1` | Hardware profiler — CPU/RAM/GPU detection for all platforms |
| `llo-core/SetupRouter.ps1` | Parameter derivation + `models-preset.ini` generator |
| `llo-core/ParseHelp.ps1` | llama-server `--help` parser for upstream compatibility |
| `llo-core/GitDiff.ps1` | Upstream git change detector with impact classification |
| `llo-core/FetchAssets.ps1` | SHA-cached template/grammar downloader from llama.cpp |
| `llo-core/Paths.ps1` | Config path resolution (AppData vs workspace) |
| `script/start-server.ps1` | Server lifecycle: terminate old, run SetupRouter, launch |
| `script/stop-server.ps1` | Graceful shutdown across platforms |
| `script/test-health.ps1` | End-to-end health checks (syntax, config, hardware, ping) |
| `script/verify-scripts.ps1` | Flag compatibility vs current llama-server binary |
| `ui/src-tauri/src/commands/profile.rs` | Tauri command: hardware detection bridge |
| `ui/src-tauri/src/commands/server.rs` | Tauri command: start/stop, log tailing |
| `ui/src-tauri/src/commands/models.rs` | Tauri command: GGUF scanner + binary parser |
| `ui/src-tauri/src/commands/gguf.rs` | GGUF binary header metadata extraction |
| `ui/src-tauri/src/commands/config.rs` | Tauri command: config load/save (AppData) |
| `ui/src-tauri/src/scripts.rs` | Workspace root resolution, PS dispatch |
| `llo-core/context_manager/proxy.py` | FastAPI proxy, Anthropic→OpenAI translation |
| `llo-core/context_manager/context_engine.py` | Compression, token counting, checkpoints |
| `llo-core/context_manager/tokenizer_cache.py` | Shared HF tokenizer with alias normalization |
| `ui/src/lib/validation.ts` | Exact KV cache calculator (UI diagnostics) |
