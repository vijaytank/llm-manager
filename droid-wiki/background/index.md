# Background

Design decisions, pitfalls, and migration context for LLM Manager.

## Why two hardware dimensions?

Every GPU is classified on `AdapterClass` (hardware identity: none/integrated/dedicated) and `PerformanceTier` (inference policy: cpu/low/mid/high). This avoids conflating a GPU's physical nature with whether it's useful for offload. A 2 GB discrete GPU is "dedicated" hardware but lands in the `cpu` tier because its VRAM is too small for meaningful layer offload.

## Override lock (legacy config promotions)

`SetupRouter.ps1` promotes flat legacy keys (e.g. `cache_type_k`, `flash_attn`) from `llo-config.json` into the `overrides` block. Because overrides take absolute priority over hardware detection, these promoted keys lock derived parameters to their historical wizard values. Clearing them restores dynamic tier-based optimization. See [configuration-system](../systems/configuration-system.md).

## CLI vs UI KV-cache math discrepancy

The CLI (`SetupRouter.ps1`) uses a simplified linear approximation (`q8_0` = 50% of `f16`, `q4_0` = 25%). The React diagnostics screen (`ui/src/lib/validation.ts`) uses exact element byte sizes (`q8_0` = 53.1%, `q4_0` = 28.1%). This causes a slight headroom-estimate mismatch between CLI output and the UI diagnostics. It is a known approximation gap, not a bug.

## AppData configuration directory split

The GUI and the Python proxy both read `llo-config.json` from the user's AppData directory, never the workspace root. PowerShell scripts receive the AppData path via `-ConfigFile`. This is intentional so the GUI's config is the single source of truth, but it means config edits made directly to the workspace `llo-config.json` won't affect the running GUI.

## Port collision handling

`start-server.ps1` scans upward from port 8080 when the port is occupied and propagates the resolved port to all client environment URLs. Clients that hardcode port 8080 will break until the port scanner resolves a free socket and exports the new URL.

## Related pages

- [Architecture](../overview/architecture.md) — decision flow and core formulas
- [Systems](../systems/index.md) — parameter derivation, configuration, compatibility guard
- [Configuration reference](../reference/configuration.md) — `llo-config.json` schema
