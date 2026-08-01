import React, { useState } from 'react';
import { PageShell } from '../components/layout/PageShell';
import { Save, FolderOpen, Code, Sliders, Check, AlertTriangle } from 'lucide-react';
import { open } from '@tauri-apps/plugin-dialog';
import { useConfigStore, AppConfig } from '../store/configStore';
import { InfoTooltip } from '../components/InfoTooltip';
import './Settings.css';

export const SettingsPage: React.FC = () => {
  const { config, updateConfig, saveConfig } = useConfigStore();
  const [activeTab, setActiveTab] = useState<'visual' | 'json'>('visual');
  const [jsonText, setJsonText] = useState(JSON.stringify(config, null, 2));
  const [jsonError, setJsonError] = useState<string | null>(null);
  const [saveSuccess, setSaveSuccess] = useState(false);

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
      setJsonError(null);
      updateConfig(parsed);
      await saveConfig();
      setSaveSuccess(true);
      setTimeout(() => setSaveSuccess(false), 2000);
    } catch (e: any) {
      setJsonError(e.toString());
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
            {saveSuccess && <span className="badge badge-success"><Check size={14} /> Saved</span>}
            <button className="btn btn-primary" onClick={activeTab === 'visual' ? handleSaveVisual : handleSaveJson}>
              <Save size={16} /> Save Changes
            </button>
          </div>
        </div>

        {activeTab === 'visual' ? (
          <div className="glass-card card-padding" style={{ display: 'flex', flexDirection: 'column', gap: '16px' }}>
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
                  onChange={(e) => updateConfig({ llama_server_path: e.target.value })}
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
                  onChange={(e) => updateConfig({ models_dir: e.target.value })}
                />
                <button className="btn btn-outline" onClick={handleBrowseModelsDir}>
                  <FolderOpen size={16} /> Browse Folder...
                </button>
              </div>
            </div>

            <div className="form-group">
              <label className="form-label">Context Window Limit</label>
              <input
                type="number"
                className="form-input font-mono"
                value={config?.default_context_size || 32768}
                onChange={(e) => updateConfig({ default_context_size: Number(e.target.value) })}
              />
            </div>
          </div>
        ) : (
          <div className="glass-card card-padding">
            <h2 style={{ marginBottom: '12px' }}>Raw Configuration JSON</h2>
            {jsonError && (
              <div className="impact-banner severity-danger" style={{ marginBottom: '12px' }}>
                <AlertTriangle size={16} /> Invalid JSON Syntax: {jsonError}
              </div>
            )}
            <textarea
              className="form-input font-mono"
              rows={22}
              style={{ width: '100%', resize: 'vertical' }}
              value={jsonText}
              onChange={(e) => {
                setJsonText(e.target.value);
                try {
                  JSON.parse(e.target.value);
                  setJsonError(null);
                } catch (err: any) {
                  setJsonError(err.toString());
                }
              }}
            />
          </div>
        )}
      </div>
    </PageShell>
  );
};
