# LLM-Manager Comprehensive Update Plan

**Generated:** 2026-11-21
**Workstream:** LLM-Manager Update
**Branch:** develop

---

## Executive Summary

This plan covers six workstreams based on codebase analysis using nakshastramcp architectural mapping and security auditing:

1. **Security Review** (CRITICAL - 5 npm vulnerabilities found)
2. **Library Updates** (HIGH - Major version upgrades needed)
3. **UI Updates & Optimization** (MEDIUM - UX/performance improvements)
4. **Process Optimization** (MEDIUM - CI/CD, build, dev workflow)
5. **Core Optimization** (MEDIUM - Performance, memory, algorithms)

---

## 1. SECURITY REVIEW (Priority: CRITICAL)

### 1.1 npm Vulnerabilities (5 found via `npm audit`)

| Package | Severity | CVE/GHSA | Current | Fixed In | Action |
|---------|----------|----------|---------|----------|--------|
| `tinypool` | **CRITICAL** | GHSA-5gmw-xhrv-c9v3, GHSA-85c8-ppgw-ccpr | 2.1.1 | vitest@5.1.1 | Upgrade vitest to 5.x (breaking) |
| `@vitest/mocker` | Moderate | GHSA-82fw-gwwq-j7x9, GHSA-qxg6-89mg-rqv8 | 4.1.11 | vitest@5.1.1 | Upgrade vitest to 5.x (breaking) |
| `vite` | **HIGH** | GHSA-698v-4r3x-3vcv, GHSA-r825-w8mm-5pxw, GHSA-587h-7wmj-h5pm, GHSA-9jrq-w75r-8gcw, GHSA-rq7h-c2jc-7f22 | 6.4.3 | vite@7+ | Upgrade vite (major) |
| `source-map-js` | **HIGH** | GHSA-68fv-2mgg-jv7q | 1.0.0-1.2.1 | 1.2.2+ | Upgrade (transitive via vite) |

**Remediation:** Run `npm audit fix --force` (upgrades vitest to 5.1.1, vite to latest) - **breaking changes expected**.

### 1.2 Rust Crates - Run `cargo audit`
- **Status:** Installation in progress (timeout during compilation)
- **Action:** Complete cargo-audit run to identify Rust vulnerabilities
- **Tool:** `cargo install cargo-audit && cargo audit`

### 1.3 Python Dependencies (Context Manager)
- **Dependencies:** fastapi, uvicorn, httpx, tokenizers, pydantic, pytest
- **Action:** Check `pip-audit` once venv has pip installed

### 1.4 Security Hardening Checklist
- [ ] Input validation on all Tauri command handlers (`ui/src-tauri/src/commands/`)
- [ ] Path traversal protection in file dialogs and config loading
- [ ] Command injection prevention in PowerShell script invocation
- [ ] Secure defaults for `mlock`, `prio`, thread limits
- [ ] TLS/config for Context Manager proxy (currently HTTP only)
- [ ] Rate limiting on proxy endpoints
- [ ] Session ID validation (prevent session fixation)

---

## 2. LIBRARY UPDATES (Priority: HIGH)

### 2.1 Frontend (ui/package.json) - Major Version Upgrades Required

| Package | Current | Target | Breaking Changes | Migration Effort |
|---------|---------|--------|------------------|------------------|
| `@tauri-apps/api` | 2.11.1 | 2.12.5 | Minor | Low |
| `@tauri-apps/cli` | 2.11.4 | 2.12.6 | Minor | Low |
| `@tauri-apps/plugin-dialog` | 2.7.2 | 2.8.4 | Minor | Low |
| `@tauri-apps/plugin-shell` | 2.3.5 | 2.6.0 | Minor | Medium |
| `react` / `react-dom` | 19.2.8 | 19.3.1 | Patch | Low |
| `vite` | 6.4.3 | **8.3.8** | **Major** | **High** |
| `@vitejs/plugin-react` | 4.7.0 | **6.3.0** | **Major** | **High** |
| `typescript` | 5.7.3 | **7.0.2** | **Major** | **Medium** |
| `vitest` | 3.2.7 | **5.1.1** | **Major** | **High** |
| `zustand` | 5.0.14 | 5.1.0 | Minor | Low |
| `lucide-react` | 0.474.0 | **1.77.0** | **Major** | **Medium** |
| `@types/node` | 22.20.1 | 26.6.6 | Major | Low |

### 2.2 Backend (ui/src-tauri/Cargo.toml) - Check for Updates
- `tauri` 2.2.0 -> check latest 2.x
- `tauri-plugin-shell` 2.2.0 -> check latest
- `tauri-plugin-dialog` 2.2.0 -> check latest
- `tokio`, `serde`, `chrono` - check updates

