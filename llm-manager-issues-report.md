# LLM Manager — Develop Branch Issue Report
**Repo:** `vijaytank/llm-manager` · **Branch:** `develop` · **Commit:** `b848a05` · **Date:** 2026-08-10

---

## How to Read This Report

Each issue has:
- **File(s):** exact file(s) affected
- **Problem:** what is wrong and why
- **Fix:** concrete, copy-paste-ready change

Issues are grouped by subsystem. Severity tags: 🔴 **CRITICAL** (will crash or silently corrupt), 🟠 **BUG** (incorrect behaviour), 🟡 **DESIGN** (works but wrong abstraction or will cause pain later), 🔵 **CODE QUALITY** (noise, duplication, dead code).

---

## 1. Context Manager Proxy (`llo-core/context_manager/`)

### 1.1 🔴 Leaked `httpx.AsyncClient` on every streaming request

**File:** `proxy.py` — `proxy_all()`

**Problem:** When `is_stream=True`, a bare `httpx.AsyncClient` is created and passed to `forward_stream()` as a generator. `aclose()` is never called on it. Every streaming request leaks an open TCP connection and file descriptor. Under sustained load this exhausts the OS file-descriptor limit and uvicorn will crash with `Too many open files`.

```python
# Current broken code
client = httpx.AsyncClient(timeout=600.0)
req = client.build_request(...)
resp = await client.send(req, stream=is_stream)

if is_stream:
    return StreamingResponse(
        forward_stream(resp),       # client never closed
        ...
        background=None             # background=None makes it worse
    )
```

**Fix:** Use `httpx.AsyncClient` as an async context manager and pass a closing generator to `StreamingResponse`. The `background` field is the correct hook.

```python
from starlette.background import BackgroundTask

@app.api_route("/{path:path}", methods=["GET","POST","PUT","DELETE","PATCH","OPTIONS","HEAD"])
async def proxy_all(request: Request, path: str):
    ...
    async with httpx.AsyncClient(timeout=600.0) as client:
        req = client.build_request(
            method=request.method,
            url=upstream_url,
            headers=req_headers,
            content=json.dumps(body).encode("utf-8"),
        )
        resp = await client.send(req, stream=is_stream)

        if is_stream:
            async def stream_and_close():
                async for chunk in resp.aiter_bytes():
                    yield chunk
                await resp.aclose()

            return StreamingResponse(
                stream_and_close(),
                status_code=resp.status_code,
                media_type=resp.headers.get("content-type", "text/event-stream"),
            )
        else:
            content = await resp.aread()
            return Response(
                content=content,
                status_code=resp.status_code,
                headers=dict(resp.headers),
            )
```

---

### 1.2 🔴 Passthrough requests also leak `httpx.AsyncClient`

**File:** `proxy.py` — `proxy_all()` non-chat branch

**Problem:** The passthrough block (non-`/completions` routes) does use `async with`, so that branch is fine. But this is the same function scope where the streaming leak (1.1) exists. After fixing 1.1, this branch remains correct — just noting it explicitly because it is easy to accidentally regress.

---

### 1.3 🔴 `_get_ctx_limit_from_messages` is hardcoded to `32768`

**File:** `context_engine.py` — `_get_ctx_limit_from_messages()`

**Problem:** This method is supposed to return the actual model context limit so that `_clamp_message_tokens` can truncate correctly. It always returns `32768` regardless of the model or the `ctx_limit` passed to `maybe_compress`. As a result:

- Models with a 4 096 token context will not be clamped properly, causing 400 errors from llama-server.
- Models with a 128 000 token context will be clamped at 32 768, cutting off perfectly valid history.

```python
def _get_ctx_limit_from_messages(self, messages):
    return 32768   # ← always wrong
```

**Fix:** Pass `ctx_limit` to `compress()` and thread it through:

```python
# In ContextEngine.__init__: store nothing extra

# In maybe_compress: pass ctx_limit into compress
async def maybe_compress(self, session_id, messages, max_tokens_requested, ctx_limit, model_alias=""):
    session = self.get_or_create_session(session_id)
    if self.needs_compression(messages, max_tokens_requested, ctx_limit, model_alias):
        return await self.compress(session, messages, model_alias, ctx_limit=ctx_limit)
    max_allowed = int((ctx_limit if ctx_limit > 0 else 32768) * 0.85)
    return self._clamp_message_tokens(messages, max_allowed, model_alias)

# In compress: accept and use ctx_limit
async def compress(self, session, messages, model_alias="", ctx_limit=32768):
    ...
    max_allowed = int(ctx_limit * 0.85)
    return self._clamp_message_tokens(rebuilt, max_allowed, model_alias)

# Delete _get_ctx_limit_from_messages entirely
```

---

### 1.4 🔴 `config.context_manager` in `SetupRouter.ps1` default has `enabled = $false` but `start-server.ps1` defaults `cmEnabled = $true`

**Files:** `llo-core/SetupRouter.ps1`, `script/start-server.ps1`

**Problem:** `SetupRouter.ps1` defines the config default as `enabled = $false`. `start-server.ps1` sets `$cmEnabled = $true` before reading the config, meaning anyone who has not run the wizard and has no `llo-config.json` will get the Context Manager started automatically, even though the documented default is off. Furthermore, `main.ps1` sets `context_manager.enabled = false` as the default PowerShell object but `Rust/config.rs` sets `ContextManagerSettings::default()` as `enabled: true`. Three different places, three different defaults.

**Fix:** Pick one canonical default (`false` — opt-in is safer) and enforce it everywhere:

