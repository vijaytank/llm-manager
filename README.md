# LLM Manager

LLM Manager is a system-specific optimization tool and integration hub built on top of `llama.cpp`. It solves configuration, compatibility, and integration problems for local LLM usage, tailoring performance specifically to your hardware (CPU cores, RAM, GPU, VRAM) and automatically adapting to upstream changes.

---

## 1. Project Goals

1. **Optimal System Tuning**: Automatically profile hardware and configure parameters like thread count (`-t`), batch sizes (`-b`), and GPU offload layers (`-ngl`) to maximize tokens per second.
2. **Upstream Compatibility Guard**: Detect changes, improvements, and deprecations in `llama.cpp` on `git pull` and automatically validate custom runner scripts.
3. **Implicit Client-Side Routing**: Enable multi-model hosting. Third-party clients (VSCode, Claude Code, Droid, Cursor) request models by ID, and the server router loads/unloads them dynamically within your VRAM budget.
4. **Bootstrapping / Hybrid Fallback**: Support cloud APIs (OpenAI, Anthropic, NVIDIA NIM) or local Ollama instances when no local GGUF models are loaded.

---

## 2. Directory Structure

```
llm-manager/
├── .gitignore              # Ignores model binaries, caches, and logs
├── README.md               # This guide
├── llo-config.json         # Settings & API keys (e.g. Anthropic, OpenAI)
├── models-preset.ini       # Automatically managed router presets
│
├── .vscode/
│   ├── tasks.json          # VSCode tasks (Start, stop, test server)
│   └── settings.json       # Env variables & integration helpers
│
├── docs/
│   └── SYSTEM_COMMANDS.md  # Auto-generated command help & hardware tips
│
├── llo-core/               # Core Engine Logic
│   ├── Profile.ps1         # Hardware detection
│   ├── ParseHelp.ps1       # Compiles command help registry & flag diffs
│   ├── GitDiff.ps1         # Checks llama.cpp commits for updates
│   └── SetupRouter.ps1     # Generates models-preset.ini automatically
│
└── script/                 # User control scripts
    ├── start-server.ps1    # Bootstraps router and launches llama-server
    ├── stop-server.ps1     # Gracefully stops the server on port 8080
    └── verify-scripts.ps1  # Scans and validates running scripts
```

---

## 3. How the Architecture Works

### A. The Optimization Engine
The engine profiles the system:
- **CPU Threads**: Matches your physical cores (optimal for Intel Core Ultra 7).
- **VRAM Buffer**: Calculates maximum layers to offload to your RTX 5060 (8GB VRAM), reserving a buffer for display/OS.
- **Model Presets**: Scans the `models/` directory, computes optimal offload layers for each GGUF size, and writes them to `models-preset.ini`.

### B. Upstream Change Registry
When `git pull` is run inside `llama.cpp/`, a `post-merge` hook:
1. Runs `llama-server.exe --help` and compares it to the previous registry.
2. Lists new flags (improvements) and deprecated flags (drawbacks/breaking changes).
3. Evaluates pulled commits for CUDA/CPU updates and logs system advisories in `docs/SYSTEM_COMMANDS.md`.

### C. Bootstrapping (First-Run Fallback)
If no `.gguf` files exist in `models/`, the server starts in **Proxy Mode** routing API queries to your specified Ollama local server or cloud API (Anthropic, OpenAI, NVIDIA NIM). As soon as you add a GGUF model, it switches to local routing.

### D. Third-Party Integrations
- **VSCode/Cursor**: Setup tasks in `.vscode/tasks.json` to control the server.
- **Claude Code**: Scripts export endpoint environment variables so that `claude` CLI connects to your local server.
- **Droid/Mobile**: Configures `--host 0.0.0.0` for safe LAN access.
