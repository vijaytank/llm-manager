# LLM Manager — Issue Report v3
**Repo:** `vijaytank/llm-manager` · **Branch:** `develop` · **Commit:** `29697f7` · **Date:** 2026-08-13

Severity: 🔴 CRITICAL · 🟠 BUG · 🟡 DESIGN · 🔵 QUALITY  
Each issue: what it is, where exactly, why it's wrong, precise fix.

---

## BATCH 1 — Python Context Manager

### B1-01 🔴 `context_engine.py` has TWO definitions of `_save_checkpoint_to_disk` and TWO of `maybe_compress` — second silently overwrites first

**File:** `llo-core/context_manager/context_engine.py`

The class body defines both methods twice. Python resolves the last definition at class creation time. The first `_save_checkpoint_to_disk` (line ~230) saves `message_count` but not `messages`. The second (line ~300) saves `messages`. The first `maybe_compress` (line ~240) acquires `session.lock`. The second (line ~310) has **no lock**. The lock-free version wins at runtime.

**Impact of the missing lock:** If two concurrent requests arrive for the same `session_id` — very common in Claude Code which sends parallel tool-result messages — both calls pass the `needs_compression` check simultaneously, both call `compress()`, both call `_request_summary()` (a slow HTTP call to llama-server), and both overwrite `session.messages`. The second write wins, losing the first summary. The session ends up with a corrupted, non-idempotent state.

**Fix:** Remove the duplicate definitions. Keep the second `_save_checkpoint_to_disk` (saves `messages`) and the first `maybe_compress` (has `session.lock`):

```python
# KEEP: first maybe_compress with lock (line ~240)
async def maybe_compress(self, session_id, messages, max_tokens_requested, ctx_limit, model_alias=""):
    session = self.get_or_create_session(session_id)
    async with session.lock:
        if not self.needs_compression(...):
            return messages
        return await self.compress(...)

# KEEP: second _save_checkpoint_to_disk (saves messages)
def _save_checkpoint_to_disk(self, session):
    data = { ..., "messages": session.messages }
    ...

# DELETE the other two copies of each
```

---

### B1-02 🔴 `proxy.py` module-level `config` and `engine` are instantiated at import time in parallel with the `lifespan` versions — the `get_config`/`get_engine` fallback makes both live simultaneously

**File:** `llo-core/context_manager/proxy.py` lines 15–21

```python
config = load_config()    # ← runs at import, reads llo-config.json
engine = ContextEngine(...)   # ← separate ContextEngine instance with own session dict

@asynccontextmanager
async def lifespan(app: FastAPI):
    cfg = load_config()   # ← second load, second ContextEngine instance
    eng = ContextEngine(...)
    app.state.config = cfg
    app.state.engine = eng
```

`get_config()` and `get_engine()` return `app.state.*` when inside a request (correct), but fall back to the module-level globals otherwise. This means:
- The module-level `engine` has its own `sessions` dict separate from `app.state.engine.sessions`
- If `get_engine(request)` is called before `app.state` is ready (e.g., during startup or testing), it returns the stale module-level instance
- The test `test_session_id.py` imports `from context_manager.proxy import extract_session_id` which triggers the module-level `load_config()` and `ContextEngine()` at import — if `llo-config.json` is missing this logs silent errors on every test run

**Fix:** Remove the module-level `config` and `engine` entirely. Make `get_config`/`get_engine` raise a clear error if called outside a request context, or accept default values:

```python
# Delete lines 15–21 entirely

def get_config(request: Optional[Request] = None) -> ContextManagerConfig:
    if request and hasattr(request.app.state, "config"):
        return request.app.state.config
    raise RuntimeError("Config not initialized — proxy called outside request context")

def get_engine(request: Optional[Request] = None) -> ContextEngine:
    if request and hasattr(request.app.state, "engine"):
        return request.app.state.engine
    raise RuntimeError("Engine not initialized — proxy called outside request context")
```

For tests that import individual functions (like `extract_session_id`), those functions don't use `config` or `engine`, so the import will work without triggering initialization.

---

### B1-03 🔴 `get_http_client` fallback creates a bare `httpx.AsyncClient` with no lifecycle management

**File:** `llo-core/context_manager/proxy.py` lines 56–59

```python
def get_http_client(request: Optional[Request] = None) -> httpx.AsyncClient:
    if request and hasattr(request.app.state, "http_client"):
        return request.app.state.http_client
    return httpx.AsyncClient(timeout=600.0)   # ← new client, never closed
```

When `request.app.state` doesn't have `http_client` (startup race, unit test, or the module-level fallback path), a new `AsyncClient` is created per call. `is_owned_client = not hasattr(request.app.state, "http_client")` is `True`, so the downstream code does call `await client.aclose()` — but only on the happy path. If `client.send()` raises, the `except Exception` block calls `aclose()` too — so this is actually handled correctly.

**Actual issue:** The fallback client is created with no `limits` set (`max_connections` defaults to 100, `max_keepalive_connections` to 20 per httpx defaults) which differs from the lifespan client that sets these explicitly. Minor inconsistency. More important: if the lifespan hasn't run yet (test environment), `request.app.state` has no `http_client` and every request creates a new client. The `is_owned_client` flag handles cleanup, so no leak, but the connection pool is never reused, hurting performance.

**Fix:** Raise clearly if called outside lifespan instead of silently creating a disposable client:
```python
def get_http_client(request: Optional[Request] = None) -> httpx.AsyncClient:
    if request and hasattr(request.app.state, "http_client"):
        return request.app.state.http_client
    raise RuntimeError("HTTP client not initialized — ensure lifespan is running")
```

---

### B1-04 🟠 `proxy.py` `is_anthropic_messages` detection matches any path ending in `messages` — catches `/v1/threads/messages`, `/some/messages`, etc.

**File:** `llo-core/context_manager/proxy.py` line 461

```python
is_anthropic_messages = clean_path.startswith("v1/messages") or clean_path.endswith("messages")
```

`clean_path.endswith("messages")` matches any path ending in `messages`. This includes `/v1/threads/{id}/messages` (OpenAI Assistants API), `/admin/messages`, or any future llama-server endpoint that ends in `messages`. These paths would then have their body rewritten as Anthropic requests and forwarded to `/v1/chat/completions`, producing garbled requests.

**Fix:** Be explicit:
```python
is_anthropic_messages = (
    clean_path == "v1/messages" or
    clean_path.startswith("v1/messages?") or
    clean_path.startswith("v1/messages/")
)
```

---

