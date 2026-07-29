import React, { useState } from 'react';
import { PageShell } from '../components/layout/PageShell';
import { Search, Trash2, Download } from 'lucide-react';
import { save } from '@tauri-apps/plugin-dialog';
import { useServerStore } from '../store/serverStore';
import './Logs.css';

export const LogsPage: React.FC = () => {
  const { logs, clearLogs } = useServerStore();
  const [searchQuery, setSearchQuery] = useState('');
  const [levelFilter, setLevelFilter] = useState<'ALL' | 'INFO' | 'WARN' | 'ERROR'>('ALL');

  const filteredLogs = logs.filter((log) => {
    const matchesLevel = levelFilter === 'ALL' || log.level === levelFilter;
    const matchesSearch =
      searchQuery === '' || log.message.toLowerCase().includes(searchQuery.toLowerCase());
    return matchesLevel && matchesSearch;
  });

  const handleExportLogs = async () => {
    try {
      const selected = await save({
        filters: [{ name: 'Text Files', extensions: ['txt', 'log'] }],
        defaultPath: 'llm-manager-server.log',
      });
      if (selected) {
        const text = logs.map((l) => `[${l.timestamp}] [${l.level}] ${l.message}`).join('\n');
        // Save via Blob URL or electron download; for now copy to clipboard if file save is simple
        const blob = new Blob([text], { type: 'text/plain' });
        const a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = 'llm-manager-server.log';
        a.click();
      }
    } catch (e) {
      console.error(e);
    }
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

            <button className="btn btn-outline" onClick={handleExportLogs}>
              <Download size={16} /> Export Logs
            </button>

            <button className="btn btn-outline btn-danger" onClick={clearLogs}>
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
