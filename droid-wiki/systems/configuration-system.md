# Configuration System

**Active contributors:** vijay

AppData-based configuration, override precedence, legacy key promotion, and VSCode workspace provisioning.

## Overview

Configuration lives in the user's AppData directory, not the workspace root. The Tauri app and PowerShell scripts coordinate via `-ConfigFile` parameter.

## Directory layout

```
llo-core/Paths.ps1                    # Config path resolution
ui/src-tauri/src/commands/config.rs   # Tauri config load/save
main.ps1                              # Wizard: initial config + VSCode generation
```

## Key Abstractions

| Abstraction | Responsibility | Key Fields |
|-------------|---------------|------------|
| `AppConfig` | Full user configuration schema | `overrides`, `integrations`, `context_manager`, `models_dir`, `fallback_provider` |
| `OverridesBlock` | User intent taking absolute priority over derived values | `ctx_size`, `n_gpu_layers`, and any llama-server flag |
| `LegacyFlatKey` | Pre-override flat config key auto-promoted to overrides | `cache_type_k`, `flash_attn`, `ctx_size`, `ubatch_size`, `parallel_slots` |
| `ContextManagerConfig` | Sub-config for the Python context proxy | `enabled`, `proxy_port`, `ctx_limit`, `warn_threshold`, `keep_turns` |
| `UserDataDir` | Platform-resolved config home | `%APPDATA%\LLM Manager` or `~/.config/LLM Manager` |

## Configuration directory split

```mermaid
graph LR
    Workspace[Workspace Root\nllo-config.json (template)] -->|First launch copy| AppData[AppData/LLM Manager/]
    AppData --> Config[llo-config.json\nPrimary config]
    AppData --> Preset[models-preset.ini\nGenerated at startup]
    AppData --> Cache[.cached_flags.json\nllama-server flag cache]
    AppData --> Assets[.assets-manifest.json\nTemplate/grammar SHA cache]
    AppData --> Logs[logs/llama-server.log]
    AppData --> Checkpoints[checkpoints/\nSession compression state]
    
    Tauri[Tauri App] -->|load_config/save_config| Config
    Tauri -->|start_server -ConfigFile| Preset
    Tauri -->|log tailers| Logs
    PS[PowerShell Scripts] -->|Read/Write -ConfigFile| Config
    PS -->|Write| Preset
    PS -->|Write| Cache
    PS -->|Write| Assets
    PS -->|Write| Logs
    CM[Context Manager] -->|Read| Config
    CM -->|Read/Write| Checkpoints
```

## Path resolution (`Paths.ps1`)

```powershell
function Get-LLMManagerUserDataDir {
    if ($IsWindows) { return "$env:APPDATA\LLM Manager" }
    elseif ($IsMacOS) { return "$env:HOME/.config/LLM Manager" }
    else { return "$env:HOME/.config/LLM Manager" }
}

function Get-LLMManagerConfigPath {
    param($ManagerDir)
    $userDir = Get-LLMManagerUserDataDir
    $candidates = @(
        "$userDir\llo-config.json",
        "$ManagerDir\llo-config.json"
    )
    return ($candidates | Where-Object { Test-Path $_ } | Select-Object -First 1)
}
```

**Resolution order:**
1. `%APPDATA%\LLM Manager\llo-config.json` (Windows)
2. `~/.config/LLM Manager/llo-config.json` (macOS/Linux)
3. Workspace `llo-config.json` (fallback/template)

## Config schema (`llo-config.json`)

```json
{
  "installation_type": "local",
  "llama_server_path": "C:\\path\\to\\llama-server.exe",
  "llama_repo_path": "C:\\path\\to\\llama.cpp",
  "models_dir": "C:\\path\\to\\models",
  "templates_dir": "C:\\path\\to\\llama.cpp\\models\\templates",
  "grammars_dir": "C:\\path\\to\\llama.cpp\\grammars",
  "active_model": "my-model",
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
  "overrides": {
    "ctx_size": 65536,
    "n_gpu_layers": -1
  },
  "integrations": ["server-only", "claude-code", "vscode"],
  "idle_timeout_sec": 600,
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
    "ctx_limit": 0,
    "tokenizer_repo": "",
    "summary_max_tokens": 768,
    "summarize_with_model": "same",
    "eviction_interval_sec": 300,
    "session_ttl_sec": 86400
  }
}
```

## Override precedence

| Priority | Source | Description |
|----------|--------|-------------|
| 1 (Highest) | `config.overrides` | Explicit user intent — absolute priority |
| 2 | Hardware-derived | Tier-based defaults from `SetupRouter.ps1` |
| 3 | Legacy flat keys | `cache_type_k`, `flash_attn`, etc. auto-promoted to overrides |
| 4 (Lowest) | Hardcoded defaults | `Get-InferenceParams` default table |

