# PowerShell CLI

**Active contributors:** vijay

Command-line interface for LLM Manager — wizard, server lifecycle, health checks, and verification.

## Directory structure

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
└── context_manager/        # Python proxy (see separate page)
```

## Main entry points

### `main.ps1` — Interactive setup wizard

```powershell
powershell -File main.ps1        # Windows
pwsh -File main.ps1              # macOS/Linux
./run-setup.sh                   # macOS/Linux convenience wrapper
```

**Flow:**
1. Detect or prompt for `llama_server_path`
2. Detect or prompt for `models_dir`
3. Optional: cloud fallback provider (Ollama, OpenAI, Anthropic, NVIDIA NIM)
4. Optional: client integrations (VSCode, Claude Code, Cursor, Continue)
5. Write `llo-config.json` to AppData
6. Generate `.vscode/tasks.json` + `.vscode/settings.json` with OS-specific terminal env

### `script/start-server.ps1` — Server lifecycle

```powershell
powershell -File script/start-server.ps1 [-Port 8080] [-ConfigFile <path>] [-LogDir <path>] [-ModelsDir <path>]
```

**Sequence:**
1. Load config (AppData or `-ConfigFile`)
2. Run `SetupRouter.ps1` → generates `models-preset.ini` + model list JSON
3. Port collision scan: checks TCP 8080 (or `-Port`), increments until free
4. Launch `llama-server` with `--models-preset`, `--port`, `--host`
5. Export client env vars (`ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN=local`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`)

**Parameters:**
| Parameter | Default | Description |
|-----------|---------|-------------|
| `-Port` | 8080 | Server port (auto-shifted if occupied) |
| `-HostAddr` | 127.0.0.1 | Bind address |
| `-ConfigFile` | Auto-resolved | Path to `llo-config.json` |
| `-LogDir` | Auto-resolved | Log directory (AppData/logs) |
| `-ModelsDir` | From config | Override models directory |
| `-Parallel`, `-CtxSize`, etc. | From config/overrides | Inline override (rarely used) |

### `script/stop-server.ps1` — Graceful shutdown

```powershell
powershell -File script/stop-server.ps1 [-ConfigFile <path>]
```

**Mechanism:**
- Windows: `Get-CimInstance Win32_Process` → find `llama-server.exe` by command line → `Stop-Process`
- macOS/Linux: `lsof -ti:PORT` or `ss -tlnp` → `kill`

### `script/test-health.ps1` — Health audit

```powershell
powershell -File script/test-health.ps1 [-Json]
```

**Checks:**
1. **PowerShell syntax** — AST parser on all `.ps1` files (excludes itself)
2. **Config schema** — Required keys (`installation_type`, `llama_server_path`, `models_dir`), overrides block validity
3. **Hardware profiler** — Invokes `Profile.ps1 -Json`, validates JSON structure
4. **Parameter derivation** — Invokes `SetupRouter.ps1`, checks output completeness
5. **Live server ping** — If running, hits `/health` and `/v1/models`
6. **Flag compatibility** — Runs `verify-scripts.ps1` logic

**Output:** Structured `[PASS]/[FAIL]` per check. Exit code 0 = all pass.

### `script/verify-scripts.ps1` — Flag compatibility

```powershell
powershell -File script/verify-scripts.ps1
```

**Mechanism:**
1. Runs `llama-server --help` (via config path or PATH)
2. Parses all flags (two-pass regex: extracts long aliases + short aliases)
3. Scans all PowerShell scripts for flag usage
4. Reports any script flags missing from binary help
5. Excludes: external commands (`git`, `nvidia-smi`), PowerShell common flags (`-ExecutionPolicy`, `--help`)

### `script/StartContextManager.ps1` — Launch proxy

```powershell
powershell -File script/StartContextManager.ps1 [-Port 8090] [-ConfigFile <path>]
```

Only runs when `context_manager.enabled = true` in config. Launches `python -m uvicorn proxy:app`.

## Core modules

### `llo-core/Profile.ps1` — Hardware profiler

```powershell
. llo-core/Profile.ps1
$hw = Get-SystemHardwareProfile [-Json]
```