### B1-05 🟠 `proxy.py` `is_openai_chat` also matches `/v1/completions` (legacy non-chat endpoint) and runs compression on it

**File:** `llo-core/context_manager/proxy.py` line 462

```python
is_openai_chat = clean_path.endswith("chat/completions") or clean_path.endswith("completions")
```

`clean_path.endswith("completions")` matches `/v1/completions` (legacy text completions, not chat). That endpoint takes a `prompt` string, not a `messages` array. The proxy then calls `body.get("messages", [])` which returns `[]`, runs compression on an empty list, then sends a `{"messages": [], ...}` body to `/v1/completions` instead of the original `{"prompt": "..."}` body. The request is silently corrupted.

**Fix:**
```python
is_openai_chat = clean_path.endswith("chat/completions")
```

---

### B1-06 🟠 `compress()` skips compression when `conversation_turns <= effective_keep` but still clamps — can return messages shorter than the system needs

**File:** `llo-core/context_manager/context_engine.py` — `compress()`

```python
if len(conversation_turns) <= effective_keep:
    max_allowed = int((ctx_limit if ctx_limit > 0 else 32768) * 0.85)
    return self._clamp_message_tokens(messages, max_allowed, model_alias)
```

If `keep_turns=6` and there are 6 conversation turns, `effective_keep` becomes 5 (from the earlier `effective_keep = max(1, len(conversation_turns) - 1)` adjustment). Then `len(conversation_turns) <= effective_keep` is `6 <= 5` = False. So compression runs when it shouldn't (only 6 turns, nothing to summarize yet). `split_idx = 6 - 5 = 1`, so it summarizes the very first turn into a summary, and `delta_turns = [turn[0]]` — just one message gets summarized, wasting a llama-server call for minimal benefit.

The `effective_keep` adjustment intended to prevent summarizing the last turn when there are exactly as many turns as `keep_turns`. But the logic misfires for counts just above `keep_turns`.

**Fix:** Simplify the guard:
```python
# Remove the effective_keep adjustment block entirely
if len(conversation_turns) <= self.keep_turns:
    max_allowed = int((ctx_limit if ctx_limit > 0 else 32768) * 0.85)
    return self._clamp_message_tokens(messages, max_allowed, model_alias)
split_idx = len(conversation_turns) - self.keep_turns
```

---

### B1-07 🟠 `tokenizer_cache.py` maps `claude`, `gpt`, `openai` aliases to Qwen tokenizer — used by summarizer when model is a cloud alias

**File:** `llo-core/context_manager/tokenizer_cache.py`

```python
"claude": "Qwen/Qwen2.5-1.5B-Instruct",
"gpt": "Qwen/Qwen2.5-1.5B-Instruct",
"openai": "Qwen/Qwen2.5-1.5B-Instruct",
```

When `summarize_with_model = "same"` and the user is using Claude Code (model alias `claude-sonnet-4-6`), the engine skips passing a model to the summarizer payload (correct) but `count_tokens` is called with `model_alias = "claude-sonnet-4-6"` which matches `"claude"` in the alias lookup and returns the Qwen tokenizer. Qwen and Claude use different tokenization — the count will be ~10–15% off, causing the compression threshold to fire too early or too late.

**Fix:** Remove the cloud model aliases from `ALIAS_TO_HF_REPO`. For these models the character heuristic (`len // 4`) is more honest than a mismatched tokenizer:
```python
# Remove these three entries:
"claude": ...,
"gpt": ...,
"openai": ...,
```

---

### B1-08 🟠 `preset_reader.py` hardcodes `o1` and `o3` to 128000 tokens — `o3` has a 200k context

**File:** `llo-core/context_manager/preset_reader.py`

```python
if "gpt-4" in alias_lower or "gpt4" in alias_lower or "o1" in alias_lower or "o3" in alias_lower:
    return 128000
```

`o3` (released 2025) has a 200k context window, same as Claude. Returning 128k causes compression to fire ~37% earlier than needed, generating unnecessary summarizer calls and truncating valid context.

**Fix:**
```python
if "o3" in alias_lower or "o4" in alias_lower:
    return 200000
if "gpt-4" in alias_lower or "gpt4" in alias_lower or "o1" in alias_lower:
    return 128000
```

---

### B1-09 🟠 `test_needs_compression.py`, `test_token_counting.py`, `test_preset_reader.py` still use `sys.path.insert` — breaks under `uv run pytest`

**Files:** `llo-core/context_manager/tests/test_needs_compression.py`, `test_token_counting.py`, `test_preset_reader.py`

`pyproject.toml` sets `pythonpath = ["."]` so `pytest` run from `llo-core/` finds the `context_manager` package. But these three files all do `sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))` which inserts the repo root, so `from context_manager.context_engine import` resolves to `llo-core/context_manager/` either way — but only by coincidence. Under `uv run pytest` from the repo root the `sys.path.insert` makes the path `<repo_root>` which doesn't contain `context_manager`, so the import fails. `test_compress.py` and `test_anthropic_conversion.py` have no `sys.path` hack and work correctly.

**Fix:** Remove the `sys.path.insert` lines from the three affected files. The `pyproject.toml` handles path resolution.

---

### B1-10 🟡 `_request_summary` creates a new `httpx.AsyncClient` per compression call, bypassing the shared connection pool

**File:** `llo-core/context_manager/context_engine.py` — `_request_summary()`

```python
async with httpx.AsyncClient(timeout=120.0) as client:
    resp = await client.post(url, json=payload)
```

The shared `http_client` from `proxy.py`'s lifespan is not accessible from `context_engine.py` (correct separation of concerns). But creating a fresh client per summarization call means no connection reuse between summary requests. For a busy session that compresses frequently, this adds ~20–50ms of TCP handshake overhead per compression event.

**Fix:** Accept an optional `http_client` parameter in `_request_summary` and thread the proxy's shared client through:
```python
async def _request_summary(self, conversation_text, model_alias, prior_summary=None,
                            http_client: Optional[httpx.AsyncClient] = None) -> str:
    client = http_client or httpx.AsyncClient(timeout=120.0)
    own_client = http_client is None
    try:
        resp = await client.post(url, json=payload)
        ...
    finally:
        if own_client:
            await client.aclose()
```

Pass the shared client from `proxy.py` when calling `maybe_compress`.

---

### B1-11 🟡 `compress()` serializes tool_call content in `conversation_lines` as `" ".join(item.get("text",""))` — tool result blocks don't have a `text` key

**File:** `llo-core/context_manager/context_engine.py` — `compress()`