```powershell
# start-server.ps1 — change line:
$cmEnabled = $false   # was $true

if ($config.context_manager) {
    $cmEnabled = [bool]$config.context_manager.enabled
}
```

```rust
// config.rs — ContextManagerSettings::default()
enabled: false,   // was true
```

---

### 1.5 🔴 `proxy.py` imports `config.rs` as a Python module

**File:** `llo-core/context_manager/proxy.py` — graph edge `proxy.py → ui/src-tauri/src/commands/config.rs`

**Problem:** The `graph.json` dependency graph shows an edge `llo-core/context_manager/proxy.py → ui/src-tauri/src/commands/config.rs` with `type: import`. This is a stale/incorrect graph artifact — Python cannot import Rust. However, inspecting the `proxy.py` import block:

```python
try:
    from .config import load_config
    ...
except ImportError:
    from config import load_config   # ← falls back to bare name
```

The bare `from config import load_config` will succeed on a system where any `config.py` is importable from `sys.path`. The `sys.path.insert(0, ...)` hack in the test files makes this even more fragile. If `proxy.py` is ever started from a directory containing an unrelated `config.py`, it silently loads the wrong module.

**Fix:** Always use the relative import, never the bare fallback. Since `proxy.py` is always run as part of the `context_manager` package (via `uvicorn context_manager.proxy:app`), relative imports work:

```python
from .config import load_config
from .preset_reader import read_preset_ctx_limit
from .context_engine import ContextEngine
# Remove the try/except ImportError block entirely
```

Update `StartContextManager.ps1` to launch via the package form so the relative import works:
```powershell
# Change uvicorn invocation from:
"proxy:app"
# To:
"context_manager.proxy:app"
# And set WorkingDirectory to $cmDir's parent (llo-core), not $cmDir itself
```

---

### 1.6 🟠 `preset_reader.py` fallback reads `fit-ctx` instead of `ctx-size` from `[*]` section

**File:** `llo-core/context_manager/preset_reader.py`

**Problem:** When no model-specific section is found, the code falls back to:
```python
if config.has_section("*") and config.has_option("*", "fit-ctx"):
    return config.getint("*", "fit-ctx")
```
`fit-ctx` is the minimum context floor for the `--fit` flag, not the actual context size. The actual key in the `[*]` global section is not `fit-ctx`. Looking at what `SetupRouter.ps1` writes, the `[*]` section never contains a `ctx-size` either (ctx-size is per-model only). So the fallback will always return `65536` regardless, which is at least a safe default, but the `fit-ctx` reference is wrong and misleading.

**Fix:**
```python
# Remove the fit-ctx fallback entirely since [*] has no ctx-size:
# The function already returns 65536 at the end. Just remove the dead branch.

# Before the final `return 65536`:
# (delete the block below)
if config.has_section("*") and config.has_option("*", "fit-ctx"):
    return config.getint("*", "fit-ctx")
```

---

### 1.7 🟠 Idempotency check in `compress()` returns stale session messages without reclamping

**File:** `context_engine.py` — `compress()`

```python
if current_hash == session.last_compress_hash and session.messages:
    return session.messages   # returned without re-clamping
```

**Problem:** `session.messages` was saved at the point of the previous compression. If the caller subsequently passes a different `ctx_limit` (e.g., the preset changed), the stale cached messages are returned unchecked. They may now exceed the new limit.

**Fix:**
```python
if current_hash == session.last_compress_hash and session.messages:
    max_allowed = int((ctx_limit if ctx_limit > 0 else 32768) * 0.85)
    return self._clamp_message_tokens(session.messages, max_allowed, model_alias)
```

---

### 1.8 🟠 Session state is purely in-memory — restarts lose all history

**File:** `context_engine.py` — `ContextEngine.__init__`

**Problem:** `self.sessions: Dict[str, SessionState] = {}` is in-process memory. `_save_checkpoint_to_disk` writes a checkpoint but only saves `summary_block`, `summary_up_to_turn`, `last_compress_hash`, and `message_count`. It does not save `session.messages`. On restart, the engine starts fresh for all sessions. Any in-progress compression state is lost. The next incoming request will re-trigger compression unnecessarily, making a redundant summarizer API call.

**Fix:** In `_save_checkpoint_to_disk`, also serialize `session.messages`. In `get_or_create_session`, attempt to load from disk if the session does not exist in memory:

```python
def get_or_create_session(self, session_id: str) -> SessionState:
    if session_id not in self.sessions:
        loaded = self._load_checkpoint_from_disk(session_id)
        if loaded:
            self.sessions[session_id] = loaded
        else:
            self.sessions[session_id] = SessionState(session_id=session_id)
    return self.sessions[session_id]

def _save_checkpoint_to_disk(self, session: SessionState):
    ...
    data = {
        ...
        "messages": session.messages,   # add this
    }
    ...

def _load_checkpoint_from_disk(self, session_id: str) -> Optional[SessionState]:
    try:
        appdata = os.getenv("APPDATA") or os.getenv("USERPROFILE") or "."
        filepath = os.path.join(appdata, "LLM Manager", "checkpoints", f"{session_id}.json")
        if not os.path.exists(filepath):
            return None
        with open(filepath, "r", encoding="utf-8") as f:
            data = json.load(f)
        s = SessionState(session_id=session_id)
        s.summary_block = data.get("summary_block")
        s.summary_up_to_turn = data.get("summary_up_to_turn", 0)
        s.last_compress_hash = data.get("last_compress_hash", "")
        s.messages = data.get("messages", [])
        return s
    except Exception:
        return None
```

---

### 1.9 🟠 `_clamp_message_tokens` only truncates the first oversized message

