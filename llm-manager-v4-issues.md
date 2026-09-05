# LLM Manager — Issue Report v4
**Repo:** `vijaytank/llm-manager` · **Branch:** `develop` · **Commit:** `908e7b1` · **Date:** 2026-08-16

> Written incrementally — each batch appended as analysis completes, so findings are safe even if session ends mid-way.
> Severity: 🔴 CRITICAL · 🟠 BUG · 🟡 DESIGN · 🔵 QUALITY

---

## BATCH 1 — Python Context Manager (`llo-core/context_manager/`)

**Fixes confirmed from v3:** Duplicate `maybe_compress`/`_save_checkpoint_to_disk` removed ✅. Module-level `config`/`engine` globals removed ✅. `get_config`/`get_engine`/`get_http_client` now raise on missing state ✅. `is_anthropic_messages` path matching fixed to exact routes ✅. `is_openai_chat` no longer matches legacy `/v1/completions` ✅. `keep_turns` guard simplified — no `effective_keep` adjustment ✅. Cloud model aliases (`claude`, `gpt`, `openai`) removed from `ALIAS_TO_HF_REPO` ✅. `o3`/`o4` returns 200k in preset_reader ✅. Tool content serialized correctly in `compress()` ✅. `_request_summary` accepts and uses shared `http_client` ✅. `sys.path.insert` removed from `test_needs_compression.py` and `test_token_counting.py` ✅.

---

### CM-01 🟠 `proxy_all` passes `is_owned_client = not hasattr(request.app.state, "http_client")` — this is always `False` during normal request handling because `http_client` is set in `lifespan`, yet `get_http_client` now raises if `app.state.http_client` is missing

**File:** `llo-core/context_manager/proxy.py`

```python
client = get_http_client(request)
is_owned_client = not hasattr(request.app.state, "http_client")
```

`get_http_client` now raises `RuntimeError` if `app.state` doesn't have `http_client`. If it reaches the next line, `hasattr(request.app.state, "http_client")` is always `True`, so `is_owned_client` is always `False`. The variable exists to signal the `finally` blocks in generators whether to call `await client.aclose()`. Since it is always `False`, the client is never closed by the generator — that's correct because the lifespan manages the shared client. But the variable name and the `not hasattr` pattern are now misleading dead logic since the only path where `is_owned_client` could be `True` (the old fallback client creation) has been removed.

**Fix:** Remove `is_owned_client` entirely and replace all `if is_owned_client: await client.aclose()` calls with just `pass` (or remove those branches). The shared client is always managed by lifespan:
```python
client = get_http_client(request)
# is_owned_client is always False now; remove it and all branches that reference it
```
This also simplifies `forward_stream_anthropic` and `forward_stream_openai` signatures by removing the unused `is_owned_client` parameter.

---

### CM-02 🟠 `proxy_all` silently discards body parsing exceptions and proceeds with an empty dict — a malformed JSON body from the client produces a silent empty request forwarded to llama-server

**File:** `llo-core/context_manager/proxy.py`

```python
try:
    body = await request.json()
except Exception:
    body = {}
```

If the client sends malformed JSON (e.g. Claude Code SDK bug, corrupted network packet), `body` becomes `{}`. Then `model_alias = ""`, `max_tokens = 512`, `messages = []`, and `rebuilt_messages = []`. The proxy sends an empty `{"model": "", "messages": [], "max_tokens": 512}` to llama-server which returns a 400 error. The client receives the 400 but the actual cause (malformed JSON) is never logged or surfaced. Debugging this is very hard.

**Fix:** Return a 400 immediately with a clear error when body parsing fails:
```python
try:
    body = await request.json()
except Exception as e:
    return JSONResponse(
        {"type": "error", "error": {"type": "invalid_request_error",
         "message": f"Failed to parse request body as JSON: {e}"}},
        status_code=400
    )
```

---

### CM-03 🟠 `_request_summary` swallows all exceptions inside `try` and returns a stub string — callers cannot distinguish a genuine summary from a fallback, causing the stub to be stored as `session.summary_block` and persisted to disk

**File:** `llo-core/context_manager/context_engine.py` — `_request_summary()`

```python
except Exception as e:
    print(f"[ContextEngine] Summarizer request failed: {e}")
# ...
return f"[Summary of previous conversation up to turn: {len(conversation_text.splitlines())} lines]"
```

