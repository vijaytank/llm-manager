import { describe, it, expect } from 'vitest';
import { validateModelLaunch } from '../../lib/validation';
import { AppConfig } from '../../store/configStore';
import { SystemHardware } from '../../store/hardwareStore';
import { ModelInfo } from '../../store/modelsStore';

const baseConfig: AppConfig = {
  installation_type: 'winget',
  llama_server_path: 'C:\\llama\\llama-server.exe',
  llama_repo_path: '',
  models_dir: 'C:\\llama\\models',
  templates_dir: '',
  grammars_dir: '',
  active_model: 'Qwythos-9B-v2-Q4_K_M',
  use_default_template: false,
  cache_type_k: 'f16',
  cache_type_v: 'f16',
  flash_attn: 'auto',
  context_shift: true,
  default_context_size: 32768,
  fit_ctx_min: 8192,
  ubatch_size: 512,
  parallel_slots: 1,
  overrides: {},
  integrations: ['server-only'],
  idle_timeout_sec: 60,
  fallback_provider: 'none',
  fallback_api_key: '',
  fallback_endpoint: '',
  fallback_model: '',
};

const rtx5060Hardware: SystemHardware = {
  cpuName: 'Intel Core Ultra 7 255H',
  physicalCores: 16,
  logicalCores: 16,
  totalRamGb: 24,
  gpuName: 'NVIDIA GeForce RTX 5060 Laptop GPU',
  vramGb: 8,
  adapterClass: 'dedicated',
  performanceTier: 'mid',
};

const cpuHardware: SystemHardware = {
  cpuName: 'Host Processor',
  physicalCores: 4,
  logicalCores: 4,
  totalRamGb: 24,
  gpuName: 'No Compatible GPU',
  vramGb: 0,
  adapterClass: 'none',
  performanceTier: 'cpu',
};

const model5Gb: ModelInfo = {
  name: 'Qwythos-9B-v2-Q4_K_M',
  filename: 'Qwythos-9B-v2-Q4_K_M.gguf',
  path: 'C:\\llama\\models\\Qwythos-9B-v2-Q4_K_M.gguf',
  fileSizeGb: 5.3,
  quantization: 'Q4_K_M',
  template: 'chatml',
  templateMatchMethod: 'binary-header',
  calculatedContext: 32768,
  status: 'Ready',
  isMmproj: false,
};

const model12Gb: ModelInfo = {
  name: 'Llama-3-70B-Q2_K',
  filename: 'llama-3-70b-q2_k.gguf',
  path: 'C:\\llama\\models\\llama-3-70b-q2_k.gguf',
  fileSizeGb: 26.0,
  quantization: 'Q2_K',
  template: 'llama',
  templateMatchMethod: 'binary-header',
  calculatedContext: 32768,
  status: 'Ready',
  isMmproj: false,
};

describe('Overview Dashboard & Pre-Flight Model Launch Engine', () => {
  it('Scenario 1: Partial GPU Offload warning on 8GB VRAM GPU when Model + KV cache exceeds VRAM', () => {
    // 5.3 GB Model + 4.0 GB KV cache = 9.3 GB > 8.0 GB VRAM
    const verdict = validateModelLaunch(model5Gb, baseConfig, rtx5060Hardware);
    expect(verdict.canLaunch).toBe(true);
    expect(verdict.severity).toBe('caution');
    expect(verdict.title).toBe('Partial GPU Offload Warning');
    expect(verdict.autoTuneConfig).toBeDefined();

    // Test Launch Auto-Tuned helper
    const autoTuned = verdict.autoTuneConfig!(baseConfig);
    expect(autoTuned.default_context_size).toBe(16384);
    expect(autoTuned.flash_attn).toBe('on');
  });

  it('Scenario 2: Full VRAM Fit when context is reduced to 16K tokens', () => {
    const tunedConfig = { ...baseConfig, default_context_size: 16384 };
    // 5.3 GB Model + 2.0 GB KV cache = 7.3 GB < 8.0 GB VRAM -> Fits 100% in VRAM!
    const verdict = validateModelLaunch(model5Gb, tunedConfig, rtx5060Hardware);
    expect(verdict.canLaunch).toBe(true);
    expect(verdict.severity).toBe('ok');
    expect(verdict.title).toBe('Fits VRAM (Full GPU Offload)');
  });

  it('Scenario 3: CPU RAM Execution Mode when running on CPU-only system', () => {
    const verdict = validateModelLaunch(model5Gb, baseConfig, cpuHardware);
    expect(verdict.canLaunch).toBe(true);
    expect(verdict.severity).toBe('info');
    expect(verdict.title).toBe('CPU RAM Execution Mode');

    const autoTuned = verdict.autoTuneConfig!(baseConfig);
    expect(autoTuned.overrides.n_gpu_layers).toBe(0);
    expect(autoTuned.flash_attn).toBe('off');
  });

  it('Scenario 4: BLOCKED launch when model exceeds system RAM budget', () => {
    // 26 GB Model on 8 GB RAM system -> BLOCKED
    const verdict = validateModelLaunch(model12Gb, baseConfig, cpuHardware);
    expect(verdict.canLaunch).toBe(false);
    expect(verdict.severity).toBe('danger');
    expect(verdict.title).toBe('BLOCKED: Insufficient Memory');
  });
});
