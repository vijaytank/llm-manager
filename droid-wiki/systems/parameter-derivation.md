# Parameter Derivation Engine

**Active contributors:** vijay

Tier-based inference parameter tables, override application, per-model context calculation, and speculative decoding validation.

## Overview

`SetupRouter.ps1` is the decision engine. It takes a `SystemHardwareProfile` and `config.overrides`, derives all `llama-server` flags, and writes `models-preset.ini`.

## Directory layout

```
llo-core/SetupRouter.ps1    # Main derivation logic
```

## Key Abstractions

| Abstraction | Responsibility | Key Parameters |
|-------------|---------------|----------------|
| `InferenceParams` | Tier-derived llama-server flag set | `n_gpu_layers`, `flash_attn`, `cache_type_k/v`, `ubatch_size`, `parallel`, `spec_type` |
| `PerformanceTier` | Hardware class driving parameter policy | `cpu`, `low`, `mid`, `high` |
| `OverridePrecedence` | Resolution order: overrides > hardware > legacy > defaults | `config.overrides` (absolute priority) |
| `ContextSizeFormula` | Per-model context ceiling from RAM/KV math | `ctxSize` (standard sizes: 4096…262144) |
| `SpecTypeValidator` | Speculative decoding compatibility gate | `ngram-simple` vs `none` |
| `TemplateMatcher` | Chat template resolution priority | exact → token → default → GGUF internal |

## Base parameter tables per tier

```powershell
$params = switch ($tier) {
    "cpu" {
        @{
            n_gpu_layers  = 0
            flash_attn    = "off"
            use_fit       = $false
            fit_target    = 0
            fit_ctx_min   = 0
            cache_type_k  = "f16"
            cache_type_v  = "f16"
            ubatch_size   = 128
            parallel      = 1
            spec_type     = "ngram-simple"
            context_shift = $true
            cache_reuse   = 0
            mmap          = 1
        }
    }
    "low" {
        @{
            n_gpu_layers  = -1
            flash_attn    = "on"
            use_fit       = $true
            fit_target    = 512
            fit_ctx_min   = 4096
            cache_type_k  = "q8_0"
            cache_type_v  = "q8_0"
            ubatch_size   = 256
            parallel      = 1
            spec_type     = "none"
            context_shift = $true
            cache_reuse   = 256
            mmap          = 1
        }
    }
    "mid" {
        @{
            n_gpu_layers  = -1
            flash_attn    = "on"
            use_fit       = $true
            fit_target    = 1024
            fit_ctx_min   = 8192
            cache_type_k  = "q8_0"
            cache_type_v  = "q8_0"
            ubatch_size   = 512
            parallel      = 1
            spec_type     = "ngram-simple"
            context_shift = $true
            cache_reuse   = 256
            mmap          = 1
        }
    }
    "high" {
        @{
            n_gpu_layers  = -1
            flash_attn    = "on"
            use_fit       = $true
            fit_target    = 1024
            fit_ctx_min   = 8192
            cache_type_k  = if ($vramMB -gt 12288) { "f16" } else { "q8_0" }
            cache_type_v  = if ($vramMB -gt 12288) { "f16" } else { "q8_0" }
            ubatch_size   = 1024
            parallel      = 1
            spec_type     = "ngram-simple"
            context_shift = $true
            cache_reuse   = 256
            mmap          = 1
        }
    }
}
```

## Conditional parallel = 2 upgrade

```powershell
if ($tier -in @("mid", "high") -and $ramMB -gt 16384 -and $vramMB -gt 4096) {
    $params.parallel = 2
}
```

Only upgrades when **both** RAM > 16 GB **and** VRAM > 4 GB (mid/high tiers only).

## Override application (absolute priority)

```powershell
foreach ($key in $Overrides.Keys) {
    if ($params.ContainsKey($key)) {
        $params[$key] = $Overrides[$key]
    }
}
```

**Legacy flat key promotion:** `cache_type_k`, `flash_attn`, `ctx_size`, `ubatch_size`, `parallel_slots` found at config root are auto-promoted to `overrides` by `Map-LegacyConfigKeyToOverride`.

**Claude Code integration floor:**
```powershell
if ($config.integrations -contains "claude-code") {
    if ($params.parallel -lt 2) { $params.parallel = 2 }
}
```

## Post-override validation

```powershell
# Low VRAM speculative decoding safeguard
if ($tier -eq "low" -and $params.spec_type -ne "none") {
    $params.spec_type = "none"
}

# Quantized KV cache requires flash_attn
if ($params.flash_attn -eq "off") {
    if ($params.cache_type_k -ne "f16") { $params.cache_type_k = "f16" }
    if ($params.cache_type_v -ne "f16") { $params.cache_type_v = "f16" }
}
```

## Per-model context size formula