When the summarizer call fails (network error, llama-server down), the stub string `"[Summary of previous conversation up to turn: N lines]"` is returned and stored in `session.summary_block`. This stub is then prepended to every subsequent request as the "compressed history". On the next compression call, the prior summary is this stub — so the new summary prompt includes `PRIOR_SUMMARY: [Summary of previous conversation up to turn: 42 lines]` which is content-free. The summarizer has no useful prior context to merge. Over many compressions, real history is permanently lost.

**Fix:** Raise the exception from `_request_summary` so callers can handle it. In `compress()`, catch the exception and skip storing the result:
```python
# _request_summary: remove the bare except, let exceptions propagate

# compress(): 
try:
    new_summary = await self._request_summary(...)
except Exception as e:
    print(f"[ContextEngine] Summarizer failed, skipping compression for session '{session.session_id}': {e}")
    # Return recent window without summary rather than storing a stub
    return self._clamp_message_tokens(messages, max_allowed, model_alias)
```

---

### CM-04 🟠 `_evict_stale_sessions` modifies `self.sessions` dict while iterating — on Python 3.11+ this raises `RuntimeError: dictionary changed size during iteration` when concurrent sessions evict simultaneously

**File:** `llo-core/context_manager/context_engine.py` — `_evict_stale_sessions()`

```python
def _evict_stale_sessions(self, max_age_seconds: float = 86400.0):
    now = time.time()
    stale_keys = [
        sid for sid, sess in self.sessions.items()   # ← iterates
        if (now - sess.last_accessed) > max_age_seconds
    ]
    for sid in stale_keys:
        self.sessions.pop(sid, None)                  # ← modifies
```

The list comprehension fully consumes `self.sessions.items()` before any modification, so this is actually safe — the list is built first, then items are popped. **No actual crash.** However, `_evict_stale_sessions` is called from `get_or_create_session` which is called from `maybe_compress` which is called from inside `async with session.lock`. The eviction iterates all sessions, including those locked by other concurrent `maybe_compress` calls. In a high-throughput scenario (100 concurrent sessions), eviction on every request is O(n) per request.

**Fix:** Run eviction on a background schedule rather than on every request:
```python
# In ContextEngine.__init__:
self._eviction_task: Optional[asyncio.Task] = None

# Start background eviction in lifespan or first compress call:
async def _start_eviction_loop(self):
    while True:
        await asyncio.sleep(300)  # every 5 minutes
        self._evict_stale_sessions()
```

---

### CM-05 🟠 `extract_session_id` fallback uses `hashlib.md5` of client IP + user-agent + path — two different users on the same IP (NAT, shared office) with the same user-agent get the same session ID, sharing compression state

**File:** `llo-core/context_manager/proxy.py` — `extract_session_id()`

```python
raw = f"{client_ip}:{user_agent}:{request.url.path}"
return "session_" + hashlib.md5(raw.encode("utf-8")).hexdigest()[:12]
```

In corporate or home NAT environments, multiple users share the same public IP. User-agent for Claude Code is fixed (`claude-code/x.y.z`). Both users hit the same path. They get the same session ID. Their conversation histories are merged. Compression summaries from user A are prepended to user B's next request. This is a data isolation failure.

**Fix:** Include a random per-connection nonce that is set at connection open, or make the fallback truly random and accept that fallback sessions don't persist across requests (which is the safer behaviour):
```python
# Fallback: generate a fresh random session ID when no stable identifier is present
# Accept that this session won't be reused across requests without an explicit ID
return "session_" + uuid.uuid4().hex[:16]
```
If session persistence for anonymous connections is required, document that users must pass `x-llm-session-id`.

---

### CM-06 🟡 `compress()` `conversation_lines` join uses `"\n\n".join(...)` — the resulting `conversation_text` could be very large for long sessions, and the whole string is passed to `_request_summary` as a single payload

**File:** `llo-core/context_manager/context_engine.py` — `compress()`

```python
conversation_text = "\n\n".join(conversation_lines)
new_summary = await self._request_summary(conversation_text, ...)
```

`delta_turns` is everything from `session.summary_up_to_turn` to `split_idx`. For a session that has never been compressed, this could be hundreds of turns. The entire text is sent as the `user` message to the summarizer. If `conversation_text` exceeds `llama-server`'s context limit, the request fails (HTTP 400 or truncation). This is especially likely when `http_client` is passed — the shared client has a 600-second timeout but llama-server may reject the oversized payload immediately.

