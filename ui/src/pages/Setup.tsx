import React, { useState, useEffect } from 'react';
import { PageShell } from '../components/layout/PageShell';
import { Check, ArrowRight, ArrowLeft, Cpu, FolderOpen, Play, RefreshCw } from 'lucide-react';
import { open } from '@tauri-apps/plugin-dialog';
import { useHardwareStore } from '../store/hardwareStore';
import { useConfigStore } from '../store/configStore';
import { useModelsStore } from '../store/modelsStore';
import { useValidationStore } from '../store/validationStore';
import { ImpactBanner } from '../components/ImpactBanner';
import './Setup.css';

interface SetupPageProps {
  onComplete?: () => void;
}

export const SetupPage: React.FC<SetupPageProps> = ({ onComplete }) => {
  const [step, setStep] = useState(1);
  const { profile, fetchHardware, loading: hardwareLoading } = useHardwareStore();
  const { config, updateConfig, saveConfig, fetchConfig } = useConfigStore();
  const { models, fetchModels } = useModelsStore();
  const { assessments } = useValidationStore();

  useEffect(() => {
    fetchHardware();
    if (!config) {
      fetchConfig();
    }
  }, [fetchHardware, fetchConfig, config]);

  const steps = [
    { num: 1, title: 'Installation' },
    { num: 2, title: 'Models' },
    { num: 3, title: 'Performance' },
    { num: 4, title: 'Integrations' },
    { num: 5, title: 'Review' },
  ];

  const isCpuOnly = profile?.adapterClass === 'none' || profile?.performanceTier === 'cpu';

  // Native File Picker for llama-server.exe
  const handleBrowseServerBinary = async () => {
    try {
      const selected = await open({
        multiple: false,
        filters: [{ name: 'Executables', extensions: ['exe'] }],
      });
      if (selected && typeof selected === 'string') {
        updateConfig({ llama_server_path: selected });
      }
    } catch (e) {
      console.error(e);
    }
  };

  // Native Folder Picker for Models Directory
  const handleBrowseModelsDir = async () => {
    try {
      const selected = await open({
        directory: true,
        multiple: false,
      });
      if (selected && typeof selected === 'string') {
        updateConfig({ models_dir: selected });
        fetchModels(selected);
      }
    } catch (e) {
      console.error(e);
    }
  };

  const handleFinishSetup = async () => {
    updateConfig({ installation_type: 'winget' });
    await saveConfig();
    if (onComplete) {
      onComplete();
    }
  };

  return (
    <PageShell title="Initial Setup Wizard">
      <div className="setup-container">
        {/* Stepper Header */}
        <div className="stepper glass-card">
          {steps.map((s) => {
            const isDone = s.num < step;
            const isCurrent = s.num === step;
            return (
              <div
                key={s.num}
                className={`step-item ${isDone ? 'done' : ''} ${isCurrent ? 'current' : ''}`}
                onClick={() => isDone && setStep(s.num)}
                style={{ cursor: isDone ? 'pointer' : 'default' }}
              >
                <div className="step-circle">
                  {isDone ? <Check size={14} /> : s.num}
                </div>
                <span className="step-title">{s.title}</span>
              </div>
            );
          })}
        </div>

        {/* Validation Banners */}
        {assessments.map((a, i) => (
          <ImpactBanner key={i} assessment={a} />
        ))}

        {/* STEP 1: Installation & Executable Path */}
        {step === 1 && (
          <div className="step-content glass-card card-padding">
            <div className="step-header">
              <h2>Step 1: Core Engine Installation</h2>
              <p className="step-desc">Configure or locate your local llama-server executable binary</p>
            </div>

            <div className="form-group">
              <label className="form-label">llama-server.exe Binary Path</label>
              <div style={{ display: 'flex', gap: '10px' }}>
                <input
                  type="text"
                  className="form-input font-mono"
                  value={config?.llama_server_path || ''}
                  onChange={(e) => updateConfig({ llama_server_path: e.target.value })}
                  placeholder="Select path to llama-server.exe..."
                />
                <button className="btn btn-outline" onClick={handleBrowseServerBinary}>
                  <FolderOpen size={16} /> Browse...
                </button>
              </div>
            </div>

            <div className="step-actions">
              <div></div>
              <button
                className="btn btn-primary"
                disabled={!config?.llama_server_path}
                onClick={() => setStep(2)}
              >
                Next: Models Folder <ArrowRight size={16} />
              </button>
            </div>
          </div>
        )}

        {/* STEP 2: Models Folder & GGUF Scan */}
        {step === 2 && (
          <div className="step-content glass-card card-padding">
            <div className="step-header">
              <h2>Step 2: GGUF Model Folder Discovery</h2>
              <p className="step-desc">Select directory containing GGUF model files</p>
            </div>

            <div className="form-group">
              <label className="form-label">GGUF Models Directory</label>
              <div style={{ display: 'flex', gap: '10px' }}>
                <input
                  type="text"
                  className="form-input font-mono"
                  value={config?.models_dir || ''}
                  onChange={(e) => {
                    updateConfig({ models_dir: e.target.value });
                    fetchModels(e.target.value);
                  }}
                  placeholder="Select directory containing GGUF models..."
                />
                <button className="btn btn-outline" onClick={handleBrowseModelsDir}>
                  <FolderOpen size={16} /> Browse Folder...
                </button>
              </div>
            </div>

            <div style={{ marginTop: '16px', fontSize: '0.9rem' }}>
              <strong>Discovered Models ({models.length}):</strong>
              <div style={{ marginTop: '8px', display: 'flex', flexDirection: 'column', gap: '6px' }}>
                {models.map((m, i) => (
                  <div key={i} className="info-row" style={{ padding: '8px 12px', background: 'var(--bg-elevated)', borderRadius: '4px' }}>
                    <span className="font-semibold">{m.name}</span>
                    <span className="font-mono">{m.fileSizeGb} GB • {m.quantization}</span>
                  </div>
                ))}
                {models.length === 0 && (
                  <div style={{ color: 'var(--text-muted)', fontStyle: 'italic' }}>
                    No GGUF models found in directory. You can add GGUF files later.
                  </div>
                )}
              </div>
            </div>

            <div className="step-actions">
              <button className="btn btn-outline" onClick={() => setStep(1)}>
                <ArrowLeft size={16} /> Back
              </button>
              <button className="btn btn-primary" onClick={() => setStep(3)}>
                Next: Performance Tuning <ArrowRight size={16} />
              </button>
            </div>
          </div>
        )}

        {/* STEP 3: Hardware Tuning & Smart Guardian */}
        {step === 3 && (
          <div className="step-content glass-card card-padding">
            <div className="step-header" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <div>
                <h2>Step 3: Hardware-Adaptive Tuning</h2>
                <p className="step-desc">Parameters automatically tuned for your detected hardware</p>
              </div>
              <button className="btn btn-outline" style={{ padding: '4px 8px', fontSize: '0.8rem' }} onClick={() => fetchHardware()}>
                <RefreshCw size={14} className={hardwareLoading ? 'spin' : ''} /> Detect Hardware
              </button>
            </div>

            {/* Capability Summary Banner */}
            <div className={`hw-summary-banner ${isCpuOnly ? 'cpu-mode' : 'gpu-mode'}`}>
              <Cpu size={20} className="banner-icon" />
              <div>
                <div style={{ fontWeight: 600 }}>
                  {profile?.cpuName || 'System CPU'} • {profile?.totalRamGb || 16} GB RAM •{' '}
                  {profile?.gpuName || 'GPU'} ({profile?.vramGb || 0} GB VRAM)
                </div>
                <div style={{ fontSize: '0.8rem', opacity: 0.9, marginTop: '2px' }}>
                  Mode: <strong>{isCpuOnly ? '🔴 CPU Only' : `🟢 ${profile?.performanceTier?.toUpperCase()} GPU`}</strong>
                </div>
              </div>
            </div>

            <div className="param-grid">
              <div className="param-card">
                <div>
                  <div className="param-label">Flash Attention</div>
                  <div className="param-value font-mono">
                    {config?.flash_attn || 'off'} ({isCpuOnly ? 'Disabled' : 'Enabled'})
                  </div>
                </div>
                <label className="toggle-switch">
                  <input
                    type="checkbox"
                    checked={config?.flash_attn === 'on'}
                    disabled={isCpuOnly}
                    onChange={(e) => updateConfig({ flash_attn: e.target.checked ? 'on' : 'off' })}
                  />
                  <span className="slider"></span>
                </label>
              </div>

              <div className="param-card">
                <div>
                  <div className="param-label">Default Context Window</div>
                  <div className="param-value font-mono">{config?.default_context_size || 32768} tokens</div>
                </div>
                <select
                  className="form-input font-mono"
                  style={{ width: '120px', padding: '4px 8px' }}
                  value={config?.default_context_size || 32768}
                  onChange={(e) => updateConfig({ default_context_size: Number(e.target.value) })}
                >
                  <option value={8192}>8192</option>
                  <option value={16384}>16384</option>
                  <option value={32768}>32768</option>
                  <option value={65536}>65536</option>
                </select>
              </div>
            </div>

            <div className="step-actions">
              <button className="btn btn-outline" onClick={() => setStep(2)}>
                <ArrowLeft size={16} /> Back
              </button>
              <button className="btn btn-primary" onClick={() => setStep(4)}>
                Next: Integrations <ArrowRight size={16} />
              </button>
            </div>
          </div>
        )}

        {/* STEP 4: Integrations */}
        {step === 4 && (
          <div className="step-content glass-card card-padding">
            <div className="step-header">
              <h2>Step 4: Client Integrations</h2>
              <p className="step-desc">Select developer clients to auto-configure</p>
            </div>

            <div className="param-grid">
              {['vscode', 'claude-code', 'cursor', 'rest-api'].map((item) => {
                const isSelected = (config?.integrations || []).includes(item);
                return (
                  <div key={item} className="param-card" style={{ textTransform: 'capitalize' }}>
                    <div>
                      <div className="param-label">{item.replace('-', ' ')}</div>
                      <div className="param-value font-mono">OpenAI & Anthropic Proxy</div>
                    </div>
                    <input
                      type="checkbox"
                      checked={isSelected}
                      onChange={(e) => {
                        const list = config?.integrations || [];
                        const next = e.target.checked
                          ? [...list, item]
                          : list.filter((i) => i !== item);
                        updateConfig({ integrations: next });
                      }}
                    />
                  </div>
                );
              })}
            </div>

            <div className="step-actions">
              <button className="btn btn-outline" onClick={() => setStep(3)}>
                <ArrowLeft size={16} /> Back
              </button>
              <button className="btn btn-primary" onClick={() => setStep(5)}>
                Next: Review & Launch <ArrowRight size={16} />
              </button>
            </div>
          </div>
        )}

        {/* STEP 5: Review & Complete Setup */}
        {step === 5 && (
          <div className="step-content glass-card card-padding">
            <div className="step-header">
              <h2>Step 5: Review & Complete</h2>
              <p className="step-desc">Setup complete! Review configuration summary</p>
            </div>

            <div className="info-row">
              <span className="info-label">Server Binary</span>
              <span className="info-value font-mono">{config?.llama_server_path}</span>
            </div>
            <div className="info-row">
              <span className="info-label">Models Folder</span>
              <span className="info-value font-mono">{config?.models_dir} ({models.length} models)</span>
            </div>
            <div className="info-row">
              <span className="info-label">Context Window</span>
              <span className="info-value font-mono">{config?.default_context_size} tokens</span>
            </div>

            <div className="step-actions" style={{ marginTop: '24px' }}>
              <button className="btn btn-outline" onClick={() => setStep(4)}>
                <ArrowLeft size={16} /> Back
              </button>
              <button className="btn btn-primary" onClick={handleFinishSetup}>
                <Play size={16} /> Complete Setup & Launch Dashboard
              </button>
            </div>
          </div>
        )}
      </div>
    </PageShell>
  );
};
