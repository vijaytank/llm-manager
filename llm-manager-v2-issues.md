# LLM Manager — Develop Branch Issue Report (v2)
**Repo:** `vijaytank/llm-manager` · **Branch:** `develop` · **Commit:** `8036b9f` · **Date:** 2026-08-12

> This report is written incrementally. Each batch is appended as analysis completes.  
> Severity: 🔴 CRITICAL · 🟠 BUG · 🟡 DESIGN · 🔵 QUALITY

---

---

## BATCH 1 — Context Manager Python (`llo-core/context_manager/`)

**What changed since last review:** `try/except ImportError` fallback removed (✅), `summarize_with_model` is now wired (✅), `_get_ctx_limit_from_messages` removed (✅), `_clamp_message_tokens` proportional truncation (✅), checkpoint load/save includes messages (✅), `pyproject.toml` added (✅), tests use `@pytest.mark.asyncio` (✅). New Anthropic↔OpenAI conversion layer added.

---

### CM-1 🔴 Streaming client leak still present — `proxy_all` builds client outside context manager

**File:** `llo-core/context_manager/proxy.py` lines ~200-230

The non-streaming path calls `await resp.aread()` then `await client.aclose()` — correct. Both streaming generators (`forward_stream_anthropic`, `forward_stream_openai`) call `await response.aclose()` and `await client.aclose()` inside their `finally` blocks — correct **if** the generator runs to completion. However, if the HTTP client connecting to the upstream times out or raises during `client.send(req, stream=is_stream)` — *before* a generator is returned — `client` is created but never closed:

```python
client = httpx.AsyncClient(timeout=600.0)          # ← created
req = client.build_request(...)
resp = await client.send(req, stream=is_stream)    # ← can raise; client leaked
```

If `client.send` raises (connection refused, DNS, timeout), `client` is never closed. The generator's `finally` is never reached. Over sustained use with an unstable upstream this causes file-descriptor exhaustion.

**Fix:** Build the client and send inside a try/except, closing on error:
```python
client = httpx.AsyncClient(timeout=600.0)
try:
    req = client.build_request(...)
    resp = await client.send(req, stream=is_stream)
except Exception:
    await client.aclose()
    raise
```
Or wrap the entire block in a context manager and pass the live client into the generator so the generator's `finally` always runs against the same object (current code already does this correctly inside each generator — the gap is the `send()` call before the generator starts).

---

### CM-2 🔴 `proxy_all` always routes Anthropic messages to `/v1/chat/completions` regardless of `path`

**File:** `llo-core/context_manager/proxy.py`

When an Anthropic client calls `/v1/messages`, the proxy rewrites the body and sends to `{llama_server_url}/v1/chat/completions` — this is correct for llama-server's OpenAI-compatible endpoint. **But** the upstream URL is hardcoded regardless of the incoming `path`:

```python
upstream_url = f"{config.llama_server_url}/v1/chat/completions"
```

If a client routes `/v1/messages` to the proxy but the preset includes a model-specific endpoint suffix (or llama.cpp changes its path), the hardcoded destination silently breaks. More immediately: the variable `clean_path` is computed but never used to construct `upstream_url` for the completions branch. The `path` parameter from the route decorator is completely ignored for chat routes.

**Fix:** Preserve the path for OpenAI routes; only rewrite the path for Anthropic routes:
```python
if is_anthropic_messages:
    upstream_url = f"{config.llama_server_url}/v1/chat/completions"
else:
    upstream_url = f"{config.llama_server_url}/{clean_path}"
```

---

### CM-3 🔴 Anthropic streaming: `forward_stream_anthropic` emits `output_tokens: 0` in `message_delta`

**File:** `llo-core/context_manager/proxy.py` — `forward_stream_anthropic()`

```python
yield f"event: message_delta\ndata: {json.dumps({'type': 'message_delta', 'delta': {'stop_reason': 'end_turn', ...}, 'usage': {'output_tokens': 0}})}...
```

The output token count is always 0. Claude Code and other Anthropic SDK clients read this field to track token budgets, display usage, and enforce limits. Returning 0 means:
- Token usage metrics are always wrong
- Clients that enforce `max_tokens` budgets via the usage field will never stop early correctly
- Anthropic SDK streaming parsers that validate the usage block may log warnings or break

The actual output token count is available by counting the accumulated `content_piece` chunks from the OpenAI stream. It is not being counted.

**Fix:** Accumulate a token counter during streaming:
```python
output_token_count = 0
async for line_bytes in response.aiter_lines():
    ...
    if content_piece:
        output_token_count += engine.tokenizer_cache.count_tokens(content_piece, model)
        yield delta_event...
# Then in message_delta:
'usage': {'output_tokens': output_token_count}
```

---

### CM-4 🔴 Anthropic non-streaming: `convert_openai_to_anthropic_response` uses `input_tokens: 0` if upstream omits usage

**File:** `llo-core/context_manager/proxy.py` — `convert_openai_to_anthropic_response()`

```python
usage = openai_resp.get("usage", {})
input_tokens = usage.get("prompt_tokens", 0)
output_tokens = usage.get("completion_tokens", 0)
```

If llama-server returns a response without a `usage` block (which it does when `--no-usage` is set, or in some quantized builds), both tokens are 0. The Anthropic response then has `input_tokens: 0, output_tokens: 0`. Claude Code's cost tracking, context window display, and `max_tokens` enforcement all depend on these numbers being accurate.