### 2.3 Python (llo-core/context_manager/requirements.txt)
- `fastapi>=0.111.0` -> check latest
- `uvicorn[standard]>=0.29.0` -> check latest
- `httpx>=0.27.0` -> check latest
- `tokenizers>=0.19.0` -> check latest
- `pydantic>=2.0.0` -> check latest (v2 is current)

### 2.4 Update Strategy
**Phase 1 (Safe):** Patch/minor updates only (tauri plugins, react, zustand)
**Phase 2 (Security):** vitest 5.x + vite 7/8 (fixes critical vulns)
**Phase 3 (Major):** TypeScript 7, lucide-react 1.x, Vite 8
**Phase 4:** Rust crate updates after cargo-audit

---

## 3. UI UPDATES & OPTIMIZATION (Priority: MEDIUM)

### 3.1 Current UI Architecture (from nakshastramcp)
- **State Management:** Zustand stores (configStore, serverStore, hardwareStore, modelsStore, validationStore)
- **Pages:** Overview, Setup, Models, Performance, Integrations, Diagnostics, Logs, Settings
- **Components:** Sidebar, TopBar, PageShell, InfoTooltip, ImpactBanner
- **Styling:** CSS Modules with glass-card design system
- **High-Impact Files:** configStore.ts (0.45), serverStore.ts (0.38), hardwareStore.ts (0.33)

### 3.2 UI Improvements Identified

| Area | Issue | Recommendation |
|------|-------|----------------|
| **Settings Page** | Raw JSON editor lacks schema validation | Add JSON Schema validation with error highlighting |
| **Models Page** | No virtualized list for large model collections | Add react-window/virtualization |
| **Logs Page** | Unbounded log accumulation (max 500 entries) | Add configurable retention, search, filtering |
| **Performance Page** | Sliders lack real-time preview | Add live parameter preview with validation |
| **Diagnostics** | Static validation only | Add runtime health metrics, benchmark history |
| **Overview** | No quick-actions for common tasks | Add "Quick Start" cards, recent models |
| **Accessibility** | No ARIA labels, keyboard nav audit | Add a11y audit, focus management |
| **Responsive** | Fixed desktop layout | Add responsive breakpoints for tablet |

### 3.3 UI Performance Optimizations
- **Code Splitting:** Lazy-load page components (`React.lazy` + `Suspense`)
- **Memoization:** `React.memo` for `ModelInfo` rows, `LogEntry` components
- **Virtualization:** Large lists (models, logs) -> `react-window`
- **Debouncing:** Config save debounce (currently immediate)
- **Web Workers:** Move validation/token counting off main thread

### 3.4 Design System Consistency
- Extract CSS custom properties to `:root` in `variables.css`
- Create component library storybook (optional)
- Standardize spacing, color tokens, border radius

---

## 4. PROCESS OPTIMIZATION (Priority: MEDIUM)

### 4.1 Build & CI/CD
- **Current:** No GitHub Actions workflows found
- **Add:** CI pipeline for:
  - PowerShell script syntax check (`test-health.ps1`)
  - TypeScript type check (`npm run build`)
  - Rust clippy + test (`cargo clippy && cargo test`)
  - Python pytest (`pytest llo-core/context_manager/tests`)
  - Security audit (`npm audit`, `cargo audit`, `pip-audit`)

### 4.2 Development Workflow
- **Hot Reload:** Tauri dev already supports, verify PowerShell script changes trigger reload
- **Debugging:** Add VSCode launch configs for Rust, PowerShell, Python
- **Pre-commit:** Husky + lint-staged for staged files

### 4.3 Release Automation
- **Version Bumping:** Automated via conventional commits
- **Changelog:** Auto-generate from commits
- **Artifacts:** Build Windows NSIS, macOS DMG, Linux AppImage
- **Signing:** Code signing pipeline for Windows/macOS

### 4.4 Testing Improvements
- **Current:** 44 Vitest tests, 12 Rust tests, 11 Python tests
- **Add:** E2E tests for critical flows (start server -> chat)
- **Add:** Visual regression tests for UI pages
- **Add:** Load testing for context manager proxy

---

## 5. CORE OPTIMIZATION (Priority: MEDIUM)

### 5.1 PowerShell Core (llo-core/)
| Script | Optimization Opportunity |
|--------|-------------------------|
| `Profile.ps1` | Cache GPU detection results, parallelize WMI queries |
| `SetupRouter.ps1` | Memoize model scanning, optimize GGUF parsing |
| `ParseHelp.ps1` | Cache llama-server help output parsing |
| `FetchAssets.ps1` | Parallel downloads, better SHA verification |
| `start-server.ps1` | Reduce startup latency, async log tailing |

