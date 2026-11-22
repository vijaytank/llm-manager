# Tauri Desktop App

**Active contributors:** Vijay

## Purpose

Native desktop GUI for LLM Manager built with Tauri 2, React 18, TypeScript, and Rust. The React frontend renders system status, diagnostics, preset models, performance tuning sliders, and live logs; the Rust backend exposes Tauri commands in `ui/src-tauri/src/commands/` (config.rs, server.rs, profile.rs, models.rs, gguf.rs, health.rs) that dispatch PowerShell scripts via `ui/src-tauri/src/scripts.rs`. Config is read/written from the AppData directory (not the workspace root), passed to PowerShell scripts via `-ConfigFile`.

## Directory layout

```
ui/src/
├── pages/
│   ├── Overview.tsx        # Hardware profile, model launch, live logs
│   ├── Models.tsx          # GGUF scanner, binary inspector, template matching
│   ├── Performance.tsx     # Override sliders for inference params
│   ├── Settings.tsx        # Config editor (paths, integrations, fallback, context mgr)
│   ├── Diagnostics.tsx     # Exact KV cache calc, hardware validation
│   ├── Logs.tsx            # Full log viewer with filtering
│   └── Integrations.tsx    # Client setup helpers (Claude Code, Cursor, Continue)
├── store/
│   ├── hardwareStore.ts    # Hardware profile + fetch
│   ├── configStore.ts      # Config CRUD + save
│   ├── serverStore.ts      # Server status, logs, port
│   ├── modelsStore.ts      # GGUF list + fetch
│   └── validationStore.ts  # Pre-flight launch checks
├── components/
│   ├── layout/PageShell.tsx
│   ├── ImpactBanner.tsx    # Severity banners
│   └── InfoTooltip.tsx     # Hover help
├── lib/
│   └── validation.ts       # Exact KV cache calculator
├── App.tsx                 # Router + providers
├── main.tsx                # Entry point
└── styles/                 # CSS modules per page
ui/src-tauri/src/
├── commands/
│   ├── config.rs       # load_config, save_config (AppData directory)
│   ├── server.rs       # start_server, stop_server, get_server_status, log tailing
│   ├── profile.rs      # detect_hardware (bridges Profile.ps1 -Json)
│   ├── models.rs       # scan_models (recursive GGUF + binary parser)
│   ├── gguf.rs         # parse_gguf_file (binary header metadata)
│   └── health.rs       # run_health_check (dispatches test-health.ps1)
├── scripts.rs          # get_workspace_root, run_powershell_script
├── main.rs             # Tauri app entry, command registration
└── tray.rs             # System tray
```

## Key abstractions

| Abstraction | Description |
|-------------|-------------|
| **Tauri commands** | Rust handlers in `ui/src-tauri/src/commands/` registered in `main.rs`, each wrapping a PowerShell script call |
| **scripts.rs bridge** | `run_powershell_script()` resolves workspace root, locates the script, executes `powershell.exe -File` / `pwsh -File`, returns stdout |
| **AppData config split** | `ui/src-tauri/src/commands/config.rs` reads/writes `%APPDATA%\LLM Manager\llo-config.json` (Windows) or `~/.config/LLM Manager/llo-config.json` |
| **Zustand stores** | Frontend state (`hardwareStore`, `configStore`, `serverStore`, `modelsStore`, `validationStore`) synced via Tauri invoke/events |
| **Log tailing** | `server.rs` tails `llama-server.log` / `llama-server.err.log`, emits `server-log` Tauri events per line |
| **Exact KV calculator** | `ui/src/lib/validation.ts` computes byte-accurate KV sizes (f16=2.0, q8_0=1.0625, q4_0=0.5625) |

## How it works

```mermaid
graph TD
    subgraph Frontend[Frontend (React + TypeScript)]
        Pages[Pages\nOverview, Models,\nPerformance, Settings,\nDiagnostics, Logs,\nIntegrations]
        Stores[Zustand Stores\nhardware, config, server,\nmodels, validation]
        Lib[lib/validation.ts\nExact KV Calculator]
    end
    subgraph IPC[IPC Layer]
        Invoke[@tauri-apps/api/core invoke()]
        Events[@tauri-apps/api/event listen()]
    end
    subgraph Backend[Backend (Rust)]
        Commands[Tauri Commands\nconfig, profile, server,\nmodels, gguf, health]
        Scripts[scripts.rs\nWorkspace Resolution + PS Dispatch]
        LogTail[Log Tailers\nstdout/stderr streaming]
    end
    subgraph PS[PowerShell Core]
        Profile[Profile.ps1]
        Router[SetupRouter.ps1]
        Start[start-server.ps1]
        Stop[stop-server.ps1]
        Health[test-health.ps1]
    end
    Pages --> Stores
    Pages --> Lib
    Stores --> Invoke
    Invoke --> Commands
    Commands --> Scripts
    Scripts --> Profile
    Scripts --> Router
    Scripts --> Start
    Scripts --> Stop
    Scripts --> Health
    Commands --> LogTail
    LogTail --> Events
    Events --> Stores
    Start --> Server[llama-server]
    Server --> Events
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
| `ui/src-tauri/src/commands/config.rs` | Add/change Tauri config load/save commands |
| `ui/src-tauri/src/commands/profile.rs` | Change hardware detection bridge |
| `ui/src-tauri/src/commands/server.rs` | Change server start/stop/status/log tailing |
| `ui/src-tauri/src/commands/models.rs` | Change GGUF scan / binary parser |
| `ui/src-tauri/src/commands/gguf.rs` | Change GGUF metadata extraction |
| `ui/src-tauri/src/commands/health.rs` | Change health check dispatcher |
| `ui/src-tauri/src/scripts.rs` | Change workspace resolution or PowerShell dispatch |
| `ui/src/pages/` | Add or change React pages |
| `ui/src/store/` | Add or change Zustand stores |
| `ui/src/lib/validation.ts` | Change exact KV cache calculation |

## Key source files

| File | Purpose |
|------|---------|
| `ui/src/pages/Overview.tsx` | Main dashboard: hardware, model launch, logs |
| `ui/src/pages/Models.tsx` | GGUF scanner, binary inspector, mmproj pairing |
| `ui/src/pages/Performance.tsx` | Override sliders for all inference params |
| `ui/src/pages/Settings.tsx` | Config editor (paths, integrations, fallback, CM) |
| `ui/src/pages/Diagnostics.tsx` | Exact KV calc, validation |
| `ui/src/pages/Logs.tsx` | Full log viewer with filtering |
| `ui/src/pages/Integrations.tsx` | Client config generators (Claude Code, Cursor, Continue) |
| `ui/src/store/hardwareStore.ts` | Hardware profile state |
| `ui/src/store/configStore.ts` | Config CRUD |
| `ui/src/store/serverStore.ts` | Server status, logs, port |
| `ui/src/store/modelsStore.ts` | GGUF list |
| `ui/src/store/validationStore.ts` | Pre-flight assessments |
| `ui/src/lib/validation.ts` | Exact KV cache calculator |
| `ui/src-tauri/src/commands/config.rs` | Config load/save (AppData) |
| `ui/src-tauri/src/commands/profile.rs` | Hardware detection bridge |
| `ui/src-tauri/src/commands/server.rs` | Start/stop, log tailing |
| `ui/src-tauri/src/commands/models.rs` | GGUF scan + binary parse |
| `ui/src-tauri/src/commands/gguf.rs` | GGUF metadata extraction |
| `ui/src-tauri/src/commands/health.rs` | Health check dispatcher |
| `ui/src-tauri/src/scripts.rs` | Workspace resolution, PS dispatch |