**Fix:** Pre-chunk `delta_turns` if the estimated token count exceeds `summary_max_tokens * 2`:
```python
max_input_tokens = self.summary_max_tokens * 8  # generous budget for summarizer input
if self.tokenizer_cache.count_tokens(conversation_text, model_alias) > max_input_tokens:
    # Take only the latest portion that fits
    lines = conversation_lines[-(max_input_tokens // 20):]
    conversation_text = "\n\n".join(lines)
```

---

### CM-07 🟡 `test_needs_compression.py` and `test_token_counting.py` still contain a `sys.path` import line that is now just a blank `import sys` + blank `from pathlib import Path` without the `sys.path.insert` — dead imports remain

**Files:** `llo-core/context_manager/tests/test_needs_compression.py`, `test_token_counting.py`

After removing the `sys.path.insert` call, `import sys` and `from pathlib import Path` are no longer used but remain at the top of the files. These trigger `F401` unused import warnings in flake8/ruff and add noise.

**Fix:** Remove the unused `import sys` and `from pathlib import Path` lines from both files.

---

### CM-08 🟡 `ContextManagerConfig.tokenizer_repo` is defined in `config.py` but never read in `proxy.py` or `context_engine.py` — the override mechanism for custom tokenizer repos is wired in config but disconnected from actual use

**File:** `llo-core/context_manager/config.py`, `proxy.py`, `context_engine.py`

```python
tokenizer_repo: str = Field(default="", description="Explicit HuggingFace tokenizer repository override")
```

`TokenizerCache.count_tokens` accepts an `override_repo` parameter. `ContextEngine.count_tokens_messages` never passes `override_repo`. The `cfg.tokenizer_repo` from config is loaded into `ContextManagerConfig` but never forwarded to any `TokenizerCache` call. Users who set `tokenizer_repo` in their config get no effect.

**Fix:** Pass `cfg.tokenizer_repo` when constructing `ContextEngine` and thread it through `count_tokens_messages`:
```python
# In ContextEngine.__init__:
self.tokenizer_repo_override: str = ""  # set externally

# In count_tokens_messages:
total += self.tokenizer_cache.count_tokens(content, model_alias, 
                                            override_repo=self.tokenizer_repo_override or None)
```

---

**BATCH 1 COMPLETE — 8 issues (2 bugs, 4 design, 2 quality). Clearing Python from memory.**

---

## BATCH 2 — PowerShell Scripts

**Fixes confirmed from v3:** `main.ps1` inference params removed from `$config` defaults block ✅. `AppConfig` in `config.rs` no longer has `cache_type_k`, `flash_attn`, `ubatch_size`, `parallel_slots`, `default_context_size` ✅. `Paths.ps1` now dot-sourced in all 7 scripts ✅. Claude Code ctx floor capped by tier ceiling (`$effectiveFloor`) ✅. Claude launch model interpolation fixed (`$m = '...'` pattern) ✅. `SetupRouter.ps1` reads `default_context_size` only from `config.overrides`, not flat config ✅. Stop-server Linux double PID bug fixed (uses `$userAppDir` from `Paths.ps1`) ✅. Performance.tsx writes all inference changes to `overrides.*` not flat keys ✅. `pendingRestart` only clears on `status === 'running'` ✅. `vramGb` now `Math.round * 10 / 10` ✅.

---

### PS-01 🟠 `main.ps1` wizard summary section (lines 621–626) still references `$config.flash_attn`, `$config.cache_type_k`, `$config.default_context_size`, `$config.ubatch_size` — all now absent from `$config`, printing empty strings

**File:** `main.ps1` lines 621–628

```powershell
Write-Host "    * Flash Attention : $($config.flash_attn)"      # → always empty
Write-Host "    * KV Cache Type   : $($config.cache_type_k)"    # → always empty
Write-Host "    * Context Size    : $($config.default_context_size) tokens"  # → always empty
Write-Host "    * UBatch Size     : $($config.ubatch_size) tokens"           # → always empty
```

These keys were correctly removed from the `$config` defaults block as part of the v3 fix. But the wizard summary display still reads them, so every wizard run shows blank values in the `[Optimizations & Performance]` section. Users cannot verify what SetupRouter will apply.

**Fix:** Replace the flat-key reads with the hardware-profiled `$inferParams`/`$hw` values that were computed in Step 2.2:
```powershell
Write-Host "    * Flash Attention : $flashAttn  (auto-tuned by SetupRouter)"
Write-Host "    * KV Cache Type   : $cacheType  (auto-tuned by SetupRouter)"
Write-Host "    * Context Size    : $defaultCtxSize tokens  (auto-tuned per model)"
Write-Host "    * UBatch Size     : $ubatchSize tokens  (auto-tuned by SetupRouter)"
Write-Host "    * Parallel Slots  : $($parallelDisplay)  (auto-tuned by SetupRouter)"
```
These local variables already hold the computed values and are still in scope at line 621.

