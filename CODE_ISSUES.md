# LLM Manager: Codebase Issues & Technical Audit

This document captures the codebase anomalies, bugs, and design inconsistencies identified during the detailed review of the **LLM Manager** repository. Since no code changes were requested, these issues are logged here for future refactoring and maintenance.

---

## 1. Major Architectural Anomalies

### 1.1 The Configuration Split (AppData vs. Workspace Root)
* **Location**: `ui-src-tauri/src/commands/config.rs` vs. `main.ps1`, `script/start-server.ps1`, and `llo-core/SetupRouter.ps1`.
* **Issue**: 
  - The Tauri GUI application loads and saves `llo-config.json` inside the user's roaming directory:
    - **Windows**: `%APPDATA%\LLM Manager\llo-config.json`
    - **macOS/Linux**: `~/.config/LLM Manager/llo-config.json`
  - The PowerShell scripts (`main.ps1`, `start-server.ps1`, `SetupRouter.ps1`) default to looking for `llo-config.json` in the workspace root folder.
* **Impact**: If a user runs the CLI setup wizard, it updates the workspace config file. If they then run the Tauri GUI app, the app will read from the AppData file (which was copied once during first-run and is now stale). The GUI and CLI settings will remain desynchronized.
* **Recommendation**: Modify the PowerShell scripts to check the AppData path first, falling back to the workspace root only if the AppData directory is uninitialized.

### 1.2 Static VSCode Settings vs. Port Collision Protection
* **Location**: `main.ps1` vs. `script/start-server.ps1`.
* **Issue**:
  - `start-server.ps1` contains robust **Port Collision Protection** that shifts the active port upward if the target port (default 8080) is occupied.
  - However, `main.ps1` writes **static environment variables** hardcoded to `http://127.0.0.1:8080` inside the `.vscode/settings.json` file.
* **Impact**: If a collision occurs and the port shifts (e.g., to `8081`), any VSCode terminals spawned afterward will still use the environment variables from `settings.json` pointing to `8080` (the occupied port), causing client requests to fail.
* **Recommendation**: Let `start-server.ps1` rewrite `.vscode/settings.json` dynamically with the shifted port whenever a collision occurs, or write a configuration key that clients read dynamically.

---

## 2. Parameter Tuning & Safety Guard Bugs

### 2.1 Speculative Decoding Safeguard Bypass on Low-Tier GPUs
* **Location**: `main.ps1` vs. `llo-core/SetupRouter.ps1`.
* **Issue**:
  - In `SetupRouter.ps1`, speculative decoding is disabled for the `low` tier (`spec-type = none`) to prevent Out-of-Memory (OOM) crashes on 2–4 GB cards.
  - However, the interactive wizard `main.ps1` prompts the user: `"Enable ngram-simple speculative decoding? (Y/N)"` regardless of their GPU tier. 
  - If the user selects "Y", the wizard writes `spec_type = "ngram-simple"` to the flat config, which `SetupRouter.ps1` maps directly into `overrides`.
* **Impact**: Overrides take absolute priority, bypassing the `low` tier safety check. This can lead to server OOM crashes during startup on low-VRAM GPUs.
* **Recommendation**: In `SetupRouter.ps1`, ensure that speculative decoding validation (`Get-ValidatedSpecType`) is enforced on overrides as well, or restrict the wizard prompt based on the detected hardware profile.

### 2.2 SetupRouter Overrides Promotion Contradiction
* **Location**: `llo-core/SetupRouter.ps1` (lines 108–132).
* **Issue**:
  - The header comments and `ARCHITECTURE.md` state that flat legacy keys in `llo-config.json` are ignored for hardware-adaptive tuning.
  - In reality, the script runs `Map-LegacyConfigKeyToOverride` to promote these flat keys directly into the `overrides` hashtable.
* **Impact**: Once a user runs `main.ps1`, all these keys are saved at the flat level in `llo-config.json`. On subsequent server starts, `SetupRouter.ps1` promotes them to overrides, effectively disabling the dynamic hardware-adaptive tuning for those parameters and locking them to stale wizard values.
* **Recommendation**: Update comments to document this promotion, or separate user overrides from wizard-generated baseline configurations.

---

## 3. Computational Discrepancies

### 3.1 KV Cache Memory Estimation Math Mismatch
* **Location**: `llo-core/SetupRouter.ps1` (lines 381–386) vs. `ui/src/lib/validation.ts` (lines 34–35).
* **Issue**:
  - **Tauri UI (`validation.ts`)**: Uses exact element byte sizes (`f16` = 2.0 bytes, `q8_0` = 1.0625 bytes, `q4_0` = 0.5625 bytes) and a physical model geometry calculation.
  - **PowerShell Backend (`SetupRouter.ps1`)**: Uses linear multipliers (`f16` = 2.0×, `q8_0` = 1.0×, `q4_0` = 0.5×) based on an estimated baseline of 12.0 MB per GB of model size per 1k tokens.
* **Impact**: Mismatched memory estimates. `q8_0` is calculated as 53.1% of `f16` in the GUI, but exactly 50% in the CLI, causing different VRAM budget warning triggers for identical setups.
* **Recommendation**: Align `SetupRouter.ps1` math with the exact element-based byte calculator.
