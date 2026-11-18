# Testing

**Active contributors:** vijay

Testing frameworks, patterns, and how to run tests for each component.

## Test matrix

| Component | Framework | Command | Location |
|-----------|-----------|---------|----------|
| PowerShell scripts | Pester / AST Parser | `powershell -File script/test-health.ps1` | `script/` |
| PowerShell flag compat | Custom | `powershell -File script/verify-scripts.ps1` | `script/` |
| Python context manager | pytest | `pytest llo-core/context_manager/tests` | `llo-core/context_manager/tests/` |
| React frontend | Vitest | `cd ui && npm run test` | `ui/src/**/__tests__/` |
| Rust backend | cargo test | `cd ui/src-tauri && cargo test` | `ui/src-tauri/src/**/tests/` |
| Rust lints | cargo clippy | `cd ui/src-tauri && cargo clippy` | — |

## PowerShell testing

### Health check script (`script/test-health.ps1`)

Comprehensive validation run before every PR:

1. **Syntax validation** — AST parser on all `.ps1` files (excludes itself)
2. **Config schema** — Validates `llo-config.json` required keys, overrides block
3. **Hardware profiler API** — Invokes `Profile.ps1 -Json`, validates JSON structure
4. **Parameter derivation** — Invokes `SetupRouter.ps1` with test config, checks output
5. **Live server ping** — If server running, hits `/health` and `/v1/models`
6. **Flag compatibility** — Runs `verify-scripts.ps1` logic inline

```powershell
# Run all checks
powershell -File script/test-health.ps1

# JSON output for CI
powershell -File script/test-health.ps1 -Json
```

### Flag compatibility (`script/verify-scripts.ps1`)

Parses `llama-server --help` and verifies all flags used in PowerShell scripts exist in the binary's help output. Excludes external command flags (`git`, `nvidia-smi`) and PowerShell common flags.

```powershell
powershell -File script/verify-scripts.ps1
```

## Python testing (Context Manager)

### Test structure

```
llo-core/context_manager/tests/
├── test_compression.py       # Context compression logic
├── test_token_counting.py    # Tokenizer accuracy
├── test_session_tracking.py  # Session state persistence
├── test_protocol_conversion.py # Anthropic ↔ OpenAI translation
├── test_http_roundtrip.py    # Full proxy integration
├── test_checkpoint_persistence.py # Disk checkpoints
├── test_needs_compression.py # Heuristic validation
├── test_tokenizer_cache.py   # Alias normalization, caching
├── test_preset_reader.py     # models-preset.ini parsing
├── test_config.py            # Pydantic settings
└── conftest.py               # Fixtures
```

### Running tests

```bash
# Using project venv (recommended)
cd llo-core/context_manager
.venv/bin/activate
pytest tests/ -v

# Or with global pytest
pytest llo-core/context_manager/tests -v

# Specific test file
pytest llo-core/context_manager/tests/test_compression.py -v

# With coverage
pytest llo-core/context_manager/tests --cov=context_manager --cov-report=term-missing
```

### Key test patterns

**Async tests** — Use `pytest-asyncio`:
```python
@pytest.mark.asyncio
async def test_compress_long_session():
    engine = ContextEngine(...)
    session = engine.get_or_create_session("test")
    # ... add messages ...
    compressed = await engine.compress(session, ...)
    assert compressed.summary_token_count > 0
```

**Fixtures** — Shared test config, mock llama-server:
```python
@pytest.fixture
def mock_llama_server(monkeypatch):
    async def mock_post(*args, **kwargs):
        return MockResponse(...)
    monkeypatch.setattr(httpx.AsyncClient, "post", mock_post)
```

**Parametrized tests** — Multiple model aliases:
```python
@pytest.mark.parametrize("alias,expected_repo", [
    ("claude-3-5-sonnet-20241022", "anthropic/claude-3.5-sonnet"),
    ("gpt-4o", "openai/gpt-4o"),
])
def test_tokenizer_alias_normalization(alias, expected_repo):
    assert normalize_alias(alias) == expected_repo
```

## React frontend testing (Vitest)

### Test structure