**File:** `context_engine.py` — `_clamp_message_tokens()`

**Problem:**
```python
for msg in messages:
    ...
    if isinstance(content, str) and len(content) > 1000 and excess_chars > 0:
        ...
        excess_chars = 0   # ← stops after first truncation
```
After the first long message is truncated, `excess_chars = 0` prevents any further truncation. If the total overflow is spread across multiple messages, or if the first long message is still too large after truncation, the function returns a message list that still exceeds the limit.

**Fix:** Remove the early exit and recalculate per message:
```python
def _clamp_message_tokens(self, messages, max_allowed_tokens, model_alias=""):
    total = self.count_tokens_messages(messages, model_alias)
    if total <= max_allowed_tokens:
        return messages

    clamped = []
    for msg in messages:
        c_msg = dict(msg)
        content = c_msg.get("content")
        if isinstance(content, str):
            current_tokens = self.tokenizer_cache.count_tokens(content, model_alias)
            # Proportion: trim each message by its share of the excess
            excess = total - max_allowed_tokens
            if current_tokens > 0 and excess > 0:
                chars_to_remove = int((current_tokens / total) * excess * 4)
                if chars_to_remove > 0 and len(content) > 500:
                    new_len = max(200, len(content) - chars_to_remove)
                    c_msg["content"] = content[:new_len] + "\n\n[... Truncated by Context Manager ...]"
        clamped.append(c_msg)
    return clamped
```

---

### 1.10 🟠 `summarize_with_model` config field is read but never used

**File:** `context_engine.py`, `config.py`, `proxy.py`

**Problem:** `ContextManagerConfig.summarize_with_model` is defined, saved to config, and surfaced in the UI. But `_request_summary()` always passes `model_alias` (the alias of the *current inference model*) directly to the summarizer payload. The `summarize_with_model = "same"` logic is never evaluated or branched on.

**Fix:** In `proxy.py`, resolve the summarizer model before calling `maybe_compress`, and thread it into the engine:

```python
# In ContextEngine.__init__: add summarize_with_model param
def __init__(self, ..., summarize_with_model: str = "same"):
    self.summarize_with_model = summarize_with_model

# In _request_summary:
effective_model = model_alias
if self.summarize_with_model and self.summarize_with_model != "same":
    effective_model = self.summarize_with_model
if effective_model:
    payload["model"] = effective_model
```

---

### 1.11 🟡 `TokenizerCache.get_repo_for_alias` returns a default Qwen repo for unknown models

**File:** `tokenizer_cache.py` — `get_repo_for_alias()`

**Problem:** If the model alias does not match any key in `ALIAS_TO_HF_REPO`, the function silently returns `Qwen/Qwen2.5-1.5B-Instruct`. This means token counts for a Llama 3.1 70B model are calculated using the Qwen tokenizer, which can be 15–30% off. The error is invisible to the user.

**Fix:** Return `None` for unknowns and let `get_tokenizer` fall through to the character heuristic, which is honest about its approximation:

```python
def get_repo_for_alias(self, model_alias, override_repo=None):
    if override_repo and override_repo.strip():
        return override_repo.strip()
    if not model_alias:
        return None   # was: return "Qwen/..."
    alias_lower = model_alias.lower()
    for key, repo in ALIAS_TO_HF_REPO.items():
        if key in alias_lower:
            return repo
    return None   # was: return "Qwen/..."
```

In `get_tokenizer`: the `if not repo: return None` already handles this correctly once the above change is made.

---

### 1.12 🟡 Tests hard-wire `sys.path` and bypass package import machinery

**Files:** All `tests/*.py`

**Problem:** Every test file does:
```python
sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))
```
This works in isolation but is fragile: it means tests do not run through the package's `__init__.py`, relative imports are bypassed, and `pytest` run from the repo root may pick up a different `context_manager` package if one is installed in `site-packages`.

**Fix:** Add a `pyproject.toml` or `setup.cfg` to `llo-core/` so `pytest` finds the package correctly, and remove the `sys.path.insert` lines:

```toml
# llo-core/pyproject.toml
[tool.pytest.ini_options]
pythonpath = ["."]
testpaths = ["context_manager/tests"]
```

---

### 1.13 🟡 `test_compress.py` wraps async tests in `asyncio.run()` instead of using `pytest-asyncio`

**File:** `llo-core/context_manager/tests/test_compress.py`

**Problem:**
```python
def test_compress_preserves_system_prompt_and_keep_turns():
    async def _test():
        ...
    asyncio.run(_test())
```
The `requirements.txt` already includes `pytest-asyncio`. Tests should use `@pytest.mark.asyncio` and be declared `async def` directly. The current pattern creates a new event loop per test, which breaks when tests share state or when the loop policy differs across platforms.

**Fix:**
```python
import pytest

@pytest.mark.asyncio
async def test_compress_preserves_system_prompt_and_keep_turns():
    engine = ContextEngine(keep_turns=2)
    ...
```

---

## 2. PowerShell Core (`llo-core/`, `script/`, `main.ps1`)

### 2.1 🟠 `start-server.ps1` passes `cache_type_k` directly from config, bypassing `SetupRouter.ps1` derivation

**Files:** `script/start-server.ps1`, `llo-core/SetupRouter.ps1`

**Problem:** `start-server.ps1` runs `SetupRouter.ps1` (which writes a correct `models-preset.ini` with hardware-derived params), but then also explicitly passes `--cache-type-k` from `$config.cache_type_k` on the command line:

```powershell
if ($config.cache_type_k) {
    $serverArgs += @("--cache-type-k", "$($config.cache_type_k)")
    ...
```

