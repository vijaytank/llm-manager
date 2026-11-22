# GGUF Model Management

**Active contributors:** vijay

Recursive model discovery, binary header parsing, chat template matching, and multimodal projector pairing.

## Overview

The system scans `models_dir` for `.gguf` files, parses binary headers for metadata, matches chat templates, and pairs vision projectors (mmproj).

## Directory layout

```
ui/src-tauri/src/commands/
├── models.rs       # scan_models command (recursive scan + binary parse)
├── gguf.rs         # parse_gguf_file (binary header metadata extraction)
ui/src/pages/Models.tsx      # Frontend: model list, inspector, mmproj pairing
ui/src/store/modelsStore.ts  # Frontend state
```

## Key Abstractions

| Abstraction | Responsibility | Key Fields |
|-------------|---------------|------------|
| `ModelInfo` | Discovered GGUF model with parsed metadata | `name`, `filename`, `path`, `quantization`, `template`, `calculated_context`, `is_mmproj` |
| `GgufMetadata` | Binary header parse result | `architecture`, `quantization`, `context_length`, `block_count`, `file_size_gb` |
| `ChatTemplate` | Matched Jinja template for a model | template name, match method (`binary-header`/`mmproj-projector`/`fallback`) |
| `MmprojPair` | Vision projector associated with a text model | `mmproj_path`, `mmproj_no_offload` |

## Recursive model scan (`models.rs`)

```rust
#[tauri::command]
pub fn scan_models(models_dir_path: Option<String>) -> Result<Vec<ModelInfo>, String>
```

**Algorithm:**
1. Resolve `models_dir` (parameter → config → workspace/models → parent/models)
2. Recursive walk: `collect_gguf_files_recursive(dir, &mut files)`
3. For each `.gguf` file:
   - Parse binary header via `parse_gguf_file()`
   - Detect mmproj: filename contains `mmproj` or `vision-projector`
   - Match chat template (see below)
   - Build `ModelInfo` struct

**ModelInfo:**
```rust
pub struct ModelInfo {
    pub name: String,                    // Filename stem
    pub filename: String,                // Full filename
    pub path: String,                    // Absolute path
    pub file_size_gb: f64,               // Rounded to 0.1 GB
    pub quantization: String,            // From GGUF header or filename
    pub template: String,                // Matched template name
    pub template_match_method: String,   // "binary-header" | "mmproj-projector" | "fallback"
    pub calculated_context: u32,         // From GGUF header (context_length)
    pub status: String,                  // "Ready" | "Multimodal Projector"
    pub is_mmproj: bool,                 // True if vision projector
}
```

## Binary header parsing (`gguf.rs`)

```rust
pub fn parse_gguf_file<P: AsRef<Path>>(path: P) -> Result<GgufMetadata, String>
```

**GGUF header structure:**
```
Magic: "GGUF" (4 bytes)
Version: u32
Tensor count: u64
KV metadata count: u64
KV entries: (key: string, type: u32, value: varies) × kv_count
```

**Parsed metadata (`GgufMetadata`):**
```rust
pub struct GgufMetadata {
    pub name: String,                    // general.name or filename
    pub architecture: String,            // general.architecture (e.g., "llama", "qwen")
    pub quantization: String,            // general.quantization (e.g., "Q4_K_M")
    pub context_length: u32,             // llm.context_length
    pub block_count: u32,                // llm.block_count
    pub file_size_gb: f64,               // From file metadata
    pub model_vram_gb: f64,              // Estimated VRAM for weights
    pub kv_cache_gb_at_8k: f64,          // KV cache at 8K context
    pub kv_cache_gb_at_32k: f64,         // KV cache at 32K context
    pub kv_cache_gb_at_64k: f64,         // KV cache at 64K context
}
```

**KV keys extracted:**
| Key | Purpose |
|-----|---------|
| `general.architecture` | Model architecture (llama, qwen, mistral, etc.) |
| `general.quantization` | Quantization name |
| `llm.context_length` | Native context limit |
| `llm.block_count` | Transformer layer count |
| `llm.attention.head_count_kv` | KV heads (for GQA) |
| `llm.rope.dimension_count` | RoPE dimension |

**Value type handling:** Supports u8, i8, u16, i16, u32, i32, f32, u64, i64, f64, string, array, with fallback for unknown types.

**Error handling:** Returns default metadata on parse failure (allows UI to show model with fallback values).

## Chat template matching

