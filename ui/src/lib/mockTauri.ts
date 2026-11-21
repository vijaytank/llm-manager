/**
 * Browser-mode mock bridge for Tauri IPC.
 * Active ONLY in standalone browser environments where window.__TAURI_INTERNALS__ is undefined.
 * In native Tauri app, window.__TAURI_INTERNALS__ is provided by the Rust webview runtime,
 * so this module is a complete no-op.
 */

export function setupMockTauriIfNeeded(): void {
  if (typeof window === 'undefined') return;
  if ((window as any).__TAURI_INTERNALS__) return;

  const mockConfig = {
    installation_type: 'winget',
    llama_server_path: 'C:\\llama.cpp\\llama-server.exe',
    llama_repo_path: 'C:\\llama.cpp',
    models_dir: 'C:\\llama.cpp\\models',
    templates_dir: 'C:\\llama.cpp\\templates',
    grammars_dir: 'C:\\llama.cpp\\grammars',
    active_model: 'Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf',
    use_default_template: false,
    fit_ctx_min: 8192,
    cache_type_k: 'f16',
    cache_type_v: 'f16',
    flash_attn: 'auto',
    context_shift: true,
    default_context_size: 32768,
    ubatch_size: 512,
    parallel_slots: 1,
    overrides: {
      n_gpu_layers: 33,
      ctx_size: 32768,
      threads: 16,
      cache_type_k: 'f16',
      cache_type_v: 'f16',
      ubatch_size: 512,
      flash_attn: 'auto',
    },
    integrations: ['claude-code', 'cursor', 'vscode'],
    idle_timeout_sec: 120,
    fallback_provider: 'openrouter',
    fallback_api_key: 'sk-or-v1-demo-key-mask',
    fallback_endpoint: 'https://openrouter.ai/api/v1',
    fallback_model: 'meta-llama/llama-3.1-70b-instruct',
    context_manager: {
      enabled: true,
      warn_threshold: 0.75,
      keep_turns: 6,
      proxy_port: 8090,
      ctx_limit: 32768,
      tokenizer_repo: 'meta-llama/Meta-Llama-3.1-8B-Instruct',
      summary_max_tokens: 768,
      summarize_with_model: 'same',
    },
  };

  const mockHardware = {
    cpu: {
      name: 'AMD Ryzen 9 7950X 16-Core Processor',
      physicalCores: 16,
      logicalCores: 32,
      optimalThreads: 16,
    },
    ram: {
      totalGb: 64.0,
      safeBudgetMb: 52000,
    },
    gpu: {
      name: 'NVIDIA GeForce RTX 4090',
      totalVramMb: 24576,
      adapterClass: 'dedicated',
      performanceTier: 'high',
      reason: '24GB VRAM dedicated GPU detected with full CUDA acceleration',
    },
  };

  const mockModels = [
    {
      name: 'Meta-Llama-3.1-8B-Instruct-Q4_K_M',
      filename: 'Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf',
      path: 'C:\\llama.cpp\\models\\Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf',
      fileSizeGb: 4.92,
      quantization: 'Q4_K_M',
      template: 'llama-3.jinja',
      templateMatchMethod: 'exact',
      calculatedContext: 32768,
      status: 'ready',
      isMmproj: false,
    },
    {
      name: 'DeepSeek-R1-Distill-Qwen-14B-Q4_K_M',
      filename: 'DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf',
      path: 'C:\\llama.cpp\\models\\DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf',
      fileSizeGb: 8.99,
      quantization: 'Q4_K_M',
      template: 'chatml.jinja',
      templateMatchMethod: 'exact',
      calculatedContext: 32768,
      status: 'ready',
      isMmproj: false,
    },
    {
      name: 'Qwen2.5-Coder-32B-Instruct-Q4_K_M',
      filename: 'Qwen2.5-Coder-32B-Instruct-Q4_K_M.gguf',
      path: 'C:\\llama.cpp\\models\\Qwen2.5-Coder-32B-Instruct-Q4_K_M.gguf',
      fileSizeGb: 19.85,
      quantization: 'Q4_K_M',
      template: 'chatml.jinja',
      templateMatchMethod: 'exact',
      calculatedContext: 16384,
      status: 'ready',
      isMmproj: false,
    },
    {
      name: 'Mistral-7B-Instruct-v0.3-Q8_0',
      filename: 'Mistral-7B-Instruct-v0.3-Q8_0.gguf',
      path: 'C:\\llama.cpp\\models\\Mistral-7B-Instruct-v0.3-Q8_0.gguf',
      fileSizeGb: 7.7,
      quantization: 'Q8_0',
      template: 'mistral.jinja',
      templateMatchMethod: 'exact',
      calculatedContext: 32768,
      status: 'ready',
      isMmproj: false,
    },
    {
      name: 'mmproj-model-f16',
      filename: 'mmproj-model-f16.gguf',
      path: 'C:\\llama.cpp\\models\\mmproj-model-f16.gguf',
      fileSizeGb: 0.85,
      quantization: 'F16',
      template: 'default.jinja',
      templateMatchMethod: 'none',
      calculatedContext: 0,
      status: 'ready',
      isMmproj: true,
    },
  ];

  const mockHealthReport = {
    timestamp: new Date().toLocaleTimeString(),
    passedCount: 5,
    totalCount: 5,
    items: [
      {
        title: 'llama-server Executable Verification',
        description: 'Binary verified at C:\\llama.cpp\\llama-server.exe (AVX2 + CUDA build)',
        status: 'passed',
      },
      {
        title: 'NVIDIA CUDA VRAM Allocation Space',
        description: '24,576 MB total VRAM available. Safe budget allows 100% layer offloading.',
        status: 'passed',
      },
      {
        title: 'Chat Template Directory Integrity',
        description: '5 verified Jinja templates discovered in C:\\llama.cpp\\templates',
        status: 'passed',
      },
      {
        title: 'GGUF Model Header & Quantization Check',
        description:
          'Selected model Meta-Llama-3.1-8B-Instruct (4.92 GB) validated with valid GGUFv3 magic number',
        status: 'passed',
      },
      {
        title: 'KV Cache Headroom & Context Budget',
        description:
          'Context size 32,768 tokens consumes 2.1 GB KV cache (f16) well within 24GB VRAM ceiling',
        status: 'passed',
      },
    ],
  };

  let serverStatus = 'running';

  const mockInvoke = async (cmd: string, args: any = {}) => {
    switch (cmd) {
      case 'load_config':
        return mockConfig;
      case 'save_config':
        if (args?.config) Object.assign(mockConfig, args.config);
        return null;
      case 'detect_hardware':
        return mockHardware;
      case 'scan_models':
        return mockModels;
      case 'get_server_status':
        return serverStatus;
      case 'start_server':
        serverStatus = 'running';
        return 'Server started successfully on port 8080';
      case 'stop_server':
        serverStatus = 'stopped';
        return 'Server stopped';
      case 'get_active_model_info':
        return {
          active_model: mockConfig.active_model,
          models_preset_path: 'C:\\llama.cpp\\models',
        };
      case 'list_templates':
        return ['llama-3.jinja', 'chatml.jinja', 'mistral.jinja', 'phi-3.jinja', 'gemma.jinja'];
      case 'run_health_check':
      case 'audit_scripts':
        return mockHealthReport;
      case 'plugin:event|listen':
        return 1;
      case 'plugin:dialog|open':
        return 'C:\\llama.cpp\\models';
      default:
        console.warn(`[MockTauri] Unhandled command: ${cmd}`, args);
        return null;
    }
  };

  (window as any).__TAURI_INTERNALS__ = {
    invoke: mockInvoke,
    transformCallback: (fn: any) => fn,
  };

  console.info('[MockTauri] Browser dev bridge active with mock hardware, models & config.');
}
