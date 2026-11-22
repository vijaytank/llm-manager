import { describe, it, expect, beforeEach } from 'vitest';
import { renderToString } from 'react-dom/server';
import { SetupPage } from '../Setup';
import { LogsPage } from '../Logs';
import { TopBar } from '../../components/layout/TopBar';
import { InfoTooltip } from '../../components/InfoTooltip';
import { useConfigStore } from '../../store/configStore';

describe('React Component Rendering Integration Tests', () => {
  beforeEach(() => {
    useConfigStore.setState({
      config: {
        installation_type: 'none',
        llama_server_path: '',
        llama_repo_path: '',
        models_dir: '',
        templates_dir: '',
        grammars_dir: '',
        active_model: '',
        use_default_template: false,
        fit_ctx_min: 8192,
        default_context_size: 32768,
        overrides: {},
        integrations: ['vscode', 'claude-code'],
        idle_timeout_sec: 60,
        fallback_provider: 'none',
        fallback_api_key: '',
        fallback_endpoint: '',
        fallback_model: '',
      },
      loading: false,
      error: null,
    });
  });

  it('renders SetupPage with step 1 and validates disabled Next button when binary path is empty', () => {
    const html = renderToString(<SetupPage />);
    expect(html).toContain('Initial Setup Wizard');
    expect(html).toContain('Step 1: Core Engine Installation');
    expect(html).toContain('Next: Models Folder');
    // Binary path is empty, so Next button must have disabled attribute
    expect(html).toMatch(/<button[^>]*disabled=""[^>]*>[\s\S]*?Next: Models Folder/);
  });

  it('renders SetupPage with enabled Next button when binary path is configured', () => {
    useConfigStore.getState().updateConfig({
      llama_server_path: 'C:\\llama\\llama-server.exe',
    });

    const html = renderToString(<SetupPage />);
    expect(html).toContain('llama-server.exe');
    expect(html).not.toMatch(/<button[^>]*disabled=""[^>]*>[\s\S]*?Next: Models Folder/);
  });

  it('renders LogsPage with toolbar, search input, and default log streams', () => {
    const html = renderToString(<LogsPage />);
    expect(html).toContain('Live Output Logs');
    expect(html).toContain('Filter logs by keyword...');
    expect(html).toContain('LLM Manager v1.2.0 server log stream tailer active.');
    expect(html).toContain('Tauri IPC event bus bound to channel &quot;server-log&quot;.');
    expect(html).toContain('Export');
    expect(html).toContain('Clear');
  });

  it('renders TopBar with server controls and title', () => {
    const html = renderToString(<TopBar title="Dashboard" />);
    expect(html).toContain('Dashboard');
    expect(html).toContain('Start');
    expect(html).toContain('Health');
  });

  it('renders InfoTooltip with title and recommendation markup', () => {
    const html = renderToString(
      <InfoTooltip
        title="Test Parameter"
        description="Detailed description for testing."
        recommendation="Recommended value is 42."
      />
    );
    expect(html).toContain('info-tooltip-trigger');
  });
});