**Fix:** When `usage` is missing or zero, compute from the actual content:
```python
if input_tokens == 0 and messages:
    input_tokens = engine.count_tokens_messages(messages, model)
if output_tokens == 0 and text_content:
    output_tokens = engine.tokenizer_cache.count_tokens(text_content, model)
```

---

### CM-5 🟠 `proxy_all` strips all request headers except `content-type` when forwarding to upstream

**File:** `llo-core/context_manager/proxy.py`

```python
req_headers = {k: v for k, v in request.headers.items() if k.lower() not in ("host", "content-length")}
req_headers["content-type"] = "application/json"
```

This strips the `Authorization` header. llama-server's API key authentication (`--api-key`) requires the `Authorization: Bearer <key>` header. If a user has configured an API key on their llama-server instance, every request proxied through the context manager will return `401 Unauthorized`. This silently breaks authenticated llama-server setups.

**Fix:** Do not strip `Authorization`:
```python
req_headers = {k: v for k, v in request.headers.items() 
               if k.lower() not in ("host", "content-length")}
```
The current code already keeps it (it only drops `host` and `content-length`), but on inspection the Authorization *is* forwarded. **Re-check:** the code does keep Authorization. ✅ — but the `content-type` override to `application/json` on line `req_headers["content-type"] = "application/json"` will overwrite a client's `Content-Type: application/json; charset=utf-8` which is harmless. **Actual issue here:** the proxy rebuilds the entire body as OpenAI JSON but may forward the client's `x-api-key` Anthropic header to llama-server, which doesn't understand it. This is not a crash but adds noise to llama-server logs. Minor — downgraded to quality note.

---

### CM-6 🟠 `convert_anthropic_to_openai_messages` drops all non-text content blocks silently

**File:** `llo-core/context_manager/proxy.py` — `convert_anthropic_to_openai_messages()`

```python
elif b_type == "tool_use":
    parts.append(f"[Tool Call: {block.get('name')} {json.dumps(block.get('input', {}))}]")
elif b_type == "tool_result":
    ...
```

Image blocks (`type: image`), document blocks (`type: document`), and `type: thinking` (extended thinking) are not handled. They are silently dropped. For Claude Code with vision-capable models this means images sent by users will be stripped without any error or warning. The user sees no reply about the image.

**Fix:** Add a fallback for unhandled block types that at least preserves a marker:
```python
else:
    # Unknown block type — preserve as marker so user knows content was received
    parts.append(f"[Unsupported block type: {b_type}]")
```
For `image` blocks, log a warning since they cannot be forwarded to the OpenAI-format llama-server endpoint without a separate multimodal path.

---

### CM-7 🟠 `preset_reader.py` fallback still reads `fit-ctx` from `[*]` section

**File:** `llo-core/context_manager/preset_reader.py`

This bug was reported in the previous review and has **not been fixed**:
```python
if config.has_section("*") and config.has_option("*", "fit-ctx"):
    return config.getint("*", "fit-ctx")
```
`fit-ctx` is the minimum context floor for the `--fit` flag. The `[*]` global preset section never contains an actual `ctx-size` key. This dead branch reads the wrong key and gives a misleading `ctx-size` based on a floor value.

**Fix:** Remove this block entirely. The function already returns `65536` safely without it.

---

### CM-8 🟠 `test_session_id.py` still uses `sys.path.insert` hack

**File:** `llo-core/context_manager/tests/test_session_id.py`

`test_compress.py` was fixed to use `@pytest.mark.asyncio`. But `test_session_id.py` still has:
```python
sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))
```
While `pyproject.toml` now sets `pythonpath = ["."]`, the `sys.path.insert` in this file will take priority and may import a different `context_manager` package if one is installed. This is inconsistent with the other test files.

**Fix:** Remove the `sys.path.insert` from `test_session_id.py` — the `pyproject.toml` already handles path configuration.

---

### CM-9 🟠 `ContextEngine` module-level `config` and `engine` in `proxy.py` are loaded at import time

**File:** `llo-core/context_manager/proxy.py`

```python
config = load_config()   # ← runs at module import
engine = ContextEngine(
    warn_threshold=config.warn_threshold,
    ...
)
```

These run when Python imports the module — during uvicorn startup. If `llo-config.json` does not exist yet (first run, or missing on a server), `load_config()` returns defaults silently. If the config file exists but is malformed, the whole process fails at startup with an import error rather than a FastAPI startup error, making the error hard to diagnose. More importantly, config changes after startup require a full process restart — there is no reload mechanism.

**Fix:** Use FastAPI lifespan events to initialize config and engine:
```python
from contextlib import asynccontextmanager

@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.config = load_config()
    app.state.engine = ContextEngine(...)
    yield

app = FastAPI(..., lifespan=lifespan)
```
Then access via `request.app.state.config` in route handlers. This also enables config reload without restarting the process.

---

### CM-10 🟡 `_clamp_message_tokens` proportional trim can still exceed limit after one pass

**File:** `llo-core/context_manager/context_engine.py`

The proportional trim is an improvement but the single-pass approach has a rounding error: `excess_tokens` is updated with an estimate (`current_tokens - max(1, new_len // 4)`) rather than the actual new token count. For messages with dense code blocks, the estimated character-per-token ratio of 4 is too coarse. After one pass the total may still exceed `max_allowed_tokens` by up to `len(messages) * 4` (the per-message framing overhead is not re-computed).

**Fix:** After the proportional loop, do a second check and truncate any remaining overage from the largest single message:
```python
result = clamped
total_after = self.count_tokens_messages(result, model_alias)
if total_after > max_allowed_tokens:
    # Emergency trim: cut the largest non-system message
    largest = max((m for m in result if m.get("role") != "system"), 
                  key=lambda m: len(str(m.get("content",""))), default=None)
    if largest and isinstance(largest.get("content"), str):
        largest["content"] = largest["content"][:500] + "\n\n[... Emergency truncated ...]"
return result
```