**Output (`SystemHardwareProfile`):**
```json
{
  "cpu": { "name": "Intel i9-13900K", "physicalCores": 24, "logicalCores": 32, "optimalThreads": 8 },
  "ram": { "totalGb": 64, "safeBudgetMb": 57344 },
  "gpu": { "name": "RTX 4090", "totalVramMb": 24576, "adapterClass": "dedicated", "performanceTier": "high", "reason": "Dedicated GPU > 8GB VRAM" }
}
```

**Detection priority:**
1. `nvidia-smi` (NVIDIA) — picks GPU with most free VRAM
2. WMI `Win32_VideoController` (Windows) — filters shared-memory adapters
3. `system_profiler SPDisplaysDataType` (macOS) — Apple Silicon unified memory
4. `rocm-smi` (Linux AMD) — ROCm GPUs
5. `/sys/class/drm` sysfs (Linux fallback) — `mem_info_vram_total`

### `llo-core/SetupRouter.ps1` — Parameter derivation

```powershell
. llo-core/SetupRouter.ps1
$models = Get-OptimizedModelEntries -ConfigFile <path> -PresetFile <path> -ModelsTempFile <path>
```

**Responsibilities:**
1. Load hardware profile + config
2. Select base parameter table per `PerformanceTier`
3. Conditional `parallel=2` upgrade (mid/high + RAM>16GB + VRAM>4GB)
4. Apply `config.overrides` (absolute priority)
5. Post-override validation (`flash_attn` off → force `cache_type_k/v=f16`)
6. Recursive GGUF scan in `models_dir`
7. Per-model: `Get-SafeContextSize`, `Get-ValidatedSpecType`, template matching
8. Write `models-preset.ini`
9. Return model list as JSON (via temp file to avoid pipeline pollution)

### `llo-core/ParseHelp.ps1` — Flag parser

```powershell
. llo-core/ParseHelp.ps1
$diff = Update-CachedFlags [-LlamaServerPath <path>] [-CacheFile <path>]
```

**Two-pass parsing:**
1. Match help lines starting with flag tokens
2. Regex extract **all** long aliases (`--flag`, `--alias`) from same line
3. Register each alias individually for allow-list lookup

**Output:** `.cached_flags.json` + diff report (added/removed flags).

### `llo-core/GitDiff.ps1` — Upstream change detector

```powershell
. llo-core/GitDiff.ps1
$diff = Get-LlamaGitStatus [-LlamaRepoPath <path>]
```

**Checks:**
- `git fetch origin`
- `git rev-list --left-right --count HEAD...@{u}` (ahead/behind)
- Commit log scan for impact keywords: CUDA/GPU, CPU, Performance, Breaking Change, Server/API, Flash Attention

### `llo-core/FetchAssets.ps1` — Template/grammar sync

```powershell
. llo-core/FetchAssets.ps1
Sync-LlamaAssets [-ConfigFile <path>] [-Force]
```

**SHA-cached:** Compares `.assets-manifest.json` vs GitHub API directory listing. Only downloads changed files.

### `llo-core/Paths.ps1` — Config path resolution

```powershell
. llo-core/Paths.ps1
$path = Get-LLMManagerConfigPath [-ManagerDir <path>]
$dir = Get-LLMManagerUserDataDir
```

**Resolution order:**
1. `%APPDATA%\LLM Manager\llo-config.json` (Windows)
2. `~/.config/LLM Manager/llo-config.json` (macOS/Linux)
3. Workspace `llo-config.json` (fallback/template)

## Key source files

| File | Purpose |
|------|---------|
| `main.ps1` | Wizard, config generation, VSCode integration |
| `script/start-server.ps1` | Server startup, port collision, env export |
| `script/stop-server.ps1` | Cross-platform process termination |
| `script/test-health.ps1` | Comprehensive health audit |
| `script/verify-scripts.ps1` | Flag compatibility checker |
| `llo-core/Profile.ps1` | Hardware detection (all platforms) |
| `llo-core/SetupRouter.ps1` | Parameter derivation, preset generation |
| `llo-core/ParseHelp.ps1` | llama-server help parser, cache |
| `llo-core/GitDiff.ps1` | Upstream git change scanner |
| `llo-core/FetchAssets.ps1` | Template/grammar downloader |
| `llo-core/Paths.ps1` | AppData config path resolution |
