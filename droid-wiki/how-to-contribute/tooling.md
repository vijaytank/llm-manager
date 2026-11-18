# Tooling

**Active contributors:** vijay

Build system, linters, code generators, and CI tooling for LLM Manager.

## PowerShell tooling

### Script execution

| Command | Purpose |
|---------|---------|
| `powershell -File main.ps1` | Interactive setup wizard (Windows) |
| `pwsh -File main.ps1` | Interactive setup wizard (macOS/Linux) |
| `powershell -File script/start-server.ps1` | Start llama-server |
| `powershell -File script/stop-server.ps1` | Stop llama-server |
| `powershell -File script/test-health.ps1` | Full health check (mandatory pre-PR) |
| `powershell -File script/verify-scripts.ps1` | Flag compatibility vs llama-server binary |
| `powershell -File script/StartContextManager.ps1` | Launch Python context proxy |
| `powershell -File llo-core/Profile.ps1 -Json` | Hardware profile as JSON |
| `powershell -File llo-core/SetupRouter.ps1` | Derive params + generate preset |
| `powershell -File llo-core/ParseHelp.ps1` | Parse llama-server --help, update cache |
| `powershell -File llo-core/GitDiff.ps1` | Scan upstream git for breaking changes |
| `powershell -File llo-core/FetchAssets.ps1` | Sync templates/grammars from llama.cpp |

### AST syntax validation

Built into `test-health.ps1`:

```powershell
$errors = $null
$tokens = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
```

Runs on all `.ps1` files recursively (excludes `test-health.ps1` itself).

### Module discovery

Scripts dot-source helpers via `$PSScriptRoot`:

```powershell
$lloCoreDir = Join-Path $ManagerDir "llo-core"
if (Test-Path (Join-Path $lloCoreDir "Paths.ps1")) {
    . (Join-Path $lloCoreDir "Paths.ps1")
}
```

## Python tooling (Context Manager)

### Virtual environment

Project-local venv at `llo-core/context_manager/.venv/`:

```bash
cd llo-core/context_manager
python -m venv .venv
.venv/bin/activate  # Windows: .venv\Scripts\Activate.ps1
pip install -r requirements.txt
pip install pytest pytest-asyncio httpx
```

### Dependencies (`requirements.txt`)

```
fastapi>=0.110
uvicorn>=0.29
httpx>=0.27
pydantic>=2.7
pydantic-settings>=2.3
tiktoken>=0.7
transformers>=4.40
tokenizers>=0.19
pytest>=8.0
pytest-asyncio>=0.23
```

### Test runner

```bash
pytest tests/ -v
pytest tests/ --cov=context_manager --cov-report=html
```

### Type checking (optional)

```bash
mypy context_manager/ --ignore-missing-imports
```

## Rust tooling (Tauri backend)

### Cargo workspace

Single package at `ui/src-tauri/`:

```toml
# Cargo.toml
[package]
name = "llm-manager"
version = "0.2.0"
edition = "2021"

[dependencies]
tauri = { version = "2", features = ["shell-open", "process-relaunch"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tokio = { version = "1", features = ["full"] }
chrono = { version = "0.4", features = ["serde"] }
```

### Commands

```bash
cd ui/src-tauri

cargo test              # Unit tests
cargo clippy            # Lints (must pass)
cargo fmt --check       # Format check
cargo build --release   # Release binary
cargo doc --open        # Generate docs
```

### Tauri CLI

```bash
cd ui
npm run tauri dev       # Dev mode (hot reload)
npm run tauri build     # Debug build
npm run tauri build --release  # Release installer
```

## Node.js tooling (Tauri frontend)

### Package.json scripts

```json
{
  "scripts": {
    "dev": "vite",
    "build": "tsc && vite build",
    "preview": "vite preview",
    "test": "vitest",
    "test:run": "vitest run",
    "test:coverage": "vitest run --coverage",
    "lint": "eslint src --ext ts,tsx",
    "tauri": "tauri",
    "tauri:dev": "tauri dev",
    "tauri:build": "tauri build"
  }
}
```

### Dependencies