---

### PS-02 🟠 `start-server.ps1` still reads `config.default_context_size` and `config.ubatch_size` from flat config as a fallback (lines 336–337, 369–371) — while the wizard no longer writes these, saving from the UI Performance page still writes `overrides.*` not the flat key, but `start-server.ps1`'s fallback branch can never trigger now except via manual config edit, making it dead code that silently does nothing

**File:** `script/start-server.ps1`

```powershell
} elseif ($config.ContainsKey("default_context_size") -and [int]$config.default_context_size -gt 0) {
    $finalCtxSize = [int]$config.default_context_size   # line 337 — dead code

} elseif ($config.ContainsKey("ubatch_size") -and [int]$config.ubatch_size -gt 0) {
    $finalUbatch = [int]$config.ubatch_size             # line 370 — dead code
```

These were the flat-key override paths. Since neither the wizard nor the UI writes these flat keys anymore, they will never match. However, they are not harmful to keep — a user who manually adds `"default_context_size": 65536` to their `llo-config.json` would be served by them. They should be either documented or removed to avoid confusion.

**Fix:** Add a comment marking these as legacy-compatibility paths:
```powershell
# Legacy: if user manually set default_context_size in llo-config.json
} elseif ($config.ContainsKey("default_context_size") -and ...) {
```
Or remove them entirely if manual flat-key overrides are no longer a supported workflow (the `overrides` object is the documented path).

---

### PS-03 🟠 `SetupRouter.ps1` `Get-InferenceParams` reads `config.parallel_slots` from flat config (line 303) — this key is no longer written by wizard or UI, but `SetupRouter.ps1` config defaults block still declares `parallel_slots = -1`

**File:** `llo-core/SetupRouter.ps1` lines 72 and 303

```powershell
parallel_slots  = -1   # line 72 — in SetupRouter's own $config defaults

# ...
if (-not $Overrides.ContainsKey("parallel") -and $config.ContainsKey("parallel_slots") -and [int]$config.parallel_slots -gt 0) {
    $params.parallel = [int]$config.parallel_slots   # line 303
```

`SetupRouter.ps1` initializes its own `$config` hashtable with `parallel_slots = -1`. When the loaded `llo-config.json` doesn't have `parallel_slots` (as expected from the new architecture), `$config.parallel_slots` still equals `-1` from the defaults block. The check `[int]$config.parallel_slots -gt 0` catches `-1 > 0 = False`, so the parallel upgrade is skipped — but the `parallel_slots = -1` in the defaults creates a false impression that there is a `parallel_slots` flat config key in play.

**Fix:** Remove `parallel_slots = -1` from `SetupRouter.ps1`'s own `$config` defaults block (line 72). The hardware-adaptive derivation and the `config.overrides.parallel` path already handle all legitimate cases:
```powershell
# Remove this from $config defaults in SetupRouter.ps1:
# parallel_slots  = -1
```

---

### PS-04 🟡 `main.ps1` wizard computes `$defaultCtxSize` in Step 2.2 but never stores it anywhere — the value is displayed in the summary using a stale local variable but no longer gets written to config or overrides

**File:** `main.ps1` lines 441–446

```powershell
$defaultCtxSize = 65536
if ($vramGB -gt 0) {
    if ($vramGB -le 8.0) { $defaultCtxSize = 32768 }
    elseif ($vramGB -ge 16.0) { $defaultCtxSize = 131072 }
}
```

This was the wizard's context size recommendation. Previously it was written to `$config.default_context_size`. Now that flat key is removed, `$defaultCtxSize` is computed, shown in the summary (if PS-01 fix is applied), and then discarded. The user sees a recommended value but it's not applied anywhere. SetupRouter will compute its own value independently, which may differ from what the wizard shows.

This is not a bug — SetupRouter's hardware-adaptive calculation is more accurate. But the wizard should not display a "recommended context size" that it doesn't actually apply. It creates a false expectation.

**Fix:** Either:
1. Write the wizard's recommendation to `config.overrides.ctx_size` if the user explicitly chose it (prompt them): `"Wizard recommends {$defaultCtxSize} tokens for your hardware. Set as override? (Y/N)"`
2. Or remove the context size from the wizard summary display and add a note: `"Context size: auto-tuned per model by SetupRouter (run server to see actual values)"`

