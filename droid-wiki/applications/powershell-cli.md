# PowerShell CLI

**Active contributors:** Vijay

## Purpose

Command-line interface for LLM Manager — interactive setup wizard, server lifecycle, health checks, and flag verification. The entry point is `main.ps1`; supporting modules live in `llo-core/` (`Profile.ps1`, `SetupRouter.ps1`, `ParseHelp.ps1`, `GitDiff.ps1`, `FetchAssets.ps1`, `Paths.ps1`) and lifecycle scripts live in `script/` (`start-server.ps1`, `stop-server.ps1`, `test-health.ps1`, `verify-scripts.ps1`, `StartContextManager.ps1`). Config lives in AppData (`%APPDATA%\LLM Manager\llo-config.json` on Windows, `~/.config/LLM Manager/llo-config.json` on macOS/Linux) and is passed to scripts via `-ConfigFile`.

## Directory layout

```
script/
├── start-server.ps1        # Server startup with port collision protection
├── stop-server.ps1         # Graceful shutdown
├── test-health.ps1         # Full health audit (syntax, config, hardware, ping)
├── verify-scripts.ps1      # Flag compatibility vs llama-server binary
├── StartContextManager.ps1 # Launch Python context proxy
├── *.sh                    # macOS/Linux wrappers (invoke pwsh)
llo-core/
├── Profile.ps1             # Hardware profiler (CPU/RAM/GPU)
├── SetupRouter.ps1         # Parameter derivation + preset generator
├── ParseHelp.ps1           # llama-server --help parser
├── GitDiff.ps1             # Upstream git change detector
├── FetchAssets.ps1         # Template/grammar downloader (SHA-cached)
├── Paths.ps1               # Config path resolution (AppData vs workspace)
└── context_manager/        # Python proxy (see context-manager-proxy.md)
```

## Key abstractions

| Abstraction | Description |
|-------------|-------------|
| **main.ps1 wizard** | Interactive setup: prompts for `llama_server_path`, `models_dir`, optional fallback provider and client integrations, writes `llo-config.json` and `.vscode/` tasks/settings |
| **Profile.ps1** | Cross-platform hardware profiler producing `SystemHardwareProfile` (CPU/RAM/GPU tier) |
| **SetupRouter.ps1** | Parameter derivation engine: tier-based tables, override application, per-model context size, speculative decoding validation, writes `models-preset.ini` |
| **start-server.ps1** | Server lifecycle: load config, run SetupRouter, port collision scan, launch `llama-server`, export client env vars |
| **stop-server.ps1** | Cross-platform graceful shutdown (WMI on Windows, lsof/ss on macOS/Linux) |
| **test-health.ps1** | Full health audit: PS syntax, config schema, hardware, parameter derivation, live ping |
| **verify-scripts.ps1** | Flag compatibility: parses `llama-server --help`, scans scripts for unknown flags |
| **Paths.ps1** | AppData config path resolution (`Get-LLMManagerConfigPath`) |

## How it works

```mermaid
graph LR
    subgraph Wizard[Wizard]
        W[main.ps1] -->|writes| Config[llo-config.json\nAppData]
    end
    subgraph Lifecycle[Server lifecycle]
        S[script/start-server.ps1] -->|runs| Router[llo-core/SetupRouter.ps1]
        Router -->|writes| Preset[models-preset.ini]
        S -->|port scan| Port[Port collision scan]
        Port -->|launch| Server[llama-server]
        Server -->|env export| Env[ANTHROPIC_BASE_URL,\nANTHROPIC_AUTH_TOKEN=local]
    end
    subgraph Health[Health & verify]
        H[script/test-health.ps1] -->|checks| Syntax[PS syntax]
        H -->|checks| ConfigCheck[Config schema]
        H -->|checks| Hardware[Profile.ps1 -Json]
        H -->|checks| Derive[SetupRouter output]
        H -->|checks| Ping[Live /health ping]
        V[script/verify-scripts.ps1] -->|flags| Help[llama-server --help]
    end
    subgraph CM[Context Manager]
        CM[script/StartContextManager.ps1] --> Proxy[proxy.py :8090]
    end
    W --> S
    S --> H
    Config --> S
    Profile[llo-core/Profile.ps1] --> Router
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
| `main.ps1` | Wizard flow, config generation, VSCode task/settings generation |
| `llo-core/Profile.ps1` | Hardware detection (CPU/RAM/GPU per platform) |
| `llo-core/SetupRouter.ps1` | Parameter tables, override application, preset writing |
| `llo-core/ParseHelp.ps1` | `llama-server --help` two-pass parser |
| `llo-core/GitDiff.ps1` | Upstream git change detection |
| `llo-core/FetchAssets.ps1` | Template/grammar SHA-cached sync |
| `llo-core/Paths.ps1` | AppData config path resolution |
| `script/start-server.ps1` | Server startup, port collision, env export |
| `script/stop-server.ps1` | Cross-platform process termination |
| `script/test-health.ps1` | Health audit checks |
| `script/verify-scripts.ps1` | Flag compatibility rules |
| `script/StartContextManager.ps1` | Python proxy launcher |

## Key source files

| File | Purpose |
|------|---------|
| `main.ps1` | Wizard, config generation, VSCode integration |
| `script/start-server.ps1` | Server startup, port collision, env export |
| `script/stop-server.ps1` | Cross-platform process termination |
| `script/test-health.ps1` | Comprehensive health audit |
| `script/verify-scripts.ps1` | Flag compatibility checker |
| `script/StartContextManager.ps1` | Python context proxy launcher |
| `llo-core/Profile.ps1` | Hardware detection (all platforms) |
| `llo-core/SetupRouter.ps1` | Parameter derivation, preset generation |
| `llo-core/ParseHelp.ps1` | llama-server help parser, flag cache |
| `llo-core/GitDiff.ps1` | Upstream git change scanner |
| `llo-core/FetchAssets.ps1` | Template/grammar downloader |
| `llo-core/Paths.ps1` | AppData config path resolution |
