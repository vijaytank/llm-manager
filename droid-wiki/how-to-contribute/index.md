# How to contribute

**Active contributors:** vijay

Guidelines for working in this codebase: workflow, testing, debugging, patterns, and tooling.

## Work pickup

1. Check the issue tracker for tagged issues (`good first issue`, `help wanted`, or unassigned)
2. Discuss approach in the issue before starting significant work
3. Create a feature branch from `develop` (the default branch)
4. Keep PRs focused — one logical change per PR

## PR process

1. **Branch naming:** `feat/`, `fix/`, `refactor/`, `docs/`, `test/`, `chore/` prefix
2. **Commit messages:** Conventional Commits — `type(scope): subject`
   - Examples: `feat(profile): add ROCm detection`, `fix(router): clamp ctx_size to 262144`
3. **Mandatory health check before PR:**
   ```powershell
   powershell -File script/test-health.ps1
   ```
   Must pass with zero failures.
4. **Run full test suite:**
   ```powershell
   # PowerShell syntax + system checks
   powershell -File script/test-health.ps1
   powershell -File script/verify-scripts.ps1
   
   # Python context manager
   pytest llo-core/context_manager/tests
   
   # Tauri frontend
   cd ui && npm run test
   
   # Tauri backend
   cd ui/src-tauri && cargo test && cargo clippy
   ```
5. **CI must pass** (GitHub Actions on push)
6. **Review:** At least one approval required
7. **Merge:** Squash and merge to `develop`

## Definition of done

- [ ] All tests pass (existing + new)
- [ ] `test-health.ps1` passes
- [ ] No new Clippy warnings (`cargo clippy`)
- [ ] No new ESLint/TypeScript errors (`npm run build` in `ui/`)
- [ ] Documentation updated if user-facing behavior changes
- [ ] CHANGELOG entry if applicable (or describe in PR body)

## Cross-platform requirements

Every OS-specific branch **must** be guarded by `$IsWindows`, `$IsMacOS`, or `$IsLinux`. Never use Windows-only APIs (e.g., `Get-CimInstance Win32_*`) without equivalent macOS/Linux branches.

Resolve all file paths relative to `$PSScriptRoot`. Never hardcode absolute drives like `C:\`.

## Configuration directory awareness

The Tauri app reads/writes config from AppData (`%APPDATA%\LLM Manager` / `~/.config/LLM Manager`), not the workspace root. When the GUI launches a PowerShell script, it passes `-ConfigFile` pointing to its AppData config. The `llo-core/Paths.ps1` helper `Get-LLMManagerConfigPath` implements this lookup.

**When testing manually**, use `-ConfigFile` to target a specific config, or rely on the auto-resolution.

## Legacy config promotions

`SetupRouter.ps1` promotes flat legacy keys (`cache_type_k`, `flash_attn`, etc.) found in `llo-config.json` into the `overrides` block. Because overrides take absolute priority, these promoted keys can lock derived parameters to historical values. Be aware when debugging — check `config.overrides` first.

## Integration provisioning

The wizard (`main.ps1`) generates `.vscode/tasks.json` and `.vscode/settings.json` with OS-specific terminal env injection. When `claude-code` integration is active, it sets:
- `ANTHROPIC_BASE_URL` → server endpoint
- `ANTHROPIC_AUTH_TOKEN = local`
- `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = 1`

## Related pages

- [Development workflow](development-workflow.md)
- [Testing](testing.md)
- [Debugging](debugging.md)
- [Patterns and conventions](patterns-and-conventions.md)
- [Tooling](tooling.md)
