# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## ⚙️ Core Architecture
This project functions as an LLM manager wrapper, primarily focused on tracking and analyzing upstream changes in the external `llama.cpp` repository. The system's intelligence is centered around its ability to parse commit logs and identify system-relevant updates.

The main logic is contained within the `llo-core` module, specifically the `GitDiff.ps1` script. This script manages the dependency relationship, reading the necessary `llama_repo_path` from `llo-config.json` to interact with `llama.cpp`'s git history.

**Key Architectural Components:**
*   **`llo-config.json`**: The central configuration file that dictates the location of the primary dependency (`llama.cpp`).
*   **`llo-core/GitDiff.ps1`**: The primary analysis tool. It performs the following critical functions:
    *   Checks the current branch status against the remote upstream repository.
    *   Parses recent commit history (`git log`).
    *   Identifies and flags commits containing keywords relevant to performance, hardware compatibility, or breaking changes (e.g., `cuda`, `perf`, `vram`, `breaking`, `server`, `preset`, `flash-attn`).

## 🛠️ Common Commands
The primary development and monitoring task is running the Git status analysis script.

**Monitoring Upstream Changes:**
To run the change log and compatibility diff tool for `llama.cpp`:
```bash
.\llo-core\GitDiff.ps1
```

**Note on Development:**
The project is built around PowerShell scripting (`.ps1`). Build, lint, and test commands are not defined in a standard package manager (`package.json`/`Makefile`), so development workflows must be tailored to PowerShell scripting conventions and the logic within `llo-core`.

## 🔗 Project Dependencies
The project is critically dependent on having a local copy of the `llama.cpp` repository available at the path configured in `llo-config.json`. This dependency is the source of all tracked changes and architecture.