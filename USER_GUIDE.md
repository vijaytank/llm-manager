# LLM Manager - Easy Setup & User Guide

Welcome to **LLM Manager**! This tool is designed to take the complexity out of running local Large Language Models (LLMs) on your computer. 

If you are using `llama.cpp` to run models locally, this manager will automatically profile your computer's hardware and tune the configuration parameters so you get the **fastest possible response speeds without system crashes**.

---

## 0. Prerequisites by Platform

LLM Manager is written in PowerShell and runs on **Windows, macOS, and Linux**.

| Platform | Requirement | How to install |
|---|---|---|
| **Windows** | PowerShell (built-in) | Nothing to install |
| **macOS** | PowerShell 7 (`pwsh`) | `brew install powershell` |
| **Linux (Ubuntu/Debian)** | PowerShell 7 (`pwsh`) | `sudo apt install powershell` |
| **Linux (Fedora/RHEL)** | PowerShell 7 (`pwsh`) | `sudo dnf install powershell` |

### llama.cpp Binary

| Platform | Recommended Install |
|---|---|
| **Windows** | `winget install llama.cpp` or compile from source |
| **macOS** | `brew install llama.cpp` (provides `llama-server` in PATH) |
| **Linux** | Build from source or download a pre-built release from GitHub |

---

## 1. What LLM Manager Does For You
* **🚀 Auto-Tuning Performance**: Automatically sets the best thread count for your CPU and offloads the correct number of layers to your GPU, avoiding slow-downs.
* **💾 VRAM Memory Protection**: If you have a laptop or a consumer graphics card (like an RTX 4060, 5060, or similar), running large models can easily run out of memory. LLM Manager automatically optimizes settings like **Flash Attention** and **KV Cache Quantization** (compressing intermediate model memory) to fit models comfortably in your graphics card.
* **🍎 Apple Silicon Support**: On M-series Macs, the entire unified memory is treated as the inference budget, enabling large models to run efficiently.
* **🔀 Smart Model Swapping**: You don't need to restart your server to load a different model. Just put all your `.gguf` files in one folder; LLM Manager configures a "router" that automatically loads and swaps models into memory as your chat clients request them.
* **🔌 Seamless Client Integrations**: Configures your environment so you can use your local models in tools like **VSCode**, **Claude Code**, **Cursor**, **Continue**, or **GitHub CLI**.

---

## 2. Quick Start Setup

### Step 1: Run the Interactive Setup Wizard

**Windows:**
1. Open **PowerShell** (Click Start, type `PowerShell`, and open it).
2. Navigate to your `llm-manager` folder and run:
   ```powershell
   powershell -File main.ps1
   ```

**macOS / Linux:**
1. Open **Terminal**.
2. Navigate to your `llm-manager` folder and run:
   ```bash
   # Option A: convenience shell script (no pwsh knowledge needed)
   ./run-setup.sh

   # Option B: call pwsh directly
   pwsh -File main.ps1
   ```

3. Follow the simple prompts:
   * **Installation Path**: Copy and paste the path to your `llama-server` binary (or the folder where you compiled it).
     - Windows: e.g. `C:\Users\YourName\llama.cpp\build\bin\Release\llama-server.exe`
     - macOS (Homebrew): just press **Enter** — it is found automatically in PATH
     - Linux: e.g. `/home/yourname/llama.cpp/build/bin/llama-server`
   * **Models Directory**: Tell the wizard where you store your `.gguf` model files. If the directory doesn't exist, the script can create it for you.
   * **Chat Templates (Optional)**: If you have custom chat prompt templates, specify the directory. If not, just press **Enter** to skip; the server will automatically use the high-quality templates built directly inside your models.
   * **Speculative Decoding (Optional)**: Enable `ngram-simple` speculative decoding (helps coding models run ~10-15% faster).
   * **Custom Arguments (Optional)**: Provide additional command line arguments to pass to the server. If a value is already saved, press **Enter** to keep it, or type **`none`** or **`clear`** to remove it.
   * **Integration Preferences**: Choose where you want to use your models (e.g. Claude Code, VSCode, or just a REST API server).
   * **Claude Code Telemetry (Optional)**: If Claude Code is selected, choose whether to enable dynamic model switching (which requires telemetry).
   * **Configuration Review**: At the preview screen, type **`Y`** to save, **`N`** to cancel without saving, or **`Update`** to re-run the wizard prompts.