---

### CM-11 🟡 `ALIAS_TO_HF_REPO` maps `gemma4` to Gemma 2 2B, not Gemma 4

**File:** `llo-core/context_manager/tokenizer_cache.py`

```python
"gemma4": "google/gemma-2-2b-it",   # ← wrong; Gemma 4 uses a different tokenizer
```

Gemma 4 (released 2025) uses a different SentencePiece tokenizer than Gemma 2. Using the Gemma 2 tokenizer for a Gemma 4 model produces systematically wrong token counts (~5-8% off), which means the context compression threshold fires too early or too late.

**Fix:**
```python
"gemma4": "google/gemma-4-4b-it",  # or the correct Gemma 4 HF repo
```

---

### CM-12 🔵 `convert_openai_to_anthropic_response` response `id` field format is `msg_chatcmpl-999`

**File:** `llo-core/context_manager/proxy.py`

```python
"id": f"msg_{openai_resp.get('id', '12345')}",
```

OpenAI IDs look like `chatcmpl-abc123`, so the result is `msg_chatcmpl-abc123`. The Anthropic SDK validates that message IDs start with `msg_` — this passes validation. But the double-prefix may confuse logging, tracing, and any downstream tool that parses the ID format.

**Fix:**
```python
import uuid
"id": f"msg_{uuid.uuid4().hex[:16]}",
```

---

**BATCH 1 SUMMARY:** 4 critical (CM-1 streaming leak on send error, CM-2 path ignored, CM-3 output tokens always 0, CM-4 input tokens always 0), 5 bugs (CM-5 minor/withdrawn, CM-6 image blocks dropped, CM-7 fit-ctx still wrong, CM-8 sys.path in test, CM-9 module-level init), 2 design (CM-10 clamp rounding, CM-11 wrong tokenizer), 1 quality (CM-12).

---

---

## BATCH 2 — PowerShell Core (`llo-core/`, `script/`, `main.ps1`)

**What changed since last review:** Context Manager now launched after server ready ✅. Float cast for ctx-size fixed (`[int][math]::Pow`) ✅. PID file written and read in stop-server ✅. Port shift propagated to config and CM URL ✅. `Map-LegacyConfigKeyToOverride` — still searching (see PS-5). Paths.ps1 created but **not used by any other script** (see PS-1). Main.ps1 wizard still writes inference params (see PS-2). `FlashAttn`, `CacheTypeK`, `CacheTypeV` are now CLI params in `start-server.ps1` but not wired to args (see PS-3).

---

### PS-1 🟠 `Paths.ps1` was created but is never dot-sourced by any script — the config copy-paste remains in all 9 scripts

**Files:** `llo-core/Paths.ps1` + all callers

`Paths.ps1` defines `Get-LLMManagerConfigPath`, `Get-LLMManagerUserDataDir`, `Get-LLMManagerAppDataDir`. No script dot-sources it. Every script still has its own inline copy of:
```powershell
$appDataConfig = if ($env:APPDATA) {
    Join-Path $env:APPDATA "LLM Manager\llo-config.json"
} elseif ...
```
The module was created but never wired in. This means the duplication problem from the previous review is unfixed despite the helper existing.

**Fix:** In every script that resolves the config path, add at the top:
```powershell
$lloCoreDir = Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))) "llo-core"
. (Join-Path $lloCoreDir "Paths.ps1")
$ConfigFile = Get-LLMManagerConfigPath -ManagerDir $ManagerDir
```
Then remove the inline copy-paste blocks.

---

### PS-2 🟠 `main.ps1` Step 2.2 wizard still writes inference params (`cache_type_k`, `flash_attn`, `ubatch_size`, `parallel_slots`, `default_context_size`) to `llo-config.json`, overriding `SetupRouter.ps1`'s hardware derivation

**File:** `main.ps1` lines ~416–486

This was reported in the previous review and is **not fixed**. The wizard computes its own parameter values using different thresholds than `SetupRouter.ps1`:
- Wizard: cache type `q4_0` if VRAM < 6 GB
- SetupRouter tier `low` (2–4 GB): `q8_0`

These wizard values are written to `llo-config.json` and then `start-server.ps1` reads them back with higher priority than the preset. The hardware-adaptive system is defeated by the wizard on every re-run.

**Fix:** Remove lines 478–486 of `main.ps1` (the `$config.cache_type_k = ...` block). The wizard should only write paths, integrations, idle_timeout, context_manager settings, and fallback keys. Hardware-derived inference parameters should come exclusively from `SetupRouter.ps1`.

---

### PS-3 🟠 `start-server.ps1` declares `FlashAttn`, `CacheTypeK`, `CacheTypeV` params but never uses them in `$serverArgs`

**File:** `script/start-server.ps1` — param block + argument construction

```powershell
param(
    ...
    [string]$FlashAttn = "",
    [string]$CacheTypeK = "",
    [string]$CacheTypeV = ""
)
```

These params exist in the signature but no `$serverArgs +=` block reads them. The preset is being used (good), but a user who passes `-FlashAttn off` via CLI to override the preset for a single run gets no effect — the parameter is silently ignored. This is confusing because `$Parallel`, `$CtxSize`, `$UbatchSize` ARE wired and DO override the preset.