These values come from what the wizard wrote during setup (which may be old or from a different hardware tier). The CLI flags passed directly to `llama-server` override the preset file. So the hardware-adaptive derivation in `SetupRouter.ps1` is silently defeated by whatever the wizard last wrote into `llo-config.json`. The two sources conflict on every server start.

**Fix:** Remove the explicit `--cache-type-k`, `--cache-type-v`, `--ubatch-size`, `--spec-type`, `--flash-attn`, `--parallel`, `--threads` overrides from `start-server.ps1`. The preset file (`models-preset.ini`) already contains the correct values and is passed via `--models-preset`. Only pass flags that are not expressed in the preset (port, host, log redirection, model path):

```powershell
# Remove these blocks from start-server.ps1:
# if ($config.cache_type_k) { $serverArgs += ... }
# if ($config.ubatch_size ...) { $serverArgs += ... }
# if ($config.spec_type ...) { $serverArgs += ... }
# if ($config.flash_attn ...) { $serverArgs += ... }
# if ($config.parallel_slots ...) { $serverArgs += ... }
# if ($config.threads ...) { $serverArgs += ... }
```

---

### 2.2 🟠 `main.ps1` Step 2.2 re-computes hardware parameters using its own logic that differs from `SetupRouter.ps1`

**File:** `main.ps1` — Step 2.2

**Problem:** The wizard has its own `$cacheType`, `$ubatchSize`, `$parallelSlots` derivation logic that produces different thresholds and values than `SetupRouter.ps1`'s `Get-InferenceParams`. For example:

- `main.ps1`: cache type `q4_0` if VRAM < 6 GB
- `SetupRouter.ps1` tier `low` (2–4 GB): `q8_0`

These then get saved to `llo-config.json` and `start-server.ps1` reads them back, defeating the hardware-adaptive logic. The wizard's manually computed values permanently override the adaptive router.

**Fix:** The wizard should not compute inference parameters at all. After setup is confirmed, call `SetupRouter.ps1` (as it already does) and let that be the single source of truth. Remove the entire Step 2.2 block from `main.ps1` — the variables it sets (`$flashAttn`, `$cacheType`, `$ubatchSize`, `$parallelSlots`) should not be written to config. Only non-hardware keys (paths, integrations, idle_timeout, context_manager settings) belong in `llo-config.json`.

---

### 2.3 🟠 `Get-SafeContextSize` snaps to powers of two using `[math]::Pow(2, exponent)` which returns a float

**File:** `llo-core/SetupRouter.ps1` — `Get-SafeContextSize()`

```powershell
$exponent = [math]::Floor([math]::Log($rawCtx) / [math]::Log(2))
$chosen = [math]::Pow(2, $exponent)   # returns [double], e.g. 32768.0
```

**Problem:** `[math]::Pow` returns `[double]`. When written to the preset as `ctx-size = 32768.0`, llama-server may reject it or behave unexpectedly depending on its INI parser. The value should be an integer.

**Fix:**
```powershell
$chosen = [int][math]::Pow(2, $exponent)
```

---

### 2.4 🟠 `Normalize-ModelAlias` strips `q4`, `q5`, `q8` tokens but not `q4_k`, `q5_k`, `q6_k`, `q8_k`, `iq4` etc.

**File:** `llo-core/SetupRouter.ps1` — `Find-MatchingTemplate()`

**Problem:** The token filter list used for template matching:
```powershell
$_ -ne 'q4' -and $_ -ne 'q5' -and $_ -ne 'q8' -and $_ -ne 'k' -and $_ -ne 'm' -and $_ -ne 's' -and $_ -ne 'l'
```
Modern GGUF quantization names like `Q4_K_M`, `Q5_K_S`, `IQ4_XS`, `Q6_K` produce tokens like `q4`, `k`, `m` which are correctly filtered, but `iq4`, `xs`, `nl`, `q6` are not. This causes false-positive template matches (e.g., `iq4` matches a template containing `iq`).

**Fix:** Expand the exclude set:
```powershell
$skipTokens = @('q4','q5','q6','q8','iq2','iq3','iq4','iq5','iq6','k','m','s','l','xs','nl','gguf','0','1','2')
$aliasTokens = $normalizedAlias -split '-' | Where-Object {
    $_.Length -gt 2 -and $_ -notmatch '^\d+$' -and $skipTokens -notcontains $_
}
```

---

### 2.5 🟠 `stop-server.ps1` attempts to filter by `$_.CommandLine` on Linux which requires root

**File:** `script/stop-server.ps1`

**Problem:**
```powershell
$cmProcs = @(Get-Process | Where-Object { $_.CommandLine -match 'proxy:app' } ...)
```
On Linux, `Get-Process` does not expose `CommandLine` without root. This always returns empty, silently failing to stop the context manager proxy.

**Fix:** Store the context manager's PID to a lockfile when it starts, and read that on stop:

```powershell
# In StartContextManager.ps1, after launch:
$pidFile = Join-Path $userAppDir "context-manager.pid"
Set-Content -Path $pidFile -Value $proc.Id -Encoding UTF8

# In stop-server.ps1:
$pidFile = Join-Path $userAppDir "context-manager.pid"
if (Test-Path $pidFile) {
    $cmPid = [int](Get-Content $pidFile -Raw)
    try { Stop-Process -Id $cmPid -Force -ErrorAction SilentlyContinue } catch {}
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}
```

---

### 2.6 🟠 Port auto-shift in `start-server.ps1` updates `settings.json` but not `llo-config.json` or the Context Manager config

**File:** `script/start-server.ps1`