```python
if isinstance(c, list):
    c = " ".join([item.get("text", "") for item in c if isinstance(item, dict)])
```

Tool result messages have content like `[{"type": "tool_result", "tool_use_id": "...", "content": "result text"}]`. These items don't have a `text` key, so they produce empty strings in the join. The summarizer sees blank content for every tool result turn. Summaries will miss all tool outputs — a significant loss for agentic Claude Code sessions.

**Fix:**
```python
if isinstance(c, list):
    parts = []
    for item in c:
        if not isinstance(item, dict):
            continue
        if item.get("type") == "text":
            parts.append(item.get("text", ""))
        elif item.get("type") == "tool_result":
            parts.append(f"[Tool Result: {str(item.get('content', ''))}]")
        elif item.get("type") == "tool_use":
            parts.append(f"[Tool Call: {item.get('name','')} {json.dumps(item.get('input',{}))}]")
    c = " ".join(parts)
```

---

---

## BATCH 2 — PowerShell Scripts (`main.ps1`, `SetupRouter.ps1`, `start-server.ps1`, `stop-server.ps1`, `StartContextManager.ps1`)

### B2-01 🔴 `main.ps1` initial `$config` object has `cache_type_k`, `cache_type_v`, `flash_attn`, `ubatch_size`, `parallel_slots`, `default_context_size` as top-level keys that are always written to `llo-config.json`, then read by `start-server.ps1` with higher priority than `SetupRouter.ps1`

**File:** `main.ps1` lines 79–119 (config defaults block), line 649 (save)

The wizard's `$config` hashtable is initialized with inference params (`cache_type_k = "f16"`, `flash_attn = "auto"`, `ubatch_size = 512`, `parallel_slots = -1`, `default_context_size = 131072`). When the wizard runs, it loads an existing config and writes it back. These keys are never removed — they exist as permanent top-level keys.

`start-server.ps1` reads `ubatch_size` from `$config.ubatch_size` and passes it as `-ub` to llama-server. `default_context_size` takes priority over `SetupRouter.ps1`'s hardware-derived `$selectedEntry.CtxSize`. A machine with 8 GB VRAM where SetupRouter calculates ctx=32768 will have `default_context_size=131072` from the wizard override pass, and launch with 128k context, causing an OOM crash.

The `SetupRouter.ps1` comments document: *"Old flat config keys... are intentionally ignored for hardware-adaptive params."* But `start-server.ps1` actively reads and applies them. The two scripts contradict each other.

**Fix:** Remove inference params from the `main.ps1` defaults block. Move them to `config.overrides` only when the user explicitly changes them from the wizard's advanced options. The keys `cache_type_k`, `cache_type_v`, `flash_attn`, `ubatch_size`, `parallel_slots` must not exist at the top level of `llo-config.json`. `default_context_size` should only be written if the user explicitly sets it, not as a default:

```powershell
# Remove from $config initialization:
# cache_type_k, cache_type_v, flash_attn, context_shift,
# ubatch_size, parallel_slots, default_context_size, vram_margin_mb

# In start-server.ps1 ubatch resolution: REMOVE the $config.ubatch_size check entirely
# (ubatch_size comes from the preset which SetupRouter already wrote)
```

---

### B2-02 🟠 `stop-server.ps1` Linux branch has TWO `$pidFile` checks that look in different directories — one finds the file, one doesn't

**File:** `script/stop-server.ps1` lines 15–31 and lines 140–155

The top of `stop-server.ps1` (lines 15–31) resolves `$userAppDir` from `$env:APPDATA`/`USERPROFILE`/`HOME` and checks `$userAppDir/context-manager.pid`. This runs on all OSes and works correctly.

Then in the Linux/macOS `else` branch (line ~140), there is a second PID file check:
```powershell
$pidFile = Join-Path $ManagerDir "context-manager.pid"   # ← wrong dir
```

`StartContextManager.ps1` writes the PID file to `$userAppDir` (AppData/LLM Manager). `stop-server.ps1`'s second check looks in `$ManagerDir` (the repo root). The PID file is never there. The fallback port-scan then runs unnecessarily.

