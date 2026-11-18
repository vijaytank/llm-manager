# Dependencies

**Active contributors:** vijay

External dependencies and versions for each component.

## Upstream dependency

| Dependency | Version | Purpose |
|------------|---------|---------|
| **llama.cpp** (ggml-org/llama.cpp) | Latest main branch | Core inference engine (`llama-server` binary) |
| **llama.cpp templates** | Synced from upstream | Chat templates (`.jinja`) |
| **llama.cpp grammars** | Synced from upstream | GBNF grammars (`.gbnf`) |

## PowerShell Core

| Dependency | Version | Purpose |
|------------|---------|---------|
| **PowerShell** | 7.4+ (cross-platform) / 5.1 (Windows) | Scripting runtime |
| **.NET Framework** | 4.8+ / .NET 6+ | `IPGlobalProperties` for port scanning, `Get-CimInstance` for WMI |
| **Pester** | 5.x | Testing framework (optional, for unit tests) |

### Platform-specific commands

| Platform | Commands Used |
|----------|---------------|
| **Windows** | `Get-CimInstance`, `Get-Command`, `Test-Path`, `nvidia-smi.exe` |
| **macOS** | `sysctl`, `system_profiler`, `nvidia-smi` |
| **Linux** | `/proc/cpuinfo`, `/proc/meminfo`, `nvidia-smi`, `rocm-smi`, `/sys/class/drm` |

## Python Context Manager (`llo-core/context_manager/`)

### `requirements.txt`

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

### Dependency details

| Package | Version | Purpose |
|---------|---------|---------|
| **fastapi** | 0.110+ | Async web framework for proxy server |
| **uvicorn** | 0.29+ | ASGI server |
| **httpx** | 0.27+ | Async HTTP client for upstream calls |
| **pydantic** | 2.7+ | Settings validation and serialization |
| **pydantic-settings** | 2.3+ | Settings management from JSON/env |
| **tiktoken** | 0.7+ | Fast token counting (OpenAI models) |
| **transformers** | 4.40+ | HuggingFace tokenizers for non-OpenAI models |
| **tokenizers** | 0.19+ | Rust-backed tokenizer library |
| **pytest** | 8.0+ | Test runner |
| **pytest-asyncio** | 0.23+ | Async test support |

### Python version

- **Minimum:** 3.10
- **Recommended:** 3.11+

## Tauri Desktop App

### Frontend (`ui/package.json`)

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

### Frontend dependency details

| Package | Version | Purpose |
|---------|---------|---------|
| **react** | 18.2+ | UI framework |
| **react-dom** | 18.2+ | DOM renderer |
| **zustand** | 4.4+ | Lightweight state management |
| **lucide-react** | 0.294+ | Icon library |
| **@tauri-apps/api** | 2.x | Tauri IPC (invoke, events) |
| **@tauri-apps/plugin-dialog** | 2.x | File dialog plugin |
| **typescript** | 5.3+ | Type checking |
| **vite** | 5.0+ | Build tool + dev server |
| **vitest** | 1.0+ | Test runner |
| **@testing-library/react** | 14+ | Component testing |
| **eslint** | 8.55+ | Linting |

### Backend (`ui/src-tauri/Cargo.toml`)

```toml
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

### Backend dependency details

| Crate | Version | Purpose |
|-------|---------|---------|
| **tauri** | 2.x | Desktop app framework |
| **serde** | 1.x | Serialization |
| **serde_json** | 1.x | JSON serialization |
| **tokio** | 1.x | Async runtime |
| **chrono** | 0.4 | Date/time with serde support |

### Rust version

- **Minimum:** 1.78 (MSRV for Tauri 2)
- **Recommended:** Latest stable

### Node.js version

- **Minimum:** 20 (LTS)
- **Recommended:** 20.x LTS

## Build & Release Tooling

| Tool | Version | Purpose |
|------|---------|---------|
| **cargo** | 1.78+ | Rust build |
| **tauri-cli** | 2.x | Tauri bundler |
| **npm** | 10+ | Node package manager |
| **GitHub Actions** | Latest | CI/CD |

## Version matrix

| Component | Version Constraint |
|-----------|-------------------|
| llama.cpp | Track main branch; test-health validates compatibility |
| PowerShell | 7.4+ / 5.1 |
| Python | 3.10+ |
| Rust | 1.78+ |
| Node.js | 20+ |
| Tauri | 2.x |

## Dependency update policy

1. **llama.cpp** — Track upstream main; `test-health.ps1` + `verify-scripts.ps1` catch breaking changes
2. **Rust crates** — `cargo update` + `cargo audit` periodically
3. **npm packages** — `npm audit` + `npm update` periodically
4. **Python packages** — `pip list --outdated` + `pip install -U` periodically

## Security auditing

```bash
# Rust
cd ui/src-tauri
cargo audit

# Node.js
cd ui
npm audit

# Python
cd llo-core/context_manager
pip-audit
```
