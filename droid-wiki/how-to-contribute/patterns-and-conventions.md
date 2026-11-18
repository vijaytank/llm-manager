# Patterns and conventions

**Active contributors:** vijay

Coding conventions, error handling, and cross-cutting patterns in LLM Manager.

## PowerShell conventions

### Cross-platform guards

Every OS-specific branch **must** use `$IsWindows`, `$IsMacOS`, or `$IsLinux`:

```powershell
if ($IsWindows) {
    $cpu = Get-CimInstance Win32_Processor
} elseif ($IsMacOS) {
    $cpuName = sysctl -n machdep.cpu.brand_string
} elseif ($IsLinux) {
    $cpuInfo = Get-Content /proc/cpuinfo
}
```

Never use Windows-only APIs without equivalent branches.

### Path resolution

Always resolve paths relative to `$PSScriptRoot`:

```powershell
$ManagerDir = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$lloCoreDir = Join-Path $ManagerDir "llo-core"
$scriptPath = Join-Path $lloCoreDir "Profile.ps1"
```

Never hardcode `C:\`, `/home/`, or absolute paths.

### Error handling

```powershell
$ErrorActionPreference = "Stop"  # At top of every script

try {
    $result = RiskyOperation
} catch {
    Write-Host "[ERROR] Operation failed: $($_.Exception.Message)" -ForegroundColor Red
    # Decide: throw, return default, or continue
}
```

Use `Write-Host` with `-ForegroundColor` for structured output:
- Green: Success
- Yellow: Warning
- Red: Error
- Cyan: Info/Progress
- DarkYellow: Override/Config notice

### JSON output for machine parsing

Use `-Json` switch for programmatic consumption:

```powershell
param([switch]$Json)

if ($Json) {
    $result | ConvertTo-Json -Depth 5 -Compress
    return
}
Write-Host "Human readable output..."
```

### Parameter validation

```powershell
param(
    [Parameter(Mandatory=$false)]
    [ValidateRange(1, 65535)]
    [int]$Port = 8080,

    [Parameter(Mandatory=$false)]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigFile
)
```

## Rust conventions

### Tauri command pattern

```rust
#[tauri::command]
pub async fn command_name(app: AppHandle, param: Type) -> Result<ReturnType, String> {
    // 1. Validate input
    // 2. Resolve paths via scripts.rs helpers
    // 3. Dispatch to PowerShell via run_powershell_script
    // 4. Parse JSON output
    // 5. Return typed result or Err(String)
}
```

### Error handling

Return `Result<T, String>` — `String` error messages propagate to frontend as toast notifications.

```rust
run_powershell_script("script/start-server.ps1", &args)
    .map_err(|e| format!("Failed to start server: {}", e))?;
```

### State management

Use `std::sync::atomic` for simple flags, `Mutex` for complex state:

```rust
static IS_RUNNING: AtomicBool = AtomicBool::new(false);
static LOG_TAIL_TASKS: Mutex<Vec<JoinHandle<()>>> = Mutex::new(Vec::new());
```

### Serialization

Use `serde` with `#[serde(rename_all = "camelCase")]` for frontend compatibility:

```rust
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GpuInfo {
    pub name: String,
    pub total_vram_mb: u32,
    pub adapter_class: String,
    pub performance_tier: String,
}
```

## TypeScript/React conventions

### State management (Zustand)

```typescript
// store/hardwareStore.ts
interface HardwareState {
  profile: SystemHardware | null;
  loading: boolean;
  error: string | null;
  fetchHardware: () => Promise<void>;
}

export const useHardwareStore = create<HardwareState>((set) => ({
  profile: null,
  loading: false,
  error: null,
  fetchHardware: async () => { /* ... */ },
  setProfile: (profile) => set({ profile }),
}));
```

### Component structure

```tsx
// pages/Overview.tsx
export const OverviewPage: React.FC = () => {
  const { profile, fetchHardware } = useHardwareStore();
  const { config } = useConfigStore();

  useEffect(() => { fetchHardware(); }, []);

  return (
    <PageShell title="Overview">
      {/* Content */}
    </PageShell>
  );
};
```

### Tauri invoke pattern

```typescript
import { invoke } from '@tauri-apps/api/core';

const result = await invoke<ReturnType>('command_name', { paramName: value });
```

### Type definitions

Match Rust structs exactly (camelCase):

```typescript
// In store or lib/types.ts
export interface SystemHardware {
  cpuName: string;
  physicalCores: number;
  logicalCores: number;
  totalRamGb: number;
  gpuName: string;
  vramGb: number;
  adapterClass: 'none' | 'integrated' | 'dedicated';
  performanceTier: 'cpu' | 'low' | 'mid' | 'high';
}
```

## Python conventions

### FastAPI dependency injection

```python
def get_engine(request: Request) -> ContextEngine:
    if hasattr(request.app.state, "engine"):
        return request.app.state.engine
    raise RuntimeError("Engine not initialized")

@app.post("/v1/messages")
async def proxy_all(request: Request, path: str, engine: ContextEngine = Depends(get_engine)):
    ...
```

### Pydantic settings

```python
class ContextManagerConfig(BaseModel):
    enabled: bool = Field(default=False, description="Enable context manager")
    warn_threshold: float = Field(default=0.70, ge=0.0, le=1.0)
    keep_turns: int = Field(default=6, ge=1)
    proxy_port: int = Field(default=8090, ge=1, le=65535)
```

### Async patterns

```python
async def compress(self, session: SessionState, max_allowed_tokens: int) -> CompressionResult:
    # Use httpx.AsyncClient for upstream calls
    async with self.http_client.stream("POST", url, json=payload) as response:
        async for chunk in response.aiter_bytes():
            yield chunk
```

## Configuration conventions

### Override precedence

1. **`config.overrides`** — Absolute priority (explicit user intent)
2. **Hardware-derived** — Tier-based defaults from `SetupRouter.ps1`
3. **Legacy flat keys** — Auto-promoted to overrides (backward compat)
4. **Hardcoded defaults** — Final fallback in `Get-InferenceParams`

### AppData vs Workspace

| File | Location | Authority |
|------|----------|-----------|
| `llo-config.json` | AppData (primary), Workspace (template) | Tauri app owns AppData; wizard copies template |
| `models-preset.ini` | AppData (generated at startup) | `SetupRouter.ps1` writes; `llama-server` reads |
| `.cached_flags.json` | AppData (or workspace fallback) | `ParseHelp.ps1` updates |
| `.assets-manifest.json` | AppData (or workspace fallback) | `FetchAssets.ps1` updates |
| Logs | AppData/logs/ | `start-server.ps1` + Tauri tailer |
| Checkpoints | AppData/checkpoints/ | `context_engine.py` |

## Git conventions

### Branch naming

`feat/`, `fix/`, `refactor/`, `docs/`, `test/`, `chore/` + short description

### Commit messages

Conventional Commits: `type(scope): subject`

### Default branch

**`develop`** — not `main` or `master`. All PRs target `develop`.

## Testing conventions

| Layer | Pattern |
|-------|---------|
| PowerShell | `test-health.ps1` AST parse + functional checks |
| Python | `pytest` with fixtures, parametrized, async |
| React | Vitest + React Testing Library, store hooks tested via `renderHook` |
| Rust | `#[cfg(test)]` modules alongside source, `cargo test` |

## Documentation conventions

- Update `ARCHITECTURE.md` for algorithm changes
- Update `SYSTEM_COMMANDS.md` for new CLI flags
- Update `USER_GUIDE.md` for user-facing features
- Wiki pages in `droid-wiki/` generated via `/wiki` command
