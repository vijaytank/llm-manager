import React, { useState, useEffect } from 'react';
import { PageShell } from '../components/layout/PageShell';
import {
  Cpu,
  Zap,
  Boxes,
  Plug,
  Terminal,
  Play,
  Square,
  Wand2,
  ShieldAlert,
  RefreshCw,
  Copy,
  Check,
  Trash2,
  Layers,
  Sparkles,
} from 'lucide-react';
import { invoke } from '@tauri-apps/api/core';
import { useHardwareStore } from '../store/hardwareStore';
import { useConfigStore } from '../store/configStore';
import { useServerStore } from '../store/serverStore';
import { useModelsStore } from '../store/modelsStore';
import { useValidationStore } from '../store/validationStore';
import { validateModelLaunch } from '../lib/validation';
import { ImpactBanner } from '../components/ImpactBanner';
import './Overview.css';

export const OverviewPage: React.FC = () => {
  const {
    profile,
    fetchHardware,
    loading: hardwareLoading,
    error: hardwareError,
  } = useHardwareStore();
  const { config, updateConfig, saveConfig } = useConfigStore();
  const { status, port, logs, clearLogs, pendingRestart } = useServerStore();
  const { models, fetchModels } = useModelsStore();
  const { assessments } = useValidationStore();
  const [backendModelInfo, setBackendModelInfo] = useState<{
    active_model?: string;
    models_preset_path?: string;
  } | null>(null);
  const [copied, setCopied] = useState(false);
  const [templates, setTemplates] = useState<string[]>([]);

  useEffect(() => {
    fetchHardware();
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    fetchModels(config?.models_dir);
  }, [fetchModels, config?.models_dir]);

  useEffect(() => {
    invoke<string[]>('list_templates', { templatesDirPath: config?.templates_dir })
      .then(res => setTemplates(res.filter(t => t !== 'default.jinja')))
      .catch(err => console.warn('Failed to list templates:', err));
  }, [config?.templates_dir]);

  useEffect(() => {
    if (status === 'running') {
      invoke('get_active_model_info')
        .then(result =>
          setBackendModelInfo(result as { active_model?: string; models_preset_path?: string })
        )
        .catch(error => {
          console.warn('Failed to fetch active model info from backend:', error);
        });
    }
  }, [status]);

  const [selectedModelFilename, setSelectedModelFilename] = useState<string>('');

  useEffect(() => {
    if (models.length > 0) {
      const active = models.find(m => m.name === config?.active_model);
      if (active && active.filename !== selectedModelFilename) {
        setSelectedModelFilename(active.filename);
      } else if (!selectedModelFilename) {
        setSelectedModelFilename(models[0].filename);
      }
    }
  }, [models, config?.active_model]);

  const baseModels = models.filter(m => !m.isMmproj);
  const mmprojModels = models.filter(m => m.isMmproj);

  const selectedModel =
    baseModels.find(m => m.filename === selectedModelFilename) ||
    baseModels.find(m => m.name === config?.active_model) ||
    baseModels[0] ||
    null;
  const activeModel = baseModels.find(m => m.name === config?.active_model);
  const launchCheck = validateModelLaunch(selectedModel, config || ({} as any), profile);

  const handleStart = async () => {
    if (!launchCheck.canLaunch) return;
    try {
      if (selectedModel) {
        updateConfig({ active_model: selectedModel.name });
        await saveConfig();
      }
      await invoke('start_server', { port });
    } catch (e) {
      console.error(e);
    }
  };

  const handleStop = async () => {
    try {
      await invoke('stop_server');
    } catch (e) {
      console.error(e);
    }
  };

  const handleAutoTuneAndLaunch = async () => {
    if (launchCheck.autoTuneConfig && config) {
      const tuned = launchCheck.autoTuneConfig(config);
      updateConfig(tuned);
      await saveConfig();
      await invoke('start_server', { port });
    }
  };

  const handleCopyLogs = async () => {
    if (logs.length === 0) return;
    const text = logs.map(l => `[${l.timestamp}] [${l.level}] ${l.message}`).join('\n');
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch (err) {
      console.error('Copy failed:', err);
    }
  };

  const overviewLogs = logs.slice(-100);

  // Compute memory allocation stats for visual headroom gauge
  const totalVram = profile?.vramGb || 24;
  const modelSize = selectedModel?.fileSizeGb || 4.9;
  const kvCacheEst = 3.56;
  const totalAllocated = Math.round((modelSize + kvCacheEst) * 10) / 10;
  const vramPercent = Math.min(100, Math.round((totalAllocated / totalVram) * 100));

  return (
    <PageShell title="Overview">
      <div className="overview-container">
        {/* Restart Required Warning Banner */}
        {pendingRestart && (
          <div
            className="impact-banner severity-caution"
            style={{ display: 'flex', alignItems: 'center', gap: '8px' }}
          >
            <ShieldAlert size={18} />
            <span>Configuration saved. Restart the server to apply updated settings.</span>
          </div>
        )}

        {/* Dynamic Validation Banners */}
        {assessments.map(a => (
          <ImpactBanner key={`${a.param}-${a.severity}`} assessment={a} />
        ))}

        {/* Hero Active Model & Pre-Flight Card */}
        {selectedModel && (
          <div className="glass-card card-padding hero-model-card">
            <div className="hero-model-header">
              <div className="hero-model-title-group">
                <div className="hero-model-name">
                  <Sparkles size={20} style={{ color: 'var(--accent)' }} />
                  <span>{selectedModel.name}</span>
                  <span className="badge badge-info">{selectedModel.quantization}</span>
                  <span className="badge badge-success">{selectedModel.fileSizeGb} GB</span>
                </div>
                <div className="hero-model-sub">
                  <span>
                    Template: <strong>{selectedModel.template}</strong>
                  </span>
                  <span>•</span>
                  <span>
                    Context Target:{' '}
                    <strong>{selectedModel.calculatedContext.toLocaleString()} tokens</strong>
                  </span>
                  {activeModel && activeModel.name === selectedModel.name && (
                    <span className="badge badge-success" style={{ marginLeft: '4px' }}>
                      Active Config
                    </span>
                  )}
                  {backendModelInfo?.active_model && (
                    <>
                      <span>•</span>
                      <span>
                        Backend Active: <strong>{backendModelInfo.active_model}</strong>
                      </span>
                    </>
                  )}
                </div>
              </div>

              {/* Selector Controls */}
              <div className="hero-selectors">
                <select
                  className="hero-select font-mono"
                  value={selectedModelFilename}
                  onChange={e => setSelectedModelFilename(e.target.value)}
                  title="Switch Target Model"
                >
                  {baseModels.map((m, i) => (
                    <option key={i} value={m.filename}>
                      Model: {m.name} ({m.fileSizeGb} GB)
                    </option>
                  ))}
                </select>

                {mmprojModels.length > 0 && (
                  <select
                    className="hero-select font-mono"
                    value={config?.mmproj_path || ''}
                    onChange={async e => {
                      updateConfig({ mmproj_path: e.target.value });
                      await saveConfig();
                    }}
                    title="Select Vision Adapter"
                  >
                    <option value="">Vision: Disabled</option>
                    {mmprojModels.map((proj, idx) => (
                      <option key={idx} value={proj.path}>
                        Vision: {proj.name}
                      </option>
                    ))}
                  </select>
                )}

                <select
                  className="hero-select font-mono"
                  value={
                    config?.active_template
                      ? config.active_template
                      : config?.use_default_template
                        ? 'default.jinja'
                        : 'auto'
                  }
                  onChange={async e => {
                    const val = e.target.value;
                    if (val === 'auto') {
                      updateConfig({ active_template: '', use_default_template: false });
                    } else if (val === 'default.jinja') {
                      updateConfig({
                        active_template: 'default.jinja',
                        use_default_template: true,
                      });
                    } else {
                      updateConfig({ active_template: val, use_default_template: false });
                    }
                    await saveConfig();
                  }}
                  title="Chat Template"
                >
                  <option value="auto">Template: Auto</option>
                  <option value="default.jinja">Template: Universal Default</option>
                  {templates.map((tpl, idx) => (
                    <option key={idx} value={tpl}>
                      Template: {tpl}
                    </option>
                  ))}
                </select>

                {status === 'stopped' ? (
                  launchCheck.canLaunch ? (
                    <button className="btn btn-primary" onClick={handleStart}>
                      <Play size={15} /> Launch Server
                    </button>
                  ) : (
                    <button className="btn btn-danger" disabled style={{ opacity: 0.6 }}>
                      <ShieldAlert size={15} /> Launch Blocked
                    </button>
                  )
                ) : (
                  <button className="btn btn-danger" onClick={handleStop}>
                    <Square size={15} /> Stop Server
                  </button>
                )}
              </div>
            </div>

            {/* Visual Memory Headroom Gauge */}
            <div className="memory-meter-box" style={{ marginTop: '16px' }}>
              <div className="memory-meter-header">
                <span className="memory-meter-label">
                  VRAM Allocation Budget: <strong>{totalAllocated} GB</strong> of{' '}
                  <strong>{totalVram} GB</strong> available ({launchCheck.title})
                </span>
                <span
                  className="memory-meter-stat"
                  style={{
                    color:
                      vramPercent > 90
                        ? 'var(--status-error)'
                        : vramPercent > 75
                          ? 'var(--status-warning)'
                          : 'var(--status-success)',
                  }}
                >
                  {vramPercent}% VRAM Capacity
                </span>
              </div>
              <div className="memory-bar-track">
                <div
                  className="memory-bar-fill"
                  style={{
                    width: `${vramPercent}%`,
                    background:
                      vramPercent > 90
                        ? 'var(--status-error)'
                        : vramPercent > 75
                          ? 'var(--status-warning)'
                          : 'var(--accent-gradient)',
                  }}
                />
              </div>
            </div>
          </div>
        )}

        {/* Quick Actions Grid */}
        <div className="glass-card card-padding">
          <div className="card-header">
            <div className="card-header-left">
              <Zap className="card-icon" size={18} />
              <h3 className="card-title">Quick Actions</h3>
            </div>
          </div>
          <div className="quick-actions-grid">
            <div
              className="quick-action-card"
              onClick={() => {
                updateConfig({ active_model: baseModels[0]?.name || '' });
                saveConfig();
                invoke('start_server', { port });
              }}
            >
              <div className="quick-action-icon">
                <Play size={18} />
              </div>
              <div className="quick-action-info">
                <span className="quick-action-title">Launch Default</span>
                <span className="quick-action-desc">Start active engine model</span>
              </div>
            </div>

            <div className="quick-action-card" onClick={handleAutoTuneAndLaunch}>
              <div
                className="quick-action-icon"
                style={{ background: 'rgba(16, 185, 129, 0.12)', color: 'var(--status-success)' }}
              >
                <Wand2 size={18} />
              </div>
              <div className="quick-action-info">
                <span className="quick-action-title">Auto-Tune & Launch</span>
                <span className="quick-action-desc">Optimize for GPU VRAM</span>
              </div>
            </div>

            <div
              className="quick-action-card"
              onClick={() =>
                invoke('launch_claude_terminal', { port, model: config?.active_model })
              }
            >
              <div
                className="quick-action-icon"
                style={{ background: 'rgba(168, 85, 247, 0.12)', color: '#c084fc' }}
              >
                <Terminal size={18} />
              </div>
              <div className="quick-action-info">
                <span className="quick-action-title">Open Claude Code</span>
                <span className="quick-action-desc">Connect terminal agent</span>
              </div>
            </div>

            <div
              className="quick-action-card"
              onClick={() => {
                fetchModels(config?.models_dir);
                fetchHardware();
              }}
            >
              <div
                className="quick-action-icon"
                style={{ background: 'rgba(56, 189, 248, 0.12)', color: 'var(--status-info)' }}
              >
                <RefreshCw size={18} />
              </div>
              <div className="quick-action-info">
                <span className="quick-action-title">Rescan Models</span>
                <span className="quick-action-desc">Reload local directory</span>
              </div>
            </div>
          </div>
        </div>

        {/* Recent Models Chips */}
        {baseModels.length > 0 && (
          <div className="glass-card card-padding">
            <div className="card-header">
              <div className="card-header-left">
                <Boxes className="card-icon" size={18} />
                <h3 className="card-title">Discovered Models ({baseModels.length} available)</h3>
              </div>
            </div>
            <div className="recent-models-pills">
              {baseModels.map((m, i) => (
                <button
                  key={i}
                  className={`model-pill-btn ${selectedModelFilename === m.filename ? 'active' : ''}`}
                  onClick={() => setSelectedModelFilename(m.filename)}
                >
                  <Layers size={13} />
                  <span>{m.name}</span>
                  <span
                    className="badge badge-info"
                    style={{ fontSize: '0.65rem', padding: '2px 6px' }}
                  >
                    {m.fileSizeGb} GB
                  </span>
                </button>
              ))}
            </div>
          </div>
        )}

        {/* 2-Column Telemetry & Parameters Grid */}
        <div className="overview-grid">
          {/* Hardware Profile Card */}
          <div className="glass-card card-padding">
            <div className="card-header">
              <div className="card-header-left">
                <Cpu className="card-icon" size={18} />
                <h3 className="card-title">System Hardware Profile</h3>
              </div>
              <button
                className="btn btn-outline"
                style={{ padding: '4px 10px', fontSize: '0.78rem' }}
                onClick={() => fetchHardware()}
              >
                <RefreshCw size={13} className={hardwareLoading ? 'spin' : ''} /> Detect
              </button>
            </div>
            <div className="card-body">
              <div className="info-row">
                <span className="info-label">CPU Processor</span>
                <span className="info-value">{profile?.cpuName || 'Probing CPU...'}</span>
              </div>
              <div className="info-row">
                <span className="info-label">Physical & Logical Cores</span>
                <span className="badge badge-info">
                  {profile?.physicalCores || 4} Cores ({profile?.logicalCores || 8} Threads)
                </span>
              </div>
              <div className="info-row">
                <span className="info-label">GPU Accelerator</span>
                <span className="info-value font-mono">
                  {profile?.gpuName || 'Graphics Adapter'}
                </span>
              </div>
              <div className="info-row">
                <span className="info-label">Dedicated VRAM</span>
                <span className="badge badge-success">{profile?.vramGb || 0} GB VRAM</span>
              </div>
              <div className="info-row">
                <span className="info-label">System RAM Capacity</span>
                <span className="info-value font-mono">
                  {profile ? `${profile.totalRamGb} GB RAM` : 'Probing RAM...'}
                </span>
              </div>
              {hardwareError && (
                <div
                  style={{
                    padding: '8px 12px',
                    borderRadius: '8px',
                    background: 'var(--status-error-bg)',
                    border: '1px solid rgba(239, 68, 68, 0.3)',
                    color: 'var(--status-error)',
                    fontSize: '0.8rem',
                  }}
                >
                  Hardware probe warning: {hardwareError}
                </div>
              )}
            </div>
          </div>

          {/* Performance Parameters Card */}
          <div className="glass-card card-padding">
            <div className="card-header">
              <div className="card-header-left">
                <Zap className="card-icon" size={18} />
                <h3 className="card-title">Runtime Performance Parameters</h3>
              </div>
            </div>
            <div className="card-body">
              <div className="info-row">
                <span className="info-label">Context Window</span>
                <span className="info-value font-mono">
                  {config?.overrides?.ctx_size ?? config?.default_context_size ?? 32768} tokens
                </span>
              </div>
              <div className="info-row">
                <span className="info-label">GPU Offload Layers</span>
                <span className="badge badge-info">
                  {config?.overrides?.n_gpu_layers !== undefined
                    ? `${config.overrides.n_gpu_layers} layers`
                    : profile?.adapterClass === 'none'
                      ? '0 (CPU Mode)'
                      : '100% (All Layers)'}
                </span>
              </div>
              <div className="info-row">
                <span className="info-label">Flash Attention</span>
                <span
                  className={`badge ${(config?.overrides?.flash_attn || config?.flash_attn) === 'on' ? 'badge-success' : 'badge-warning'}`}
                >
                  {config?.overrides?.flash_attn || config?.flash_attn || 'auto'}
                </span>
              </div>
              <div className="info-row">
                <span className="info-label">KV Cache Precision</span>
                <span className="info-value font-mono">
                  {config?.overrides?.cache_type_k || config?.cache_type_k || 'f16'}
                </span>
              </div>
              <div className="info-row">
                <span className="info-label">Micro-Batch (ubatch)</span>
                <span className="info-value font-mono">
                  {config?.overrides?.ubatch_size || config?.ubatch_size || 512}
                </span>
              </div>
            </div>
          </div>

          {/* Client Integrations Card */}
          <div className="glass-card card-padding">
            <div className="card-header">
              <div className="card-header-left">
                <Plug className="card-icon" size={18} />
                <h3 className="card-title">Active Integrations</h3>
              </div>
            </div>
            <div className="card-body gap-12">
              {(config?.integrations && config.integrations.length > 0
                ? config.integrations
                : ['claude-code', 'cursor', 'vscode']
              ).map((int, i) => (
                <div
                  key={i}
                  className="info-row"
                  style={{
                    padding: '8px 12px',
                    background: 'rgba(255, 255, 255, 0.02)',
                    borderRadius: '8px',
                  }}
                >
                  <span style={{ textTransform: 'capitalize', fontWeight: 600 }}>
                    {int.replace('-', ' ')}
                  </span>
                  <span className="badge badge-success">Configured</span>
                </div>
              ))}
            </div>
          </div>

          {/* Engine Status Card */}
          <div className="glass-card card-padding">
            <div className="card-header">
              <div className="card-header-left">
                <Terminal className="card-icon" size={18} />
                <h3 className="card-title">Inference Engine Telemetry</h3>
              </div>
            </div>
            <div className="card-body">
              <div className="info-row">
                <span className="info-label">Engine Socket</span>
                <span className="info-value font-mono">127.0.0.1:{port}</span>
              </div>
              <div className="info-row">
                <span className="info-label">Engine Lifecycle</span>
                <span
                  className={`badge ${status === 'running' ? 'badge-success' : 'badge-warning'}`}
                >
                  {status.toUpperCase()}
                </span>
              </div>
              <div className="info-row">
                <span className="info-label">Context Manager Proxy</span>
                <span className="badge badge-info">
                  {config?.context_manager?.enabled ? 'Port 8090 (Active)' : 'Disabled'}
                </span>
              </div>
            </div>
          </div>
        </div>

        {/* Live Logs Card */}
        <div className="glass-card card-padding">
          <div className="card-header">
            <div className="card-header-left">
              <Terminal className="card-icon" size={18} />
              <h3 className="card-title">Live Server Output Streams</h3>
            </div>
            <div style={{ display: 'flex', gap: '8px' }}>
              <button
                className="btn btn-outline"
                style={{ padding: '4px 10px', fontSize: '0.78rem' }}
                onClick={handleCopyLogs}
                disabled={logs.length === 0}
              >
                {copied ? (
                  <Check size={13} style={{ color: 'var(--status-success)' }} />
                ) : (
                  <Copy size={13} />
                )}
                {copied ? 'Copied' : 'Copy'}
              </button>
              <button
                className="btn btn-outline"
                style={{ padding: '4px 10px', fontSize: '0.78rem' }}
                onClick={clearLogs}
                disabled={logs.length === 0}
              >
                <Trash2 size={13} /> Clear
              </button>
            </div>
          </div>
          <div className="log-container font-mono">
            {overviewLogs.length > 0 ? (
              overviewLogs.map((log, index) => (
                <div key={index} className="log-line">
                  <span className="log-time">[{log.timestamp}]</span>
                  <span className={`log-level level-${log.level.toLowerCase()}`}>
                    [{log.level}]
                  </span>
                  <span className="log-msg">{log.message}</span>
                </div>
              ))
            ) : (
              <>
                <div className="log-line" style={{ color: 'var(--text-muted)' }}>
                  <span className="log-time">[system]</span> [INFO] llama-server ready. Select model
                  and click &quot;Launch Server&quot; to begin streaming.
                </div>
                <div className="log-line" style={{ color: 'var(--text-dim)' }}>
                  <span className="log-time">[system]</span> [INFO] Active socket endpoint listening
                  on http://127.0.0.1:{port}
                </div>
              </>
            )}
          </div>
        </div>
      </div>
    </PageShell>
  );
};