**Problem:** When `$Port` is shifted due to a conflict, the code updates `.vscode/settings.json` but does not update:
- `llo-config.json` (so next startup still tries the old port)
- The Context Manager proxy upstream URL (`context_manager.llama_server_url`)
- The Tauri UI's `serverStore.port`

The UI will show the wrong port and Claude Code will point at the old port.

**Fix:** After the port shift, write the new port back to `llo-config.json`:
```powershell
if ($Port -ne 8080) {
    try {
        $cfgJson = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        $cfgJson.port = $Port
        if ($cfgJson.context_manager) {
            $cfgJson.context_manager.llama_server_url = "http://127.0.0.1:$Port"
        }
        $cfgJson | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigFile -Encoding UTF8
    } catch {}
}
```

---

### 2.7 🟡 `Map-LegacyConfigKeyToOverride` is defined but never called

**File:** `llo-core/SetupRouter.ps1`

**Problem:** The function `Map-LegacyConfigKeyToOverride` is defined around line 118 but has zero call sites anywhere in the file. It is dead code.

**Fix:** Either call it for the known legacy keys or remove it:
```powershell
# Remove:
function Map-LegacyConfigKeyToOverride { ... }
```

---

### 2.8 🟡 `FetchAssets.ps1` is dot-sourced in `main.ps1` but never in `SetupRouter.ps1` or `start-server.ps1`

**File:** `main.ps1`, `llo-core/SetupRouter.ps1`

**Problem:** Template/grammar asset syncing only happens during the interactive wizard. If `start-server.ps1` is called directly (e.g., from Tauri, from VSCode task, or from the shell), templates and grammars are never refreshed. This means a user who never re-runs the wizard will have stale or missing templates.

**Fix:** Call `Sync-GitHubFolder` from `SetupRouter.ps1` (or `start-server.ps1`) with a `MaxAge` guard so it only fetches when the manifest is older than 24 hours, preventing slow fetches on every server start.

---

### 2.9 🔵 Config path resolution is copy-pasted across 5 scripts

**Files:** `main.ps1`, `llo-core/SetupRouter.ps1`, `script/start-server.ps1`, `script/stop-server.ps1`, `script/StartContextManager.ps1`, `llo-core/GitDiff.ps1`, `llo-core/ParseHelp.ps1`

**Problem:** The pattern:
```powershell
$appDataConfig = if ($env:APPDATA) {
    Join-Path $env:APPDATA "LLM Manager\llo-config.json"
} elseif ($env:USERPROFILE) { ... } elseif ($env:HOME) { ... } else { $null }
```
appears identically in seven files. Any change to the directory name or structure requires updating all seven.

**Fix:** Extract to a shared helper module `llo-core/Paths.ps1`:
```powershell
function Get-LLMManagerConfigPath {
    $base = if ($env:APPDATA) { $env:APPDATA }
            elseif ($env:USERPROFILE) { Join-Path $env:USERPROFILE ".config" }
            elseif ($env:HOME) { $env:HOME + "/.config" }
            else { $null }
    if ($base) { return Join-Path $base "LLM Manager\llo-config.json" }
    return $null
}
```
Then dot-source `Paths.ps1` and call the function.

---

## 3. Tauri UI / Rust Backend (`ui/`)

### 3.1 🔴 `start_server` emits `"running"` status before the script succeeds

**File:** `ui/src-tauri/src/commands/server.rs` — `start_server()`

**Problem:**
```rust
IS_RUNNING.store(true, Ordering::SeqCst);
let _ = app.emit("server-status-changed", "running");  // ← emitted immediately
// ... then spawns blocking task that may fail
```
The UI shows "running" the moment the user clicks Launch. If `start-server.ps1` fails (wrong llama path, port conflict, etc.), `IS_RUNNING` is set back to `false` and `"stopped"` is emitted — but by then the user already saw a flash of "running" and the status text reverts. More importantly, there is a race: if the user clicks "Stop" during the startup window, `stop_server` sets `IS_RUNNING=false`, then the blocking task finishes successfully and no one emits `"stopped"` again, leaving the server actually running but the UI showing stopped.

**Fix:** Do not emit `"running"` until `start-server.ps1` exits successfully. Use a channel or a callback from the blocking task:

```rust
tokio::task::spawn_blocking(move || {
    let result = run_powershell_script("script/start-server.ps1", &[...]);
    match result {
        Ok(_) => {
            IS_RUNNING.store(true, Ordering::SeqCst);
            let _ = app_err.emit("server-status-changed", "running");
        }
        Err(e) => {
            IS_RUNNING.store(false, Ordering::SeqCst);
            let _ = app_err.emit("server-status-changed", "stopped");
            let _ = app_err.emit("server-log", serde_json::json!({...}));
        }
    }
});
// Do NOT emit "running" here
Ok("Server launch initiated".to_string())
```

---

### 3.2 🔴 `IS_RUNNING` is a global `AtomicBool` — multiple simultaneous starts corrupt state

**File:** `ui/src-tauri/src/commands/server.rs`

**Problem:** `IS_RUNNING` is a process-level `static AtomicBool`. If the user clicks "Launch" twice quickly (or the UI re-calls `start_server` on reconnect), two blocking tasks run simultaneously, both reading the same flag. The log tailers also read the same flag and will exit when either task sets it to `false`.

**Fix:** Use a `Mutex<Option<JoinHandle<...>>>` in Tauri's managed state to track a single active server process handle. On a second `start_server` call, return an error or no-op if already running.

---

### 3.3 🟠 `serverStore.ts` seeds `logs` with fake startup messages

**File:** `ui/src/store/serverStore.ts`

