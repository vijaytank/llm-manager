import { describe, it, expect } from 'vitest';
import { validateConfiguration, validateModelLaunch, calculateKvCacheGb } from '../validation';
import { AppConfig } from '../../store/configStore';
import { SystemHardware } from '../../store/hardwareStore';
import { ModelInfo } from '../../store/modelsStore';

const mockBaseConfig: AppConfig = {
  installation_type: 'winget',
  llama_server_path: 'C:\\llama\\llama-server.exe',
  llama_repo_path: '',
  models_dir: 'C:\\llama\\models',
  templates_dir: '',
  grammars_dir: '',
  active_model: '',
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

const mockCpuHardware: SystemHardware = {
  cpuName: 'Intel Core i7-11700K',
  physicalCores: 8,
  logicalCores: 16,
  totalRamGb: 24,
  gpuName: 'Intel UHD Graphics 750',
  vramGb: 0,
  adapterClass: 'none',
  performanceTier: 'cpu',
};

const mockGpuHardware: SystemHardware = {
  cpuName: 'AMD Ryzen 9 7900X',
  physicalCores: 12,
  logicalCores: 24,
  totalRamGb: 32,
  gpuName: 'NVIDIA RTX 4070',
  vramGb: 12,
  adapterClass: 'dedicated',
  performanceTier: 'high',
};

const mockSmallModel: ModelInfo = {
  name: 'Qwen2.5-1.5B',
  filename: 'qwen2.5-1.5b.gguf',
  path: 'C:\\llama\\models\\qwen2.5-1.5b.gguf',
  fileSizeGb: 1.1,
  quantization: 'Q4_K_M',
  template: 'qwen2.5',
  templateMatchMethod: 'jinja',
  calculatedContext: 32768,
  status: 'Ready',
  isMmproj: false,
};

const mockMediumModel: ModelInfo = {
  name: 'Llama-3.1-8B',
  filename: 'llama-3.1-8b.gguf',
  path: 'C:\\llama\\models\\llama-3.1-8b.gguf',
  fileSizeGb: 5.4,
  quantization: 'Q4_K_M',
  template: 'llama',
  templateMatchMethod: 'jinja',
  calculatedContext: 32768,
  status: 'Ready',
  isMmproj: false,
};

const mockHugeModel: ModelInfo = {
  name: 'DeepSeek-67B',
  filename: 'deepseek-67b.gguf',
  path: 'C:\\llama\\models\\deepseek-67b.gguf',
  fileSizeGb: 40.0,
  quantization: 'Q4_K_M',
  template: 'deepseek',
  templateMatchMethod: 'jinja',
  calculatedContext: 32768,
  status: 'Ready',
  isMmproj: false,
};

describe('validation engine & kv cache math', () => {
  it('calculates mathematically exact KV cache size for various context lengths & precisions', () => {
    // 32 layers, 1024 kvDim, f16 -> 131,072 bytes per token
    expect(calculateKvCacheGb(8192, 32, 'f16', 'f16')).toBe(1.0);
    expect(calculateKvCacheGb(32768, 32, 'f16', 'f16')).toBe(4.0);
    expect(calculateKvCacheGb(65536, 32, 'f16', 'f16')).toBe(8.0);

    // q8_0 precision -> ~2.13 GB at 32K
    expect(calculateKvCacheGb(32768, 32, 'q8_0', 'q8_0')).toBe(2.13);
  });

  it('detects GPU layers warning and provides auto-fix on CPU-only system', () => {
    const invalidConfig = {
      ...mockBaseConfig,
      overrides: { n_gpu_layers: 32 },
    };

    const res = validateConfiguration(invalidConfig, mockCpuHardware);
    expect(res.assessments.some((a) => a.param === 'n_gpu_layers')).toBe(true);
    const nGpuAssessment = res.assessments.find((a) => a.param === 'n_gpu_layers');
    expect(nGpuAssessment?.autoFix).toBeDefined();
    
    const fixed = nGpuAssessment!.autoFix!.applyFix(invalidConfig);
    expect(fixed.overrides.n_gpu_layers).toBe(0);
  });

  it('detects Flash Attention warning and provides auto-fix on CPU-only system', () => {
    const invalidConfig = {
      ...mockBaseConfig,
      flash_attn: 'on',
    };

    const res = validateConfiguration(invalidConfig, mockCpuHardware);
    expect(res.assessments.some((a) => a.param === 'flash_attn')).toBe(true);
    const faAssessment = res.assessments.find((a) => a.param === 'flash_attn');
    expect(faAssessment?.autoFix).toBeDefined();

    const fixed = faAssessment!.autoFix!.applyFix(invalidConfig);
    expect(fixed.flash_attn).toBe('off');
  });

  it('pre-flight validator allows safe launch for small model on GPU', () => {
    const verdict = validateModelLaunch(mockSmallModel, mockBaseConfig, mockGpuHardware);
    expect(verdict.canLaunch).toBe(true);
    expect(verdict.severity).toBe('ok');
    expect(verdict.autoTuneConfig).toBeDefined();
  });

  it('pre-flight validator warns for partial GPU offload when model + KV exceeds VRAM', () => {
    const tightGpuHardware: SystemHardware = {
      ...mockGpuHardware,
      vramGb: 6, // 6GB VRAM GPU
    };
    // 5.4 GB model + 4.0 GB KV cache = 9.4 GB total > 6 GB VRAM
    const verdict = validateModelLaunch(mockMediumModel, mockBaseConfig, tightGpuHardware);
    expect(verdict.canLaunch).toBe(true);
    expect(verdict.severity).toBe('caution');
    expect(verdict.title).toContain('Partial GPU Offload');
  });

  it('pre-flight validator blocks launch for huge model exceeding RAM', () => {
    const verdict = validateModelLaunch(mockHugeModel, mockBaseConfig, mockCpuHardware);
    expect(verdict.canLaunch).toBe(false);
    expect(verdict.severity).toBe('danger');
  });

  it('prioritizes overrides for flash_attn and sets overrides in autoFix on CPU-only', () => {
    const configWithOverride = {
      ...mockBaseConfig,
      flash_attn: 'off',
      overrides: { flash_attn: 'on' },
    };
    const res = validateConfiguration(configWithOverride, mockCpuHardware);
    expect(res.assessments.some((a) => a.param === 'flash_attn')).toBe(true);
    const faAssessment = res.assessments.find((a) => a.param === 'flash_attn');
    const fixed = faAssessment!.autoFix!.applyFix(configWithOverride);
    expect(fixed.overrides.flash_attn).toBe('off');
  });

  it('prioritizes overrides for ctx_size and cache precision in pre-flight calculation', () => {
    const configWithOverrides = {
      ...mockBaseConfig,
      default_context_size: 8192,
      overrides: { ctx_size: 65536, cache_type_k: 'q8_0', cache_type_v: 'q8_0' },
    };
    // 65536 ctx with q8_0 KV on medium model
    const verdict = validateModelLaunch(mockMediumModel, configWithOverrides, mockGpuHardware);
    expect(verdict.autoTuneConfig).toBeDefined();
    const tuned = verdict.autoTuneConfig!(configWithOverrides);
    expect(tuned.overrides.flash_attn).toBe('on');
  });
});