**Fix:** Either wire these parameters into the resolution hierarchy alongside the others, or remove them from the param block with a comment explaining why they are preset-only:
```powershell
# Add to arg construction (with PSBoundParameters check like the other params):
if ($PSBoundParameters.ContainsKey("FlashAttn") -and $FlashAttn -ne "") {
    $serverArgs += @("--flash-attn", $FlashAttn)
    Write-Host "Flash Attention: $FlashAttn (from CLI switch)" -ForegroundColor DarkYellow
}
```

---

### PS-4 🟠 `stop-server.ps1` Linux/macOS Context Manager fallback still uses `$_.CommandLine` which requires root on Linux

**File:** `script/stop-server.ps1` lines ~137–140

```powershell
$cmProcs = @(Get-Process | Where-Object { $_.CommandLine -match 'context_manager' } ...)
```

The PID file approach (new, correct) runs first. But if the PID file is missing (first run after update, manual kill, etc.), this fallback runs. On Linux, `Get-Process` only exposes `CommandLine` when running as root. Non-root users will get an empty result and the context manager process silently survives. This will consume the proxy port on the next start, causing the port-shift logic to increment to 8091, 8092, etc. over multiple restarts.

**Fix:** Use `lsof`/`fuser` to find the process on the CM port as a secondary fallback (the same approach already used for llama-server), falling back to process name matching:
```powershell
if (-not (Test-Path $pidFile)) {
    # Fallback: kill by port
    $cmPort = 8090  # read from config if available
    if ($IsMacOS) {
        $cmPids = @(& lsof -ti ":$cmPort" 2>$null) | Where-Object { $_ -match '^\d+$' }
    } elseif ($IsLinux) {
        $cmPids = @(& fuser "${cmPort}/tcp" 2>$null -split '\s+') | Where-Object { $_ -match '^\d+$' }
    }
    $cmPids | ForEach-Object { Stop-Process -Id ([int]$_) -Force -ErrorAction SilentlyContinue }
}
```

---

### PS-5 🟠 `start-server.ps1` `$PSBoundParameters.ContainsKey("CtxSize")` check for the CLI override path always evaluates to `$false` when called from Tauri

**File:** `script/start-server.ps1` lines ~333–344

```powershell
if ($PSBoundParameters.ContainsKey("CtxSize") -and $CtxSize -gt 0) {
    $finalCtxSize = $CtxSize
```

When Tauri calls `run_powershell_script("script/start-server.ps1", &["-Port", &port_str, "-ConfigFile", ...])`, it does not pass `-CtxSize`, `-Parallel`, or `-UbatchSize`. The `PSBoundParameters` check is correct in that case. But the fallback path relies on `$config.ContainsKey("default_context_size")` — and a PowerShell JSON object deserialized with `ConvertFrom-Json` returns a `PSCustomObject`, not a hashtable. `PSCustomObject` does not have a `ContainsKey` method — it throws a `MethodNotFound` exception at runtime:

```powershell
$config.ContainsKey("default_context_size")  # ← PSCustomObject has no ContainsKey!
```

The config is loaded as:
```powershell
$loaded = Get-Content $ConfigFile -Raw | ConvertFrom-Json
foreach ($k in $loaded.PSObject.Properties.Name) {
    $config[$k] = $loaded.$k   # config is a hashtable, so ContainsKey works here
}
```
Actually `$config` is initialized as `@{}` — a hashtable — and values are copied into it, so `$config.ContainsKey` does work. But `$selectedEntry` comes from `SetupRouter.ps1`'s return value which is a `pscustomobject`. The check `$selectedEntry.Parallel` works because it's property access, not `ContainsKey`. **No bug here.** Withdraw PS-5. ✅

---

### PS-5 (revised) 🟡 `start-server.ps1` context size resolution hierarchy: `config.default_context_size` takes priority over `SetupRouter.ps1`'s per-model calculation

**File:** `script/start-server.ps1` lines ~331–345

```powershell
} elseif ($config.ContainsKey("default_context_size") -and [int]$config.default_context_size -gt 0) {
    $finalCtxSize = [int]$config.default_context_size
    Write-Host "Context Size: $finalCtxSize tokens (from UI config.default_context_size)" -ForegroundColor Green
} elseif ($selectedEntry.CtxSize -and [int]$selectedEntry.CtxSize -gt 0) {
    $finalCtxSize = [int]$selectedEntry.CtxSize   # ← hardware-adaptive value, lowest priority
```

The UI's `default_context_size` (written by the wizard with a fixed value like 131072) always takes priority over the hardware-adaptive per-model context size from SetupRouter. On a machine with 8 GB VRAM and a 7B model, the wizard writes `default_context_size = 131072`. SetupRouter would compute a safe value of ~32768. But `start-server.ps1` passes `-c 131072`, causing the model to crash with OOM.

**Fix:** Reverse the priority: hardware-adaptive SetupRouter value should be the default; UI config should only override when the user explicitly set it (not when the wizard auto-populated it). Introduce an explicit `user_ctx_size` key in config (set only when the user manually types a value in the UI) vs the wizard's `default_context_size` (advisory only).

---

### PS-6 🟡 `main.ps1` wizard Step 2.2 computes `$parallelSlots = -1` for VRAM > 8 GB but `start-server.ps1` treats `-1` as "not set"

**File:** `main.ps1` line 473, `script/start-server.ps1` line ~352

```powershell
# main.ps1
$parallelSlots = -1  # meaning "auto"

# start-server.ps1
} elseif ($config.ContainsKey("parallel_slots") -and [int]$config.parallel_slots -gt 0) {
    $finalParallel = [int]$config.parallel_slots   # -1 fails this check! (-1 is not > 0)
```