```typescript
logs: [
    { timestamp: '14:32:01', level: 'INFO', message: 'LLM Manager server state initialized' },
    { timestamp: '14:32:02', level: 'INFO', message: 'Ready to launch server process' }
],
```

**Problem:** These hardcoded log entries with a fixed timestamp of `14:32:01` appear every time the app loads, regardless of whether the server was ever started. They look like real logs but are synthetic and mislead users into thinking the server has been running since 2:32 PM. When real logs arrive, they are appended after these stale entries.

**Fix:**
```typescript
logs: [],  // start empty; add a real timestamped entry on first start event
```

---

### 3.4 🟠 `hardwareStore.ts` fetches hardware on `fetchHardware()` call but the Overview page calls it inside `useEffect` with `[fetchHardware]` as a dependency — infinite loop risk

**File:** `ui/src/pages/Overview.tsx`, `ui/src/store/hardwareStore.ts`

**Problem:**
```typescript
// Overview.tsx
useEffect(() => {
    fetchHardware();
}, [fetchHardware]);
```
`fetchHardware` is created with `create<HardwareState>((set) => ({ fetchHardware: async () => { ... } }))`. In Zustand, the store action reference is stable across renders, so this effect does not actually create an infinite loop. However, the dependency array is semantically incorrect — `fetchHardware` never changes, so the `useEffect` only runs once anyway. This confuses readers into thinking re-fetches are triggered by something.

**Fix:** Use an empty dependency array and call `fetchHardware()` explicitly:
```typescript
useEffect(() => {
    fetchHardware();
}, []); // eslint-disable-line react-hooks/exhaustive-deps
```

---

### 3.5 🟠 `config.rs` default `spec_type` is `"ngram-simple"` but `SetupRouter.ps1` defaults to `"none"`

**File:** `ui/src-tauri/src/commands/config.rs`

**Problem:**
```rust
fn default_spec_type() -> String { "ngram-simple".to_string() }
```
`SetupRouter.ps1` and `main.ps1` both default spec_type to `"none"`. When a new user launches the Tauri app without a config file, `AppConfig::default()` writes `"ngram-simple"` to the new config. On a CPU-only machine or a low-VRAM GPU, `SetupRouter.ps1` would then detect the low-VRAM tier and enforce `spec_type = "none"` — but the explicit CLI override from `start-server.ps1` (issue 2.1) passes `--spec-type ngram-simple` anyway. The safest and most consistent default is `"none"`.

**Fix:**
```rust
fn default_spec_type() -> String { "none".to_string() }
```

---

### 3.6 🟠 `validation.ts` uses hardcoded `blockCount = 32` in KV cache math for all models

**File:** `ui/src/lib/validation.ts` — `calculateKvCacheGb()`

```typescript
export function calculateKvCacheGb(
  ctxTokens: number,
  blockCount: number = 32,   // ← hardcoded default
  ...
```

**Problem:** Callers in `validateConfiguration` and `validateModelLaunch` pass no `blockCount`. A 7B model has 32 layers (correct), a 13B has 40, a 70B has 80, a Qwen2.5-72B has 80. Using 32 for a 70B model underestimates KV cache by 60%, so the pre-flight check passes when it should warn.

**Fix:** Derive `blockCount` from model file size. If the `ModelInfo` struct carries `fileSizeGb`, use a lookup table:
```typescript
function estimateBlockCount(fileSizeGb: number): number {
    if (fileSizeGb < 3)   return 22;   // ~1B
    if (fileSizeGb < 6)   return 32;   // 3B–7B
    if (fileSizeGb < 12)  return 40;   // 8B–13B
    if (fileSizeGb < 25)  return 60;   // 14B–30B
    return 80;                          // 32B+
}
```
Pass this to `calculateKvCacheGb` in both callers.

---

### 3.7 🟡 `Overview.tsx` calls `invoke('get_active_model_info')` with an empty dependency array, never refreshing after server restart

**File:** `ui/src/pages/Overview.tsx`

```typescript
useEffect(() => {
    invoke('get_active_model_info')
        .then((result) => setBackendModelInfo(...))
        ...
}, []);   // never re-runs
```

**Problem:** After stopping and restarting the server with a different model, `backendModelInfo` still shows the previous model.

**Fix:** Add `status` from `useServerStore` as a dependency:
```typescript
const { status, port, logs, clearLogs } = useServerStore();
...
useEffect(() => {
    if (status === 'running') {
        invoke('get_active_model_info').then(...).catch(...);
    }
}, [status]);
```

---

### 3.8 🟡 `Overview.tsx` renders `assessments.map((a, i) => <ImpactBanner key={i} .../>)` using array index as key

**File:** `ui/src/pages/Overview.tsx`

**Problem:** Using array index as React `key` causes unnecessary re-renders and animation glitches when assessments are added/removed. Each `ImpactBanner` should be keyed by a stable ID derived from the assessment content.

**Fix:**
```typescript
{assessments.map((a) => (
    <ImpactBanner key={`${a.param}-${a.severity}`} assessment={a} />
))}
```

---

### 3.9 🟡 `serverStore.ts` logs are sliced to 5000 in `addLog` but displayed sliced to 100 in `Overview.tsx`

**Files:** `ui/src/store/serverStore.ts`, `ui/src/pages/Overview.tsx`

**Problem:** The store keeps up to 5000 log entries. The Overview page slices to 100. The Logs page presumably shows more, but the slice is done inside the component, not the store. This means 4900 entries accumulate in RAM but are never visible anywhere.

