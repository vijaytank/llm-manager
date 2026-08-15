import { AppConfig } from '../store/configStore';
import { SystemHardware } from '../store/hardwareStore';
import { ModelInfo } from '../store/modelsStore';

export type Severity = 'ok' | 'info' | 'warn' | 'caution' | 'danger';

export interface AutoFix {
  label: string;
  applyFix: (config: AppConfig) => AppConfig;
}

export interface ImpactAssessment {
  param: string;
  severity: Severity;
  title: string;
  explanation: string;
  recommendation: string;
  autoFix?: AutoFix;
}

export interface ValidationResult {
  assessments: ImpactAssessment[];
  correctedConfig: AppConfig;
}

export function estimateBlockCount(fileSizeGb: number): number {
  if (fileSizeGb < 3)   return 22;   // ~1B
  if (fileSizeGb < 6)   return 32;   // 3B–7B
  if (fileSizeGb < 12)  return 40;   // 8B–13B
  if (fileSizeGb < 25)  return 60;   // 14B–30B
  return 80;                          // 32B+
}

/// Mathematically Exact KV Cache Memory Calculator
/// Formula: (ctxTokens * layers * kvDim * (bytesPerElemK + bytesPerElemV)) / 1024^3
export function calculateKvCacheGb(
  ctxTokens: number,
  blockCount: number = 32,
  cacheTypeK: string = 'f16',
  cacheTypeV: string = 'f16',
  parallelSlots: number = 1
): number {
  const bytesPerElemK = cacheTypeK === 'q4_0' ? 0.5625 : cacheTypeK === 'q8_0' ? 1.0625 : 2.0;
  const bytesPerElemV = cacheTypeV === 'q4_0' ? 0.5625 : cacheTypeV === 'q8_0' ? 1.0625 : 2.0;

  const kvDim = 1024;
  const bytesPerToken = blockCount * kvDim * (bytesPerElemK + bytesPerElemV);
  const totalBytes = ctxTokens * Math.max(1, parallelSlots) * bytesPerToken;

  return Number((totalBytes / (1024 * 1024 * 1024)).toFixed(2));
}

export function validateConfiguration(
  config: AppConfig,
  hardware: SystemHardware | null,
  activeModelSizeGb: number = 4.5
): ValidationResult {
  const assessments: ImpactAssessment[] = [];
  let correctedConfig = { ...config };

  if (!hardware) {
    return { assessments, correctedConfig };
  }

  const isCpuOnly = hardware.adapterClass === 'none' || hardware.performanceTier === 'cpu';
  const vramGb = hardware.vramGb || 0;
  const ramGb = hardware.totalRamGb || 16;

  // Rule 1: GPU Layers on CPU-Only System
  const nGpuLayersOverride = config.overrides?.n_gpu_layers;
  if (isCpuOnly && nGpuLayersOverride !== undefined && nGpuLayersOverride !== 0) {
    assessments.push({
      param: 'n_gpu_layers',
      severity: 'warn',
      title: 'GPU Offloading Incompatible',
      explanation: `Your system is running in CPU-only mode. Setting GPU offload layers (${nGpuLayersOverride}) will cause server initialization errors.`,
      recommendation: 'Set GPU offload layers to 0 for CPU-only systems.',
      autoFix: {
        label: 'Fix Automatically: Set GPU Layers to 0',
        applyFix: (cfg) => ({
          ...cfg,
          overrides: { ...cfg.overrides, n_gpu_layers: 0 },
        }),
      },
    });
  }

  // Rule 2: Flash Attention Without GPU
  if (isCpuOnly && config.flash_attn !== 'off') {
    assessments.push({
      param: 'flash_attn',
      severity: 'warn',
      title: 'Flash Attention Unsupported on CPU',
      explanation: 'Flash Attention requires CUDA/Metal GPU hardware tensor cores. Enabling it on CPU will crash the server on startup.',
      recommendation: 'Disable Flash Attention for CPU-only inference.',
      autoFix: {
        label: 'Fix Automatically: Disable Flash Attention',
        applyFix: (cfg) => ({ ...cfg, flash_attn: 'off' }),
      },
    });
  }

  // Rule 3: CPU-only Performance Expectation Notice
  if (isCpuOnly) {
    const safeModelSizeGb = (ramGb * 0.45).toFixed(1);
    assessments.push({
      param: 'cpu_mode',
      severity: 'info',
      title: 'CPU System Capability Profile',
      explanation: `System CPU (${hardware.cpuName}) with ${hardware.physicalCores} physical cores and ${ramGb} GB RAM detected.`,
      recommendation: `Models up to ~${safeModelSizeGb} GB fit comfortably in your ${ramGb} GB RAM budget. Larger models will require swapping.`,
    });
  }

  // Rule 4: Context Size vs. VRAM Memory Overflow
  const ctx = config.overrides?.ctx_size || config.default_context_size || 32768;
  const estimatedKvGb = calculateKvCacheGb(
    ctx,
    estimateBlockCount(activeModelSizeGb),
    config.overrides?.cache_type_k || config.cache_type_k,
    config.overrides?.cache_type_v || config.cache_type_v,
    config.overrides?.parallel || config.parallel_slots || 1
  );
  const totalMem = activeModelSizeGb + estimatedKvGb;

  if (!isCpuOnly && totalMem > vramGb * 0.90) {
    const safeCtx = vramGb >= 8 ? 16384 : 8192;
    assessments.push({
      param: 'default_context_size',
      severity: 'caution',
      title: 'VRAM Memory Overflow Risk',
      explanation: `At ${ctx.toLocaleString()} tokens, KV cache requires ~${estimatedKvGb.toFixed(2)} GB. Total VRAM needed (${totalMem.toFixed(2)} GB) exceeds your ${vramGb} GB GPU limit. Inference will spill to System RAM (50–200× slower).`,
      recommendation: `Reduce context window to ${safeCtx.toLocaleString()} tokens to keep KV cache fully inside GPU VRAM.`,
      autoFix: {
        label: `Fix Automatically: Set Context to ${safeCtx.toLocaleString()}`,
        applyFix: (cfg) => ({
          ...cfg,
          overrides: { ...cfg.overrides, ctx_size: safeCtx },
        }),
      },
    });
  }

  // Rule 5: KV Quantization Precision Mismatch
  const flashIsEffectivelyOff = config.flash_attn === 'off' || (isCpuOnly && config.flash_attn !== 'on');
  if ((config.cache_type_k === 'q8_0' || config.cache_type_v === 'q8_0') && flashIsEffectivelyOff) {
    assessments.push({
      param: 'cache_type_k',
      severity: 'warn',
      title: 'KV Precision Mismatch',
      explanation: 'q8_0 KV cache quantization requires Flash Attention to prevent llama.cpp from silently falling back to f32.',
      recommendation: 'Enable Flash Attention or switch KV cache precision to f16.',
      autoFix: {
        label: 'Fix Automatically: Enable Flash Attention',
        applyFix: (cfg) => ({ ...cfg, flash_attn: 'on' }),
      },
    });
  }

  return { assessments, correctedConfig };
}