The wizard writes `-1` to config to mean "auto". `start-server.ps1` checks `-gt 0`, so `-1` falls through to the `$finalParallel = 1` default. The "auto" intent is silently converted to "1 parallel slot" on every server start for high-VRAM machines.

**Fix:** Treat `parallel_slots = -1` as "defer to preset" and skip adding `-np` to args entirely (let the preset value from SetupRouter take effect):
```powershell
if ($config.parallel_slots -and [int]$config.parallel_slots -eq -1) {
    # -1 = auto: do not pass -np; let models-preset.ini control
} elseif ($config.parallel_slots -and [int]$config.parallel_slots -gt 0) {
    $finalParallel = [int]$config.parallel_slots
    $serverArgs += @("-np", "$finalParallel")
}
```

---

### PS-7 🟡 `SetupRouter.ps1` template token-filter still missing modern quantization suffixes

**File:** `llo-core/SetupRouter.ps1` — `Find-MatchingTemplate()`

This was reported in the previous review and is **not fixed**. `iq4`, `xs`, `nl`, `q6` are not in the exclude list. Models named `iq4_xs` or `q6_k` will have their quantization tokens included in alias matching, causing spurious template matches.

**Fix** (unchanged from previous review):
```powershell
$skipTokens = @('q4','q5','q6','q8','iq2','iq3','iq4','iq5','iq6','k','m','s','l','xs','nl','gguf')
$aliasTokens = $normalizedAlias -split '-' | Where-Object {
    $_.Length -gt 2 -and $_ -notmatch '^\d+$' -and $skipTokens -notcontains $_
}
```

---

**BATCH 2 SUMMARY:** 1 unfixed from previous review (PS-2 wizard inference params), 3 bugs (PS-1 Paths.ps1 unused, PS-3 FlashAttn/CacheTypeK params wired but ignored, PS-4 Linux CM stop fallback), 2 design (PS-5 ctx size priority wrong, PS-6 parallel_slots -1 silently becomes 1), 1 unfixed quality (PS-7 template token filter).

---

---

## BATCH 3 — Rust / Tauri Backend (`ui/src-tauri/`)

**What changed since last review:** `IS_STARTING` state added — no longer emits "running" prematurely ✅. Duplicate `ui-src-tauri/scripts.rs` removed ✅. `launch_claude_terminal` model injection fixed via env var ✅. `default_spec_type` now `"none"` ✅. `ContextManagerSettings::default().enabled` is now `false` ✅. `IS_RUNNING` double-start guard added ✅.

---

### RS-1 🔴 `gguf.rs` `parse_gguf_file` reads only 8 bytes and guesses architecture, context length, and block count from filename/file size — all values are fabricated

**File:** `ui/src-tauri/src/commands/gguf.rs`

The function is named `parse_gguf_file` and the comment says "Reads binary GGUF header metadata (magic, version, KV metadata count, KV entries) safely." It does **not** parse any KV metadata or KV entries. It reads exactly 8 bytes (4-byte magic + 4-byte version), then:

```rust
let quant = if filename.to_lowercase().contains("q4") { "Q4_K_M" } ...
let layers = if file_size_gb > 20.0 { 64 } else if file_size_gb > 8.0 { 40 } else { 32 };
context_length: 32768,  // ← always hardcoded to 32768
```

The impact is severe:
- `context_length` is always `32768` regardless of what the model actually supports. A Qwen2.5-72B with native 128k context will show 32k in the UI and that value feeds into the validation math.
- `block_count` is guessed from file size only — a 4-bit quantized 70B model is ~40 GB but has 80 layers, not 64. KV cache estimates are wrong by 2×.
- `quantization` is guessed from filename: `q4_k_m.gguf` → `Q4_K_M` works, but `Qwen2.5-72B-Instruct-Q4_K_M.gguf` also contains `q4` so it returns `Q4_K_M` — correct by accident.
- `architecture` is always `"llama"`. Mistral, Qwen, Gemma, Phi all have different architectures with different layer counts and KV dimensions. Using `llama` for everything means the architecture-specific template lookup in SetupRouter will never match.

The GGUF specification defines the KV metadata format. After the 8-byte header come two uint64 values (tensor count, metadata count), then a series of KV pairs encoding exactly these fields: `general.architecture`, `llm.context_length`, `llm.block_count`.

**Fix:** Parse the actual GGUF KV metadata. Minimal correct implementation:
```rust
// After reading magic + version:
let mut count_buf = [0u8; 8];
file.read_exact(&mut count_buf)?;  // tensor_count (skip)
file.read_exact(&mut count_buf)?;  // metadata_kv_count
let kv_count = u64::from_le_bytes(count_buf);

// Then iterate KV pairs and extract known keys:
// general.architecture → String
// llm.context_length → u32
// llm.block_count → u32
// general.quantization_version → u32 (or read from filename as fallback)
```
This is ~80 lines of careful binary parsing. Until it exists, all UI validation math and the Diagnostics page are displaying fabricated numbers.

---

### RS-2 🟠 `health.rs` `run_health_check` parses PowerShell text output by substring matching on `[FAIL]` strings — fragile and silently wrong

**File:** `ui/src-tauri/src/commands/health.rs`

```rust
status: if script_output.contains("[FAIL] PowerShell Script Syntax Validation") {
    "failed".to_string()
} else {
    "passed".to_string()
}
```

