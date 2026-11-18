# Upstream Compatibility

**Active contributors:** vijay

Proactive protection against llama.cpp breaking changes via flag parsing, git scanning, and asset synchronization.

## Overview

Three-layer defense against upstream `llama.cpp` (ggml-org/llama.cpp) changes that could break LLM Manager:

1. **Flag parser** — `llama-server --help` → alias registry → diff vs cache
2. **Git scanner** — `git fetch` + commit keyword classification
3. **Asset sync** — SHA-cached template/grammar download

## Layer 1: Flag parser (`ParseHelp.ps1`)

### Two-pass parsing

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

### Verification exclusion (`verify-scripts.ps1`)

Excludes from compatibility check:
- External commands: `git`, `nvidia-smi`, `rocm-smi`, `system_profiler`, `sysctl`
- PowerShell common: `-ExecutionPolicy`, `-WindowStyle`, `-NonInteractive`, `--help`, `--version`

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

## Layer 2: Git change detector (`GitDiff.ps1`)

### Status check

```powershell
git fetch origin
git rev-list --left-right --count HEAD...@{u}
# Returns: "ahead_count behind_count"
```

### Commit impact classification

Scans recent commits (HEAD~15..HEAD or ORIG_HEAD..HEAD after pull):

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

## Layer 3: Asset synchronization (`FetchAssets.ps1`)

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

## Integration points

### Wizard (`main.ps1`)
- Runs `FetchAssets.ps1` during setup
- Runs `ParseHelp.ps1` to initialize flag cache

### Health check (`test-health.ps1`)
- Runs `ParseHelp.ps1` logic inline (flag cache update)
- Runs `verify-scripts.ps1` for flag compatibility

### Parameter derivation (`SetupRouter.ps1`)
- Uses cached flags to validate derived params
- Template matching uses synced `templates/` directory

### CI/CD
- GitHub Actions runs `test-health.ps1` on every PR
- Flag compatibility must pass for merge

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