**Legacy key promotion** (in `SetupRouter.ps1`):
```powershell
$legacyKeys = @("cache_type_k", "cache_type_v", "flash_attn", "ctx_size", "ubatch_size", "parallel_slots")
foreach ($key in $legacyKeys) {
    if ($config.ContainsKey($key) -and -not $config.overrides.ContainsKey($key)) {
        $config.overrides[$key] = $config[$key]
    }
}
```

Once promoted, they lock derived parameters to historical values.

## Tauri config commands (`config.rs`)

```rust
#[tauri::command]
pub fn load_config() -> Result<AppConfig, String> {
    let path = get_config_path();  // AppData/llo-config.json
    let json = fs::read_to_string(path)?;
    serde_json::from_str(&json)
}

#[tauri::command]
pub fn save_config(config: AppConfig) -> Result<(), String> {
    let path = get_config_path();
    fs::create_dir_all(path.parent().unwrap())?;
    let json = serde_json::to_string_pretty(&config)?;
    fs::write(path, json)
}
```

**AppConfig struct** mirrors TypeScript interface (camelCase serialization via `#[serde(rename_all = "camelCase")]`).

## Frontend config store (`configStore.ts`)

```typescript
const useConfigStore = create<ConfigState>((set, get) => ({
  config: null,
  fetchConfig: async () => {
    const config = await invoke<AppConfig>('load_config');
    set({ config });
  },
  updateConfig: (partial) => set({ config: { ...get().config, ...partial } }),
  saveConfig: async () => {
    await invoke('save_config', { config: get().config });
    // Triggers pendingRestart in serverStore
  },
}));
```

## VSCode workspace provisioning (`main.ps1`)

Generates `.vscode/tasks.json` and `.vscode/settings.json`:

### `tasks.json`
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
      "args": ["-File", "script/stop-server.ps1"],
      "group": "build"
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

### `settings.json` (OS-specific terminal env)
```json
{
  "terminal.integrated.env.windows": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8080",
    "ANTHROPIC_AUTH_TOKEN": "local",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  },
  "terminal.integrated.env.osx": { ... },
  "terminal.integrated.env.linux": { ... }
}
```

**OS-specific shell:**
- Windows: `powershell.exe`
- macOS/Linux: `pwsh`

## Integration-specific config

### Claude Code
```json
"integrations": ["claude-code"]
```
Effects:
- `parallel` floored at 2
- `idle_timeout_sec` floored at 600 (10 min)
- Wizard offers interactive launch
- Tauri `launch_claude_terminal` command sets env vars + spawns terminal

### Context Manager
```json
"context_manager": { "enabled": true, "proxy_port": 8090 }
```
Effects:
- `StartContextManager.ps1` launches proxy
- `launch_claude_terminal` routes to proxy port (8090) instead of server port

### Fallback provider
```json
"fallback_provider": "anthropic",
"fallback_api_key": "sk-...",
"fallback_endpoint": "https://api.anthropic.com",
"fallback_model": "claude-3-5-sonnet-20241022"
```
When no local models found: routes client traffic to cloud provider instead of starting `llama-server`.

## Entry Points for Modification

| Task | Entry Point | File |
|------|-------------|------|
| Add a config key | Add to JSON schema + Rust/TS `AppConfig` | `ui/src/lib/configSchema.ts`, `ui/src-tauri/src/commands/config.rs` |
| Change config path resolution | Edit candidate order | `llo-core/Paths.ps1` |
| Change override promotion list | Edit legacy keys array | `llo-core/SetupRouter.ps1` |
| Change VSCode task/env generation | Edit wizard emission block | `main.ps1` |
| Change context manager defaults | Edit sub-config defaults | `main.ps1`, `script/StartContextManager.ps1` |
| Add a fallback provider | Edit provider enum + env wiring | `ui/src/lib/configSchema.ts`, `main.ps1` |

## Key source files

| File | Purpose |
|------|---------|
| `llo-core/Paths.ps1` | `Get-LLMManagerUserDataDir`, `Get-LLMManagerConfigPath` |
| `ui/src-tauri/src/commands/config.rs` | `load_config`, `save_config`, `get_config_path` |
| `main.ps1` | Wizard, initial config, VSCode generation |
| `llo-core/SetupRouter.ps1` | Legacy key promotion, override application |
| `ui/src/store/configStore.ts` | Frontend config state + CRUD |
| `script/start-server.ps1` | Reads config, passes `-ConfigFile` to SetupRouter |
| `script/StartContextManager.ps1` | Reads CM config, launches proxy |

## Related Pages

- [Architecture](../overview/architecture.md) — hardware classification, decision flow, core formulas
- [PowerShell CLI](../applications/powershell-cli.md) — CLI entry points
- [Tauri Desktop App](../applications/tauri-desktop-app.md) — Tauri desktop app command dispatch
- [Hardware-Adaptive Inference](../features/hardware-adaptive-inference.md) — adaptive inference feature