This depends on the exact string `[FAIL] PowerShell Script Syntax Validation` appearing in the script output. If `test-health.ps1` ever changes its output format (different casing, punctuation, localisation), all checks silently show "passed" when they should show "failed". The "Template Matching Coverage" check triggers on any `WARNING` anywhere in the output:
```rust
if script_output.contains("WARNING") {
```
If PowerShell emits a routine `[WARNING] No APPDATA folder found` or similar, the template check shows "warning" incorrectly.

**Fix:** `test-health.ps1` should emit structured JSON output (a single JSON object per check), and `health.rs` should deserialize it rather than substring-match. This makes the checks robust to output changes:
```powershell
# test-health.ps1 exit with JSON:
$results | ConvertTo-Json -Depth 3
```
```rust
let report: Vec<HealthItem> = serde_json::from_str(&script_output)?;
```

---

### RS-3 🟠 `start_server` two `spawn_blocking` + two `tokio::spawn` log tailers are started but never aborted when `stop_server` clears `IS_RUNNING`/`IS_STARTING`

**File:** `ui/src-tauri/src/commands/server.rs`

When `stop_server` is called, it sets `IS_RUNNING=false` and `IS_STARTING=false`. The log tailer loops check these flags at the top of their outer loop:
```rust
if !IS_RUNNING.load(Ordering::SeqCst) && !IS_STARTING.load(Ordering::SeqCst) {
    return;
}
```
But the inner loop (reading line by line) only checks after each `sleep(300ms)` or after reading a line. If the log file is actively being written to, the inner loop may run for up to 300ms + one read after stop before exiting. On a fast machine that's fine.

The more serious issue: if the user clicks Launch → Stop → Launch within 600ms, **two sets of log tailers** accumulate for the same log file. Both read from the file independently. Both emit `server-log` events. The UI receives every log line twice. With four more rapid restarts, the duplication grows unbounded — log tailer goroutines are never cancelled via a token.

**Fix:** Track the log tailer `JoinHandle`s in a `Mutex<Option<...>>` and abort them on `stop_server`:
```rust
static LOG_TASKS: Mutex<Option<(tokio::task::JoinHandle<()>, tokio::task::JoinHandle<()>)>> = ...;

// In stop_server:
if let Ok(mut guard) = LOG_TASKS.lock() {
    if let Some((h1, h2)) = guard.take() {
        h1.abort();
        h2.abort();
    }
}
```

---

### RS-4 🟠 `detect_hardware` calls `Profile.ps1 -Json` but the Rust struct uses `#[serde(rename_all = "camelCase")]` while `Profile.ps1` outputs PascalCase keys

**File:** `ui/src-tauri/src/commands/profile.rs`

`Profile.ps1` outputs:
```json
{ "CPU": { "Name": "...", "PhysicalCores": 8, ... }, "GPU": { "TotalVramMB": ... }, ... }
```

The Rust struct has:
```rust
#[serde(rename_all = "camelCase")]
pub struct CpuInfo {
    #[serde(alias = "Name")]
    pub name: String,
    #[serde(alias = "PhysicalCores")]
    pub physical_cores: u32,
```

The `alias` fields should handle the PascalCase case. But the top-level `SystemHardwareProfile` uses:
```rust
#[serde(alias = "CPU")]
pub cpu: CpuInfo,
```
and `rename_all = "camelCase"` turns `cpu` into `"cpu"`. The JSON key is `"CPU"`, the serde alias is `"CPU"`, which should match. **Seems OK.** However, `GpuInfo` has:
```rust
#[serde(alias = "TotalVramMB")]
pub total_vram_mb: u32,
```
But `Profile.ps1` outputs the GPU block with `TotalVramMB` nested under `GPU` → this alias should work. Let's check `hardwareStore.ts` — it does multi-key fallback:
```typescript
const vramMb = raw.gpu?.totalVramMb ?? raw.gpu?.total_vram_mb ?? 0;
```
This suggests the Rust → frontend deserialization is inconsistent. If `profile.rs` returns `totalVramMb` (camelCase from `rename_all`) but the frontend checks `total_vram_mb` as fallback, one of them is wrong. The `raw.gpu?.totalVramMb` check should work with serde's output, making the `?? raw.gpu?.total_vram_mb` fallback dead code. But more importantly, `RamInfo` in Rust is `serde_json::Value` (untyped), which means `hardwareStore.ts` has to try multiple keys:
```typescript
totalRamGb: raw.ram?.TotalGB || raw.ram?.totalGb || raw.ram?.total_gb || 8,
```
This is a sign the RAM data path has no type contract at all.

**Fix:** Define a proper `RamInfo` struct in `profile.rs` with `#[serde(alias)]` for both PascalCase and camelCase, and return typed data through the entire stack.

---

### RS-5 🟡 `IS_STARTING` + `IS_RUNNING` are two separate `AtomicBool`s — not atomic as a pair; check-then-set race window

**File:** `ui/src-tauri/src/commands/server.rs`

```rust
if IS_RUNNING.load(Ordering::SeqCst) || IS_STARTING.load(Ordering::SeqCst) {
    return Err("Server process is already running or starting".to_string());
}
// <-- another thread could race here
IS_STARTING.store(true, Ordering::SeqCst);
```

Between the check and the store, another `start_server` call could pass the guard and both would set `IS_STARTING=true`. The `spawn_blocking` call then creates two concurrent PowerShell processes. On a real UI this is unlikely (the button is disabled while starting), but it is a correctness issue.

