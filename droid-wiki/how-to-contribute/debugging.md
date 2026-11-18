# Debugging

**Active contributors:** vijay

Logs, common errors, and troubleshooting runbook for LLM Manager.

## Log locations

| Component | Log file | Notes |
|-----------|----------|-------|
| llama-server stdout | `%APPDATA%\LLM Manager\logs\llama-server.log` | Tailed by Tauri GUI |
| llama-server stderr | `%APPDATA%\LLM Manager\logs\llama-server.err.log` | Tailed by Tauri GUI |
| Hardware probe | `%APPDATA%\LLM Manager\logs\hardware_debug.log` | Written by `profile.rs` on deserialize error |
| Context Manager | Console output (stdout/stderr) | Run with `python -m uvicorn proxy:app --log-level debug` |
| Tauri app | DevTools console (frontend), terminal (backend) | `npm run tauri dev` |

## Common errors and fixes

### Server won't start

| Symptom | Cause | Fix |
|---------|-------|-----|
| `llama-server not found` | Path wrong in config | Update `llama_server_path` in AppData `llo-config.json` |
| `Port 8080 in use` | Another process | Server auto-shifts; check output for actual port |
| `CUDA not found` | Driver missing or `nvidia-smi` not in PATH | Install CUDA toolkit; ensure `nvidia-smi` works in shell |
| `GGUF file not found` | `models_dir` wrong or empty | Check `models_dir` in config; ensure `.gguf` files present |
| `Flash Attention failed` | Incompatible GPU/llama.cpp build | Disable via `overrides.flash_attn = "off"` or rebuild llama.cpp |
| `Out of memory` | VRAM exceeded | Reduce `ctx_size`, enable `fit`, lower `cache_type_k/v` to `q8_0` |

### Hardware detection issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| GPU shows "No Compatible GPU" | `nvidia-smi`/`rocm-smi` not found | Ensure in PATH; check `Profile.ps1` detection priority |
| Integrated GPU misclassified as dedicated | WMI `AdapterRAM` ≈ system RAM | Threshold is 256 MB difference; check manually |
| Apple Silicon VRAM = 0 | Unified memory not reported as VRAM | `system_profiler` shows "Memory: X GB (Unified)"; tier logic handles this |
| CPU threads = logical not physical | Intel hybrid not detected | `Profile.ps1` caps at 8 for Intel >8 physical cores |

### Config issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| Changes not applying | Editing workspace `llo-config.json` | Edit AppData config (`%APPDATA%\LLM Manager\llo-config.json`) |
| Overrides ignored | Key not in `overrides` block | Move key to `config.overrides`; legacy flat keys auto-promoted |
| Context Manager not starting | `enabled: false` | Set `context_manager.enabled = true` in config |
| Template not applied | `templates_dir` wrong | Check `templates_dir` in config; run wizard to resync |

### Tauri app issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| "Script not found" | Workspace root resolution failed | Check `scripts.rs` `get_workspace_root()` logic; ensure `llo-core/` exists |
| Config not saving | AppData dir permissions | Ensure `%APPDATA%\LLM Manager` writable |
| Logs not streaming | Log file not created yet | Server hasn't started; check `server.rs` tailer retry logic |
| Build fails | Rust/Node version mismatch | `rustup update`; `node --version` (need 20+) |

## Debugging PowerShell scripts

### Verbose output

```powershell
# Run with verbose/debug
powershell -File script/start-server.ps1 -Verbose
powershell -File llo-core/Profile.ps1 -Json  # JSON output for parsing
```

### Inspect intermediate values

```powershell
# Profile hardware manually
. llo-core/Profile.ps1
$hw = Get-SystemHardwareProfile
$hw | ConvertTo-Json -Depth 5

# Derive params manually
. llo-core/SetupRouter.ps1
$params = Get-InferenceParams -Hardware $hw -Overrides @{}
$params | ConvertTo-Json
```

### AST syntax check (used by test-health)

```powershell
$errors = $null
$tokens = $null
[void][System.Management.Automation.Language.Parser]::ParseFile("script/start-server.ps1", [ref]$tokens, [ref]$errors)
$errors
```

## Debugging Python Context Manager

### Run with debug logging