---

### PS-05 🟡 `start-server.ps1` `$selectedModel` model name may contain single quotes — the shell escaping `'$($selectedModel -replace "'", "''")'` is correct for PowerShell string escaping but the resulting command string is wrapped in outer double-quote-escaped single-quotes that may fail on Windows PowerShell 5 vs pwsh 7

**File:** `script/start-server.ps1` lines 604–617

```powershell
$startupCmds = @(
    "`$m = '$($selectedModel -replace \"'\",\"''\")'"
    ...
) -join "; "
Start-Process powershell -ArgumentList "-NoExit", "-Command", "`"$startupCmds`""
```

The escaping works for `pwsh` 7 on all platforms but on Windows PowerShell 5 (`powershell.exe`), the `-Command` argument parsing has known differences with deeply nested quoting. A model name containing a backtick or dollar sign would also break this despite the apostrophe escaping.

**Fix:** Use `-EncodedCommand` with Base64 encoding, which avoids all shell quoting issues:
```powershell
$cmdBytes = [System.Text.Encoding]::Unicode.GetBytes($startupCmds)
$encodedCmd = [Convert]::ToBase64String($cmdBytes)
if ($IsWindows) {
    Start-Process powershell -ArgumentList "-NoExit", "-EncodedCommand", $encodedCmd
} else {
    Start-Process pwsh -ArgumentList "-NoExit", "-EncodedCommand", $encodedCmd
}
```

---

**BATCH 2 COMPLETE — 5 issues (2 bugs, 2 design, 1 quality). Clearing PS from memory.**

---

## BATCH 3 — Rust / Tauri Backend (`ui/src-tauri/`)

**Fixes confirmed from v3:** GGUF KV cache formula now uses correct `bytes_per_kv_elem` per quant type ✅. `kv_dim` now derived from `kv_head_count * head_size` parsed from GGUF metadata (GQA-correct) ✅. `health.rs` template warning now checks `"[WARN] Template Matching"` not generic `"WARNING"` ✅. `hardwareStore.ts` `error` field added and surfaced ✅. `App.tsx` useEffect uses `[]` with eslint-disable ✅.

---

### RS-01 🟠 `gguf.rs` `parse_gguf_file`: real GGUF files use architecture-prefixed keys (`llama.attention.head_count_kv`) but the parser only checks `llm.attention.head_count_kv` and the `.ends_with()` fallback — the `llm.` prefix does not exist in any real GGUF file

**File:** `ui/src-tauri/src/commands/gguf.rs` lines 139, 150

```rust
} else if (key == "llm.attention.head_count_kv" || key.ends_with(".attention.head_count_kv")) && ...
} else if (key == "llm.rope.dimension_count" || key.ends_with(".rope.dimension_count")) && ...
```

Real GGUF files use the model architecture as the prefix: `llama.attention.head_count_kv`, `qwen2.attention.head_count_kv`, `phi3.rope.dimension_count`, etc. The `.ends_with(".attention.head_count_kv")` fallback does correctly match all of these — so `kv_head_count` is populated correctly in practice. The `key == "llm.attention.head_count_kv"` literal check is dead code (no real GGUF file uses `llm.` prefix). However, `.ends_with(".context_length")` on line 127 also applies, and `llm.context_length` is similarly a dead literal. These dead literals add confusion.

The test at line 266 writes `"llm.attention.head_count_kv"` using the dead literal, so the test validates the dead code path, not the real GGUF format. The test should use the architecture-prefixed key to validate real-world behavior:

```rust
// Test should write:
write_kv_u32(&mut f, "llama.attention.head_count_kv", 8);  // not "llm."
write_kv_u32(&mut f, "llama.rope.dimension_count", 128);
```

**Fix:** Remove the dead `llm.*` literal checks; keep only the `.ends_with()` fallbacks. Update tests to use architecture-prefixed keys:
```rust
} else if key.ends_with(".attention.head_count_kv") && (val_type == 4 || val_type == 5 || val_type == 10) {
```

---

### RS-02 🟠 `gguf.rs` `skip_gguf_value` does not handle val_type 13 — if a future GGUF metadata entry uses an unknown type, the parser will return an error and fall through to defaults, silently producing wrong KV cache estimates

**File:** `ui/src-tauri/src/commands/gguf.rs` — `skip_gguf_value()`