**Fix:** Decide on one limit. If the UI never shows more than 200 at once, keep 200 in the store and remove the in-component slice:
```typescript
// serverStore.ts
addLog: (log) => set((state) => ({ logs: [...state.logs.slice(-199), log] })),
```

---

### 3.10 🔵 Duplicate `scripts.rs` files

**Files:** `ui/src-tauri/src/scripts.rs`, `ui-src-tauri/src/scripts.rs`

**Problem:** There are two copies of `scripts.rs`: one at `ui/src-tauri/src/scripts.rs` (inside the Cargo workspace, compiled) and one at `ui-src-tauri/src/scripts.rs` (outside, not compiled). The outer one appears to be a leftover from a refactor and is never referenced by `Cargo.toml`.

**Fix:** Delete `ui-src-tauri/src/scripts.rs` and the `ui-src-tauri/` directory if it contains no other active files.

---

## 4. Architecture Issues

### 4.1 🟠 Two parallel parameter authority systems exist simultaneously and fight each other

**Files:** `llo-config.json` (flat keys), `llo-config.json` (`overrides` block), `models-preset.ini`, CLI args in `start-server.ps1`

**Problem:** Inference parameters are authored in four places:
1. Flat keys in `llo-config.json` (written by wizard and Tauri UI)
2. `overrides` block in `llo-config.json` (written by Tauri UI performance sliders)
3. `models-preset.ini` (written by `SetupRouter.ps1` from hardware profile + overrides)
4. CLI args passed directly by `start-server.ps1`

Priority is documented as "overrides > hardware-derived", but `start-server.ps1` passes flat config keys as CLI args which override the preset entirely. The architecture makes it impossible to reason about what value is actually active without tracing all four sources.

**Fix:** Define a single authority chain:
- `models-preset.ini` is the **only** source of inference params for `llama-server`
- `start-server.ps1` passes only `--models-preset`, `--host`, `--port`
- `SetupRouter.ps1` reads `overrides` from config and applies them inside the preset generation
- Remove all inference param keys from the flat `llo-config.json` top level (keep only non-inference keys: paths, integrations, idle_timeout, fallback_provider, context_manager)

---

### 4.2 🟡 `run-setup.sh` and `start-server.sh` require `pwsh` but there is no install check or guidance for Linux users installing via `apt` vs `snap`

**File:** `run-setup.sh`, `script/start-server.sh`

**Problem:** Both scripts check `command -v pwsh` and exit with a generic install guide. On Ubuntu, `snap install powershell` installs `pwsh` to `/snap/bin/pwsh` which is only in PATH for interactive shells, not non-login shells or cron. The `apt` method (`sudo apt install powershell`) installs to `/usr/bin/pwsh`. Many users will install via snap, run the script from a non-interactive context, and see `command not found`.

**Fix:** Extend the check:
```bash
for candidate in /usr/bin/pwsh /snap/bin/pwsh /usr/local/bin/pwsh; do
    if [ -x "$candidate" ]; then
        exec "$candidate" -File ...
    fi
done
echo "[ERROR] pwsh not found. Install: sudo apt install powershell"
exit 1
```

---

### 4.3 🟡 Context Manager is launched inside `start-server.ps1` before the `llama-server` is ready

**File:** `script/start-server.ps1`

**Problem:**
```powershell
# 3.5 Auto-start Context Manager Proxy if enabled
if ($cmEnabled) {
    & $cmScript -Port $cmPort -ConfigFile $ConfigFile   # ← launched here
}
...
# then llama-server is started and we wait 30s for it to be ready
```
The Context Manager starts before llama-server. Its `config.llama_server_url` points at the local llama-server. Any request that arrives at the proxy in the startup window will immediately fail with a connection refused to the upstream, producing confusing errors and triggering compression logic against a dead server.

**Fix:** Start the Context Manager after the 30-second readiness poll confirms llama-server is live:
```powershell
# Move the $cmEnabled block to AFTER the $ready check
if ($ready -and $cmEnabled) {
    & $cmScript -Port $cmPort -ConfigFile $ConfigFile
}
```

---

### 4.4 🟡 No mechanism to reload config without restarting the server

**Design issue across all components**

**Problem:** The entire config is loaded once at server start. Changes made via the Tauri UI (Settings page saves to `llo-config.json`) are not reflected in a running server. The only way to apply new settings is to stop and restart. The UI does not warn the user that a restart is required after saving.

**Fix (minimal):** In `Overview.tsx`, after `saveConfig()` succeeds and `status === 'running'`, show a warning badge:
```typescript
const [pendingRestart, setPendingRestart] = useState(false);

const handleSave = async () => {
    await saveConfig();
    if (status === 'running') setPendingRestart(true);
};
```
Show a persistent banner: *"Configuration saved. Restart the server to apply changes."*

---

## 5. Security / Correctness

### 5.1 🔴 `launch_claude_terminal` in `server.rs` injects model name directly into a shell command string

**File:** `ui/src-tauri/src/commands/server.rs` — `launch_claude_terminal()`

**Problem:**
```rust
let script = format!(
    "...; claude --model {}",
    m   // ← m comes from UI/config, no sanitization
);
command.arg("-Command").arg(&script);
```
If `model` contains spaces, semicolons, backticks, or other shell metacharacters, the resulting PowerShell string is syntactically broken. A model name like `my-model; rm -rf /` would execute arbitrary commands.

**Fix:** Pass `model` as a separate PowerShell variable, never interpolated into the command string:
```rust
let script = format!(
    "$env:ANTHROPIC_BASE_URL='{}'; $env:ANTHROPIC_AUTH_TOKEN='local'; \
     $env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1'; \
     $env:CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY='1'; \
     claude --model $model",
    base_url
);
command.arg("-Command").arg(&script).arg("-").arg(&m);
// Or better: pass as named variable
let script = "$m=$args[0]; claude --model $m";
command.arg("-Command").arg(script).arg("--").arg(&m);
```