### Step 2: Auto-Optimization (Hands-off)
The script will analyze your system:
* It reads your CPU cores, system RAM, and GPU VRAM (or unified memory on Apple Silicon).
* It auto-tunes parameters (e.g., setting your cache compression to `q8_0` or `q4_0` if VRAM is tight).
* It prints a clean summary of your **Proposed Configuration** and saves it to `llo-config.json`.

---

## 3. Managing Your Local Server

### Starting the Server
At the end of the setup wizard, you will be asked if you want to start the server.

To start the server manually later:

**Windows:**
```powershell
powershell -File script\start-server.ps1
```

**macOS / Linux:**
```bash
# Option A: convenience wrapper
./script/start-server.sh

# Option B: pwsh directly
pwsh -File script/start-server.ps1
```

### Stopping the Server

**Windows:**
```powershell
powershell -File script\stop-server.ps1
```

**macOS / Linux:**
```bash
# Option A: convenience wrapper
./script/stop-server.sh

# Option B: pwsh directly
pwsh -File script/stop-server.ps1
```

---

## 4. Connecting Your Chat Clients

By default, the server runs on **`http://127.0.0.1:8080`**.

> [!NOTE]
> **Port Collision Protection**: If port `8080` is already occupied by another application on your system, LLM Manager will automatically scan and shift `llama-server` to the next available free port (e.g., `8081`, `8082`). Always check the server logs in the startup window for the active port!

### A. VSCode & Cursor / Continue
Most IDE plugins expect an OpenAI-compatible endpoint. Configure your plugin settings with:
* **API Base URL**: `http://127.0.0.1:<PORT>/v1` (replace `<PORT>` with your active port, e.g., `8080` or `8081`)
* **API Key**: `local-key` (any text works)
* **Model ID**: Enter the name of any model file from your folder (e.g., `qwen3-5-4b-q5-k-m`).

### B. Claude Code CLI
During server startup, the script automatically exports the necessary environment variables (`ANTHROPIC_BASE_URL`, etc.). 
1. Start the server in one window.
2. Open a new terminal in the same session.
3. Run `claude` — it will automatically connect to your local server instead of the cloud!

---

## 5. Troubleshooting & Tips
* **Slow Responses / Lag**: Ensure your GGUF models are not too large for your GPU. If you load a 14B model on an 8GB VRAM card, parts of it will spill over to system RAM, causing slow-downs. Try models in the 3B to 9B range (like `qwen3.5-4b`, `gemma-2-9b`, etc.) for optimal speed.
* **Upstream Flag Compatibility**: If you have recently run `git pull` on `llama.cpp` and the server fails to start, you can audit your local scripts against the current `llama-server` binary options:

  **Windows:**
  ```powershell
  powershell -File script\verify-scripts.ps1
  ```
  **macOS / Linux:**
  ```bash
  pwsh -File script/verify-scripts.ps1
  ```

* **Full E2E Health Verification**: To test all configuration schemas, local PowerShell script syntax, system hardware profiling values, and execute a live REST API ping to see if the server is healthy:

  **Windows:**
  ```powershell
  powershell -File script\test-health.ps1
  ```
  **macOS / Linux:**
  ```bash
  pwsh -File script/test-health.ps1
  ```

* **Apple Silicon (M-series) Notes**: The profiler detects Apple Silicon automatically via `system_profiler`. The entire unified memory is used as the inference budget. A 16 GB M3 Mac is treated as having 16 GB of "VRAM".
* **AMD GPU on Linux**: Install ROCm and ensure `rocm-smi` is in your PATH for accurate VRAM detection. Without it, the profiler falls back to `/sys/class/drm` sysfs entries.