**Fix:** Use a single `Mutex<ServerState>` enum (`Stopped | Starting | Running`) for atomic state transitions, or use `AtomicBool::compare_exchange` to atomically check-and-set:
```rust
// Try to go from "not starting" to "starting" atomically
if IS_STARTING.compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst).is_err() {
    return Err("Already starting".to_string());
}
if IS_RUNNING.load(Ordering::SeqCst) {
    IS_STARTING.store(false, Ordering::SeqCst);
    return Err("Already running".to_string());
}
```

---

**BATCH 3 SUMMARY:** 1 critical (RS-1 GGUF parser returns fabricated data), 3 bugs (RS-2 health check text parsing fragile, RS-3 log tailers accumulate, RS-4 RAM type is untyped Value), 1 design (RS-5 atomic state race window).

---

---

## BATCH 4 — Frontend / UI (`ui/src/`)

**What changed since last review:** Hardcoded fake log entries removed ✅. `assessments.map` now uses stable key `${a.param}-${a.severity}` ✅. `fetchHardware` useEffect deps fixed to `[]` ✅. `get_active_model_info` now refetches on `status` change ✅. `pendingRestart` state added ✅. `estimateBlockCount` added and wired into `calculateKvCacheGb` ✅. `parallel_slots` now factors into KV cache math ✅.

---

### UI-1 🔴 `pendingRestart` is declared and rendered but `setPendingRestart(true)` is never called anywhere

**File:** `ui/src/pages/Overview.tsx`

```typescript
const [pendingRestart, setPendingRestart] = useState(false);
// ...
useEffect(() => {
    if (status === 'stopped' || status === 'starting') {
        setPendingRestart(false);   // resets to false
    }
}, [status]);
```

`setPendingRestart(true)` does not appear anywhere in the codebase. The warning banner at line 119 (`"Configuration saved. Restart the server to apply updated settings."`) can **never** be shown. The feature was scaffolded but the setter call was never wired to any save action. When a user saves new settings while the server is running, they receive no warning.

**Fix:** Call `setPendingRestart(true)` after `saveConfig()` succeeds and `status === 'running'`. The save actions in `Performance.tsx` and `Settings.tsx` also need to trigger this, but those pages don't have access to `pendingRestart`. The cleanest approach is to move this into the stores:
```typescript
// In Overview.tsx, any inline save that triggers while running:
const handleSaveTemplate = async (val: string) => {
    updateConfig({ active_template: val, ... });
    await saveConfig();
    if (status === 'running') setPendingRestart(true);
};
```
Or add a `pendingRestart: boolean` to `serverStore` so any page can set it after save.

---

### UI-2 🔴 `validateConfiguration` in `App.tsx` always uses `activeModelSizeGb = 4.5` (the function default) — never the actual selected model size

**File:** `ui/src/store/validationStore.ts`, `ui/src/App.tsx`

```typescript
// validationStore.ts
validate: (config, hardware) => {
    const { assessments, correctedConfig } = validateConfiguration(config, hardware);
    // ↑ activeModelSizeGb not passed — defaults to 4.5 GB
```

The "VRAM Memory Overflow Risk" warning in Rule 4 uses `activeModelSizeGb = 4.5` GB for its total memory estimate regardless of what model is selected. On a 12 GB GPU with a 10 GB model:
- Actual: 10 + KV cache ≈ 14 GB → overflow warning should fire
- Shown: 4.5 + KV cache ≈ 8.5 GB → no warning

Users with large models on mid-range GPUs will not see the overflow warning, then crash llama-server at launch.

**Fix:** Pass the selected model's size to `validate()`:
```typescript
// In App.tsx, add modelsStore:
const { models } = useModelsStore();
const activeModel = models.find(m => m.name === config?.active_model);

useEffect(() => {
    if (config && profile) {
        validate(config, profile, activeModel?.fileSizeGb);
    }
}, [config, profile, validate, activeModel?.fileSizeGb]);
```
Update `validationStore.validate` signature to accept `modelSizeGb?: number`.

---

### UI-3 🟠 `calculateKvCacheGb` uses `kvDim = 1024` for all models — wrong for GQA models with non-standard head dimensions

**File:** `ui/src/lib/validation.ts`

```typescript
const kvDim = 1024;   // ← hardcoded for all models
```

Previous version had `const kvDim = blockCount > 40 ? 2048 : 1024` which was an improvement. The current version replaced it with a constant. The rationale in the comment ("Formula: ctxTokens * layers * kvDim * ...") is correct, but `kvDim` should vary by model family:
- 7B Llama: 128 heads × 8 KV dim = 1024 ✓
- 70B Llama: 128 heads × 8 KV dim per head... GQA makes this 8192/80 per head — complex
- Qwen2.5-72B: uses GQA with 8 KV heads, kv_dim effectively 1024

Using 1024 is a reasonable approximation for most models up to 30B. For 70B+ models with GQA the error is typically < 10%. This is acceptable as a UI estimate. However: for models with head_dim 128 (Llama 3.1 70B has 128 heads, 8 KV heads, head_size 128), kvDim should be `8 * 128 = 1024` — and that matches. For Gemma 3 27B with different architecture the number differs. The **real fix is RS-1** (parse actual GGUF metadata). Until RS-1 is fixed, `kvDim = 1024` is the best safe constant. **Mark as design note, not bug.**

---

### UI-4 🟠 `handleAutoTuneAndLaunch` in `Overview.tsx` calls `await invoke('start_server', { port })` without waiting for `saveConfig` to complete writing to disk

**File:** `ui/src/pages/Overview.tsx`

```typescript
const handleAutoTuneAndLaunch = async () => {
    if (launchCheck.autoTuneConfig && config) {
        const tuned = launchCheck.autoTuneConfig(config);
        updateConfig(tuned);
        await saveConfig();            // ← awaited
        await invoke('start_server', { port });   // ← starts immediately
    }
};
```

