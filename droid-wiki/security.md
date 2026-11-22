# Security

LLM Manager runs local LLM inference and optionally routes traffic to cloud fallback providers. This page describes the trust boundaries and security-relevant design decisions.

## Trust boundaries

* **Local-only by default.** When `fallback_provider` is `"none"` (the default), all inference happens on the local machine via `llama-server`. No model data or prompts leave the host.
* **Cloud fallback.** When `fallback_provider` is set to `anthropic`, `openai`, `nim`, or `ollama`, and no local models are found, client traffic is routed to the configured cloud provider. The API key is stored in `llo-config.json` under `fallback_api_key` — treat this file as containing secrets and restrict filesystem permissions accordingly.
* **Client integrations.** The VSCode, Claude Code, Cursor, and Continue integrations inject environment variables (`ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`) into the local terminal/workspace so clients point at the local server instead of remote endpoints. This reduces data leaving the machine but means anyone with access to the workspace terminal env can see the local routing configuration.

## Secrets handling

`fallback_api_key` is the only secret stored in config. It is read from `llo-config.json` and passed through to the fallback provider. There is no vault or encryption at rest in the current implementation. Rotate keys if `llo-config.json` is exposed.

## Input validation

* The TypeScript config schema (`ui/src/lib/configSchema.ts`) validates config keys, types, ranges, and enums at edit time in the Settings JSON editor.
* `verify-scripts.ps1` checks that every llama-server flag used in PowerShell scripts exists in the current binary's `--help` output, preventing silent failures from deprecated or renamed flags after a llama.cpp upgrade.
* External command flags (`git`, `nvidia-smi`) and PowerShell common flags (`-ExecutionPolicy`, `--help`, `--version`) are excluded from flag-compatibility checks to avoid false positives.

## Context Manager Proxy security

The optional Python proxy (`llo-core/context_manager/`) supports TLS (`tls_enabled`, `tls_cert_path`, `tls_key_path`), rate limiting (`rate_limit_enabled`, `rate_limit_requests`, `rate_limit_window_sec`), and session ID validation (`session_id_min_length`, `session_id_max_length`, `session_id_allowed_chars`). These are disabled by default (`enabled: false`).

## Related pages

- [Configuration reference](reference/configuration.md) — `fallback_api_key`, `context_manager` security keys
- [Systems](./systems/index.md) — compatibility guard and server lifecycle
- [Features](./features/index.md) — client integrations and upstream compatibility
