# Getting started

**Active contributors:** vijay

Prerequisites, installation, and first run instructions for LLM Manager.

## Prerequisites by platform

### Windows

| Requirement | Version | Notes |
|-------------|---------|-------|
| PowerShell | 7.4+ (recommended) or 5.1 | PowerShell 7 is cross-platform; install via `winget install Microsoft.PowerShell` |
| llama.cpp | Latest | Compile from source or download pre-built `llama-server.exe` |
| Rust | 1.78+ | For Tauri desktop app development |
| Node.js | 20+ | For Tauri frontend development |
| Git | Latest | For upstream compatibility checks |

**Optional but recommended:**
- NVIDIA GPU with CUDA 12.x drivers for GPU acceleration
- Visual Studio Build Tools 2022 (for compiling llama.cpp from source)

### macOS

| Requirement | Version | Notes |
|-------------|---------|-------|
| PowerShell | 7.4+ | `brew install powershell` |
| llama.cpp | Latest | `brew install llama.cpp` or compile from source |
| Rust | 1.78+ | `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \| sh` |
| Node.js | 20+ | `brew install node` |
| Xcode Command Line Tools | Latest | `xcode-select --install` |

**Optional:**
- Apple Silicon (M-series) for Metal acceleration
- AMD GPU with Metal support

### Linux

| Requirement | Version | Notes |
|-------------|---------|-------|
| PowerShell | 7.4+ | `sudo apt install powershell` (Ubuntu/Debian) or distro equivalent |
| llama.cpp | Latest | Compile from source; see llama.cpp docs for CUDA/ROCm/Vulkan |
| Rust | 1.78+ | `curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \| sh` |
| Node.js | 20+ | Distro package or `fnm`/`nvm` |
| Build tools | GCC/Clang, CMake, make | For compiling llama.cpp |

**GPU backends:**
- NVIDIA: CUDA 12.x + `nvidia-smi` in PATH
- AMD: ROCm + `rocm-smi` in PATH
- Intel/AMD integrated: Vulkan SDK + `vulkaninfo`

## Installation

### Option 1: Clone and run wizard (recommended)

```bash
git clone https://github.com/vijaytank/llm-manager.git
cd llm-manager

# Windows
powershell -File main.ps1

# macOS / Linux
pwsh -File main.ps1
# or
./run-setup.sh
```

The interactive wizard will:
1. Detect or prompt for `llama-server` binary path
2. Detect or prompt for models directory (where your `.gguf` files live)
3. Optionally configure cloud fallback (Ollama, OpenAI, Anthropic, NVIDIA NIM)
4. Optionally enable client integrations (VSCode, Claude Code, Cursor, Continue)
5. Write `llo-config.json` to your AppData directory
6. Generate `.vscode/tasks.json` and `.vscode/settings.json` for VSCode integration

### Option 2: Tauri desktop app (development)

```bash
cd ui
npm install
npm run tauri dev
```

This runs the React frontend with hot reload and the Rust backend in development mode.

### Option 3: Tauri desktop app (production build)

```bash
cd ui
npm run tauri build --release
```

Produces platform-specific installers:
- Windows: `.msi` / `.exe` (NSIS)
- macOS: `.dmg` / `.app`
- Linux: `.AppImage` / `.deb` / `.rpm`

## First run

After the wizard completes:

1. **Place your GGUF models** in the configured `models_dir` (default: `./models` relative to workspace root, or your chosen path)

2. **Start the server:**
   ```powershell
   # Windows
   powershell -File script/start-server.ps1

   # macOS / Linux
   pwsh -File script/start-server.ps1
   # or
   ./script/start-server.sh
   ```

   The server starts on port 8080 (auto-shifts if occupied). Output includes:
   - Detected hardware profile and performance tier
   - Derived inference parameters
   - Discovered models with assigned chat templates
   - Client environment variables for integration

3. **Verify health:**
   ```powershell
   powershell -File script/test-health.ps1
   ```

4. **Connect a client:**
   - **Claude Code:** The wizard offers to launch it automatically, or run:
     ```bash
     ANTHROPIC_BASE_URL=http://127.0.0.1:8080 \
     ANTHROPIC_AUTH_TOKEN=local \
     CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
     claude
     ```
   - **Cursor / Continue:** Use `http://127.0.0.1:8080/v1` as the OpenAI-compatible base URL
   - **VSCode:** Use the generated tasks (Ctrl+Shift+B → "Start LLM Server")

## Directory layout after setup

```
%APPDATA%\LLM Manager\          (Windows)
~/.config/LLM Manager/          (macOS/Linux)
├── llo-config.json             # Your configuration
├── models-preset.ini           # Generated at each server start
├── .cached_flags.json          # llama-server flag cache
├── .assets-manifest.json       # Template/grammar SHA cache
├── logs/
│   ├── llama-server.log        # Server stdout
│   └── llama-server.err.log    # Server stderr
└── checkpoints/                # Context manager session state
```

## Configuration basics

The wizard creates `llo-config.json` with these key sections:

```json
{
  "installation_type": "local",
  "llama_server_path": "C:\\path\\to\\llama-server.exe",
  "llama_repo_path": "C:\\path\\to\\llama.cpp",
  "models_dir": "C:\\path\\to\\your\\models",
  "templates_dir": "C:\\path\\to\\llama.cpp\\models\\templates",
  "grammars_dir": "C:\\path\\to\\llama.cpp\\grammars",
  "active_model": "",
  "overrides": {},
  "integrations": ["server-only"],
  "idle_timeout_sec": 60,
  "fallback_provider": "none",
  "context_manager": {
    "enabled": false,
    "proxy_port": 8090
  }
}
```

**Important:** The Tauri app and PowerShell scripts read/write the config in AppData, not the workspace root. The workspace `llo-config.json` is only a template copied on first launch.

## Common commands

| Task | Command |
|------|---------|
| Run wizard | `powershell -File main.ps1` / `pwsh -File main.ps1` |
| Start server | `powershell -File script/start-server.ps1` |
| Stop server | `powershell -File script/stop-server.ps1` |
| Health check | `powershell -File script/test-health.ps1` |
| Verify flags | `powershell -File script/verify-scripts.ps1` |
| Launch context proxy | `powershell -File script/StartContextManager.ps1` |
| Tauri dev | `cd ui && npm run tauri dev` |
| Tauri build | `cd ui && npm run tauri build --release` |
| Frontend tests | `cd ui && npm run test` |
| Rust tests | `cd ui/src-tauri && cargo test` |
| Python tests | `pytest llo-core/context_manager/tests` |

## Troubleshooting first run

| Issue | Resolution |
|-------|------------|
| `llama-server` not found | Ensure path in `llo-config.json` is correct; use absolute path |
| No models discovered | Check `models_dir` exists and contains `.gguf` files |
| Port 8080 in use | Server auto-shifts; check output for actual port |
| GPU not detected | Verify `nvidia-smi` / `rocm-smi` / `system_profiler` work in shell |
| PowerShell execution policy | Run `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` |
| Tauri build fails | Ensure Rust toolchain installed; run `rustup update` |

## Next steps

- Read [Architecture](architecture.md) for the decision engine details
- See [Hardware Profiling](systems/hardware-profiling.md) for GPU classification
- See [Parameter Derivation](systems/parameter-derivation.md) for inference formulas
- See [Client Integrations](features/client-integrations.md) for VSCode, Claude Code, Cursor setup
- See [Configuration Reference](reference/configuration.md) for all config options