```powershell
function Get-SafeContextSize {
    param($ModelBytes, $RamMB, $VramMB, $GpuTier, $Parallel, $CacheTypeK)
    
    $modelGB = $ModelBytes / 1024.0 / 1024.0 / 1024.0
    $baseKV = 12.0 * $modelGB  # MB per 1K tokens at f16
    
    $kvMBPerKToken = switch ($CacheTypeK) {
        "f16"  { $baseKV * 2.0 }
        "q8_0" { $baseKV }
        "q4_0" { $baseKV * 0.5 }
        default { $baseKV }
    }
    $kvMBPerKToken = [math]::Max($kvMBPerKToken, 5.0)  # Floor 5 MB
    $kvMBPerKToken *= $Parallel
    
    $availRAM = $RamMB - $modelGB * 1024 - 512  # Model size + 512 MB headroom
    $maxCtxFromRam = [math]::Floor($availRAM / $kvMBPerKToken) * 1000
    $maxCtxFromRam = [math]::Max($maxCtxFromRam, 4096)
    
    # Ceiling to standard sizes
    $standardSizes = @(4096, 8192, 16384, 32768, 65536, 131072, 262144)
    $ctxSize = ($standardSizes | Where-Object { $_ -le $maxCtxFromRam } | Select-Object -Last 1)
    
    # Integration-aware floors
    if ($config.integrations -contains "claude-code") {
        if ($GpuTier -eq "cpu") { $ctxSize = [math]::Max($ctxSize, 32768) }
        else { $ctxSize = [math]::Max($ctxSize, 65536) }
    }
    
    return $ctxSize
}
```

**CLI vs UI discrepancy:**
- CLI: `q8_0 = 50% f16`, `q4_0 = 25% f16` (linear approximation)
- UI (`lib/validation.ts`): exact bytes/element → `q8_0 = 53.1%`, `q4_0 = 28.1%`

## Speculative decoding validation

```powershell
function Get-ValidatedSpecType {
    param($ModelAlias, $GpuTier)
    
    $incompatible = @(
        "moe", "mixture", "vision", "llava", "clip",
        "phi-3-v", "qwen.*vl", "minicpm-v", "cogvlm"
    )
    
    foreach ($pattern in $incompatible) {
        if ($ModelAlias -match $pattern) {
            return "none"
        }
    }
    
    if ($GpuTier -eq "low") { return "none" }
    return "ngram-simple"
}
```

## Chat template matching

Priority order:
1. **Exact normalized name match** — `qwen3.5-4b` → `Qwen3.5-4B.jinja`
2. **Token substring match** — Score overlaps of model/version tokens
3. **Default template** — If `use_default_template = true` → `default.jinja`
4. **GGUF internal metadata** — Fallback to template embedded in GGUF

## Preset generation

```ini
; models-preset.ini
[model-alias]
model = /path/to/model.gguf
alias = model-alias
chat_template = /path/to/template.jinja
n_gpu_layers = -1
ctx_size = 32768
ubatch_size = 512
cache_type_k = q8_0
cache_type_v = q8_0
flash_attn = on
parallel = 1
spec_type = ngram-simple
```

Consumed by `llama-server --models-preset models-preset.ini`.

## Entry Points for Modification

| Task | Entry Point | File |
|------|-------------|------|
| Change base parameter values per tier | Edit tier switch block | `llo-core/SetupRouter.ps1` |
| Change `parallel=2` upgrade condition | Edit conditional upgrade block | `llo-core/SetupRouter.ps1` |
| Change override precedence | Edit override application loop | `llo-core/SetupRouter.ps1` |
| Change context size formula | Edit `Get-SafeContextSize` | `llo-core/SetupRouter.ps1` |
| Change speculative decoding compatibility | Edit `Get-ValidatedSpecType` incompatible list | `llo-core/SetupRouter.ps1` |
| Change KV-cache byte math discrepancy | Edit `calculateKvCacheGb` exact byte sizes | `ui/src/lib/validation.ts` |
| Add a template match method | Edit `Find-MatchingTemplate` priority order | `llo-core/SetupRouter.ps1` |

## Key source files

| File | Purpose |
|------|---------|
| `llo-core/SetupRouter.ps1` | Main derivation (Get-InferenceParams, Get-SafeContextSize, Get-ValidatedSpecType, template matching, preset writer) |
| `ui/src/lib/validation.ts` | UI-side exact KV calculator (bytes/element) |
| `ui/src/pages/Performance.tsx` | Override sliders for all params |
| `ui/src/pages/Diagnostics.tsx` | Validation display |

## Related Pages

- [Architecture](../overview/architecture.md) — hardware classification, decision flow, core formulas
- [PowerShell CLI](../applications/powershell-cli.md) — CLI entry points
- [Hardware-Adaptive Inference](../features/hardware-adaptive-inference.md) — adaptive inference feature
- [Upstream Compatibility](../features/upstream-compatibility.md) — llama.cpp argument tracking