```json
{
  "dependencies": {
    "react": "^18.2",
    "react-dom": "^18.2",
    "zustand": "^4.4",
    "lucide-react": "^0.294",
    "@tauri-apps/api": "^2",
    "@tauri-apps/plugin-dialog": "^2"
  },
  "devDependencies": {
    "typescript": "^5.3",
    "vite": "^5.0",
    "vitest": "^1.0",
    "@testing-library/react": "^14",
    "@testing-library/jest-dom": "^6",
    "eslint": "^8.55",
    "@typescript-eslint/eslint-plugin": "^6",
    "@typescript-eslint/parser": "^6"
  }
}
```

### Type checking

```bash
cd ui
npm run build  # Runs tsc (noEmit) + Vite build
```

### Testing

```bash
npm run test:run        # CI mode
npm run test:coverage   # With coverage report
```

## Build orchestration

### GitHub Actions (`.github/workflows/`)

CI runs on push/PR to `develop`:

1. **PowerShell matrix** — Windows, macOS, Linux runners
   - `test-health.ps1`
   - `verify-scripts.ps1`
2. **Python** — Ubuntu
   - `pytest llo-core/context_manager/tests`
3. **Frontend** — Ubuntu
   - `npm ci && npm run build && npm run test:run`
4. **Backend** — Ubuntu, Windows, macOS
   - `cargo test && cargo clippy`
5. **Release** — On tag push (`v*`)
   - `tauri build --release` on all platforms
   - Upload artifacts (NSIS, DMG, AppImage)

### Release artifacts

| Platform | Format | Tool |
|----------|--------|------|
| Windows | `.msi` / `.exe` (NSIS) | Tauri bundler |
| macOS | `.dmg` / `.app` | Tauri bundler |
| Linux | `.AppImage` / `.deb` / `.rpm` | Tauri bundler |

## Code generation

### Template/grammar sync (`FetchAssets.ps1`)

Downloads from `ggml-org/llama.cpp` GitHub:

```powershell
# SHA-cached: only downloads changed files
$manifest = Get-Content .assets-manifest.json | ConvertFrom-Json
$remoteSHA = (Invoke-RestMethod "https://api.github.com/repos/ggml-org/llama.cpp/contents/models/templates").sha
if ($manifest.templates_sha -ne $remoteSHA) {
    # Download changed files only
}
```

### VSCode workspace generation (`main.ps1`)

Creates `.vscode/tasks.json` and `.vscode/settings.json`:

```json
// tasks.json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "Start LLM Server",
      "type": "shell",
      "command": "powershell.exe",
      "args": ["-File", "script/start-server.ps1"],
      "group": "build"
    }
  ]
}
```

OS-specific terminal env injection in `settings.json`:
- `terminal.integrated.env.windows`
- `terminal.integrated.env.osx`
- `terminal.integrated.env.linux`

## Development utilities

### Hardware probe debug

```powershell
# Raw JSON output
powershell -File llo-core/Profile.ps1 -Json | ConvertFrom-Json

# Check cached flags
Get-Content .cached_flags.json | ConvertFrom-Json

# Check asset manifest
Get-Content .assets-manifest.json | ConvertFrom-Json
```

### Config inspection

```powershell
# AppData config (what Tauri uses)
Get-Content "$env:APPDATA\LLM Manager\llo-config.json" | ConvertFrom-Json

# Generated preset
Get-Content "$env:APPDATA\LLM Manager\models-preset.ini"
```

### Server debug

```powershell
# Direct llama-server test
& "path\to\llama-server.exe" -m model.gguf -c 4096 --port 8081

# Health endpoint
Invoke-RestMethod http://127.0.0.1:8080/health

# Models endpoint
Invoke-RestMethod http://127.0.0.1:8080/v1/models
```

### Context Manager debug

```bash
# Run proxy directly with debug logs
cd llo-core/context_manager
.venv/bin/activate
python -m uvicorn proxy:app --log-level debug --port 8090

# Test compression
curl -X POST http://127.0.0.1:8090/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-llm-session-id: test-session" \
  -d '{"model":"test","messages":[{"role":"user","content":"Hello"}]}'
```

## Version management

| File | Version field |
|------|---------------|
| `ui/package.json` | `"version"` |
| `ui/src-tauri/Cargo.toml` | `version` |
| `llo-core/context_manager/pyproject.toml` | `version` |
| `main.ps1` | `$ScriptVersion` variable |

Update all four on release.
