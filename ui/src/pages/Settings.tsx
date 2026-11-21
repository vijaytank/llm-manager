import React, { useState, useEffect, useRef } from 'react';
import { PageShell } from '../components/layout/PageShell';
import { Save, FolderOpen, Code, Sliders, Check, AlertTriangle, X } from 'lucide-react';
import { open } from '@tauri-apps/plugin-dialog';
import { useConfigStore, AppConfig } from '../store/configStore';
import { InfoTooltip } from '../components/InfoTooltip';
import { useJsonSchemaValidation } from '../hooks/useJsonSchemaValidation';
import './Settings.css';

export const SettingsPage: React.FC = () => {
  const { config, updateConfig, saveConfig } = useConfigStore();
  const [activeTab, setActiveTab] = useState<'visual' | 'json'>('visual');
  const [jsonText, setJsonText] = useState(JSON.stringify(config, null, 2));
  const [saveSuccess, setSaveSuccess] = useState(false);

  // JSON Schema validation
  const { errors, isValid, validate } = useJsonSchemaValidation(jsonText);
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  // Sync jsonText with config when visual tab changes
  useEffect(() => {
    if (activeTab === 'visual') {
      setJsonText(JSON.stringify(config, null, 2));
    }
  }, [config, activeTab]);

  // Validate on change
  useEffect(() => {
    if (activeTab === 'json') {
      const timer = setTimeout(() => {
        validate();
      }, 300);
      return () => clearTimeout(timer);
    }
  }, [jsonText, activeTab, validate]);

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

  const handleBrowseModelsDir = async () => {
    try {
      const selected = await open({
        directory: true,
        multiple: false,
      });
      if (selected && typeof selected === 'string') {
        updateConfig({ models_dir: selected });
      }
    } catch (e) {
      console.error(e);
    }
  };

  const handleSaveVisual = async () => {
    await saveConfig();
    setSaveSuccess(true);
    setTimeout(() => setSaveSuccess(false), 2000);
  };

  const handleSaveJson = async () => {
    try {
      const parsed: AppConfig = JSON.parse(jsonText);
      updateConfig(parsed);
      await saveConfig();
      setSaveSuccess(true);
      setTimeout(() => setSaveSuccess(false), 2000);
    } catch (e: any) {
      // Error handled by validation hook
    }
  };

  return (
    <PageShell title="Settings">
      <div className="settings-container">
        <div className="settings-tabs glass-card card-padding">
          <div className="tab-buttons">
            <button
              className={`tab-btn ${activeTab === 'visual' ? 'active' : ''}`}
              onClick={() => {
                setJsonText(JSON.stringify(config, null, 2));
                setActiveTab('visual');
              }}
            >
              <Sliders size={16} /> Visual Form Editor
            </button>
            <button
              className={`tab-btn ${activeTab === 'json' ? 'active' : ''}`}
              onClick={() => {
                setJsonText(JSON.stringify(config, null, 2));
                setActiveTab('json');
              }}
            >
              <Code size={16} /> Raw JSON Editor
            </button>
          </div>

          <div style={{ display: 'flex', gap: '10px', alignItems: 'center' }}>
            {saveSuccess && (
              <span className="badge badge-success">
                <Check size={14} /> Saved
              </span>
            )}
            <button
              className="btn btn-primary"
              onClick={activeTab === 'visual' ? handleSaveVisual : handleSaveJson}
            >
              <Save size={16} /> Save Changes
            </button>
          </div>
        </div>

        {activeTab === 'visual' ? (
          <div
            className="glass-card card-padding"
            style={{ display: 'flex', flexDirection: 'column', gap: '16px' }}
          >
            <h2>System Path Configurations</h2>

            <div className="form-group">
              <label className="form-label">
                llama-server.exe Executable Path
                <InfoTooltip
                  title="llama-server.exe Executable Path"
                  description="Absolute path to the backend llama-server binary. Built-in precompiled binary is used by default."
                  recommendation="Leave default unless you are using a custom compiled llama.cpp build."
                />
              </label>
              <div style={{ display: 'flex', gap: '10px' }}>
                <input
                  type="text"
                  className="form-input font-mono"
                  value={config?.llama_server_path || ''}
                  onChange={e => updateConfig({ llama_server_path: e.target.value })}
                />
                <button className="btn btn-outline" onClick={handleBrowseServerBinary}>
                  <FolderOpen size={16} /> Browse...
                </button>
              </div>
            </div>

            <div className="form-group">
              <label className="form-label">
                GGUF Models Directory
                <InfoTooltip
                  title="GGUF Models Folder"
                  description="Root folder where LLM Manager scans for .gguf model files and .jinja templates."
                  recommendation="Set to your dedicated model storage drive."
                />
              </label>
              <div style={{ display: 'flex', gap: '10px' }}>
                <input
                  type="text"
                  className="form-input font-mono"
                  value={config?.models_dir || ''}
                  onChange={e => updateConfig({ models_dir: e.target.value })}
                />
                <button className="btn btn-outline" onClick={handleBrowseModelsDir}>
                  <FolderOpen size={16} /> Browse Folder...
                </button>
              </div>
            </div>

            <div className="form-group">
              <label className="form-label">
                Context Window Limit
                <InfoTooltip
                  title="Context Window Limit (-c / --ctx-size)"
                  description="Maximum number of tokens (prompt + response + history) the model can hold in memory simultaneously."
                  recommendation="Synchronized with the Context Window setting in Performance & System Tuning."
                />
              </label>
              <input
                type="number"
                className="form-input font-mono"
                value={config?.overrides?.ctx_size ?? config?.default_context_size ?? 32768}
                onChange={e => {
                  const val = Number(e.target.value);
                  updateConfig({
                    default_context_size: val,
                    overrides: { ...(config?.overrides || {}), ctx_size: val },
                  });
                }}
              />
            </div>

            <hr style={{ borderColor: 'rgba(255, 255, 255, 0.1)', margin: '12px 0' }} />

            <h2 style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
              Context Manager Proxy
              <InfoTooltip
                title="Context Manager Proxy"
                description="Prevent model crashes and speed collapse by automatically summarizing chat history when approaching token limits."
                recommendation="Enable for long-running coding agents like Claude Code."
              />
            </h2>

            <div className="form-group" style={{ margin: '8px 0' }}>
              <label className="toggle-switch-wrapper">
                <input
                  type="checkbox"
                  className="toggle-checkbox"
                  id="cm-enabled"
                  checked={config?.context_manager?.enabled ?? false}
                  onChange={e =>
                    updateConfig({
                      context_manager: {
                        enabled: e.target.checked,
                        warn_threshold: config?.context_manager?.warn_threshold ?? 0.7,
                        keep_turns: config?.context_manager?.keep_turns ?? 6,
                        proxy_port: config?.context_manager?.proxy_port ?? 8090,
                        ctx_limit: config?.context_manager?.ctx_limit ?? 0,
                        tokenizer_repo: config?.context_manager?.tokenizer_repo ?? '',
                        summary_max_tokens: config?.context_manager?.summary_max_tokens ?? 768,
                        summarize_with_model:
                          config?.context_manager?.summarize_with_model ?? 'same',
                      },
                    })
                  }
                />
                <span className="toggle-slider"></span>
                <span className="toggle-label-text">Enable Context Manager Proxy</span>
              </label>
            </div>

            {config?.context_manager?.enabled && (
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: '16px' }}>
                <div className="form-group">
                  <label className="form-label">
                    Warn Threshold Ratio
                    <InfoTooltip
                      title="Warn Threshold"
                      description="Percentage of context limit at which compression triggers (e.g. 0.70 = 70%)."
                    />
                  </label>
                  <input
                    type="number"
                    step="0.05"
                    min="0.4"
                    max="0.95"
                    className="form-input font-mono"
                    value={config?.context_manager?.warn_threshold ?? 0.7}
                    onChange={e =>
                      updateConfig({
                        context_manager: {
                          ...config.context_manager!,
                          warn_threshold: Number(e.target.value),
                        },
                      })
                    }
                  />
                </div>

                <div className="form-group">
                  <label className="form-label">
                    Recent Turns to Keep
                    <InfoTooltip
                      title="Keep Turns"
                      description="Number of recent chat turns preserved verbatim without compression."
                    />
                  </label>
                  <input
                    type="number"
                    min="2"
                    max="20"
                    className="form-input font-mono"
                    value={config?.context_manager?.keep_turns ?? 6}
                    onChange={e =>
                      updateConfig({
                        context_manager: {
                          ...config.context_manager!,
                          keep_turns: Number(e.target.value),
                        },
                      })
                    }
                  />
                </div>

                <div className="form-group">
                  <label className="form-label">Proxy Listen Port</label>
                  <input
                    type="number"
                    className="form-input font-mono"
                    value={config?.context_manager?.proxy_port ?? 8090}
                    onChange={e =>
                      updateConfig({
                        context_manager: {
                          ...config.context_manager!,
                          proxy_port: Number(e.target.value),
                        },
                      })
                    }
                  />
                </div>

                <div className="form-group">
                  <label className="form-label">
                    HuggingFace Tokenizer Override
                    <InfoTooltip
                      title="Tokenizer Repo Override"
                      description="Optional HuggingFace repository ID (e.g. google/gemma-2-2b-it) to override auto-detected tokenizer."
                    />
                  </label>
                  <input
                    type="text"
                    placeholder="Auto-detected from model alias"
                    className="form-input font-mono"
                    value={config?.context_manager?.tokenizer_repo ?? ''}
                    onChange={e =>
                      updateConfig({
                        context_manager: {
                          ...config.context_manager!,
                          tokenizer_repo: e.target.value,
                        },
                      })
                    }
                  />
                </div>
              </div>
            )}
          </div>
        ) : (
          <div className="glass-card card-padding">
            <div
              style={{
                display: 'flex',
                justifyContent: 'space-between',
                alignItems: 'center',
                marginBottom: '12px',
              }}
            >
              <h2 style={{ marginBottom: 0 }}>Raw Configuration JSON</h2>
              <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                {isValid ? (
                  <span className="badge badge-success">
                    <Check size={12} /> Valid JSON Schema
                  </span>
                ) : (
                  <span className="badge badge-danger">
                    <X size={12} /> {errors.length} Error(s)
                  </span>
                )}
              </div>
            </div>

            {errors.length > 0 && (
              <div
                className="impact-banner severity-danger"
                style={{ marginBottom: '12px', maxHeight: '150px', overflow: 'auto' }}
              >
                <AlertTriangle size={16} /> JSON Schema Validation Errors:
                <ul style={{ margin: '8px 0 0 0', paddingLeft: '20px', fontSize: '0.85rem' }}>
                  {errors.slice(0, 10).map((err, idx) => (
                    <li key={idx} style={{ marginBottom: '4px', color: 'var(--text-secondary)' }}>
                      Line {err.line}, Col {err.column}: {err.message}
                      {err.instancePath && (
                        <code style={{ marginLeft: '8px', fontSize: '0.8em' }}>
                          {err.instancePath}
                        </code>
                      )}
                    </li>
                  ))}
                  {errors.length > 10 && (
                    <li style={{ color: 'var(--text-muted)' }}>
                      ... and {errors.length - 10} more
                    </li>
                  )}
                </ul>
              </div>
            )}

            <div style={{ position: 'relative' }}>
              <textarea
                ref={textareaRef}
                className="form-input font-mono"
                rows={22}
                style={{ width: '100%', resize: 'vertical' }}
                value={jsonText}
                onChange={e => {
                  setJsonText(e.target.value);
                }}
                aria-invalid={!isValid}
                aria-describedby={errors.length > 0 ? 'json-errors' : undefined}
              />
              {/* Error line markers */}
              {errors.length > 0 && (
                <div
                  id="json-errors"
                  style={{
                    position: 'absolute',
                    left: '0',
                    top: '0',
                    bottom: '0',
                    width: '4px',
                    pointerEvents: 'none',
                    zIndex: 10,
                  }}
                >
                  {errors.map(err => (
                    <div
                      key={`${err.line}-${err.column}`}
                      style={{
                        position: 'absolute',
                        top: `calc(${err.line} * 1.5rem - 1.5rem)`,
                        left: 0,
                        width: '4px',
                        height: '1.5rem',
                        background: 'var(--status-error)',
                        borderRadius: '0 2px 2px 0',
                      }}
                    />
                  ))}
                </div>
              )}
            </div>
          </div>
        )}
      </div>
    </PageShell>
  );
};
