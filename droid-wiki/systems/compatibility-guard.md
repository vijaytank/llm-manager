# Upstream Compatibility Guard

**Active contributors:** vijay

llama-server flag parsing, git change detection, and template/grammar synchronization.

## Overview

Three components protect against upstream `llama.cpp` breaking changes:
1. **Flag parser** (`ParseHelp.ps1`) — parses `llama-server --help`, caches flags, detects additions/removals
2. **Git scanner** (`GitDiff.ps1`) — scans upstream commits for hardware-impacting changes
3. **Asset sync** (`FetchAssets.ps1`) — SHA-cached template/grammar download from ggml-org/llama.cpp

## Directory layout

```
llo-core/
├── ParseHelp.ps1      # Flag parser + cache
├── GitDiff.ps1        # Upstream git change detector
├── FetchAssets.ps1    # Template/grammar downloader
```

## Key Abstractions

| Abstraction | Responsibility | Key Fields |
|-------------|---------------|------------|
| `FlagEntry` | Parsed `llama-server --help` flag | `Short`, `Long`, `Aliases`, `ValueToken`, `Description`, `EnvVar` |
| `FlagCache` | Serialized allow-list of known flags | `.cached_flags.json` |
| `FlagDiff` | Added/removed flags vs cached cache | `Added`, `Removed`, `TotalCurrent` |
| `CommitImpact` | Classified upstream commit | keywords → impact tag (CUDA/GPU, CPU, Performance, Breaking Change, Server/API, Flash Attention) |
| `AssetManifest` | SHA-cached template/grammar inventory | `templates_sha`, `grammars_sha`, `files` map |

## Flag parser (`ParseHelp.ps1`)

### Two-pass parsing algorithm

```powershell
# Pass 1: Match help lines starting with flag tokens
$optionLineRegex = '^\s{0,12}((?:-[\w?]+,\s+)?(?:--[\w-]+(?:,\s+)?)+)'

# Pass 2: Extract ALL long aliases from the line
$longAliases = @([regex]::Matches($line, '--[\w-]+') | ForEach-Object { $_.Value })
# Example: "-ngl, --gpu-layers, --n-gpu-layers N" → ["--gpu-layers", "--n-gpu-layers"]
```

**Each alias registered individually** for allow-list lookup.

### Flag entry structure

```powershell
[pscustomobject]@{
    Short       = $shortAlias      # e.g., "-ngl"
    Long        = $primaryLong     # e.g., "--n-gpu-layers"
    Aliases     = $longAliases     # All aliases from line
    ValueToken  = $valueToken      # e.g., "N", "PATH", "BOOL"
    Description = $desc            # Help text
    EnvVar      = $envVar          # From "(env: VAR_NAME)"
}
```

### Cache update (`Update-CachedFlags`)

```powershell
function Update-CachedFlags {
    $currentFlags = Get-LlamaServerFlags -ServerPath $LlamaServerPath
    $cachedFlags = Get-Content $CacheFile | ConvertFrom-Json
    
    $diff = @{
        Added = @($currentFlags | Where-Object { $cachedFlags.Long -notcontains $_.Long })
        Removed = @($cachedFlags | Where-Object { $currentFlags.Long -notcontains $_.Long })
        TotalCurrent = $currentFlags.Count
    }
    
    $currentFlags | ConvertTo-Json -Depth 5 | Set-Content $CacheFile
    return $diff
}
```

**Cache file:** `.cached_flags.json` (AppData or workspace)

### Output example

```
--- Help Parser Diff Results ---
Total flags in current binary: 142
New flags added: 3
  + --new-flag (New feature description)
  + --another-flag (Another description)
Deprecated/removed flags: 1
  - --old-flag (Deprecated description)
--------------------------------
```

### Verification exclusion (`verify-scripts.ps1`)

Excludes from compatibility check:
- External commands: `git`, `nvidia-smi`, `rocm-smi`, `system_profiler`, `sysctl`
- PowerShell common: `-ExecutionPolicy`, `-WindowStyle`, `-NonInteractive`, `--help`, `--version`

## Git change detector (`GitDiff.ps1`)

### Status check

```powershell
git fetch origin
git rev-list --left-right --count HEAD...@{u}
# Returns: "ahead_count behind_count"
```

### Commit impact classification

Scans recent commits (HEAD~15..HEAD or ORIG_HEAD..HEAD after pull) for keywords:

| Keyword Pattern | Impact Tag |
|-----------------|------------|
| `cuda\|nvidia\|gpu\|vram` | CUDA/GPU |
| `cpu\|thread\|numa` | CPU |
| `perf\|speed\|token/s\|throughput` | Performance |
| `breaking\|deprecate\|remove` | Breaking Change |
| `server\|preset\|api` | Server/API |
| `flash-attn\|flashattn` | Flash Attention |

### Output example

```
--- Git Status Report ---
Branch: master
Status: Behind remote by 5 commit(s). You should do a 'git pull'.
Scanned commits (HEAD~15..HEAD): 12
Recent Highlights:
  a1b2c3d - feat: add new quantization format [CUDA/GPU, Performance]
  e4f5g6h - fix: flash attention memory leak [Flash Attention, Breaking Change]
  i7j8k9l - chore: update dependencies
-------------------------
```

## Asset synchronization (`FetchAssets.ps1`)

### SHA-cached download

```powershell
function Sync-LlamaAssets {
    # 1. Read local manifest
    $manifest = Get-Content .assets-manifest.json | ConvertFrom-Json
    
    # 2. Fetch remote directory listing (GitHub API)
    $remoteTemplates = Invoke-RestMethod "https://api.github.com/repos/ggml-org/llama.cpp/contents/models/templates"
    $remoteGrammars = Invoke-RestMethod "https://api.github.com/repos/ggml-org/llama.cpp/contents/grammars"
    
    # 3. Compare SHA hashes
    $templatesSha = $remoteTemplates | Where-Object { $_.name -eq ".sha" } | Select-Object -ExpandProperty sha
    if ($manifest.templates_sha -ne $templatesSha) {
        # Download changed files only
        foreach ($file in $remoteTemplates) {
            if ($file.sha -ne $manifest.files[$file.name]) {
                Download-File $file.download_url $localPath
            }
        }
        $manifest.templates_sha = $templatesSha
    }
    
    # 4. Update manifest
    $manifest | ConvertTo-Json | Set-Content .assets-manifest.json
}
```

### Manifest structure (`.assets-manifest.json`)

```json
{
  "templates_sha": "abc123...",
  "grammars_sha": "def456...",
  "files": {
    "llama.jinja": "sha1...",
    "chatml.jinja": "sha2...",
    "json.gbnf": "sha3..."
  }
}
```

### Offline fallback

If GitHub API unreachable and no local templates:
- Prompts user to apply bundled `templates/default.jinja` to all models
- Sets `use_default_template = true` in config

## Integration with workflow

### Wizard (`main.ps1`)
- Runs `FetchAssets.ps1` during setup
- Runs `ParseHelp.ps1` to initialize flag cache

### Health check (`test-health.ps1`)
- Runs `ParseHelp.ps1` logic inline
- Runs `verify-scripts.ps1` for flag compatibility

### Parameter derivation (`SetupRouter.ps1`)
- Uses cached flags to validate derived params
- Template matching uses synced `templates/` directory

## Entry Points for Modification

| Task | Entry Point | File |
|------|-------------|------|
| Change help-line regex | Edit two-pass parsing patterns | `llo-core/ParseHelp.ps1` |
| Change flag cache location | Edit cache file path | `llo-core/ParseHelp.ps1` |
| Add an impact keyword | Edit keyword→tag map | `llo-core/GitDiff.ps1` |
| Change commit scan range | Edit `git rev-list` range | `llo-core/GitDiff.ps1` |
| Add an asset source | Edit sync target URLs | `llo-core/FetchAssets.ps1` |
| Add an excluded flag | Edit exclusion list | `script/verify-exclude.json` |

## Key source files

| File | Purpose |
|------|---------|
| `llo-core/ParseHelp.ps1` | `Get-LlamaServerFlags`, `Update-CachedFlags` |
| `llo-core/GitDiff.ps1` | `Get-LlamaGitStatus`, commit impact classification |
| `llo-core/FetchAssets.ps1` | `Sync-LlamaAssets`, SHA-cached download |
| `script/verify-scripts.ps1` | Flag compatibility vs binary |
| `script/test-health.ps1` | Integrated flag check |
| `.cached_flags.json` | Flag cache (AppData/workspace) |
| `.assets-manifest.json` | Template/grammar SHA manifest |

## Related Pages

- [Architecture](../overview/architecture.md) — hardware classification, decision flow, core formulas
- [PowerShell CLI](../applications/powershell-cli.md) — CLI entry points
- [Tauri Desktop App](../applications/tauri-desktop-app.md) — Tauri desktop app command dispatch
- [Upstream Compatibility](../features/upstream-compatibility.md) — llama.cpp argument tracking
