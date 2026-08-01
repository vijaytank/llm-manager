import React from 'react';
import { PageShell } from '../components/layout/PageShell';
import { Cpu, HardDrive, Sliders } from 'lucide-react';
import { useHardwareStore } from '../store/hardwareStore';
import { useConfigStore } from '../store/configStore';
import { InfoTooltip } from '../components/InfoTooltip';
import './Performance.css';

export const PerformancePage: React.FC = () => {
  const { profile } = useHardwareStore();
  const { config, updateConfig, saveConfig } = useConfigStore();

  const isCpuOnly = profile?.adapterClass === 'none' || profile?.performanceTier === 'cpu';
  const vramGb = profile?.vramGb || 0;
  const cores = profile?.physicalCores || 4;

  return (
    <PageShell title="Performance & System Tuning">
      <div className="perf-container">
        <div className="perf-grid">
          <div className="glass-card card-padding">
            <div className="card-header">
              <Cpu className="card-icon" size={20} />
              <h3>
                Hardware Profile Breakdown
                <InfoTooltip
                  title="Hardware Profile"
                  description="Detected hardware capabilities used by LLM Manager to compute adaptive VRAM budgets and thread allocations."
                  recommendation={isCpuOnly ? "Running in CPU mode. Quantized models (Q4_K_M) are recommended." : `Dedicated GPU with ${vramGb} GB VRAM detected. GPU offloading is active.`}
                  impact="Governs memory ceiling and compute offloading."
                />
              </h3>
            </div>
            <div className="info-row">
              <span className="info-label">Physical CPU Cores</span>
              <span className="info-value font-mono">
                {profile?.physicalCores || 4} cores (Logical: {profile?.logicalCores || 8})
              </span>
            </div>
            <div className="info-row">
              <span className="info-label">VRAM Budget Target</span>
              <span className="info-value font-mono">
                {isCpuOnly ? 'N/A (CPU RAM Mode)' : `${vramGb * 1024} MB (${vramGb} GB VRAM)`}
              </span>
            </div>
            <div className="info-row">
              <span className="info-label">Memory Spill Prevention</span>
              <span className="badge badge-success">Fit-Throttle Active</span>
            </div>
          </div>

          <div className="glass-card card-padding">
            <div className="card-header">
              <HardDrive className="card-icon" size={20} />
              <h3>KV Cache & Memory Locking</h3>
            </div>
            <div className="info-row">
              <span className="info-label">
                KV Cache Precision (K/V)
                <InfoTooltip
                  title="KV Cache Precision (--cache-type-k / --cache-type-v)"
                  description="Quantization format for the Key/Value context memory cache stored during inference."
                  recommendation={vramGb > 0 && vramGb <= 12 ? "q8_0 is recommended on your system to cut VRAM usage by 50% without quality loss." : "f16 provides maximum floating-point precision."}
                  impact="f16 = High VRAM (~4GB @ 32k). q8_0 = 50% VRAM Savings (~2GB @ 32k). q4_0 = 75% VRAM Savings."
                />
              </span>
              <select
                className="form-input font-mono"
                style={{ width: '220px', padding: '4px 8px', fontSize: '0.85rem' }}
                value={config?.cache_type_k || 'f16'}
                onChange={async (e) => {
                  const val = e.target.value;
                  updateConfig({ cache_type_k: val, cache_type_v: val });
                  await saveConfig();
                }}
              >
                <option value="f16">f16 (Full - Highest VRAM usage)</option>
                <option value="q8_0">q8_0 (8-bit - 50% VRAM Savings ⭐)</option>
                <option value="q4_0">q4_0 (4-bit - 75% VRAM Savings)</option>
              </select>
            </div>
            <div className="info-row">
              <span className="info-label">
                Flash Attention
                <InfoTooltip
                  title="Flash Attention (--flash-attn)"
                  description="Accelerated attention kernel that significantly reduces memory footprint and boosts prompt evaluation speed."
                  recommendation="Keep 'on' for all modern NVIDIA / AMD GPUs."
                  impact="Required for quantized KV cache (q8_0/q4_0). Reduces VRAM overhead during long prompts."
                />
              </span>
              <select
                className="form-input font-mono"
                style={{ width: '150px', padding: '4px 8px', fontSize: '0.85rem' }}
                value={config?.flash_attn || 'on'}
                onChange={async (e) => {
                  updateConfig({ flash_attn: e.target.value });
                  await saveConfig();
                }}
              >
                <option value="on">on (Active ⭐)</option>
                <option value="off">off (Disabled)</option>
                <option value="auto">auto (Detect)</option>
              </select>
            </div>
            <div className="info-row">
              <span className="info-label">
                Context Window
                <InfoTooltip
                  title="Context Window (-c / --ctx-size)"
                  description="Maximum number of tokens (prompt + response + history) the model can hold in memory simultaneously."
                  recommendation={vramGb > 0 && vramGb <= 8 ? "32,768 tokens with q8_0 KV cache is optimal for your 8 GB GPU." : "65,536 tokens for long documents."}
                  impact="Larger context sizes increase KV cache memory consumption proportionally."
                />
              </span>
              <select
                className="form-input font-mono"
                style={{ width: '150px', padding: '4px 8px', fontSize: '0.85rem' }}
                value={config?.default_context_size || 32768}
                onChange={async (e) => {
                  updateConfig({ default_context_size: Number(e.target.value) });
                  await saveConfig();
                }}
              >
                <option value={8192}>8,192 tokens</option>
                <option value={16384}>16,384 tokens</option>
                <option value={32768}>32,768 tokens</option>
                <option value={65536}>65,536 tokens</option>
                <option value={131072}>131,072 tokens</option>
              </select>
            </div>
            <div className="info-row">
              <span className="info-label">
                Memory Locking (--mlock)
                <InfoTooltip
                  title="Memory Locking (--mlock)"
                  description="Locks model weights into physical RAM to prevent Windows OS from swapping pages to virtual disk memory."
                  recommendation={(profile?.totalRamGb || 16) >= 32 ? "Enabled (Recommended when physical RAM >= 32 GB)." : "Disabled (prevents RAM pressure)." }
                  impact="Eliminates page-fault stutters, but consumes dedicated un-swappable system RAM."
                />
              </span>
              <label className="toggle-switch">
                <input
                  type="checkbox"
                  checked={config?.mlock || false}
                  onChange={async (e) => {
                    updateConfig({ mlock: e.target.checked });
                    await saveConfig();
                  }}
                />
                <span className="slider"></span>
              </label>
            </div>
            <div className="info-row">
              <span className="info-label">
                Prompt Cache Reuse
                <InfoTooltip
                  title="Prompt Cache Reuse (--cache-prompt)"
                  description="Saves evaluated prompt prefixes into RAM/VRAM so multi-turn conversations reuse previous evaluations instantly."
                  recommendation="Keep enabled for fast multi-turn chat and coding sessions."
                  impact="Drastically speeds up initial response time on follow-up questions."
                />
              </span>
              <label className="toggle-switch">
                <input
                  type="checkbox"
                  checked={config?.cache_prompt !== false}
                  onChange={async (e) => {
                    updateConfig({ cache_prompt: e.target.checked });
                    await saveConfig();
                  }}
                />
                <span className="slider"></span>
              </label>
            </div>
          </div>
        </div>

        {/* SYSTEM_COMMANDS.md Interactive Options Panel */}
        <div className="glass-card card-padding">
          <div className="card-header">
            <Sliders className="card-icon" size={20} />
            <h3>SYSTEM_COMMANDS.md Optimization Controls</h3>
          </div>
          <div className="param-grid" style={{ marginTop: '16px' }}>
            <div className="param-card">
              <div>
                <div className="param-label">
                  Parallel User Slots (--parallel)
                  <InfoTooltip
                    title="Parallel Slots (-np / --parallel)"
                    description="Number of concurrent generation slots. Slot 1 focuses 100% of GPU memory bandwidth on a single user for maximum token speed."
                    recommendation="Select '1' for maximum single-user generation speed (~10-20+ t/s). Select '2' or '4' for multi-agent concurrency."
                    impact="Setting parallel = 1 concentrates full GPU bandwidth on one stream. Multi-slots split bandwidth."
                  />
                </div>
                <div className="param-value font-mono">
                  {config?.parallel_slots === 1 ? '1 Slot (Single User - Max Speed ⭐)' : `${config?.parallel_slots || 1} Slots`}
                </div>
              </div>
              <select
                className="form-input font-mono"
                style={{ width: '150px' }}
                value={config?.parallel_slots || 1}
                onChange={async (e) => {
                  updateConfig({ parallel_slots: Number(e.target.value) });
                  await saveConfig();
                }}
              >
                <option value={1}>1 (Max Speed ⭐)</option>
                <option value={2}>2 (Dual Slots)</option>
                <option value={4}>4 (Quad Slots)</option>
              </select>
            </div>

            <div className="param-card">
              <div>
                <div className="param-label">
                  Micro-Batch Size (--ubatch-size)
                  <InfoTooltip
                    title="Micro-Batch Size (-ub / --ubatch-size)"
                    description="Physical batch size for prompt evaluation. Larger values increase GPU tensor core utilization."
                    recommendation={vramGb >= 8 ? "512 or 1024 is optimal for your GPU." : "256 for lower VRAM cards."}
                    impact="Higher values increase prompt processing speed (tokens/sec) but require slight temporary VRAM."
                  />
                </div>
                <div className="param-value font-mono">
                  {config?.ubatch_size || 512} tokens
                </div>
              </div>
              <select
                className="form-input font-mono"
                style={{ width: '130px' }}
                value={config?.ubatch_size || 512}
                onChange={async (e) => {
                  updateConfig({ ubatch_size: Number(e.target.value) });
                  await saveConfig();
                }}
              >
                <option value={128}>128</option>
                <option value={256}>256</option>
                <option value={512}>512 (Default)</option>
                <option value={1024}>1024 (High VRAM)</option>
                <option value={2048}>2048 (Ultra)</option>
              </select>
            </div>

            <div className="param-card">
              <div>
                <div className="param-label">
                  CPU Inference Threads (-t / --threads)
                  <InfoTooltip
                    title="CPU Inference Threads (-t / --threads)"
                    description="Number of CPU worker threads used during prompt processing and CPU-offloaded layer computation."
                    recommendation={`Auto detected ${cores} physical CPU P-cores.`}
                    impact="Setting to match physical performance cores optimizes throughput without hyperthreading overhead."
                  />
                </div>
                <div className="param-value font-mono">
                  {config?.threads || 0} ({config?.threads === 0 ? 'Auto: P-cores' : `${config?.threads} threads`})
                </div>
              </div>
              <select
                className="form-input font-mono"
                style={{ width: '120px' }}
                value={config?.threads || 0}
                onChange={async (e) => {
                  updateConfig({ threads: Number(e.target.value) });
                  await saveConfig();
                }}
              >
                <option value={0}>0 (Auto)</option>
                <option value={4}>4 threads</option>
                <option value={8}>8 threads</option>
                <option value={12}>12 threads</option>
                <option value={16}>16 threads</option>
              </select>
            </div>

            <div className="param-card">
              <div>
                <div className="param-label">
                  Process Priority (--prio)
                  <InfoTooltip
                    title="Process Priority (--prio)"
                    description="Windows OS process scheduling priority assigned to the llama-server background process."
                    recommendation="Normal (0) or Medium (1) ensures smooth OS multitasking."
                    impact="Higher priority reduces latency spikes when other desktop applications are open."
                  />
                </div>
                <div className="param-value font-mono">
                  {config?.prio === 2 ? 'High (2)' : config?.prio === 1 ? 'Medium (1)' : 'Normal (0)'}
                </div>
              </div>
              <select
                className="form-input font-mono"
                style={{ width: '120px' }}
                value={config?.prio || 0}
                onChange={async (e) => {
                  updateConfig({ prio: Number(e.target.value) });
                  await saveConfig();
                }}
              >
                <option value={0}>0 (Normal)</option>
                <option value={1}>1 (Medium)</option>
                <option value={2}>2 (High)</option>
                <option value={3}>3 (Realtime)</option>
              </select>
            </div>

            <div className="param-card">
              <div>
                <div className="param-label">
                  Speculative Decoding (--spec-type)
                  <InfoTooltip
                    title="Speculative Decoding (--spec-type)"
                    description="Generates candidate tokens ahead of time using N-gram lookup. Zero quality or accuracy loss."
                    recommendation="ngram-simple provides +30% to +60% faster generation for code and text."
                    impact="Boosts generation tokens/sec without modifying output probabilities."
                  />
                </div>
                <div className="param-value font-mono">{config?.spec_type || 'none'}</div>
              </div>
              <select
                className="form-input font-mono"
                style={{ width: '140px' }}
                value={config?.spec_type || 'none'}
                onChange={async (e) => {
                  updateConfig({ spec_type: e.target.value });
                  await saveConfig();
                }}
              >
                <option value="none">none (Disabled)</option>
                <option value="ngram-simple">ngram-simple (+30% Speed ⭐)</option>
                <option value="ngram-map-k">ngram-map-k</option>
              </select>
            </div>

            <div className="param-card">
              <div>
                <div className="param-label">
                  Reasoning Thought Tags (--reasoning)
                  <InfoTooltip
                    title="Reasoning Output Format (--reasoning)"
                    description="Controls how internal reasoning chain-of-thought tags (<think>...</think>) are processed."
                    recommendation="auto (Detect) automatically parses thinking tags for reasoning models like DeepSeek-R1 or Ministral."
                    impact="Ensures client applications receive clean thinking blocks vs final text."
                  />
                </div>
                <div className="param-value font-mono">{config?.reasoning || 'auto'}</div>
              </div>
              <select
                className="form-input font-mono"
                style={{ width: '120px' }}
                value={config?.reasoning || 'auto'}
                onChange={async (e) => {
                  updateConfig({ reasoning: e.target.value });
                  await saveConfig();
                }}
              >
                <option value="auto">auto (Detect)</option>
                <option value="on">on (Always)</option>
                <option value="off">off (Strip tags)</option>
              </select>
            </div>
          </div>
        </div>
      </div>
    </PageShell>
  );
};