---

### 5.2 🟠 `_save_checkpoint_to_disk` uses `os.getenv("APPDATA") or os.getenv("USERPROFILE") or "."` — falls back to process CWD

**File:** `context_engine.py`

**Problem:** On Linux/macOS, `APPDATA` is not set. The fallback chain reaches `"."` (the current working directory), which is wherever uvicorn was launched from — likely `llo-core/context_manager/`. Checkpoint files will be written to the working directory alongside source code, and will be committed to git if the developer forgets to run `.gitignore`.

**Fix:** Match the logic in `config.py` which correctly handles Linux/macOS:
```python
appdata = os.getenv("APPDATA") or \
          (os.path.join(os.getenv("USERPROFILE", ""), ".config") if os.getenv("USERPROFILE") else None) or \
          (os.path.join(os.getenv("HOME", ""), ".config") if os.getenv("HOME") else None) or \
          "."
```

---

## 6. Summary Table

| # | Severity | File(s) | Description |
|---|----------|---------|-------------|
| 1.1 | 🔴 CRITICAL | `proxy.py` | Streaming httpx client never closed → FD leak/crash |
| 1.3 | 🔴 CRITICAL | `context_engine.py` | `_get_ctx_limit_from_messages` hardcoded to 32768 |
| 1.4 | 🔴 CRITICAL | `SetupRouter.ps1`, `start-server.ps1`, `config.rs` | Three conflicting defaults for `context_manager.enabled` |
| 1.5 | 🔴 CRITICAL | `proxy.py` | Bare `from config import` can import wrong module |
| 3.1 | 🔴 CRITICAL | `server.rs` | Status emitted "running" before script succeeds |
| 3.2 | 🔴 CRITICAL | `server.rs` | Global AtomicBool breaks on concurrent start calls |
| 5.1 | 🔴 CRITICAL | `server.rs` | Model name injected unsanitised into shell command |
| 1.6 | 🟠 BUG | `preset_reader.py` | Reads `fit-ctx` instead of `ctx-size` as fallback |
| 1.7 | 🟠 BUG | `context_engine.py` | Idempotency path returns unclamped stale messages |
| 1.8 | 🟠 BUG | `context_engine.py` | Sessions lost on restart; no checkpoint reload |
| 1.9 | 🟠 BUG | `context_engine.py` | `_clamp_message_tokens` stops after first truncation |
| 1.10 | 🟠 BUG | `context_engine.py`, `proxy.py` | `summarize_with_model` field never used |
| 1.11 | 🟠 BUG | `tokenizer_cache.py` | Unknown model gets wrong Qwen tokenizer silently |
| 2.1 | 🟠 BUG | `start-server.ps1` | CLI flags override preset, defeating adaptive router |
| 2.2 | 🟠 BUG | `main.ps1` | Wizard computes different params than SetupRouter |
| 2.3 | 🟠 BUG | `SetupRouter.ps1` | Context size written as float (e.g. 32768.0) |
| 2.5 | 🟠 BUG | `stop-server.ps1` | Context Manager not stopped on Linux (no root) |
| 2.6 | 🟠 BUG | `start-server.ps1` | Port shift not propagated to config or CM URL |
| 3.3 | 🟠 BUG | `serverStore.ts` | Hardcoded fake log entries with fixed timestamp |
| 3.5 | 🟠 BUG | `config.rs` | Default `spec_type = "ngram-simple"` contradicts PS1 default |
| 3.6 | 🟠 BUG | `validation.ts` | KV cache math uses hardcoded 32 layers for all models |
| 3.7 | 🟠 BUG | `Overview.tsx` | Active model info never refreshes after server restart |
| 5.2 | 🟠 BUG | `context_engine.py` | Checkpoint path falls back to CWD on Linux |
| 1.12 | 🟡 DESIGN | `tests/*.py` | sys.path hacks bypass package import machinery |
| 1.13 | 🟡 DESIGN | `test_compress.py` | asyncio.run wrapping instead of pytest-asyncio |
| 2.4 | 🟡 DESIGN | `SetupRouter.ps1` | Template token filter misses modern quant suffixes |
| 2.7 | 🟡 DESIGN | `SetupRouter.ps1` | `Map-LegacyConfigKeyToOverride` defined, never called |
| 2.8 | 🟡 DESIGN | `main.ps1` | Template sync only runs in wizard, not on server start |
| 2.9 | 🟡 DESIGN | 7 files | Config path resolution copy-pasted across scripts |
| 3.4 | 🟡 DESIGN | `Overview.tsx` | useEffect dependency array semantically wrong |
| 3.8 | 🟡 DESIGN | `Overview.tsx` | Array index used as React key |
| 3.9 | 🟡 DESIGN | `serverStore.ts` | 5000-entry log buffer never visible in UI |
| 3.10 | 🔵 QUALITY | `ui-src-tauri/` | Duplicate `scripts.rs` outside Cargo workspace |
| 4.1 | 🟡 DESIGN | Architecture | Four conflicting parameter authority systems |
| 4.2 | 🟡 DESIGN | `*.sh` | pwsh snap install not in PATH for non-interactive shells |
| 4.3 | 🟡 DESIGN | `start-server.ps1` | Context Manager started before llama-server is ready |
| 4.4 | 🟡 DESIGN | Architecture | No indication in UI that restart is required after config save |
