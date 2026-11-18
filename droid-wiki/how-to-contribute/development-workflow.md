# Development workflow

**Active contributors:** vijay

Branch, code, test, PR, merge cycle for LLM Manager.

## Branch strategy

- **`develop`** — Default branch. All feature branches target `develop`.
- **`main`** — Release tags only. Protected.
- **Feature branches:** `feat/<short-description>`, `fix/<short-description>`, `refactor/<...>`, `docs/<...>`, `test/<...>`, `chore/<...>`
- **No long-running feature branches** — keep changes small and merge frequently.

## Local development setup

```bash
# Clone
git clone https://github.com/vijaytank/llm-manager.git
cd llm-manager

# PowerShell core development
# No build step — edit .ps1 files directly

# Python context manager
cd llo-core/context_manager
# Use project venv or global Python
python -m venv .venv
.venv/bin/activate  # or .venv\Scripts\Activate.ps1 on Windows
pip install -r requirements.txt
pip install pytest httpx

# Tauri desktop app
cd ui
npm install
npm run tauri dev  # Development with hot reload
```

## Making changes

### PowerShell scripts (`llo-core/`, `script/`)

1. Edit the `.ps1` file
2. Test syntax: `powershell -File script/test-health.ps1` (includes AST parse check)
3. Test functionally: run the script with appropriate parameters
4. Cross-platform check: verify `$IsWindows`/`$IsMacOS`/`$IsLinux` guards

### Python context manager (`llo-core/context_manager/`)

1. Edit `.py` files
2. Run tests: `pytest llo-core/context_manager/tests -v`
3. Type check: `mypy llo-core/context_manager/` (if configured)

### Tauri frontend (`ui/src/`)

1. Edit React/TypeScript files
2. Type check: `npm run build` (runs `tsc`)
3. Test: `npm run test` (Vitest)
4. Lint: `npm run lint` (if configured)

### Tauri backend (`ui/src-tauri/src/`)

1. Edit Rust files
2. Test: `cargo test`
3. Lint: `cargo clippy`
4. Format: `cargo fmt --check`

## Testing before commit

Run the full suite locally:

```powershell
# 1. PowerShell health check (mandatory)
powershell -File script/test-health.ps1

# 2. Flag compatibility
powershell -File script/verify-scripts.ps1

# 3. Python tests
pytest llo-core/context_manager/tests

# 4. Frontend tests
cd ui
npm run test

# 5. Backend tests
cd src-tauri
cargo test
cargo clippy
```

## Commit message format

```
<type>(<scope>): <subject>

<body> (optional)

<footer> (optional)
```

**Types:** `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `perf`, `security`

**Scopes:** `profile`, `router`, `server`, `models`, `config`, `gui`, `context-manager`, `assets`, `health`, `ci`

**Examples:**
```
feat(profile): add Intel Arc discrete GPU detection
fix(router): prevent ctx_size overflow on 32-bit systems
docs(arch): update KV cache formula with exact byte sizes
refactor(gui): extract model selection logic to hook
test(cm): add compression idempotency test
chore(deps): update Tauri to 2.0.0
```

## PR checklist

- [ ] Branch targets `develop`
- [ ] Conventional commit messages
- [ ] `test-health.ps1` passes
- [ ] All test suites pass
- [ ] No Clippy warnings
- [ ] TypeScript build passes
- [ ] Documentation updated for user-facing changes
- [ ] No hardcoded absolute paths
- [ ] Cross-platform guards in PowerShell
- [ ] AppData config paths respected (not workspace root)

## Release process

1. Maintainer creates release branch from `develop`
2. Version bump in `ui/package.json`, `ui/src-tauri/Cargo.toml`, `llo-core/context_manager/pyproject.toml`
3. CHANGELOG updated
4. Tagged release on `main` triggers GitHub Actions build
5. Artifacts: NSIS installer (Windows), DMG (macOS), AppImage (Linux)
