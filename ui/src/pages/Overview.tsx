import React, { useState, useEffect } from 'react';
import { PageShell } from '../components/layout/PageShell';
import { Cpu, Zap, Boxes, Plug, Terminal, Play, Square, Wand2, ShieldAlert, Image, RefreshCw, Copy, Check, Trash2 } from 'lucide-react';
import { invoke } from '@tauri-apps/api/core';
import { useHardwareStore } from '../store/hardwareStore';
import { useConfigStore } from '../store/configStore';
import { useServerStore } from '../store/serverStore';
import { useModelsStore } from '../store/modelsStore';
import { useValidationStore } from '../store/validationStore';
import { validateModelLaunch } from '../lib/validation';
import { ImpactBanner } from '../components/ImpactBanner';
import { InfoTooltip } from '../components/InfoTooltip';
import './Overview.css';

export const OverviewPage: React.FC = () => {
  const { profile, fetchHardware, loading: hardwareLoading } = useHardwareStore();
  const { config, updateConfig, saveConfig } = useConfigStore();
  const { status, port, logs, clearLogs, pendingRestart } = useServerStore();
  const { models, fetchModels } = useModelsStore();
  const { assessments } = useValidationStore();
  const [backendModelInfo, setBackendModelInfo] = useState<{ active_model?: string; models_preset_path?: string } | null>(null);
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
      .then((res) => setTemplates(res.filter((t) => t !== 'default.jinja')))
      .catch((err) => console.warn('Failed to list templates:', err));
  }, [config?.templates_dir]);

  useEffect(() => {
    if (status === 'running') {
      invoke('get_active_model_info')
        .then((result) => setBackendModelInfo(result as { active_model?: string; models_preset_path?: string }))
        .catch((error) => {
          console.warn('Failed to fetch active model info from backend:', error);
        });
    }
  }, [status]);

  const [selectedModelFilename, setSelectedModelFilename] = useState<string>('');

  useEffect(() => {
    if (models.length > 0) {
      const active = models.find((m) => m.name === config?.active_model);
      if (active && active.filename !== selectedModelFilename) {
        setSelectedModelFilename(active.filename);
      } else if (!selectedModelFilename) {
        setSelectedModelFilename(models[0].filename);
      }
    }
  }, [models, config?.active_model]);

  const baseModels = models.filter((m) => !m.isMmproj);
  const mmprojModels = models.filter((m) => m.isMmproj);

  const selectedModel = baseModels.find((m) => m.filename === selectedModelFilename) || baseModels.find((m) => m.name === config?.active_model) || baseModels[0] || null;
  const activeModel = baseModels.find((m) => m.name === config?.active_model);
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
    const text = logs.map((l) => `[${l.timestamp}] [${l.level}] ${l.message}`).join('\n');
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch (err) {
      console.error('Copy failed:', err);
    }
  };

  const overviewLogs = logs.slice(-100);

  return (
    <PageShell title="Overview">
      {/* Restart Required Warning Banner */}
      {pendingRestart && (
        <div className="impact-banner severity-caution" style={{ marginBottom: '16px', display: 'flex', alignItems: 'center', gap: '8px' }}>
          <ShieldAlert size={18} />
          <span>Configuration saved. Restart the server to apply updated settings.</span>
        </div>
      )}

      {/* Dynamic Validation Banners */}
      {assessments.map((a) => (
        <ImpactBanner key={`${a.param}-${a.severity}`} assessment={a} />
      ))}

      {/* Pre-Flight Model Launch Verdict Card */}
      {selectedModel && (
        <div className={`glass-card card-padding launch-card severity-${launchCheck.severity}`} style={{ marginBottom: '20px' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
              <Boxes size={24} className="card-icon" />
              <div>
                <h3 style={{ margin: 0, display: 'flex', alignItems: 'center' }}>
                  Model Selection & Pre-Flight Check
                  <InfoTooltip
                    title="Model Selection & Pre-Flight Check"
                    description="Selects the primary GGUF model for inference and validates memory safety before launching llama-server."
                    recommendation={profile?.vramGb ? `Your ${profile.vramGb} GB GPU fits models up to ~${Math.floor(profile.vramGb * 0.8)} GB file size.` : "Running on CPU RAM budget."}
                    impact="Ensures system RAM/VRAM is not exceeded during server initialization."
                  />
                </h3>
                <div style={{ fontSize: '0.85rem', color: 'var(--text-secondary)', marginTop: '2px' }}>
                  {launchCheck.message}
                </div>
                {activeModel && (
                  <div style={{ marginTop: '8px', display: 'flex', gap: '8px', alignItems: 'center' }}>
                    <span className="badge badge-info">Configured Active Model</span>
                    <span className="font-mono">{activeModel.name}</span>
                    {config?.mmproj_path && config.mmproj_path !== 'none' && (
                      <span className="badge badge-success" style={{ display: 'flex', alignItems: 'center', gap: '4px' }}>
                        <Image size={12} /> Vision Enabled ({config.mmproj_no_offload ? 'CPU RAM' : 'GPU'})
                      </span>
                    )}
                  </div>
                )}
                {backendModelInfo?.active_model && (
                  <div style={{ marginTop: '8px', display: 'flex', gap: '8px', alignItems: 'center' }}>
                    <span className="badge badge-outline">Backend Active Model</span>
                    <span className="font-mono">{backendModelInfo.active_model}</span>
                  </div>
                )}
              </div>
            </div>

            <div style={{ display: 'flex', alignItems: 'center', gap: '12px', flexWrap: 'wrap' }}>
              {/* Primary LLM Model Dropdown */}
              <select
                className="form-input font-mono"
                style={{ width: '240px', padding: '6px 12px' }}
                value={selectedModelFilename}
                onChange={(e) => setSelectedModelFilename(e.target.value)}
              >
                {baseModels.map((m, i) => (
                  <option key={i} value={m.filename}>
                    {m.name} ({m.fileSizeGb} GB)
                  </option>
                ))}
              </select>

              {/* Vision mmproj Dropdown */}
              {mmprojModels.length > 0 && (
                <div style={{ display: 'flex', flexDirection: 'column', gap: '4px' }}>
                  <div style={{ display: 'flex', alignItems: 'center' }}>
                    <select
                      className="form-input font-mono"
                      style={{ width: '220px', padding: '6px 10px', fontSize: '0.85rem' }}
                      value={config?.mmproj_path || ''}
                      onChange={async (e) => {
                        updateConfig({ mmproj_path: e.target.value });
                        await saveConfig();
                      }}
                    >
                      <option value="">Vision: Disabled (Text Only)</option>
                      {mmprojModels.map((proj, idx) => (
                        <option key={idx} value={proj.path}>
                          Vision: {proj.name} ({proj.fileSizeGb} GB)
                        </option>
                      ))}
                    </select>
                    <InfoTooltip
                      title="Multimodal Vision Adapter (--mmproj)"
                      description="Enables image and multimodal visual processing for compatible GGUF vision models (CLIP / LLaVA / Qwen-VL)."
                      recommendation="Select matching mmproj file for image support. Use CPU offload if VRAM is tight."
                      impact="Consumes ~0.8-1.5 GB VRAM or RAM."
                    />
                  </div>
                  {config?.mmproj_path && config.mmproj_path !== 'none' && (
                    <div style={{ display: 'flex', gap: '12px', fontSize: '0.75rem', marginTop: '2px', background: 'var(--bg-card)', padding: '4px 8px', borderRadius: '4px' }}>
                      <label style={{ display: 'flex', alignItems: 'center', gap: '4px', cursor: 'pointer' }}>
                        <input
                          type="radio"
                          name="overview-mmproj-offload"
                          checked={!config?.mmproj_no_offload}
                          onChange={async () => {
                            updateConfig({ mmproj_no_offload: false });
                            await saveConfig();
                          }}
                        />
                        <span style={{ color: 'var(--accent-green, #10b981)' }}>GPU Offload</span>
                      </label>
                      <label style={{ display: 'flex', alignItems: 'center', gap: '4px', cursor: 'pointer' }}>
                        <input
                          type="radio"
                          name="overview-mmproj-offload"
                          checked={!!config?.mmproj_no_offload}
                          onChange={async () => {
                            updateConfig({ mmproj_no_offload: true });
                            await saveConfig();
                          }}
                        />
                        <span style={{ color: 'var(--text-muted)' }}>CPU (RAM)</span>
                      </label>
                    </div>
                  )}
                </div>
              )}

              {/* Chat Template Selector */}
              <div style={{ display: 'flex', alignItems: 'center', gap: '4px' }}>
                <select
                  className="form-input font-mono"
                  style={{ width: '240px', padding: '6px 10px', fontSize: '0.85rem' }}
                  value={
                    config?.active_template
                      ? config.active_template
                      : config?.use_default_template
                      ? 'default.jinja'
                      : 'auto'
                  }
                  onChange={async (e) => {
                    const val = e.target.value;
                    if (val === 'auto') {
                      updateConfig({ active_template: '', use_default_template: false });
                    } else if (val === 'default.jinja') {
                      updateConfig({ active_template: 'default.jinja', use_default_template: true });
                    } else {
                      updateConfig({ active_template: val, use_default_template: false });
                    }
                    await saveConfig();
                  }}
                >
                  <option value="auto">Template: Auto (GGUF internal)</option>
                  <option value="default.jinja">Template: Universal Default (default.jinja)</option>
                  {templates.map((tpl, idx) => (
                    <option key={idx} value={tpl}>
                      Template: {tpl}
                    </option>
                  ))}
                </select>
                <InfoTooltip
                  title="Chat Template (--chat-template-file)"
                  description="Formats system, user, and assistant prompt roles. Universal Default (default.jinja) fixes Jinja system role exceptions across custom GGUF models."
                  recommendation="Universal Default (default.jinja) is recommended if your model returns template parsing errors."
                  impact="Ensures system prompts and multi-turn conversations format cleanly."
                />
              </div>

              {status === 'stopped' ? (
                launchCheck.canLaunch ? (
                  <button className="btn btn-primary" onClick={handleStart}>
                    <Play size={16} /> Launch Server
                  </button>
                ) : (
                  <button className="btn btn-danger" disabled style={{ opacity: 0.6, cursor: 'not-allowed' }}>
                    <ShieldAlert size={16} /> Launch Blocked (Insufficient RAM)
                  </button>
                )
              ) : status === 'stopping' ? (
                <button className="btn btn-outline btn-danger" disabled style={{ opacity: 0.6, cursor: 'not-allowed' }}>
                  <RefreshCw size={16} className="spin" /> Stopping Server...
                </button>
              ) : status === 'starting' ? (
                <button className="btn btn-outline" disabled style={{ opacity: 0.8, cursor: 'wait' }}>
                  <RefreshCw size={16} className="spin" /> Starting Server...
                </button>
              ) : (
                <button className="btn btn-outline btn-danger" onClick={handleStop}>
                  <Square size={16} /> Stop Server
                </button>
              )}

              {status === 'stopped' && launchCheck.autoTuneConfig && launchCheck.severity !== 'ok' && (
                <button className="btn btn-outline" onClick={handleAutoTuneAndLaunch}>
                  <Wand2 size={16} /> Launch Auto-Tuned
                </button>
              )}
            </div>
          </div>
        </div>
      )}

      <div className="overview-grid">
        {/* Hardware Profile Card */}
        <div className="glass-card card-padding">
          <div className="card-header" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
              <Cpu className="card-icon" size={20} />
              <h3 className="card-title">System Hardware Profile</h3>
            </div>
            <button className="btn btn-outline" style={{ padding: '4px 8px', fontSize: '0.8rem' }} onClick={() => fetchHardware()}>
              <RefreshCw size={14} className={hardwareLoading ? 'spin' : ''} /> Detect Hardware
            </button>
          </div>
          <div className="card-body">
            <div className="info-row">
              <span className="info-label">CPU</span>
              <span className="info-value">{profile?.cpuName || 'Probing CPU...'}</span>
            </div>
            <div className="info-row">
              <span className="info-label">RAM</span>
              <span className="info-value">{profile ? `${profile.totalRamGb} GB` : 'Probing RAM...'}</span>
            </div>
            <div className="info-row">
              <span className="info-label">GPU Adapter</span>
              <span className="info-value">
                {profile?.gpuName || 'Graphics Adapter'} ({profile?.vramGb || 0} GB VRAM)
              </span>
            </div>
            <div className="info-row">
              <span className="info-label">Adapter Class</span>
              <span className="badge badge-info">{profile?.adapterClass || 'none'}</span>
            </div>
            <div className="info-row">
              <span className="info-label">Performance Tier</span>
              <span className="badge badge-success">{profile?.performanceTier || 'cpu'}</span>
            </div>
          </div>
        </div>

        {/* Performance Parameters Card */}
        <div className="glass-card card-padding">
          <div className="card-header">
            <Zap className="card-icon" size={20} />
            <h3 className="card-title">Performance Parameters</h3>
          </div>
          <div className="card-body">
            <div className="info-row">
              <span className="info-label">Context Window</span>
              <span className="info-value font-mono">{config?.default_context_size || 32768} tokens</span>
            </div>
            <div className="info-row">
              <span className="info-label">GPU Offload Layers</span>
              <span className="info-value font-mono">
                {config?.overrides?.n_gpu_layers !== undefined
                  ? config.overrides.n_gpu_layers
                  : profile?.adapterClass === 'none'
                  ? '0 (CPU Mode)'
                  : '-1 (All Layers)'}
              </span>
            </div>
            <div className="info-row">
              <span className="info-label">Flash Attention</span>
              <span className={`badge ${config?.flash_attn === 'on' ? 'badge-success' : 'badge-warning'}`}>
                {config?.flash_attn || 'off'}
              </span>
            </div>
            <div className="info-row">
              <span className="info-label">KV Cache Precision</span>
              <span className="info-value font-mono">{config?.cache_type_k || 'f16'}</span>
            </div>
            <div className="info-row">
              <span className="info-label">UBatch Size</span>
              <span className="info-value font-mono">{config?.ubatch_size || 512}</span>
            </div>
          </div>
        </div>

        {/* Discovered Models Card with Full Scrollbar */}
        <div className="glass-card card-padding">
          <div className="card-header">
            <Boxes className="card-icon" size={20} />
            <h3 className="card-title">Discovered GGUF Models ({models.length})</h3>
          </div>
          <div className="card-body gap-12" style={{ maxHeight: '240px', overflowY: 'auto', paddingRight: '4px' }}>
            {models.length > 0 ? (
              models.map((m, i) => (
                <div key={i} className="model-row">
                  <div>
                    <div className="model-name">{m.name}</div>
                    <div className="model-sub font-mono">
                      {m.fileSizeGb} GB • {m.quantization}
                    </div>
                  </div>
                  {m.isMmproj ? (
                    <span className="badge badge-info">
                      <Image size={12} style={{ marginRight: '4px' }} /> Multimodal Projector
                    </span>
                  ) : (
                    <span className="badge badge-success">{m.status}</span>
                  )}
                </div>
              ))
            ) : (
              <div className="model-row">
                <div>
                  <div className="model-name">Models Directory</div>
                  <div className="model-sub font-mono">{config?.models_dir || 'Directory unconfigured'}</div>
                </div>
                <span className="badge badge-warning">Setup Required</span>
              </div>
            )}
          </div>
        </div>

        {/* Integrations Card */}
        <div className="glass-card card-padding">
          <div className="card-header">
            <Plug className="card-icon" size={20} />
            <h3 className="card-title">Client Integrations (Port: {port})</h3>
          </div>
          <div className="card-body gap-12">
            {(config?.integrations || ['server-only']).map((int, i) => (
              <div key={i} className="integration-item">
                <span style={{ textTransform: 'capitalize' }}>{int}</span>
                <span className="badge badge-success">Active</span>
              </div>
            ))}
          </div>
        </div>

        {/* Live Logs Card */}
        <div className="glass-card card-padding full-width">
          <div className="card-header" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
              <Terminal className="card-icon" size={20} />
              <h3 className="card-title">Live Server Streams (Latest 100 Lines)</h3>
            </div>
            <div style={{ display: 'flex', gap: '8px' }}>
              <button
                className="btn btn-outline"
                style={{ padding: '4px 10px', fontSize: '0.8rem' }}
                onClick={handleCopyLogs}
                disabled={logs.length === 0}
              >
                {copied ? <Check size={14} style={{ color: 'var(--accent-green, #10b981)' }} /> : <Copy size={14} />}
                {copied ? 'Copied!' : 'Copy Logs'}
              </button>
              <button
                className="btn btn-outline"
                style={{ padding: '4px 10px', fontSize: '0.8rem' }}
                onClick={clearLogs}
                disabled={logs.length === 0}
              >
                <Trash2 size={14} /> Clear
              </button>
            </div>
          </div>
          <div className="log-container font-mono">
            {overviewLogs.length > 0 ? (
              overviewLogs.map((log, index) => (
                <div key={index} className="log-line">
                  <span className="log-time">[{log.timestamp}]</span>
                  <span className={`log-level level-${log.level.toLowerCase()}`}>{log.level}</span>
                  <span className="log-msg">{log.message}</span>
                </div>
              ))
            ) : (
              <div className="log-line" style={{ color: 'var(--text-muted)' }}>
                Server is currently stopped. Select a model above and click "Launch Server" to begin inference.
              </div>
            )}
          </div>
        </div>
      </div>
    </PageShell>
  );
};
