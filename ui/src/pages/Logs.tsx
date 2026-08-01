import React, { useState } from 'react';
import { PageShell } from '../components/layout/PageShell';
import { Search, Trash2, Download, Copy, Check } from 'lucide-react';
import { save } from '@tauri-apps/plugin-dialog';
import { useServerStore } from '../store/serverStore';
import './Logs.css';

export const LogsPage: React.FC = () => {
  const { logs, clearLogs } = useServerStore();
  const [searchQuery, setSearchQuery] = useState('');
  const [levelFilter, setLevelFilter] = useState<'ALL' | 'INFO' | 'WARN' | 'ERROR'>('ALL');
  const [copied, setCopied] = useState(false);

  const filteredLogs = logs.filter((log) => {
    const matchesLevel = levelFilter === 'ALL' || log.level === levelFilter;
    const matchesSearch =
      searchQuery === '' || log.message.toLowerCase().includes(searchQuery.toLowerCase());
    return matchesLevel && matchesSearch;
  });

  const handleCopyLogs = async () => {
    if (filteredLogs.length === 0) return;
    const text = filteredLogs.map((l) => `[${l.timestamp}] [${l.level}] ${l.message}`).join('\n');
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
    const text = filteredLogs.map((l) => `[${l.timestamp}] [${l.level}] ${l.message}`).join('\n');
    const defaultName = `llm-manager-server-${new Date().toISOString().slice(0, 10)}.log`;

    let filename = defaultName;
    try {
      const selected = await save({
        filters: [{ name: 'Log Files (*.log)', extensions: ['log', 'txt'] }],
        defaultPath: defaultName,
      });
      if (selected && typeof selected === 'string') {
        filename = selected.split(/[/\\]/).pop() || defaultName;
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
            <Search size={16} className="search-icon" />
            <input
              type="text"
              placeholder="Search logs by keyword..."
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              className="form-input"
            />
          </div>

          <div style={{ display: 'flex', gap: '10px', alignItems: 'center' }}>
            <select
              className="form-input font-mono"
              value={levelFilter}
              onChange={(e) => setLevelFilter(e.target.value as any)}
            >
              <option value="ALL">All Levels</option>
              <option value="INFO">INFO Only</option>
              <option value="WARN">WARN Only</option>
              <option value="ERROR">ERROR Only</option>
            </select>

            <button className="btn btn-outline" onClick={handleCopyLogs} disabled={filteredLogs.length === 0}>
              {copied ? <Check size={16} style={{ color: 'var(--accent-green, #10b981)' }} /> : <Copy size={16} />}
              {copied ? 'Copied!' : 'Copy Logs'}
            </button>

            <button className="btn btn-outline" onClick={handleExportLogs} disabled={filteredLogs.length === 0}>
              <Download size={16} /> Export Logs
            </button>

            <button className="btn btn-outline btn-danger" onClick={clearLogs} disabled={logs.length === 0}>
              <Trash2 size={16} /> Clear Logs
            </button>
          </div>
        </div>

        <div className="glass-card log-terminal font-mono">
          {filteredLogs.length > 0 ? (
            filteredLogs.map((log, i) => (
              <div key={i} className="log-line">
                <span className="log-time">[{log.timestamp}]</span>
                <span className={`log-level level-${log.level.toLowerCase()}`}>[{log.level}]</span>
                <span className="log-msg">{log.message}</span>
              </div>
            ))
          ) : (
            <div className="log-line" style={{ color: 'var(--text-muted)' }}>
              No log entries matching filter.
            </div>
          )}
        </div>
      </div>
    </PageShell>
  );
};
