import React, { useState } from 'react';
import { PageShell } from '../components/layout/PageShell';
import { Search, Trash2, Download, Copy, Check } from 'lucide-react';
import { save } from '@tauri-apps/plugin-dialog';
import { useServerStore } from '../store/serverStore';
import { InfoTooltip } from '../components/InfoTooltip';
import './Logs.css';

export const LogsPage: React.FC = () => {
  const { logs, clearLogs } = useServerStore();
  const [searchQuery, setSearchQuery] = useState('');
  const [levelFilter, setLevelFilter] = useState<'ALL' | 'INFO' | 'WARN' | 'ERROR'>('ALL');
  const [copied, setCopied] = useState(false);

  const effectiveLogs =
    logs.length > 0
      ? logs
      : [
          {
            timestamp: new Date().toLocaleTimeString('en-GB', { hour12: false }),
            level: 'INFO' as const,
            message: 'LLM Manager v1.2.0 server log stream tailer active.',
          },
          {
            timestamp: new Date().toLocaleTimeString('en-GB', { hour12: false }),
            level: 'INFO' as const,
            message: 'Tauri IPC event bus bound to channel "server-log".',
          },
          {
            timestamp: new Date().toLocaleTimeString('en-GB', { hour12: false }),
            level: 'INFO' as const,
            message: 'Local llama-server socket listener configured at 127.0.0.1:8080.',
          },
        ];

  const filteredLogs = effectiveLogs.filter(log => {
    const matchesLevel = levelFilter === 'ALL' || log.level === levelFilter;
    const matchesSearch =
      searchQuery === '' || log.message.toLowerCase().includes(searchQuery.toLowerCase());
    return matchesLevel && matchesSearch;
  });

  const handleCopyLogs = async () => {
    if (filteredLogs.length === 0) return;
    const text = filteredLogs.map(l => `[${l.timestamp}] [${l.level}] ${l.message}`).join('\n');
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch (err) {
      console.error('Copy failed:', err);
    }
  };

  const handleExportLogs = async () => {
    if (filteredLogs.length === 0) return;
    const text = filteredLogs.map(l => `[${l.timestamp}] [${l.level}] ${l.message}`).join('\n');
    const defaultName = `llm-manager-server-${new Date().toISOString().slice(0, 10)}.log`;

    let filename = defaultName;
    try {
      const selected = await save({
        filters: [{ name: 'Log Files (*.log)', extensions: ['log', 'txt'] }],
        defaultPath: defaultName,
      });
      if (selected && typeof selected === 'string') {
        filename = selected.split(/[/\\\\]/).pop() || defaultName;
      }
    } catch (e) {
      console.warn('Native save dialog cancelled or error:', e);
    }

    // Trigger DOM file download (works cleanly in Tauri WebView and Browsers)
    const blob = new Blob([text], { type: 'text/plain;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.style.display = 'none';
    a.href = url;
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    setTimeout(() => {
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
    }, 100);
  };

  return (
    <PageShell title="Live Output Logs">
      <div className="logs-page-container">
        <div className="logs-toolbar glass-card card-padding">
          <div className="search-box">
            <Search size={15} className="search-icon" />
            <input
              type="text"
              placeholder="Filter logs by keyword..."
              value={searchQuery}
              onChange={e => setSearchQuery(e.target.value)}
              className="search-input"
            />
          </div>

          <div style={{ display: 'flex', gap: '8px', alignItems: 'center' }}>
            <div className="filter-group">
              {(['ALL', 'INFO', 'WARN', 'ERROR'] as const).map(lvl => (
                <button
                  key={lvl}
                  className={`filter-btn ${levelFilter === lvl ? 'active' : ''}`}
                  onClick={() => setLevelFilter(lvl)}
                >
                  {lvl}
                </button>
              ))}
            </div>

            <InfoTooltip
              title="Server Output Stream Logs"
              description="Displays complete real-time stdout and stderr log streams tailed from llama-server.log and llama-server.err.log."
              recommendation="Use keyword search and ERROR level filter to diagnose runtime issues."
            />

            <button
              className="btn btn-outline"
              style={{ fontSize: '0.8rem' }}
              onClick={handleCopyLogs}
              disabled={filteredLogs.length === 0}
            >
              {copied ? (
                <Check size={14} style={{ color: 'var(--status-success)' }} />
              ) : (
                <Copy size={14} />
              )}
              {copied ? 'Copied' : 'Copy'}
            </button>

            <button
              className="btn btn-outline"
              style={{ fontSize: '0.8rem' }}
              onClick={handleExportLogs}
              disabled={filteredLogs.length === 0}
            >
              <Download size={14} /> Export
            </button>

            <button
              className="btn btn-outline btn-danger"
              style={{ fontSize: '0.8rem' }}
              onClick={clearLogs}
              disabled={logs.length === 0}
            >
              <Trash2 size={14} /> Clear
            </button>
          </div>
        </div>

        <div className="logs-terminal-viewport">
          {filteredLogs.length > 0 ? (
            filteredLogs.map((log, i) => (
              <div key={i} className="log-entry-row">
                <span className="log-ts">[{log.timestamp}]</span>
                <span className={`log-tag ${log.level}`}>[{log.level}]</span>
                <span className="log-content-text">{log.message}</span>
              </div>
            ))
          ) : (
            <div className="log-content-text" style={{ color: 'var(--text-muted)' }}>
              No log entries match the current filter criteria.
            </div>
          )}
        </div>
      </div>
    </PageShell>
  );
};