Additionally, `$ManagerDir` is never defined in `stop-server.ps1` — the variable is used but not set in that script (it's set in other scripts). This causes a PowerShell silent empty-string resolution, and `Join-Path "" "context-manager.pid"` resolves to `context-manager.pid` in the current working directory.

**Fix:** Remove the duplicate PID file check in the Linux else-branch entirely. The top-of-script block already handles it correctly for all platforms.

---

### B2-03 🟠 `start-server.ps1` Claude Code launch command interpolates `$selectedModel` directly into a PowerShell string passed to a new process — spaces and special characters in model names break it

**File:** `script/start-server.ps1` lines ~480–500

```powershell
$startupCmds = @(
    ...
    "claude --model $selectedModel"   # ← $selectedModel interpolated into a string
) -join "; "

Start-Process powershell -ArgumentList "-NoExit", "-Command", "`"$startupCmds`""
```

If `$selectedModel` is `"qwen2-5-coder-1-5b-instruct"` this works. If it contains spaces (possible with some HF model names) or quotes, the generated command breaks. The outer quotes around `$startupCmds` are escaped with backticks, but inner model name quotes are not handled.

**Fix:** Use a PowerShell variable assignment in the startup command instead of interpolation:
```powershell
$startupCmds = @(
    "`$m = '$($selectedModel -replace "'","''")'",
    "`$env:ANTHROPIC_BASE_URL = '$clientBase'",
    ...
    "claude --model `$m"
) -join "; "
```

---

### B2-04 🟠 `SetupRouter.ps1` `Get-SafeContextSize` Claude Code floor of 65536 on non-CPU tiers is applied even when the hardware can't sustain it — forces 64k context on a 4 GB GPU with a 7B model

**File:** `llo-core/SetupRouter.ps1` — `Get-SafeContextSize()`

```powershell
$minFloor = if ($GpuTier -eq "cpu") {
    if ($hasClaude) { 32768 } else { 4096 }
} else {
    if ($hasClaude) { 65536 } else { 8192 }
}
return [int][math]::Max([int]$chosen, [int]$minFloor)
```

On a `low` tier GPU (2–4 GB), with a 4 GB model file, `$availRam` after model subtract is minimal. `$maxCtxFromRam` may compute to `4096` or even negative. `$chosen` is clamped to the tier max of 32768 (`tierMaxCtx`), then `Max(chosen, minFloor)` with `minFloor=65536` forces the output to **65536** — **above the tier ceiling of 32768**. The tier ceiling is designed to prevent OOM, but the Claude Code floor bypass it.

**Fix:** Apply the Claude Code floor only if it doesn't exceed the tier ceiling:
```powershell
$effectiveFloor = [math]::Min($minFloor, $tierMaxCtx)
return [int][math]::Max([int]$chosen, [int]$effectiveFloor)
```

---

### B2-05 🟠 `StartContextManager.ps1` does not dot-source `Paths.ps1` — uses inline APPDATA copy-paste for config path; also `stop-server.ps1`, `main.ps1`, `GitDiff.ps1`, `ParseHelp.ps1` all still have inline copies

**Files:** `script/StartContextManager.ps1`, `script/stop-server.ps1`, `main.ps1`, `llo-core/GitDiff.ps1`, `llo-core/ParseHelp.ps1`

`Paths.ps1` was created and `SetupRouter.ps1` and `start-server.ps1` now use it. But the other five scripts still have the inline APPDATA resolution copy-paste. Any future change to the LLM Manager directory structure (e.g., renaming from `LLM Manager` to `LLO`) requires updating all five separately.

**Fix:** Dot-source `Paths.ps1` in each remaining script. The `$ManagerDir` variable is already computed in all of them:
```powershell
$lloCoreDir = Join-Path $ManagerDir "llo-core"
if (Test-Path (Join-Path $lloCoreDir "Paths.ps1")) {
    . (Join-Path $lloCoreDir "Paths.ps1")
    $ConfigFile = Get-LLMManagerConfigPath -ManagerDir $ManagerDir
}
```

---

### B2-06 🟡 `SetupRouter.ps1` `Get-InferenceParams` applies `parallel_slots` from flat config even though the comment says flat keys are ignored for hardware-adaptive params

**File:** `llo-core/SetupRouter.ps1` — `Get-InferenceParams()`

```powershell
# Support legacy and top-level config key mappings for user settings
if (-not $Overrides.ContainsKey("parallel") -and $config.ContainsKey("parallel_slots") -and [int]$config.parallel_slots -gt 0) {
    $params.parallel = [int]$config.parallel_slots
```

The header comment says *"Old flat config keys... are intentionally ignored for hardware-adaptive params."* But `parallel_slots` from the flat config is read here with lower priority than overrides but higher than hardware derivation. This is inconsistent. `-1` (auto) is also filtered out by `-gt 0`, so the auto value is silently dropped and the hardware-derived value wins instead — which is probably correct behaviour but is not documented.

**Fix:** Document the exception explicitly and handle `-1`:
```powershell
# parallel_slots = -1 means "auto" — defer to hardware-derived value (do nothing)
# parallel_slots > 0 is an explicit user setting; respect it
if (-not $Overrides.ContainsKey("parallel") -and
    $config.ContainsKey("parallel_slots") -and
    [int]$config.parallel_slots -gt 0) {
    $params.parallel = [int]$config.parallel_slots
    Write-Host "  [config] parallel = $($params.parallel)  (from config.parallel_slots > 0)" -ForegroundColor DarkYellow
}
# If parallel_slots == -1: no-op, hardware-derived value stands
```

---

### B2-07 🟡 `start-server.ps1` `default_context_size` takes priority over `selectedEntry.CtxSize` in the resolution hierarchy — this means the wizard's 131072 default always wins over hardware-derived values

**File:** `script/start-server.ps1` lines ~330–345

```powershell
} elseif ($selectedEntry.CtxSize -and [int]$selectedEntry.CtxSize -gt 0) {
    $finalCtxSize = [int]$selectedEntry.CtxSize           # ← lower priority
    ...
} elseif ($config.ContainsKey("default_context_size") -and ...) {
    $finalCtxSize = [int]$config.default_context_size     # ← this is the fallback
```

Wait — checking the actual order: CLI > `selectedEntry.CtxSize` > `config.default_context_size`. This is the correct order IF `$selectedEntry.CtxSize` is populated by `SetupRouter.ps1`. But `SetupRouter.ps1` only sets `CtxSize` on the returned objects when models exist. The `$selectedEntry.CtxSize` value IS the hardware-derived value from `Get-SafeContextSize`. So the priority is actually correct in `start-server.ps1`.

The issue is upstream: `SetupRouter.ps1` itself has this block:
```powershell
if ($config.ContainsKey("default_context_size") -and $config.default_context_size -and [int]$config.default_context_size -gt 0) {
    $ctxSize = [int]$config.default_context_size   # ← overwrites hardware-derived value inside SetupRouter
```

So `$selectedEntry.CtxSize` is already set to `default_context_size` by SetupRouter before it's even returned. The `start-server.ps1` resolution hierarchy is irrelevant — the damage is done inside SetupRouter.

**Fix:** In `SetupRouter.ps1`, move the `default_context_size` override to `config.overrides.ctx_size` and process it through the override pathway, which already exists and handles it correctly. Do not override `$ctxSize` from the flat config key inside `SetupRouter`.

---

---

## BATCH 3 — Rust / Tauri Backend (`ui/src-tauri/`)

### B3-01 🔴 `gguf.rs` KV cache size formula uses `bytes_per_elem = 4.0` (f32) for ALL quantization types — dramatically overstates KV cache for q8_0 and q4_0

**File:** `ui/src-tauri/src/commands/gguf.rs` lines ~140–145

```rust
let kv_8k = ((8192.0 * block_count as f64 * kv_dim * 4.0 / bytes_per_gb) * 10.0).round() / 10.0;
```

The formula uses `4.0` (bytes per element, assuming f32 full precision). When the actual cache type is `q8_0`, the correct multiplier is `1.0625` bytes/element; for `q4_0` it's `0.5625`. For a 70B model with q8_0 cache, the UI will display a KV cache at 64k of ~`65536 * 80 * 2048 * 4 / 1024³ = 40 GB` when the actual usage is `~10.5 GB`. The VRAM overflow warning fires when it should not, and users will think their GPU can't run the model when it can.

The `gguf.rs` file reads `file_type` from the GGUF header but never uses it to select the bytes-per-element multiplier. The `GetSafeContextSize` in `SetupRouter.ps1` has a correct `$getBytesPerElem` helper — but `gguf.rs` ignores it.

**Fix:**
```rust
let bytes_per_kv_elem = match quant.as_str() {
    "Q8_0" => 1.0625,
    "Q4_0" | "Q4_K_M" | "Q4_K_S" => 0.5625,
    "Q5_K_M" | "Q5_K_S" => 0.6875,
    _ => 2.0,  // f16 default
};
let kv_8k  = ((8192.0  * block_count as f64 * kv_dim * bytes_per_kv_elem * 2.0 / bytes_per_gb) * 10.0).round() / 10.0;
let kv_32k = ((32768.0 * block_count as f64 * kv_dim * bytes_per_kv_elem * 2.0 / bytes_per_gb) * 10.0).round() / 10.0;
let kv_64k = ((65536.0 * block_count as f64 * kv_dim * bytes_per_kv_elem * 2.0 / bytes_per_gb) * 10.0).round() / 10.0;
// × 2.0 for K + V caches combined
```

---

### B3-02 🔴 `gguf.rs` KV cache formula uses `kv_dim = 2048` for models with `block_count > 40` — wrong for most 70B+ models with GQA

**File:** `ui/src-tauri/src/commands/gguf.rs`

```rust
let kv_dim = if block_count > 40 { 2048.0 } else { 1024.0 };
```

The actual KV dimension is `num_kv_heads * head_size`, where `num_kv_heads` is typically **8** for GQA models (Llama 3 70B, Qwen 72B) and `head_size` is **128**. That gives `8 * 128 = 1024` — not 2048. This heuristic doubles the KV cache estimate for all large models, compounding the B3-01 error.

For a 70B model with the two bugs combined: actual q8_0 KV cache at 64k ≈ `65536 * 80 * 1024 * 1.0625 * 2 / 1024³ ≈ 10.6 GB`. The UI computes `65536 * 80 * 2048 * 4 / 1024³ ≈ 40 GB`. The shown number is **3.8× the actual value**.

**Fix:** The GGUF KV metadata contains `llm.attention.head_count_kv` and `llm.rope.dimension_count`. Parse those in the KV loop:
```rust
let mut kv_head_count: u32 = 0;
// In the KV parse loop:
} else if key.ends_with(".attention.head_count_kv") && ... {
    if let Ok(val) = read_u32(&mut file) { kv_head_count = val; }
}
// After loop:
let head_size = 128u32; // safe default; can also parse from rope.dimension_count
let kv_dim = if kv_head_count > 0 { (kv_head_count * head_size) as f64 } else {
    if block_count > 40 { 1024.0 } else { 1024.0 }  // GQA is standard; 1024 safe default
};
```

---

### B3-03 🟠 `health.rs` text-parsing fallback path fires every time `test-health.ps1` outputs any `WARNING` string — including non-template warnings

**File:** `ui/src-tauri/src/commands/health.rs`

```rust
if script_output.contains("WARNING") {
    items.push(HealthItem { title: "Template Matching Coverage", status: "warning", ... });
```

`test-health.ps1` is called with `-Json` flag, so the JSON parse path should succeed most of the time. But if the script outputs any warning (e.g. `[WARNING] Failed to load llo-config.json`) the text-fallback path shows "Template Matching Coverage: warning" when the actual issue is config loading. This is a false attribution.

The JSON path already handles this correctly — but if `test-health.ps1` doesn't have a `-Json` implementation or fails to emit valid JSON, the fallback masks the real error with confusing output.

**Fix:** When the JSON parse fails, emit the raw script output as a single debug item rather than trying to parse it with substring matching:
```rust
// If JSON parsing fails, return a single error item with the raw output
return Ok(HealthReport {
    timestamp: ...,
    passed_count: 0,
    total_count: 1,
    items: vec![HealthItem {
        title: "Health Check Script Error".to_string(),
        description: format!("Script output was not valid JSON:\n{}", &script_output[..script_output.len().min(500)]),
        status: "failed".to_string(),
    }],
});
```

---

### B3-04 🟠 `server.rs` `emit_log_file_lines` seeks to `SeekFrom::End(0)` and then tails from there — misses all output written before the tailer started

**File:** `ui/src-tauri/src/commands/server.rs` — `emit_log_file_lines()`

```rust
let current_pos = match reader.seek(SeekFrom::End(0)) {
    Ok(pos) => pos,
    ...
};
```

The log tailers start immediately after `start_server` is called. `start-server.ps1` runs `SetupRouter.ps1`, which may take 5–10 seconds on a large models directory. During this time, llama-server is not yet running and nothing is written to the log file. The file is cleared at the start of `start-server.ps1`:

```powershell
if (Test-Path $logPath) { try { Clear-Content $logPath } catch {} }
```

Then llama-server starts writing. The tailer has already seeked to end-of-empty-file (position 0), so the first lines ARE captured. This is actually fine. **But:** if the tailer starts before `start-server.ps1` has cleared the old log, it seeks to the end of the previous run's log and only captures new content. That's correct.

**Actual issue:** The log file is opened once (`File::open`) at the start of the loop. On Windows, if `start-server.ps1` clears the log file by running `Clear-Content` (which truncates in place), `seek(SeekFrom::End(0))` returns 0, then `read_line` will pick up new content correctly. On Linux/macOS, `Clear-Content` uses PowerShell truncation which replaces the inode. The open file handle now points to a deleted inode. The loop detects `metadata.len() < current_pos` (log rotation check) and breaks — then the outer loop reopens the file. This works correctly.

**No critical bug here.** B3-04 withdrawn. ✅

---

### B3-04 🟠 `config.rs` `AppConfig` struct has `cache_type_k`, `cache_type_v`, `flash_attn`, `default_context_size`, `ubatch_size`, `parallel_slots` as first-class fields — writing these via `save_config` re-introduces the flat inference params that SetupRouter is designed to ignore

**File:** `ui/src-tauri/src/commands/config.rs`

When the user changes settings in the UI's Performance page and calls `save_config`, it serializes the full `AppConfig` including `cache_type_k`, `flash_attn`, etc. as top-level keys. As described in B2-01, these keys are then read by `start-server.ps1` and override SetupRouter's hardware-derived values.

The UI has a Performance page with sliders for these values. The intent is that users can manually tune. But the mechanism bypasses the hardware safeguards. A user setting `cache_type_k = "q4_0"` with `flash_attn = "off"` will trigger a silent correction in SetupRouter (`if flash_attn == "off" → force cache to f16`) but the UI still shows their q4_0 setting. The UI state and actual running config diverge silently.

**Fix:** Move all inference parameters that SetupRouter manages to `config.overrides` in both the UI config struct and the persistence layer. When the user changes `cache_type_k` in the Performance page, write it to `overrides.cache_type_k`, not the top level. This is the mechanism SetupRouter already supports and it's already documented in the SetupRouter header comment.

---

### B3-05 🟡 `server.rs` `start_server` starts log tailers immediately regardless of whether the server starts successfully — if the script fails in under 1 second, tailers run for up to `missing_count=5 * 300ms = 1.5s` emitting "waiting for log file" warnings to the UI

**File:** `ui/src-tauri/src/commands/server.rs`

```rust
// Start tailers unconditionally before knowing if the script succeeded:
let t1 = tokio::spawn(async move { emit_log_file_lines(...).await });
let t2 = tokio::spawn(async move { emit_log_file_lines(...).await });
```

If `start-server.ps1` fails immediately (wrong llama path, missing binary), the UI shows:
1. "Starting..." (correct)
2. "Waiting for llama-server stdout log file: /path/to/log" (confusing, then)
3. "Waiting for llama-server stderr log file: /path/to/log" (confusing)
4. "start-server.ps1 failed: ..." (the real error)

The two intermediate warnings add noise and delay the real error message by ~1.5 seconds.

**Fix:** The tailers check `IS_STARTING/IS_RUNNING` at startup. Since `abort_log_tailers()` is called in `start_server` before starting new tailers, they start clean. The issue is only cosmetic (2 extra warning messages). The stop signal works. Note as design improvement — set the `missing_count` warning threshold higher (e.g. 20 × 300ms = 6s) so short-lived startup sequences don't emit the "waiting for log" message at all.

---

---

## BATCH 4 — Frontend / UI (`ui/src/`)

### B4-01 🔴 `validation.ts` `validateConfiguration` Rule 4 uses `config.default_context_size` as the context size — but this is always the wizard's fixed value (32768 or 131072), never the hardware-adaptive `selectedEntry.CtxSize` that llama-server actually uses

**File:** `ui/src/lib/validation.ts` — `validateConfiguration()` Rule 4

```typescript
const ctx = config.default_context_size || 32768;
const estimatedKvGb = calculateKvCacheGb(ctx, ...);
```

The validation check is supposed to warn when context + model > VRAM. But `config.default_context_size` is a wizard-set value. The actual runtime context size comes from `SetupRouter.ps1`'s `Get-SafeContextSize`, which is hardware-adaptive and is not stored in `config` (by design). So:

- On a 24 GB GPU: `Get-SafeContextSize` computes `ctx=131072`. `config.default_context_size=32768` (wizard default). The UI validation uses 32k, says "fits fine." The running server uses 128k and may OOM.
- On an 8 GB GPU with a 7B model: `Get-SafeContextSize` computes `ctx=32768`. `config.default_context_size=131072` (old wizard value). The UI says "VRAM overflow at 128k" but the server runs at 32k and is fine. False positive.

The validation result and the actual server behaviour are disconnected.

**Fix:** The only correct fix is to also store the hardware-derived ctx value somewhere the UI can read it — or to compute it in the UI using the same formula as `Get-SafeContextSize`. The latter is partially done via `calculateKvCacheGb` + `estimateBlockCount`, but validation uses `config.default_context_size` instead of actually computing the hardware-derived value. 

Short-term fix: Use the model-specific adaptive estimate for the validation, not `config.default_context_size`:
```typescript
// Estimate hardware-adaptive ctx from model size and available VRAM
const adaptiveCtx = vramGb > 0
  ? Math.min(131072, Math.max(8192, Math.floor((vramGb - activeModelSizeGb) * 1024 / estimateKvMbPerKToken(activeModelSizeGb)) * 1000))
  : 32768;
const ctx = config.default_context_size || adaptiveCtx;
```

---

### B4-02 🟠 `hardwareStore.ts` `vramGb` is rounded to the nearest GB with `Math.round(vramMb / 1024)` — a GPU with 8192 MB becomes 8, but a GPU with 7900 MB (e.g. RX 6700 XT) becomes 8 too, inflating VRAM by 4%

**File:** `ui/src/store/hardwareStore.ts`

```typescript
vramGb: Math.round(vramMb / 1024),
```

The GPU budget in `SetupRouter.ps1` uses `$hardware.GPU.BudgetVramMB` with a margin, not total VRAM. The UI hardwareStore rounds to the nearest GB and uses raw total. A 7900 MB GPU rounded to 8 GB passes the 8 GB tier check when it should be in the 6–8 GB range. This only matters at tier boundaries, but the VRAM overflow warning math `totalMem > vramGb * 0.90` uses the rounded value.

**Fix:** Do not round — keep one decimal place:
```typescript
vramGb: Math.round(vramMb / 1024 * 10) / 10,
```

---

### B4-03 🟠 `Overview.tsx` `selectedModelFilename` effect does not respond when `config.active_model` changes without models also changing — clicking a model in `Models.tsx` and switching back to `Overview` shows the old model selected

**File:** `ui/src/pages/Overview.tsx` lines ~55–63

```typescript
useEffect(() => {
    if (models.length > 0) {
        const active = models.find((m) => m.name === config?.active_model);
        if (active && active.filename !== selectedModelFilename) {
            setSelectedModelFilename(active.filename);
        } else if (!selectedModelFilename) {
            setSelectedModelFilename(models[0].filename);
        }
    }
}, [models, config?.active_model]);  // ← dep on config?.active_model
```

The effect does depend on `config?.active_model`. But `updateConfig` in `Models.tsx` or `Settings.tsx` updates the Zustand store, and `config?.active_model` in the dep array will change. **This looks correct.** However the condition `active.filename !== selectedModelFilename` prevents the update if the model is already selected. When the user changes active_model in Settings and comes back, `active` is the new model and `active.filename !== selectedModelFilename` is true, so the update fires. **No actual bug.** Withdraw B4-03. ✅

---

### B4-03 (revised) 🟠 `configStore.ts` `saveConfig` fires `setPendingRestart(true)` — but `Overview.tsx` reads `pendingRestart` from `useServerStore()` and clears it on server status change, not on server restart completion

**File:** `ui/src/store/configStore.ts` line 99, `ui/src/pages/Overview.tsx`, `ui/src/store/serverStore.ts` line 33

```typescript
// serverStore.ts
pendingRestart: (status === 'stopped' || status === 'starting') ? false : state.pendingRestart,
```

`pendingRestart` is cleared when status becomes `stopped` OR `starting`. When the user clicks Stop → the status changes to `stopping` → then `stopped`. At that point `pendingRestart` becomes false. The user then makes a new config change and clicks Start without saving again. The banner no longer shows even though the new start will use the old pre-change config already saved to disk. 

More importantly: `pendingRestart` is cleared when status becomes `starting` — before the server has actually picked up the new config. If the server start fails, `pendingRestart` was already cleared. The warning disappears even though the config change still hasn't been applied to a running server.

**Fix:** Only clear `pendingRestart` when status transitions to `running` (meaning the new config was successfully applied), not on `stopping`/`stopped`/`starting`:
```typescript
// serverStore.ts
pendingRestart: status === 'running' ? false : state.pendingRestart,
```

---

### B4-04 🟠 `validation.ts` `validateModelLaunch` Case B auto-tune sets `default_context_size: safeCtx` as a top-level key — this re-introduces the wizard's flat inference param back into config, defeating SetupRouter's override priority

**File:** `ui/src/lib/validation.ts` — `validateModelLaunch()` Case B

```typescript
autoTuneConfig: (cfg) => ({
    ...cfg,
    active_model: model.name,
    default_context_size: safeCtx,    // ← writes to top-level flat key
    flash_attn: 'on',
})
```

When the user clicks "Launch Auto-Tuned" on a model that partially overflows VRAM, this writes `default_context_size` and `flash_attn` to the top-level config. `SetupRouter.ps1` then reads `default_context_size` and uses it instead of the hardware-derived value (see B2-07). The auto-tune creates the exact conflict the architecture is designed to prevent.

**Fix:** Write to `overrides` instead of top-level:
```typescript
autoTuneConfig: (cfg) => ({
    ...cfg,
    active_model: model.name,
    overrides: {
        ...cfg.overrides,
        ctx_size: safeCtx,       // SetupRouter reads overrides.ctx_size
    },
    flash_attn: 'on',           // flash_attn may remain top-level (SetupRouter validates it)
})
```

---

### B4-05 🟡 `hardwareStore.ts` `fetchHardware` catches all errors silently — if `detect_hardware` fails (Profile.ps1 not found, PowerShell error), the UI shows no error and `profile` stays `null`

**File:** `ui/src/store/hardwareStore.ts`

```typescript
} catch {
    set({ loading: false });
}
```

When `profile` is null, `validateConfiguration` returns empty assessments (the null guard at the top). The Overview page shows no hardware info and no warnings. The user sees a blank hardware section with no indication of why. This silently breaks validation and the KV cache display.

**Fix:** Store the error and surface it:
```typescript
interface HardwareState {
    ...
    error: string | null;
}

} catch (err: any) {
    set({ loading: false, error: err?.toString() || 'Failed to detect hardware' });
}
```
Show the error string in the Overview hardware panel when `profile` is null.

---

### B4-06 🟡 `App.tsx` `useEffect` with `[fetchConfig, fetchHardware, setStatus, addLog]` deps — these are Zustand store actions and are stable references, but the dep array is misleading and causes React linter warnings

**File:** `ui/src/App.tsx`

```typescript
useEffect(() => {
    fetchConfig();
    fetchHardware();
    ...
}, [fetchConfig, fetchHardware, setStatus, addLog]);
```

Zustand store actions are created once and are referentially stable — they never change. The effect will only run once (on mount), which is correct. But listing them in the dep array signals to readers and linters that re-runs are expected when they change. The `eslint-disable-line` comment is absent here (unlike the `Overview.tsx` effect), so `react-hooks/exhaustive-deps` will flag this.

**Fix:**
```typescript
useEffect(() => {
    fetchConfig();
    fetchHardware();
    ...
}, []); // eslint-disable-line react-hooks/exhaustive-deps
```

---

---

## BATCH 5 — Architecture / Cross-Cutting

### B5-01 🔴 Inference parameter authority is split between three systems that contradict each other and have no single source of truth

**Files:** `main.ps1` (wizard), `llo-core/SetupRouter.ps1` (hardware-adaptive), `ui/src-tauri/src/commands/config.rs` (UI config struct), `script/start-server.ps1` (runtime resolution)

The system has three places that independently compute or store inference parameters, with overlapping but conflicting precedence:

1. **`main.ps1` wizard** writes `cache_type_k`, `flash_attn`, `ubatch_size`, `parallel_slots`, `default_context_size` as top-level flat keys to `llo-config.json`
2. **`config.rs` `AppConfig`** has those same fields as first-class struct members with default values — serialized on every `save_config` call
3. **`SetupRouter.ps1`** derives the same parameters from hardware profile and documents that flat keys should be ignored — but only ignores some of them

The result: any save from the UI re-writes flat inference keys, any wizard re-run overwrites them again, and SetupRouter's hardware-adaptive values are in a `$selectedEntry.CtxSize` that is often pre-overwritten by `default_context_size` before it reaches `start-server.ps1`.

**Actual design intent** (from SetupRouter.ps1 header): Flat keys = non-hardware operational config. Inference params = SetupRouter only, overridable via `config.overrides`.

**Fix:** Enforce the documented design:
- Remove `cache_type_k`, `cache_type_v`, `flash_attn`, `ubatch_size`, `parallel_slots`, `default_context_size` from `AppConfig` struct in `config.rs`
- Remove them from `main.ps1` defaults block
- Remove them from `start-server.ps1` CLI resolution (except the already-correct `config.overrides.ctx_size` path)
- The Performance page in the UI writes to `config.overrides.*` not top-level keys
- `SetupRouter.ps1` reads `config.overrides` (already implemented) — this becomes the only override path

---

### B5-02 🟠 No integration test or end-to-end test exists — the test suite is entirely unit tests mocking Tauri, PowerShell, and the proxy

**Files:** `ui/src/pages/__tests__/`, `llo-core/context_manager/tests/`

All tests mock `invoke` (Tauri IPC), mock `_request_summary` (context engine), and mock `sys.path`. No test:
- Runs `start-server.ps1` against a real `llama-server` binary (even a tiny bootstrap)
- Sends an actual HTTP request through the proxy
- Verifies the Anthropic↔OpenAI conversion round-trip with a real response

The B1-01 bug (duplicate method definitions) was not caught by any test because the compression test mocks `_request_summary` and never exercises the concurrent path.

**Fix:** Add at minimum one integration smoke test per subsystem:
- `pytest` test that starts `proxy.py` with `httpx.AsyncClient` and sends a mock `/v1/messages` request through to a stubbed upstream (using `httpx_mock` or a simple FastAPI stub)
- Vitest test that invokes `validateModelLaunch` with realistic GGUF metadata values (not defaults) and asserts the correct case fires

---

### B5-03 🟡 `SetupRouter.ps1` returns `$modelEntries.ToArray()` but `start-server.ps1` wraps in `@(. $setupScript)` — on macOS/Linux, if `SetupRouter.ps1` writes any `Write-Host` output before the return, the array is contaminated with strings

**Files:** `llo-core/SetupRouter.ps1`, `script/start-server.ps1`

```powershell
$models = @(. $setupScript @setupArgs)
```

PowerShell dot-sourcing captures ALL output to the pipeline, including any stray `return` or unassigned expression. `SetupRouter.ps1` uses `Write-Host` throughout (which goes to the host, not pipeline — safe), but any accidental unpiped expression would contaminate `$models`. The `return $modelEntries.ToArray()` correctly outputs only the array, but the `Write-Host` calls protect this assumption.

If a future contributor adds a debug `$someVar` bare expression in `SetupRouter.ps1`, it appears as a string element in `$models`. `$models.Count -gt 0` would still be true, and `start-server.ps1` would try to call `.Alias` on a string — silent null. Template selection would silently fall back.

**Fix:** Use an explicit output variable pattern instead of pipeline capture:
```powershell
# SetupRouter.ps1: write to a temp file instead of pipeline
$modelEntries.ToArray() | ConvertTo-Json -Depth 3 | Set-Content $modelListFile

# start-server.ps1: read from file
$models = @(Get-Content $modelListFile -Raw | ConvertFrom-Json)
```
Or use `$script:modelEntries` scoped variable, or the `OutputFile` parameter pattern.

---

## Summary Table

| ID | Sev | File(s) | Issue |
|----|-----|---------|-------|
| B1-01 | 🔴 | `context_engine.py` | Two definitions of `_save_checkpoint_to_disk` and `maybe_compress` — lock-free version wins, causing concurrent compression corruption |
| B1-02 | 🔴 | `proxy.py` | Module-level `config`+`engine` live alongside lifespan versions — two separate `ContextEngine` instances with separate session dicts |
| B1-03 | 🔴 | `proxy.py` | `get_http_client` fallback silently creates a disposable client with no error when called outside lifespan |
| B1-04 | 🟠 | `proxy.py` | `is_anthropic_messages` matches any path ending in `messages` — catches unrelated endpoints |
| B1-05 | 🟠 | `proxy.py` | `is_openai_chat` matches `/v1/completions` (legacy) — corrupts prompt body by converting to chat format |
| B1-06 | 🟠 | `context_engine.py` | `effective_keep` adjustment causes compression to fire when `len == keep_turns` — summarizes 1 turn wastefully |
| B1-07 | 🟠 | `tokenizer_cache.py` | `claude`, `gpt`, `openai` aliases map to Qwen tokenizer — wrong counts for all Claude Code sessions |
| B1-08 | 🟠 | `preset_reader.py` | `o3` hardcoded to 128k — should be 200k |
| B1-09 | 🟠 | `test_needs_compression.py`, `test_token_counting.py`, `test_preset_reader.py` | `sys.path.insert` still present, breaks `uv run pytest` from repo root |
| B1-10 | 🟡 | `context_engine.py` | `_request_summary` creates new httpx client per call — no connection reuse |
| B1-11 | 🟡 | `context_engine.py` | Tool result blocks serialized with `item.get("text","")` — empty string for all tool outputs in summaries |
| B2-01 | 🔴 | `main.ps1`, `config.rs` | Wizard writes inference params as top-level flat keys; UI saves them back — always overrides SetupRouter |
| B2-02 | 🟠 | `stop-server.ps1` | Linux branch has second PID file check using `$ManagerDir` (undefined in this script) — falls back to wrong path |
| B2-03 | 🟠 | `start-server.ps1` | Claude Code launch interpolates `$selectedModel` into PowerShell string — spaces in model names break the command |
| B2-04 | 🟠 | `SetupRouter.ps1` | Claude Code context floor (65536) bypasses tier ceiling (32768 for `low`) on low-VRAM GPUs — forces OOM ctx |
| B2-05 | 🟠 | 5 scripts | `Paths.ps1` only dot-sourced in 2 of 7 scripts — config path copy-paste remains in `StartContextManager.ps1`, `stop-server.ps1`, `main.ps1`, `GitDiff.ps1`, `ParseHelp.ps1` |
| B2-06 | 🟡 | `SetupRouter.ps1` | `parallel_slots` from flat config silently ignored when `-1`, contradicting documented behaviour |
| B2-07 | 🟡 | `SetupRouter.ps1` | `default_context_size` overrides hardware-derived ctx inside SetupRouter before returning `$selectedEntry.CtxSize` |
| B3-01 | 🔴 | `gguf.rs` | KV cache formula uses `4.0` bytes/elem (f32) for all quant types — 4× overestimate for q8_0 |
| B3-02 | 🔴 | `gguf.rs` | `kv_dim = 2048` for `block_count > 40` — wrong for GQA models; 70B models are shown at ~4× actual KV size |
| B3-03 | 🟠 | `health.rs` | Text-fallback health check shows "Template warning" on any `WARNING` string in output — wrong attribution |
| B3-04 | 🟠 | `config.rs`, `config.ts` | `AppConfig` has inference params as first-class fields — every UI save writes them back, defeating SetupRouter |
| B3-05 | 🟡 | `server.rs` | Log tailers emit "waiting for log file" noise for 1.5s when server fails immediately — cosmetic but confusing |
| B4-01 | 🔴 | `validation.ts` | Rule 4 uses `config.default_context_size` (wizard fixed value) — validation is disconnected from actual runtime ctx |
| B4-02 | 🟠 | `hardwareStore.ts` | `vramGb` rounded to integer — inflates VRAM at tier boundaries (e.g. 7900 MB → 8 GB) |
| B4-03 | 🟠 | `configStore.ts` | `pendingRestart` cleared on `starting`/`stopped` — disappears before server successfully picks up new config |
| B4-04 | 🟠 | `validation.ts` | Auto-tune writes `default_context_size` to top-level config — re-introduces the wizard flat-key override pattern |
| B4-05 | 🟡 | `hardwareStore.ts` | Hardware fetch errors silently set `profile = null` — validation disabled with no user-visible error |
| B4-06 | 🟡 | `App.tsx` | Zustand actions in `useEffect` deps array — misleading to readers, linter will flag |
| B5-01 | 🔴 | Architecture | Inference params stored in 3 places (wizard/UI config/SetupRouter) with no single source of truth |
| B5-02 | 🟠 | Architecture | No integration tests — concurrent proxy path, conversion round-trip, PS1→llama-server unverified |
| B5-03 | 🟡 | `SetupRouter.ps1`, `start-server.ps1` | Pipeline capture of dot-sourced script is fragile to stray output expressions |

---
*Report complete. Commit analysed: `29697f7` on branch `develop`, 2026-08-13.*