### 5.2 Context Manager Proxy (Python)
- **Connection Pooling:** httpx limits (100 conn, 20 keepalive) - tune for load
- **Tokenizer Cache:** Add persistent disk cache for token counts
- **Compression:** Batch summarization requests, async pipeline
- **Session Eviction:** Configurable TTL, LRU eviction policy
- **Metrics:** Add Prometheus metrics endpoint

### 5.3 Tauri Backend (Rust)
- **Command Dispatch:** Batch IPC calls where possible
- **Log Tailing:** Current implementation reopens files - use `notify` crate for fs events
- **State Management:** AtomicBool for server status - consider `parking_lot::RwLock` for richer state
- **Resource Cleanup:** Ensure `LOG_TAIL_TASKS` properly cleaned on app exit

### 5.4 Algorithmic Improvements
- **Context Size Formula:** Align CLI (PowerShell) and UI (TypeScript) calculations (see ARCHITECTURE.md discrepancy note)
- **GPU Tier Detection:** Add Intel Arc, AMD ROCm improvements
- **Model Scanning:** Incremental scanning with mtime checks
- **Port Scanning:** Cache free port, reduce collision retries

---

## 6. EXECUTION ROADMAP

### Sprint 1 (Week 1) - Security & Critical Fixes
- [ ] Fix npm vulnerabilities (`npm audit fix --force`)
- [ ] Complete `cargo audit` and fix Rust vulnerabilities
- [ ] Run `pip-audit` on Python deps
- [ ] Apply security hardening to Tauri commands

### Sprint 2 (Week 2) - Library Updates (Safe)
- [ ] Update Tauri plugins, React, Zustand (patch/minor)
- [ ] Update Rust crates (cargo update)
- [ ] Update Python deps
- [ ] Run full test suite after each batch

### Sprint 3 (Week 3) - Major Library Updates
- [ ] Upgrade vitest -> 5.x (fixes critical vulns)
- [ ] Upgrade vite -> 7/8 + @vitejs/plugin-react -> 6
- [ ] Upgrade TypeScript -> 7
- [ ] Upgrade lucide-react -> 1.x (icon API changes)
- [ ] Fix all breaking changes in codebase

### Sprint 4 (Week 4) - UI Updates
- [ ] Settings: JSON Schema validation
- [ ] Models: Virtualized list
- [ ] Logs: Search/filter, retention config
- [ ] Performance: Live preview
- [ ] Accessibility audit + fixes

### Sprint 5 (Week 5) - Process & Core Optimization
- [ ] Add GitHub Actions CI pipeline
- [ ] Optimize PowerShell scripts (caching, parallelization)
- [ ] Context Manager: connection pooling, metrics
- [ ] Tauri: log tailing via fsnotify
- [ ] Align CLI/UI context size formulas

### Sprint 6 (Week 6) - Polish & Release
- [ ] E2E tests for critical flows
- [ ] Visual regression tests
- [ ] Documentation updates
- [ ] Release automation
- [ ] Performance benchmarks

---

## 7. RISK MITIGATION

| Risk | Impact | Mitigation |
|------|--------|------------|
| vitest 5.x breaking changes | Test suite failures | Run tests in isolation, fix incrementally |
| Vite 8 config changes | Build failures | Check migration guide, test dev/build |
| TypeScript 7 strictness | Type errors | Enable gradually, fix errors |
| lucide-react 1.x API | Icon import breaks | Codemod script, manual review |
| Tauri 2.x plugin API | Command failures | Test each command after upgrade |
| PowerShell 7+ requirement | Windows 5.1 compat | Add version check, fallback |

---

## 8. SUCCESS CRITERIA

- [ ] **Zero critical/high vulnerabilities** (npm, cargo, pip)
- [ ] **All tests pass** (44 Vitest, 12 Rust, 11 Python + new)
- [ ] **Build succeeds** on Windows, macOS, Linux
- [ ] **UI loads < 2s** (measure with web vitals)
- [ ] **Server startup < 5s** (cold start)
- [ ] **Context Manager proxy < 50ms** overhead
- [ ] **CI pipeline** runs on every PR
- [ ] **Documentation** updated for all changes

---

## 9. AGENT ASSIGNMENTS (for parallel execution)

| Agent | Workstream | Key Files |
|-------|------------|-----------|
| security-agent | Security Review | package.json, Cargo.toml, requirements.txt, Tauri commands |
| deps-agent | Library Updates | package.json, Cargo.toml, requirements.txt, migration scripts |
| ui-agent | UI Updates | ui/src/pages/*, ui/src/components/*, ui/src/store/* |
| process-agent | Process Optimization | .github/workflows/, scripts/, CI configs |
| core-agent | Core Optimization | llo-core/*.ps1, llo-core/context_manager/*.py, ui/src-tauri/src/ |

---

*Plan stored in shared folder: `docs/plans/comprehensive-update-plan.md`*
