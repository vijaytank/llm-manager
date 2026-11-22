# Lore

**Narrative history of the LLM Manager codebase.** Dates are taken from git history on the `develop` branch; motivations are hedged with "appears to" / "likely" where the commit record doesn't say why.

The visible history begins on **11 July 2026** with the initial commit ("initial commit: add basic files and architecture documentation") and runs through **22 November 2026** — about 65 commits by a single contributor on `develop`.

## Eras

### Era 1: Scaffold (July 2026)

The project appears to have started as a hardware-adaptive inference orchestrator built on top of `llama.cpp`. On 11 July 2026 the initial commit added basic files and architecture documentation. Within days (12–14 July 2026) the core PowerShell pieces landed: `llo-core/Profile.ps1` for CPU/RAM/GPU detection, `llo-core/SetupRouter.ps1` for deriving inference parameters, `script/start-server.ps1` / `script/stop-server.ps1` for server lifecycle, and `main.ps1` as the setup-wizard entry point. Project governance files (contribution guidelines, security policy, issue and PR templates) were added on 12 July 2026, which likely reflects an intent to run the repo as an open, contributable project from the start — even though it has remained a solo effort.

### Era 2: CI/CD + core scripts + security policy (July 2026)

The second half of July focused on hardening the core. On 14 July 2026 a commit added an automated code-review workflow, the model preset router, and the server startup script; the same period saw `llo-core/ParseHelp.ps1` introduced to parse `llama-server --help` output and track upstream llama.cpp changes — a compatibility guard that appears designed to catch breaking flag changes before they reach users. Cross-platform support followed on 21–22 July 2026, extending hardware profiling from Windows WMI to macOS (`sysctl`/`system_profiler`) and Linux (`/proc`, `nvidia-smi`/`rocm-smi`). By late July the repository also had CI workflows (`.github/workflows/ci.yml`, `release.yml`) and the security policy in place.

### Era 3: Context manager performance + security (August – November 2026)

The optional Python context-manager proxy began taking shape in August: the virtual environment and core utility scripts were initialized around 11 August 2026, and the proxy itself — translating the Anthropic protocol to OpenAI, with session tracking and message translation — appeared around 16 August 2026. September brought performance-tuning UI work, system-resource-management scripts, and comprehensive configuration testing (5 September 2026), along with local model-server management and cross-platform port handling. The proxy later gained performance and security features: a Prometheus metrics endpoint and configurable connection pooling (21 November 2026), alongside TLS, rate-limiting, and session-ID validation work.

### Era 4: Tauri + architectural report (July – August 2026)

The desktop UI is a Tauri 2 application wrapping the PowerShell core. UI scaffolding appears in late July 2026 (overview UI components, backend model-scanning commands, TopBar navigation, server lifecycle management), followed by a full UI-scaffolding push on 2 August 2026 (integration pages, logging dashboard, diagnostics). A project dependency graph was generated in JSON format on 30 July and again on 3 August 2026, and `ARCHITECTURE.md` documents the hardware classification and decision flow. The configuration directory split (AppData vs. workspace) landed around 3–4 August 2026, centralizing config handling with dynamic port support for integrations — a change likely driven by the Tauri app's need to read and write user config outside the install directory.

### Era 5: Comprehensive update + CI hardening (November 2026)

November was by far the busiest month (32 of 65 visible commits). On 21 November 2026 a cluster of commits delivered Sprint 4 UI updates (virtualization, JSON Schema validation, live preview, quick actions), Sprint 5 CI/CD with pre-commit hooks and release automation, major library updates (Vite 8, TypeScript 7), critical npm vulnerability fixes, Rust dependency updates, context-manager Prometheus metrics, file-based caching for hardware profiles and model scanning, and alignment of the context-size formula between PowerShell and TypeScript. On 22 November 2026 PR #4 ("comprehensive update") was merged, followed by CI bumps (pytest 9.0.3, pytest-asyncio), cargo-audit advisory handling, and cross-platform fixes for temp paths and Windows-only APIs on Linux/macOS. This era appears to represent a push to harden the whole stack before wider use.

## Longest-standing features

| Feature | First appeared | Status |
|---------|----------------|--------|
| Hardware profiling (`llo-core/Profile.ps1`) | 11–13 July 2026 | Active — survived the cross-platform expansion of 21–22 July 2026 |
| Parameter derivation / preset router (`llo-core/SetupRouter.ps1`, `script/start-server.ps1`) | 12–14 July 2026 | Active — override precedence and context formula added later |
| llama.cpp flag tracking (`llo-core/ParseHelp.ps1`) | 12 July 2026 (extended 22 July 2026) | Active |
| AppData configuration directory (`llo-core/Paths.ps1`) | 3–4 August 2026 | Active |

## Deprecated features

No features are formally marked deprecated in the repository. One convention changed early: flat legacy config keys (e.g. `cache_type_k`, `flash_attn` at config root) were superseded by the `config.overrides` block — but this is a configuration convention rather than a removed feature, and nothing appears to have been deleted.

## Major rewrites

| Rewrite | Period | Scope | Likely reason |
|---------|--------|-------|---------------|
| Cross-platform hardware detection | 21–22 July 2026 | `llo-core/Profile.ps1` | macOS/Linux support beyond Windows WMI |
| Configuration directory split | 3–4 August 2026 | `llo-core/Paths.ps1`, `main.ps1`, Tauri config commands | Tauri app reads/writes user config in AppData |
| Context Manager proxy | 11 August – September 2026 | New Python subsystem (`llo-core/context_manager/`) | Long-context session compression and Anthropic↔OpenAI translation |
| Tauri desktop app | 30 July – 16 August 2026 | New `ui/` and `ui/src-tauri/` | Visual dashboard on top of the PowerShell CLI |
| CI hardening | 21–22 November 2026 | `.github/workflows/`, `cargo-audit`, pytest versions | Supply-chain advisories and test stability |

## Growth trajectory

Visible commit cadence: July 17 → August 12 → September 4 → October 0 → November 32. The November surge (roughly half of all visible commits in a single month) suggests a period of intense consolidation — CI/CD, pre-commit hooks, release automation, dependency updates, and the merged comprehensive update — rather than steady linear growth. Lines of code grew alongside, but historical per-month LOC isn't reconstructed here.

## Related pages

- [Overview](overview/index.md)
- [Getting started](overview/getting-started.md) — prerequisites, install, build, test, run
- [Systems index](systems/index.md) — systems overview
- [Applications index](applications/index.md) — applications overview
- [Architecture](overview/architecture.md) — hardware classification and decision flow
- [Compatibility guard](systems/compatibility-guard.md) — `ParseHelp.ps1` / `GitDiff.ps1` / `FetchAssets.ps1`
- [Tauri desktop app](applications/tauri-desktop-app.md)
- [Context manager proxy](applications/context-manager-proxy.md)
- [By the numbers](by-the-numbers.md) — codebase statistics snapshot
- [Fun facts](fun-facts.md) — light notes on origins, age, and trivia