```rust
_ => return Err(format!("Unknown GGUF value type: {}", val_type)),
```

The GGUF spec currently defines types 0–12. If `val_type = 13` appears (possible in future spec revisions or vendor extensions), `skip_gguf_value` returns an `Err`, the inner `if skip_gguf_value(...).is_err() { break; }` breaks the KV parse loop immediately. All subsequent keys including `context_length`, `block_count`, and `kv_head_count` are skipped. The function returns with zeros, triggering all fallbacks: `context_length = 32768`, `block_count` guessed from file size, `kv_head_count = 0`. This is a silent accuracy failure that produces no error to the user.

**Fix:** Instead of erroring on unknown types, read a safe number of bytes and continue:
```rust
_ => {
    // Unknown or future GGUF type — skip safely by reading 8 bytes as a best-effort
    // (types 10-12 are 8 bytes, larger types undefined; break loop on read failure)
    let mut b = [0u8; 8];
    r.read_exact(&mut b).map_err(|e| e.to_string())?;
}
```

---

### RS-03 🟠 `health.rs` text-parsing fallback path is reached when `test-health.ps1` fails to emit valid JSON — in this case the script likely printed an error message, but the fallback silently reports most checks as "passed" because the error string doesn't contain `[FAIL]` tags

**File:** `ui/src-tauri/src/commands/health.rs`

When `test-health.ps1` emits a PowerShell runtime error (e.g. missing `llo-config.json`), the output is something like:
```
Get-Content: Cannot find path 'C:\...\llo-config.json'
```

This does not match any `[FAIL]` substring, so `PowerShell Syntax Validation`, `Config JSON Format`, and `Hardware Profile Limits` all show "passed". The user sees 4/5 checks passed when the script actually crashed. This is a diagnostic failure.

**Fix:** When JSON parsing fails, return a single error item with the raw output so the user can see what went wrong:
```rust
// After the JSON parse attempt fails:
let raw_snippet = &script_output[..script_output.len().min(600)];
return Ok(HealthReport {
    timestamp: chrono::Local::now().format("%H:%M:%S").to_string(),
    passed_count: 0,
    total_count: 1,
    items: vec![HealthItem {
        title: "Health Check Script Error".to_string(),
        description: format!("Script did not return valid JSON. Raw output:\n{}", raw_snippet),
        status: "failed".to_string(),
    }],
});
```

---

### RS-04 🟠 `hardwareStore.ts` hardware error is stored in the store `error` field but never displayed in any page — `profile` is `null` and validation is silently disabled with no visible reason

**File:** `ui/src/store/hardwareStore.ts`, `ui/src/pages/Overview.tsx`

`hardwareStore` now has `error: string | null`. When `detect_hardware` fails, `error` is set. But no page reads `useHardwareStore(state => state.error)` or renders anything for it. The Overview hardware card simply shows nothing (empty/loading state). Users whose `Profile.ps1` fails (PowerShell not found, permission error) see a blank hardware section with no explanation.

**Fix:** In `Overview.tsx`, read and display the error:
```typescript
const { profile, error: hardwareError, fetchHardware } = useHardwareStore();
// ...
{hardwareError && !profile && (
    <div className="impact-banner severity-warn">
        <span>Hardware detection failed: {hardwareError}</span>
    </div>
)}
```

---

### RS-05 🟡 `gguf.rs` `parse_gguf_file` reads up to 500 KV entries before stopping — for models with many KV entries (some models have 80–120 entries), the important architectural keys (`context_length`, `block_count`) appear early, but the 500 limit is arbitrary and opaque

**File:** `ui/src-tauri/src/commands/gguf.rs` line 113

```rust
for _ in 0..kv_count.min(500) {
```

Most GGUF files have 30–60 KV entries. The 500 limit is generous. However, there is no early exit once all 5 target keys have been found (`general.architecture`, `context_length`, `block_count`, `head_count_kv`, `rope.dimension_count`). The parser reads all 500 entries even when the needed values were found in the first 10.

**Fix:** Add early exit when all target keys are populated:
```rust
for _ in 0..kv_count.min(500) {
    // ... parse ...
    // Early exit once we have everything we need
    if context_length > 0 && block_count > 0 && kv_head_count > 0 && rope_head_size > 0 && file_type.is_some() {
        break;
    }
}
```

---

**BATCH 3 COMPLETE — 5 issues (3 bugs, 2 quality). Clearing Rust from memory.**

---
