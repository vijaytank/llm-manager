# Fun facts

A few light notes about the LLM Manager codebase. Five topics, no more.

## 1. Naming origins — built on llama.cpp

LLM Manager is an orchestrator for [llama.cpp](https://github.com/ggerganov/llama.cpp), Georgi Gerganov's C/C++ library for LLM inference. It drives the `llama-server` binary and derives its launch parameters from host hardware. The name "LLM Manager" reflects its role — it manages the full local inference lifecycle (hardware profiling, parameter derivation, model serving, client routing) rather than being a model itself. Internally, `llo-core` is shorthand for "LLM Manager Orchestrator Core" (per `CLAUDE.md`).

## 2. Repo age

Git history shows the first commit on **11 July 2026** ("initial commit: add basic files and architecture documentation"), with active development through **22 November 2026**. The codebase is roughly four and a half months old at the time of this writing. The busiest month by far was November 2026 (32 of 65 visible commits) — see [Lore](lore.md) for the full timeline.

## 3. Longest file

The longest single source file is `llo-core/context_manager/proxy.py` at **1,043 lines** — the FastAPI proxy that translates the Anthropic protocol to OpenAI and runs the HTTP round-trip. Runner-up: `llo-core/SetupRouter.ps1` at **891 lines** (parameter derivation and preset generation), then `main.ps1` at **847 lines** (the interactive setup wizard). `main.ps1` is sometimes assumed to be the largest, but it places third by measured line count.

## 4. Almost no TODO/FIXME debt

A repo-wide scan for `TODO`, `FIXME`, `HACK`, and `XXX` markers turns up **zero actionable markers** in source code. The word "TODO" appears only incidentally, in prose inside an architecture-decision comment block in `llo-core/context_manager/context_engine.py`. Whether that means the project is well-groomed or simply that rough edges go unrecorded is unclear.

## 5. No bot commits

The project has a single contributor (Vijay Tank) and **no bot-attributed commits** on `develop` — 64 commits by Vijay Tank, 1 by `vijay10`, and none by Dependabot, GitHub Actions bots, or automation accounts. So 100% of commits are human-attributed, though inline AI tool use leaves no trace in git history.

## Related pages

- [By the numbers](by-the-numbers.md) — codebase statistics snapshot, including commit trend and churn hotspots
- [Lore](lore.md) — full dated timeline and era history
- [Overview](overview/index.md) — what LLM Manager does
- [Architecture](overview/architecture.md) — hardware classification and decision flow
- [Getting started](overview/getting-started.md) — prerequisites, install, build, test, run
