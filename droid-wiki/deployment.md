# Deployment

LLM Manager is not a hosted service — it runs locally on the user's machine. There are two runtime surfaces: the PowerShell CLI (headless server) and the Tauri desktop app (packaged installer). This page covers how each is built, packaged, and shipped.

## PowerShell CLI deployment

There is no separate build step for the CLI — the `.ps1` files in `llo-core/` and `script/` are executed directly by PowerShell 7+. Distribution consists of copying the repository (or a release zip) to the target machine and running `main.ps1` through the setup wizard.

The wizard:
1. Collects `llama_server_path`, `models_dir`, `templates_dir`, `grammars_dir`, fallback provider, and integrations.
2. Writes `llo-config.json` to the AppData config directory.
3. Runs `SetupRouter.ps1` to derive parameters and generate `models-preset.ini`.
4. Generates `.vscode/tasks.json` and `.vscode/settings.json` for editor integration.

## Tauri desktop app deployment

The desktop app is packaged with Tauri 2. From `ui/`:

```powershell
npm run tauri build --release
```

Output installers:

| Platform | Artifact |
|----------|----------|
| Windows | `src-tauri/target/release/bundle/nsis/llm-manager_*_x64_en-US.msi` |
| macOS | `src-tauri/target/release/bundle/dmg/llm-manager_*_aarch64.dmg` |
| Linux | `src-tauri/target/release/bundle/appimage/llm-manager_*_amd64.AppImage` |

## CI

`.github/workflows/ci.yml` runs test-health, verify-scripts, pytest, frontend Vitest, Rust cargo test, and clippy on each push/PR to `develop`. `.github/workflows/release.yml` handles release builds. See [tooling](./how-to-contribute/tooling.md) for details.

## Configuration at runtime

Both the CLI and the GUI read `llo-config.json` from the AppData directory (`%APPDATA%\LLM Manager\llo-config.json` on Windows, `~/.config/LLM Manager` on macOS/Linux), not from the install/workspace directory. The GUI passes its config path to PowerShell scripts via `-ConfigFile`. This means a deployed app's configuration persists across updates and is independent of the install location.

## Related pages

- [Getting started](overview/getting-started.md) — install, build, test, run
- [Tooling](./how-to-contribute/tooling.md) — build system, linters, CI tooling
- [Architecture](overview/architecture.md) — configuration directory split
- [Systems](./systems/index.md) — server lifecycle and parameter derivation