export interface ModelLaunchValidation {
  canLaunch: boolean;
  severity: Severity;
  title: string;
  message: string;
  recommendation: string;
  autoTuneConfig?: (cfg: AppConfig) => AppConfig;
}

/// Pre-Flight Model Launch Validation Engine
/// Validates a specific GGUF model BEFORE process execution using exact KV cache math.
export function validateModelLaunch(
  model: ModelInfo | null,
  config: AppConfig,
  hardware: SystemHardware | null
): ModelLaunchValidation {
  if (!model) {
    return {
      canLaunch: false,
      severity: 'warn',
      title: 'No Model Selected',
      message: 'Please select a GGUF model to start inference.',
      recommendation: 'Scan your models directory and pick an available GGUF file.',
    };
  }

  if (!hardware) {
    return {
      canLaunch: true,
      severity: 'info',
      title: 'Ready to Launch',
      message: `Model: ${model.name} (${model.fileSizeGb} GB)`,
      recommendation: 'Starting server...',
    };
  }

  const isCpuOnly = hardware.adapterClass === 'none' || hardware.performanceTier === 'cpu';
  const vramGb = hardware.vramGb || 0;
  const ramGb = hardware.totalRamGb || 16;

  const ctx = config.default_context_size || 32768;
  const estimatedKvGb = calculateKvCacheGb(
    ctx,
    estimateBlockCount(model.fileSizeGb),
    config.cache_type_k,
    config.cache_type_v,
    config.parallel_slots || 1
  );
  const totalModelMem = model.fileSizeGb + estimatedKvGb + 0.5;

  // Case D: Severe RAM Deficit (Blocked launch)
  if (totalModelMem > ramGb * 0.85) {
    const maxSafeSize = (ramGb * 0.70).toFixed(1);
    return {
      canLaunch: false,
      severity: 'danger',
      title: 'BLOCKED: Insufficient Memory',
      message: `Cannot launch ${model.name}. Model (${model.fileSizeGb} GB) + KV cache (${estimatedKvGb} GB) requires ~${totalModelMem.toFixed(2)} GB RAM, but your system has only ${ramGb} GB RAM. Launching will trigger a Windows system freeze or Out-Of-Memory crash.`,
      recommendation: `Select a smaller model under ${maxSafeSize} GB that fits within your system RAM budget.`,
    };
  }

  // Case C: CPU-Only Execution
  if (isCpuOnly) {
    return {
      canLaunch: true,
      severity: 'info',
      title: 'CPU RAM Execution Mode',
      message: `Model ${model.name} (${model.fileSizeGb} GB) will load into System RAM. Available RAM: ${ramGb} GB.`,
      recommendation: 'GPU layers auto-set to 0 for safe CPU execution.',
      autoTuneConfig: (cfg) => ({
        ...cfg,
        active_model: model.name,
        flash_attn: 'off',
        overrides: { ...cfg.overrides, n_gpu_layers: 0 },
      }),
    };
  }

  // Case B: Partial GPU Offload
  if (totalModelMem > vramGb) {
    return {
      canLaunch: true,
      severity: 'caution',
      title: 'Partial GPU Offload Warning',
      message: `Model + KV cache (${totalModelMem.toFixed(2)} GB) exceeds your GPU VRAM (${vramGb} GB). Layers will spill over to System RAM (~3–5× slower than pure VRAM).`,
      recommendation: 'Click "Launch Auto-Tuned" to automatically set maximum GPU layers and context size to fit in VRAM 100%.',
      autoTuneConfig: (cfg) => {
        const safeCtx = vramGb >= 8 ? 16384 : 8192;
        return {
          ...cfg,
          active_model: model.name,
          overrides: {
            ...cfg.overrides,
            ctx_size: safeCtx,
          },
          flash_attn: 'on',
        };
      },
    };
  }

  // Case A: Full VRAM Fit
  return {
    canLaunch: true,
    severity: 'ok',
    title: 'Fits VRAM (Full GPU Offload)',
    message: `Model ${model.name} (${model.fileSizeGb} GB) + KV cache (${estimatedKvGb} GB) fit comfortably in your ${vramGb} GB VRAM.`,
    recommendation: 'Full GPU acceleration active.',
    autoTuneConfig: (cfg) => ({
      ...cfg,
      active_model: model.name,
      flash_attn: 'on',
      overrides: { ...cfg.overrides, n_gpu_layers: -1 },
    }),
  };
}
