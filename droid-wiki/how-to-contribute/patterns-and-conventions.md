# Patterns and conventions

## Cross-platform PowerShell

Every OS-specific branch is guarded by `$IsWindows`, `$IsMacOS`, or `$IsLinux`. Windows-only APIs such as `Get-CimInstance Win32_*` are never used without an equivalent macOS/Linux branch. All file paths resolve relative to `$PSScriptRoot`; absolute drives like `C:\` are never hardcoded.

## Configuration directory split

The Tauri app and the Python proxy both resolve `llo-config.json` from the user's AppData directory (`%APPDATA%\LLM Manager` on Windows, `~/.config/LLM Manager` on macOS/Linux), not the workspace root. The GUI passes its AppData config path to PowerShell scripts via `-ConfigFile`; `Paths.ps1` (`Get-LLMManagerConfigPath`) implements this lookup in PowerShell.

## Override policy

`config.overrides` is the single source of explicit user intent. Keys present here take absolute priority over all hardware-derived values. `SetupRouter.ps1` promotes flat legacy keys (e.g. `cache_type_k`, `flash_attn`) into `overrides`, which can lock derived parameters to historical wizard values.

## Commit conventions

Conventional commits: `<type>(<scope>): <subject>` with types `feat`, `fix`, `docs`, `refactor`, `test`, `chore`. The default branch is `develop`.

## Health check before a PR

Run `powershell -File script/test-health.ps1` (or `./script/test-health.sh` on macOS/Linux) before opening a PR.

## Testing patterns

* PowerShell: syntax checks, config schema validation, live TCP/REST health checks in `script/test-health.ps1`.
* Python context manager: 11 pytest modules in `llo-core/context_manager/tests/` covering compression, token counting, session tracking, protocol conversion, and HTTP round-trip.
* Rust Tauri: unit tests in each command file (`profile.rs`, `models.rs`, `config.rs`, `gguf.rs`, `health.rs`, `server.rs`) plus `cargo clippy`.
* React frontend: Vitest tests across stores, components, and flows (`npm run test` in `ui/`).

## Error handling

PowerShell scripts use try/catch around hardware probing and server lifecycle. Tauri commands return `Result<T, String>` and log parse failures to rotating debug logs (`logs/hardware_debug.log`, max 10 MB, 5 backups).

## Related pages

- [Development workflow](./development-workflow.md) — branch, code, test, PR cycle
- [Testing](./testing.md) — frameworks and how to run each suite
- [Debugging](./debugging.md) — logs and common errors