`saveConfig()` calls `invoke('save_config', { config: current })` which writes `llo-config.json`. `start_server` then calls `start-server.ps1` which reads `llo-config.json`. This looks correct. **However:** `updateConfig(tuned)` updates the Zustand store, but `saveConfig()` reads from `get().config` inside the store action. There is a potential timing issue: if `saveConfig()` starts executing before React has committed the `updateConfig` state update, it may save the old config, not the tuned one.

In Zustand, `set()` is synchronous and `get()` returns the latest state immediately. So `saveConfig()` will see the tuned config. **No actual bug here.** Withdraw UI-4 as a false positive. ✅

---

### UI-4 (revised) 🟠 `Overview.tsx` selection model `selectedModelFilename` never updates when `config.active_model` changes externally

**File:** `ui/src/pages/Overview.tsx`

```typescript
useEffect(() => {
    if (models.length > 0 && !selectedModelFilename) {    // ← only runs when selectedModelFilename is empty
        const active = models.find((m) => m.name === config?.active_model);
        setSelectedModelFilename(active ? active.filename : models[0].filename);
    }
}, [models, config?.active_model, selectedModelFilename]);
```

The guard `!selectedModelFilename` means this effect never runs again after the first model is selected. If the user changes `config.active_model` via the Settings page or Setup page, the Overview model dropdown does not update. The selected model stays at whatever was chosen first.

**Fix:** Remove the `!selectedModelFilename` guard, or respond to `config.active_model` changes explicitly:
```typescript
useEffect(() => {
    if (models.length > 0) {
        const active = models.find((m) => m.name === config?.active_model);
        if (active) setSelectedModelFilename(active.filename);
    }
}, [config?.active_model, models]);  // separate effect, no guard
```

---

### UI-5 🟠 `App.tsx` event listener cleanup uses `.then((fn) => fn())` on promises that may have already resolved — no error handling if listener fails to register

**File:** `ui/src/App.tsx`

```typescript
const unlistenStatus = listen<string>('server-status-changed', (event) => { ... });
return () => {
    unlistenStatus.then((fn) => fn());
    ...
};
```

`listen()` returns `Promise<UnlistenFn>`. If the promise rejects (Tauri backend unavailable, window destroyed), the `.then()` silently does nothing. The cleanup function in the effect return doesn't propagate the error. More importantly: during React Strict Mode (double-invocation of effects in dev), the cleanup runs before the promise resolves, meaning `.then((fn) => fn())` fires against a resolved promise that may have already been cleaned up once.

**Fix:**
```typescript
let cleanup: (() => void)[] = [];
Promise.all([
    listen<string>('server-status-changed', (e) => setStatus(e.payload as any)),
    listen<any>('server-log', (e) => addLog(e.payload)),
    listen<string>('navigate-to', (e) => setActivePage(e.payload as PageId)),
]).then(([u1, u2, u3]) => {
    cleanup = [u1, u2, u3];
}).catch(console.error);

return () => cleanup.forEach((fn) => fn());
```

---

### UI-6 🟡 `validateConfiguration` passes `flash_attn: 'off'` check but `flash_attn: 'auto'` (the default) is not considered "off" — Rule 5 never fires on default config

**File:** `ui/src/lib/validation.ts`

```typescript
if ((config.cache_type_k === 'q8_0' || config.cache_type_v === 'q8_0') && config.flash_attn === 'off') {
```

The default `flash_attn` is `'auto'`. When a user installs fresh and gets a q8_0 cache type from the wizard, `flash_attn` is still `'auto'`. The KV mismatch check does not fire because `'auto' !== 'off'`. In practice, llama.cpp will auto-enable flash attention on supported hardware when `'auto'` is set, so q8_0 is fine. **But** if the hardware doesn't support flash attention (CPU-only, old GPU), `'auto'` resolves to off at runtime — and then q8_0 will fall back to f32, silently degrading performance and memory.

**Fix:** Trigger Rule 5 on `flash_attn === 'off' || (isCpuOnly && flash_attn === 'auto')`:
```typescript
const flashIsEffectivelyOff = config.flash_attn === 'off' || (isCpuOnly && config.flash_attn !== 'on');
if ((config.cache_type_k === 'q8_0' || config.cache_type_v === 'q8_0') && flashIsEffectivelyOff) {
```

---

### UI-7 🟡 `serverStore.addLog` keeps only 500 entries (`.slice(-499)`) but `LogsPage` renders all of them without virtualisation

**File:** `ui/src/store/serverStore.ts`, `ui/src/pages/Logs.tsx`

500 log entries rendered as DOM nodes with per-line `<div>` elements. On slow machines or with long messages this causes visible jank. `Overview.tsx` limits to 100 which is fine, but the Logs page shows everything.

**Fix:** Use `windowed` rendering (e.g. a CSS `overflow-y: auto` container with `max-height` already in place) — the container exists, so the DOM is clipped. Check whether the CSS forces a re-render of all 500 items or only visible ones. Since there's no virtual scrolling library, at 500 items with moderate message length this is acceptable — but should be noted for when the limit is increased.

---

**BATCH 4 SUMMARY:** 2 critical (UI-1 pendingRestart never set, UI-2 validation always uses 4.5 GB model size), 2 bugs (UI-4 model selection not updated from external config change, UI-5 listener cleanup race), 2 design (UI-3 kvDim constant noted, UI-6 flash_attn auto not covered in Rule 5).

---

## STATUS: Analysis in progress — batches appending below
