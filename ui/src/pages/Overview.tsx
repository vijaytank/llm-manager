import React, { useState, useEffect } from 'react';
import { PageShell } from '../components/layout/PageShell';
import { Cpu, Zap, Boxes, Plug, Terminal, Play, Square, Wand2, ShieldAlert, Image, RefreshCw } from 'lucide-react';
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
  const { profile, fetchHardware, loading: hardwareLoading } = useHardwareStore();
  const { config, updateConfig, saveConfig } = useConfigStore();
  const { status, port, logs } = useServerStore();
  const { models } = useModelsStore();
  const { assessments } = useValidationStore();
  const [backendModelInfo, setBackendModelInfo] = useState<{ active_model?: string; models_preset_path?: string } | null>(null);

  useEffect(() => {
    fetchHardware();
  }, [fetchHardware]);

  useEffect(() => {
    invoke('get_active_model_info')
      .then((result) => setBackendModelInfo(result as { active_model?: string; models_preset_path?: string }))
      .catch((error) => {
        console.warn('Failed to fetch active model info from backend:', error);
      });
  }, []);

  const [selectedModelFilename, setSelectedModelFilename] = useState<string>(
    models.length > 0 ? models[0].filename : ''
  );

  const selectedModel = models.find((m) => m.filename === selectedModelFilename) || models[0] || null;
  const activeModel = models.find((m) => m.name === config?.active_model);
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

  return (
    <PageShell title="Overview">
      {/* Dynamic Validation Banners */}
      {assessments.map((a, i) => (
        <ImpactBanner key={i} assessment={a} />
      ))}

      {/* Pre-Flight Model Launch Verdict Card */}
      {selectedModel && (
        <div className={`glass-card card-padding launch-card severity-${launchCheck.severity}`} style={{ marginBottom: '20px' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
              <Boxes size={24} className="card-icon" />
              <div>
                <h3 style={{ margin: 0 }}>Model Selection & Pre-Flight Check</h3>
                <div style={{ fontSize: '0.85rem', color: 'var(--text-secondary)', marginTop: '2px' }}>
                  {launchCheck.message}
                </div>
                {activeModel && (
                  <div style={{ marginTop: '8px', display: 'flex', gap: '8px', alignItems: 'center' }}>
                    <span className="badge badge-info">Configured Active Model</span>
                    <span className="font-mono">{activeModel.name}</span>
                    {activeModel.isMmproj && (
                      <span className="badge badge-warning">mmproj selected</span>
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

            <div style={{ display: 'flex', alignItems: 'center', gap: '12px' }}>
              <select
                className="form-input font-mono"
                style={{ width: '240px', padding: '6px 12px' }}
                value={selectedModelFilename}
                onChange={(e) => setSelectedModelFilename(e.target.value)}
              >
                {models.map((m, i) => (
                  <option key={i} value={m.filename}>
                    {m.name} ({m.fileSizeGb} GB)
                  </option>
                ))}
              </select>

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
          <div className="card-header">
            <Terminal className="card-icon" size={20} />
            <h3 className="card-title">Live Server Output Streams</h3>
          </div>
          <div className="log-container font-mono">
            {logs.length > 0 ? (
              logs.map((log, index) => (
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
