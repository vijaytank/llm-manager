import React, { useEffect, useState } from 'react';
import { PageShell } from '../components/layout/PageShell';
import { RefreshCw, FolderOpen, Check, AlertTriangle, Zap, Info, FileCode, Image } from 'lucide-react';
import { open } from '@tauri-apps/plugin-dialog';
import { invoke } from '@tauri-apps/api/core';
import { useModelsStore, ModelInfo } from '../store/modelsStore';
import { useConfigStore } from '../store/configStore';
import { useHardwareStore } from '../store/hardwareStore';
import { validateModelLaunch } from '../lib/validation';
import { InfoTooltip } from '../components/InfoTooltip';
import './Models.css';

interface GgufDetail {
  name: string;
  architecture: string;
  quantization: string;
  contextLength: number;
  blockCount: number;
  fileSizeGb: number;
  modelVramGb: number;
  kvCacheGbAt8k: number;
  kvCacheGbAt32k: number;
  kvCacheGbAt64k: number;
}

export const ModelsPage: React.FC = () => {
  const { models, loading, fetchModels } = useModelsStore();
  const { config, updateConfig, saveConfig } = useConfigStore();
  const { profile } = useHardwareStore();
  const [inspectingModel, setInspectingModel] = useState<ModelInfo | null>(null);
  const [ggufDetail, setGgufDetail] = useState<GgufDetail | null>(null);

  useEffect(() => {
    fetchModels(config?.models_dir);
  }, [fetchModels, config?.models_dir]);

  const handleBrowseFolder = async () => {
    try {
      const selected = await open({
        directory: true,
        multiple: false,
      });
      if (selected && typeof selected === 'string') {
        updateConfig({ models_dir: selected });
        await saveConfig();
        fetchModels(selected);
      }
    } catch (e) {
      console.error(e);
    }
  };

  const handleInspect = async (m: ModelInfo) => {
    setInspectingModel(m);
    try {
      const info = await invoke<GgufDetail>('read_gguf_info', { filePath: m.path });
      setGgufDetail(info);
    } catch (e) {
      console.error(e);
      setGgufDetail(null);
    }
  };

  const handleSelectActiveModel = async (m: ModelInfo) => {
    updateConfig({ active_model: m.name });
    await saveConfig();
  };

  return (
    <PageShell title="Models & GGUF Inspector">
      <div className="models-container">
        <div className="models-header glass-card card-padding">
          <div>
            <h2>Discovered GGUF Models ({models.length})</h2>
            <p className="font-mono text-muted">{config?.models_dir || 'Directory not configured'}</p>
          </div>
          <div className="models-actions">
            <button className="btn btn-outline" onClick={() => fetchModels(config?.models_dir)}>
              <RefreshCw size={16} className={loading ? 'spin' : ''} /> Refresh
            </button>
            <button className="btn btn-primary" onClick={handleBrowseFolder}>
              <FolderOpen size={16} /> Browse Folder...
            </button>
          </div>
        </div>

        {/* GGUF Header Inspector Modal / Panel */}
        {inspectingModel && ggufDetail && (
          <div className="glass-card card-padding" style={{ borderLeft: '4px solid var(--accent)' }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                <FileCode size={20} className="card-icon" />
                <h3>GGUF Binary Header Details: {ggufDetail.name}</h3>
              </div>
              <button className="btn btn-outline" onClick={() => setInspectingModel(null)}>Close</button>
            </div>
            <div className="overview-grid" style={{ marginTop: '12px' }}>
              <div className="info-row">
                <span className="info-label">Architecture</span>
                <span className="info-value font-mono">{ggufDetail.architecture}</span>
              </div>
              <div className="info-row">
                <span className="info-label">Quantization</span>
                <span className="info-value font-mono">{ggufDetail.quantization}</span>
              </div>
              <div className="info-row">
                <span className="info-label">Transformer Layers</span>
                <span className="info-value font-mono">{ggufDetail.blockCount} blocks</span>
              </div>
              <div className="info-row">
                <span className="info-label">Native Context Limit</span>
                <span className="info-value font-mono">{ggufDetail.contextLength.toLocaleString()} tokens</span>
              </div>
              <div className="info-row">
                <span className="info-label">KV Cache @ 8K</span>
                <span className="info-value font-mono">{ggufDetail.kvCacheGbAt8k} GB</span>
              </div>
              <div className="info-row">
                <span className="info-label">KV Cache @ 32K</span>
                <span className="info-value font-mono">{ggufDetail.kvCacheGbAt32k} GB</span>
              </div>
            </div>
          </div>
        )}

        <div className="glass-card table-container">
          <table className="models-table">
            <thead>
              <tr>
                <th>
                  Model Name
                  <InfoTooltip
                    title="GGUF Model File"
                    description="The main GGML/GGUF quantized weights file scanned from your configured models directory."
                    recommendation="Q4_K_M or NVFP4 quantizations provide the best balance of speed, quality, and low VRAM footprint."
                  />
                </th>
                <th>File Size</th>
                <th>Quantization</th>
                <th>
                  Template / Type
                  <InfoTooltip
                    title="Detected Chat Template & Type"
                    description="Chat template auto-detected from GGUF metadata headers (e.g. ChatML, Mistral, Llama-3)."
                  />
                </th>
                <th>
                  Vision (mmproj) Adapter
                  <InfoTooltip
                    title="Multimodal Projector Adapter"
                    description="Identifies if the file is a vision adapter (mmproj) or text model."
                    recommendation="Must match the base vision model architecture to enable image input."
                  />
                </th>
                <th>
                  Hardware Check
                  <InfoTooltip
                    title="Hardware Safety & Pre-Flight Check"
                    description="Evaluates if your GPU VRAM and System RAM can fit the model weights + KV cache."
                    recommendation={profile?.vramGb ? `Models under ${profile.vramGb * 0.8} GB will run with 100% GPU offload.` : "CPU mode active."}
                  />
                </th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              {models.length > 0 ? (
                (() => {
                  const baseModels = models.filter((m) => !m.isMmproj);
                  const mmprojModels = models.filter((m) => m.isMmproj);
                  const selectedMmprojPath = config?.mmproj_path || '';
                  const isNoOffload = !!config?.mmproj_no_offload;

                  const displayList = baseModels.length > 0 ? baseModels : models;

                  return displayList.map((m, i) => {
                    const launchCheck = validateModelLaunch(m, config || ({} as any), profile);
                    const isActive = config?.active_model === m.name;
                    const isCurrentModelMmprojSelected = isActive && selectedMmprojPath !== '' && selectedMmprojPath !== 'none';

                    return (
                      <tr key={i} style={{ background: isActive ? 'rgba(16, 185, 129, 0.08)' : undefined }}>
                        <td className="font-semibold">
                          {m.name}
                          {isActive && <span className="badge badge-success" style={{ marginLeft: '8px' }}>Active</span>}
                        </td>
                        <td className="font-mono">{m.fileSizeGb} GB</td>
                        <td className="font-mono">{m.quantization}</td>
                        <td>
                          {m.isMmproj ? (
                            <span className="badge badge-info">
                              <Image size={12} style={{ marginRight: '4px' }} /> Multimodal Projector
                            </span>
                          ) : (
                            <span className="template-badge">
                              <Check size={14} /> {m.template}
                            </span>
                          )}
                        </td>
                        <td>
                          {m.isMmproj ? (
                            <span className="text-muted font-mono" style={{ fontSize: '0.85rem' }}>N/A (Is Projector)</span>
                          ) : mmprojModels.length > 0 ? (
                            <div style={{ display: 'flex', flexDirection: 'column', gap: '4px' }}>
                              <select
                                className="form-input font-mono"
                                style={{ fontSize: '0.8rem', padding: '2px 6px' }}
                                value={isActive ? selectedMmprojPath : ''}
                                onChange={async (e) => {
                                  if (!isActive) {
                                    updateConfig({ active_model: m.name, mmproj_path: e.target.value });
                                  } else {
                                    updateConfig({ mmproj_path: e.target.value });
                                  }
                                  await saveConfig();
                                }}
                              >
                                <option value="">Disabled (Text Only)</option>
                                {mmprojModels.map((proj, idx) => (
                                  <option key={idx} value={proj.path}>
                                    {proj.name} ({proj.fileSizeGb} GB)
                                  </option>
                                ))}
                              </select>
                              {isCurrentModelMmprojSelected && (
                                <div style={{ display: 'flex', alignItems: 'center', gap: '8px', fontSize: '0.75rem' }}>
                                  <label style={{ display: 'flex', alignItems: 'center', gap: '4px', cursor: 'pointer' }}>
                                    <input
                                      type="radio"
                                      name={`offload-${i}`}
                                      checked={!isNoOffload}
                                      onChange={async () => {
                                        updateConfig({ mmproj_no_offload: false });
                                        await saveConfig();
                                      }}
                                    />
                                    <span style={{ color: 'var(--accent-green, #10b981)' }}>GPU</span>
                                  </label>
                                  <label style={{ display: 'flex', alignItems: 'center', gap: '4px', cursor: 'pointer' }}>
                                    <input
                                      type="radio"
                                      name={`offload-${i}`}
                                      checked={isNoOffload}
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
                          ) : (
                            <span className="text-muted font-mono" style={{ fontSize: '0.85rem' }}>None Available</span>
                          )}
                        </td>
                        <td>
                          {m.isMmproj ? (
                            <span className="badge badge-info">Vision Adapter</span>
                          ) : (
                            <span className={`badge severity-${launchCheck.severity}`}>
                              {launchCheck.canLaunch ? <Zap size={12} style={{ marginRight: '4px' }} /> : <AlertTriangle size={12} style={{ marginRight: '4px' }} />}
                              {launchCheck.title}
                            </span>
                          )}
                        </td>
                        <td>
                          <div style={{ display: 'flex', gap: '6px' }}>
                            <button className="btn btn-outline" style={{ padding: '4px 8px' }} onClick={() => handleInspect(m)}>
                              <Info size={14} /> Inspect
                            </button>
                            {!isActive && !m.isMmproj && (
                              <button className="btn btn-primary" style={{ padding: '4px 8px' }} onClick={() => handleSelectActiveModel(m)}>
                                Select
                              </button>
                            )}
                          </div>
                        </td>
                      </tr>
                    );
                  });
                })()
              ) : (
                <tr>
                  <td colSpan={7} style={{ textAlign: 'center', color: 'var(--text-muted)', padding: '24px' }}>
                    No GGUF models discovered in {config?.models_dir || 'configured directory'}. Click "Browse Folder..." to select your models directory.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </PageShell>
  );
};
