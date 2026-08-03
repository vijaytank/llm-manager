import React, { useState } from 'react';
import { PageShell } from '../components/layout/PageShell';
import { Code, Terminal, Sparkles, Globe, Copy, Check } from 'lucide-react';
import { invoke } from '@tauri-apps/api/core';
import { useConfigStore } from '../store/configStore';
import { useServerStore } from '../store/serverStore';
import { InfoTooltip } from '../components/InfoTooltip';
import './Integrations.css';

export const IntegrationsPage: React.FC = () => {
  const { port } = useServerStore();
  const { config } = useConfigStore();
  const baseUrl = `http://127.0.0.1:${port}`;
  const [copiedSection, setCopiedSection] = useState<string | null>(null);

  const handleCopy = (text: string, section: string) => {
    navigator.clipboard.writeText(text);
    setCopiedSection(section);
    setTimeout(() => setCopiedSection(null), 2000);
  };

  const handleLaunchClaudeCode = async () => {
    try {
      const model = config?.active_model?.trim() || 'local';
      await invoke('launch_claude_terminal', { port, model });
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
                <h3>
                  VS Code Workspace
                  <InfoTooltip
                    title="VS Code Integration"
                    description="Configures environment variables for Continue, GitHub Copilot alternatives, and local LLM extensions."
                    recommendation="Set OPENAI_BASE_URL to point to local LLM Manager."
                  />
                </h3>
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
                <h3>
                  Claude Code CLI
                  <InfoTooltip
                    title="Claude Code CLI Integration"
                    description="Launches an interactive Command Prompt terminal pre-configured with ANTHROPIC_BASE_URL pointing to local LLM Manager."
                    recommendation="Uses local GGUF models as Anthropic Claude drop-in replacements."
                    impact="Zero API costs; 100% offline agentic coding."
                  />
                </h3>
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
                <h3>
                  Cursor & Continue
                  <InfoTooltip
                    title="Cursor & Continue IDE Integration"
                    description="Connects Cursor IDE, Continue, or Aider to local OpenAI-compatible endpoint."
                    recommendation="Set model name to 'local-model' or matching GGUF alias."
                  />
                </h3>
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
                <h3>
                  Direct REST API
                  <InfoTooltip
                    title="Direct REST API Endpoints"
                    description="Native llama.cpp endpoints (/health, /v1/chat/completions, /slots) for custom scripts or curl commands."
                    recommendation="Supports streaming responses, vision payloads, and slot monitoring."
                  />
                </h3>
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
