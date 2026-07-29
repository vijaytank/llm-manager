import React from 'react';
import { PageShell } from '../components/layout/PageShell';
import { Cpu, HardDrive, Sliders } from 'lucide-react';
import { useHardwareStore } from '../store/hardwareStore';
import { useConfigStore } from '../store/configStore';
import './Performance.css';

export const PerformancePage: React.FC = () => {
  const { profile } = useHardwareStore();
  const { config, updateConfig, saveConfig } = useConfigStore();

  const isCpuOnly = profile?.adapterClass === 'none' || profile?.performanceTier === 'cpu';
  const vramGb = profile?.vramGb || 0;

  return (
    <PageShell title="Performance & System Tuning">
      <div className="perf-container">
        <div className="perf-grid">
          <div className="glass-card card-padding">
            <div className="card-header">
              <Cpu className="card-icon" size={20} />
              <h3>Hardware Profile Breakdown</h3>
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
              <span className="info-label">Memory Locking (--mlock)</span>
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
              <span className="info-label">Prompt Cache Reuse</span>
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
            <div className="info-row">
              <span className="info-label">Flash Attention</span>
              <span className={`badge ${config?.flash_attn === 'on' ? 'badge-success' : 'badge-warning'}`}>
                {config?.flash_attn === 'on' ? 'Active' : 'Disabled'}
              </span>
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
                <div className="param-label">CPU Inference Threads (--threads)</div>
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
                <div className="param-label">Process Priority (--prio)</div>
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
                <div className="param-label">Speculative Decoding (--spec-type)</div>
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
                <option value="ngram-simple">ngram-simple (+15% code speed)</option>
                <option value="ngram-map-k">ngram-map-k</option>
              </select>
            </div>

            <div className="param-card">
              <div>
                <div className="param-label">Reasoning Thought Tags (--reasoning)</div>
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
