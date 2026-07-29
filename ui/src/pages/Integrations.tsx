import React, { useState } from 'react';
import { PageShell } from '../components/layout/PageShell';
import { Code, Terminal, Sparkles, Globe, Copy, Check } from 'lucide-react';
import { Command } from '@tauri-apps/plugin-shell';
import { useServerStore } from '../store/serverStore';
import './Integrations.css';

export const IntegrationsPage: React.FC = () => {
  const { port } = useServerStore();
  const baseUrl = `http://127.0.0.1:${port}`;
  const [copiedSection, setCopiedSection] = useState<string | null>(null);

  const handleCopy = (text: string, section: string) => {
    navigator.clipboard.writeText(text);
    setCopiedSection(section);
    setTimeout(() => setCopiedSection(null), 2000);
  };

  const handleLaunchClaudeCode = async () => {
    try {
      const cmd = Command.create('cmd', ['/c', 'start', 'cmd', '/k', `set ANTHROPIC_BASE_URL=${baseUrl}&& set ANTHROPIC_AUTH_TOKEN=local&& claude`]);
      await cmd.spawn();
    } catch (e) {
      console.error(e);
    }
  };

  return (
    <PageShell title="Integrations & Client Setup">
      <div className="integrations-grid">
        {/* VSCode Card */}
        <div className="glass-card card-padding">
          <div className="integration-card-header">
            <div className="flex-items-center gap-10">
              <Code className="card-icon" size={24} />
              <div>
                <h3>VS Code Workspace</h3>
                <p className="card-sub">Tasks & integrated terminal environment</p>
              </div>
            </div>
            <span className="badge badge-success">Active</span>
          </div>
          <div className="card-code-block font-mono">
            <div>"OPENAI_BASE_URL": "{baseUrl}/v1"</div>
            <div>"ANTHROPIC_BASE_URL": "{baseUrl}"</div>
          </div>
          <div className="card-footer-actions">
            <button
              className="btn btn-outline"
              onClick={() => handleCopy(`"OPENAI_BASE_URL": "${baseUrl}/v1"\n"ANTHROPIC_BASE_URL": "${baseUrl}"`, 'vscode')}
            >
              {copiedSection === 'vscode' ? <Check size={16} /> : <Copy size={16} />} Copy Settings JSON
            </button>
          </div>
        </div>

        {/* Claude Code Card */}
        <div className="glass-card card-padding">
          <div className="integration-card-header">
            <div className="flex-items-center gap-10">
              <Terminal className="card-icon" size={24} />
              <div>
                <h3>Claude Code CLI</h3>
                <p className="card-sub">Local model proxy & telemetry control</p>
              </div>
            </div>
            <span className="badge badge-success">Active</span>
          </div>
          <div className="card-code-block font-mono">
            <div>set ANTHROPIC_BASE_URL={baseUrl}</div>
            <div>set ANTHROPIC_AUTH_TOKEN=local</div>
          </div>
          <div className="card-footer-actions">
            <button className="btn btn-primary" onClick={handleLaunchClaudeCode}>
              <Sparkles size={16} /> Launch Claude Code Terminal
            </button>
          </div>
        </div>

        {/* Cursor Card */}
        <div className="glass-card card-padding">
          <div className="integration-card-header">
            <div className="flex-items-center gap-10">
              <Sparkles className="card-icon" size={24} />
              <div>
                <h3>Cursor & Continue</h3>
                <p className="card-sub">OpenAI compatible API endpoint</p>
              </div>
            </div>
            <span className="badge badge-warning">Configured</span>
          </div>
          <div className="card-code-block font-mono">
            <div>Base URL: {baseUrl}/v1</div>
            <div>API Key: local-key</div>
          </div>
          <div className="card-footer-actions">
            <button
              className="btn btn-outline"
              onClick={() => handleCopy(`Base URL: ${baseUrl}/v1\nAPI Key: local-key`, 'cursor')}
            >
              {copiedSection === 'cursor' ? <Check size={16} /> : <Copy size={16} />} Copy Config Block
            </button>
          </div>
        </div>

        {/* REST API Card */}
        <div className="glass-card card-padding">
          <div className="integration-card-header">
            <div className="flex-items-center gap-10">
              <Globe className="card-icon" size={24} />
              <div>
                <h3>Direct REST API</h3>
                <p className="card-sub">Native llama.cpp & OpenAI endpoints</p>
              </div>
            </div>
            <span className="badge badge-info">Ready</span>
          </div>
          <div className="card-code-block font-mono">
            <div>GET  {baseUrl}/health</div>
            <div>POST {baseUrl}/v1/chat/completions</div>
          </div>
          <div className="card-footer-actions">
            <button
              className="btn btn-outline"
              onClick={() => handleCopy(`${baseUrl}/v1/chat/completions`, 'rest')}
            >
              {copiedSection === 'rest' ? <Check size={16} /> : <Copy size={16} />} Copy Endpoint URL
            </button>
          </div>
        </div>
      </div>
    </PageShell>
  );
};