```bash
cd llo-core/context_manager
.venv/bin/activate
python -m uvicorn proxy:app --host 0.0.0.0 --port 8090 --log-level debug
```

### Inspect compression decisions

```python
# In context_engine.py, add debug prints or use debugger
engine = ContextEngine(...)
session = engine.get_or_create_session("test")
print(f"Tokens: {engine.count_tokens_messages(session.messages)}")
print(f"Needs compression: {engine.needs_compression(session, max_tokens_requested)}")
print(f"Hash: {engine._compute_hash(session.id, to_summarize)}")
```

### Check tokenizer cache

```python
from tokenizer_cache import get_tokenizer
tok = get_tokenizer("claude-3-5-sonnet-20241022")
print(f"Tokenizer: {tok.name_or_path}")
print(f"Token count: {len(tok.encode('Hello world'))}")
```

## Debugging Tauri app

### Frontend (React)

```bash
cd ui
npm run tauri dev
# Opens DevTools automatically; check Console, Network, React DevTools
```

### Backend (Rust)

```bash
cd ui/src-tauri
cargo run
# Logs appear in terminal; use `RUST_LOG=debug cargo run` for verbose
```

### IPC inspection

In `scripts.rs`, `run_powershell_script` returns stdout/stderr. Add debug:

```rust
let output = run_powershell_script(...);
eprintln!("PS stdout: {}", output);  // Appears in terminal
```

## Health check diagnostics

Run the full health check with details:

```powershell
powershell -File script/test-health.ps1
```

Output includes:
- Syntax check: file + line numbers for any parse errors
- Config schema: missing keys, overrides block status
- Hardware probe: JSON output or error
- Parameter derivation: derived values vs overrides
- Server ping: HTTP status, response time, model list
- Flag compat: any flags used in scripts but missing from binary

## Troubleshooting runbook

### Server starts but clients can't connect

1. Check `llama-server.log` for "HTTP server listening on"
2. Verify port matches client config (`ANTHROPIC_BASE_URL`, Cursor base URL)
3. Check firewall (Windows: allow `llama-server.exe`; Linux: `ufw allow 8080`)
4. Try `curl http://127.0.0.1:8080/health` → should return JSON

### Model not loading / wrong template

1. Check `models-preset.ini` in AppData — does it have your model?
2. Verify `templates_dir` has matching `.jinja` file
3. Check `Models` page in Tauri GUI — shows template match method
4. Force template: set `active_template` in config overrides

### Context Manager compressing too aggressively / not enough

1. Check `warn_threshold` (default 0.70) — lower = earlier compression
2. Check `keep_turns` (default 6) — increase to preserve more history
3. Check `ctx_limit` — 0 = auto from preset; set explicit value if needed
4. Review `context_engine.py` `needs_compression` logic

### Performance lower than expected

1. Verify GPU tier in Overview page — is it `mid`/`high` or stuck at `cpu`?
2. Check `n_gpu_layers` in Performance page — should be `-1` for GPU tiers
3. Check `cache_type_k/v` — `q8_0` for GPU, `f16` for CPU
4. Check `ubatch_size` — larger = more throughput (512/1024 for GPU)
5. Run `llama-server` manually with `-v` for verbose timing logs

## Useful diagnostic commands

```powershell
# Show current config (AppData)
Get-Content "$env:APPDATA\LLM Manager\llo-config.json" | ConvertFrom-Json

# Show generated preset
Get-Content "$env:APPDATA\LLM Manager\models-preset.ini"

# Show hardware profile JSON
powershell -File llo-core/Profile.ps1 -Json

# Test llama-server binary directly
& "path\to\llama-server.exe" --help

# Check port listeners
Get-NetTCPConnection -LocalPort 8080 -State Listen

# Tail server logs
Get-Content "$env:APPDATA\LLM Manager\logs\llama-server.log" -Wait -Tail 50
```

```bash
# macOS/Linux equivalents
cat ~/.config/LLM\ Manager/llo-config.json | jq
cat ~/.config/LLM\ Manager/models-preset.ini
pwsh -File llo-core/Profile.ps1 -Json
./llama-server --help
ss -tlnp | grep 8080
tail -f ~/.config/LLM\ Manager/logs/llama-server.log
```