**Priority algorithm (in `SetupRouter.ps1` → `Find-MatchingTemplate`):**

1. **Exact normalized name match**
   - Normalize: lowercase, remove non-alphanumeric
   - `qwen3.5-4b` ↔ `Qwen3.5-4B.jinja` ✓

2. **Token substring match**
   - Split model name and template name into tokens (version numbers, architecture names)
   - Score by token overlap
   - Best score wins

3. **Default template**
   - If `use_default_template = true` in config → `default.jinja`

4. **GGUF internal metadata**
   - Some GGUF files embed chat template in `tokenizer.chat_template` KV
   - Fallback to "built-in (GGUF)"

**Template directory resolution:**
- Config `templates_dir` → workspace `templates/` → parent `templates/`

## Multimodal projector (mmproj) pairing

**Detection:** Filename contains `mmproj` or `vision-projector` → `is_mmproj = true`

**Pairing UI (`Models.tsx`):**
- Dropdown per text model: "Disabled (Text Only)" + list of mmproj files
- When active model selected: shows GPU/CPU offload radio buttons
- Config keys: `mmproj_path`, `mmproj_no_offload`

**Offload modes:**
- `mmproj_no_offload = false` (default): GPU offload via `--mmproj`
- `mmproj_no_offload = true`: CPU RAM via `--mmproj` + `--no-mmproj-offload`

**VRAM cost:** ~0.8–1.5 GB additional VRAM/RAM

## Frontend integration

### Models page (`Models.tsx`)

- Recursive scan trigger (refresh button + browse folder)
- Table: name, size, quantization, template, mmproj dropdown, hardware check, actions
- Binary inspector modal: shows `GgufMetadata` fields
- "Select" button sets `active_model` in config

### Overview page (`Overview.tsx`)

- Model dropdown with pre-flight validation (`validateModelLaunch`)
- Auto-tune launch button (applies safe overrides + starts server)
- mmproj selector with offload radios
- Chat template selector (auto, default.jinja, discovered templates)

### Validation (`lib/validation.ts`)

```typescript
export function validateModelLaunch(
  model: ModelInfo | null,
  config: AppConfig,
  profile: SystemHardware | null
): LaunchCheck {
  // Computes required VRAM/RAM vs available
  // Returns: canLaunch, severity (ok/warn/caution/block), message, autoTuneConfig
}
```

**Hardware check logic:**
- Model VRAM estimate from GGUF header
- KV cache at target context (exact byte calculation)
- Compares against `profile.vramGb` and `profile.totalRamGb`
- Severity: `ok` (fits comfortably), `warn` (tight), `caution` (close), `block` (exceeds)

## Entry Points for Modification

| Task | Entry Point | File |
|------|-------------|------|
| Change recursive scan roots | Edit `models_dir` resolution priority | `ui/src-tauri/src/commands/models.rs` |
| Add a GGUF KV key | Extend header parse switch | `ui/src-tauri/src/commands/gguf.rs` |
| Change template match priority | Edit `Find-MatchingTemplate` order | `llo-core/SetupRouter.ps1` |
| Add a template directory | Edit template resolution fallback chain | `llo-core/SetupRouter.ps1` |
| Change mmproj pairing UI | Edit dropdown/offload radio logic | `ui/src/pages/Models.tsx` |
| Change pre-flight severity thresholds | Edit `validateModelLaunch` cases | `ui/src/lib/validation.ts` |

## Key source files

| File | Purpose |
|------|---------|
| `ui/src-tauri/src/commands/models.rs` | Recursive GGUF scan, binary parse dispatch |
| `ui/src-tauri/src/commands/gguf.rs` | Binary header parser (GgufMetadata) |
| `llo-core/SetupRouter.ps1` | Template matching (Find-MatchingTemplate) |
| `ui/src/pages/Models.tsx` | Model list, inspector, mmproj pairing |
| `ui/src/pages/Overview.tsx` | Model select, pre-flight check, launch |
| `ui/src/lib/validation.ts` | Hardware safety validation |
| `ui/src/store/modelsStore.ts` | Frontend model state |

## Related Pages

- [Architecture](../overview/architecture.md) — hardware classification, decision flow, core formulas
- [Tauri Desktop App](../applications/tauri-desktop-app.md) — Tauri desktop app command dispatch
- [Hardware-Adaptive Inference](../features/hardware-adaptive-inference.md) — adaptive inference feature