```
ui/src/
├── components/__tests__/
│   ├── ImpactBanner.test.tsx
│   └── InfoTooltip.test.tsx
├── store/__tests__/
│   ├── hardwareStore.test.ts
│   ├── configStore.test.ts
│   ├── serverStore.test.ts
│   ├── modelsStore.test.ts
│   └── validationStore.test.ts
├── lib/__tests__/
│   └── validation.test.ts
└── pages/__tests__/
    └── OverviewPage.test.tsx
```

### Running tests

```bash
cd ui
npm run test           # Watch mode
npm run test:run       # Single run (CI)
npm run test:coverage  # With coverage
```

### Key patterns

**Zustand store testing:**
```typescript
import { useHardwareStore } from '../store/hardwareStore';
import { renderHook, act } from '@testing-library/react';

test('fetchHardware populates profile', async () => {
  const { result } = renderHook(() => useHardwareStore());
  await act(async () => {
    await result.current.fetchHardware();
  });
  expect(result.current.profile).not.toBeNull();
  expect(result.current.profile.performanceTier).toBeDefined();
});
```

**Component testing with Tauri mock:**
```typescript
import { ImpactBanner } from '../components/ImpactBanner';
import { render, screen } from '@testing-library/react';

test('renders severity badge', () => {
  render(<ImpactBanner assessment={{ severity: 'caution', param: 'ctx_size', message: 'Test' }} />);
  expect(screen.getByText('Test')).toBeInTheDocument();
});
```

## Rust backend testing (cargo test)

### Test structure

Unit tests live alongside source in `#[cfg(test)]` modules:

```rust
// ui/src-tauri/src/commands/profile.rs
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_profile_deserialization() {
        let raw_json = r#"{"cpu":{"name":"Test",...}}"#;
        let profile: SystemHardwareProfile = serde_json::from_str(raw_json).unwrap();
        assert_eq!(profile.gpu.performance_tier, "high");
    }

    #[test]
    fn test_live_hardware_detection() {
        let live_profile = detect_hardware().expect("Live hardware detection must succeed");
        assert_ne!(live_profile.gpu.name, "No Compatible GPU");
    }
}
```

### Running tests

```bash
cd ui/src-tauri
cargo test                    # All tests
cargo test profile::tests     # Specific module
cargo test -- --nocapture     # Show println! output
cargo clippy                  # Lints (must pass)
cargo fmt --check             # Format check
```

### Integration test pattern

Tests that invoke PowerShell scripts use the `run_powershell_script` bridge:

```rust
#[test]
fn test_profile_script_output() {
    let output = run_powershell_script("llo-core/Profile.ps1", &["-Json"]).unwrap();
    let profile: SystemHardwareProfile = serde_json::from_str(&output).unwrap();
    assert!(profile.gpu.total_vram_mb > 0);
}
```

## Mocking strategies

| Layer | Mock approach |
|-------|---------------|
| llama-server HTTP | `httpx.AsyncClient` monkeypatch (Python), `mockito` / `wiremock` (Rust) |
| PowerShell scripts | Test with `-Json` flag, validate JSON schema; or use temporary config files |
| Tauri commands | Unit test command handlers directly with mocked `AppHandle` |
| File system | `tempfile` crate (Rust), `tempfile` module (Python), temp dirs (PowerShell) |
| Hardware detection | Not mocked in integration tests — runs real detection |

## CI pipeline

GitHub Actions (`.github/workflows/`) runs on every push/PR to `develop`:

1. **PowerShell** — `test-health.ps1` + `verify-scripts.ps1` on Windows/macOS/Linux runners
2. **Python** — `pytest` on Ubuntu (with project venv)
3. **Frontend** — `npm run build` + `npm run test:run` on Ubuntu
4. **Backend** — `cargo test` + `cargo clippy` on Ubuntu/Windows/macOS
5. **Tauri build** — Release artifacts on tag push

## Coverage targets

No hard gates, but aim for:
- Python: >80% on `context_engine.py`, `proxy.py`
- Rust: >70% on command handlers
- React: >60% on stores and validation logic
- PowerShell: 100% syntax validation (AST parse)
