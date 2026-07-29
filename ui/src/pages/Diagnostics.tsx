import React, { useState } from 'react';
import { PageShell } from '../components/layout/PageShell';
import { Activity, CheckCircle, ShieldCheck } from 'lucide-react';
import { invoke } from '@tauri-apps/api/core';
import './Diagnostics.css';

interface HealthReport {
  timestamp: string;
  status: string;
  checksPassed: number;
  checksFailed: number;
  details: Record<string, string>;
}

export const DiagnosticsPage: React.FC = () => {
  const [loading, setLoading] = useState(false);
  const [report, setReport] = useState<HealthReport | null>(null);

  const handleRunHealthCheck = async () => {
    setLoading(true);
    try {
      await invoke('audit_scripts');
      const res = await invoke<HealthReport>('run_health_check');
      setReport(res);
    } catch (e) {
      console.error(e);
    } finally {
      setLoading(false);
    }
  };

  return (
    <PageShell title="Diagnostics & Health Audit">
      <div className="diag-container">
        <div className="diag-header glass-card card-padding">
          <div>
            <h2>System & Infrastructure Health Check</h2>
            <p className="card-sub">Audits PowerShell scripts, binary paths, system dependencies, and port availability</p>
          </div>
          <div className="diag-actions">
            <button className="btn btn-primary" onClick={handleRunHealthCheck} disabled={loading}>
              <Activity size={16} className={loading ? 'spin' : ''} /> {loading ? 'Auditing...' : 'Run Full Health Check'}
            </button>
          </div>
        </div>

        {report ? (
          <div className="glass-card card-padding">
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '16px' }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: '10px' }}>
                <ShieldCheck size={24} style={{ color: 'var(--accent)' }} />
                <h3>Health Audit Results ({report.timestamp})</h3>
              </div>
              <span className={`badge ${report.checksFailed === 0 ? 'badge-success' : 'badge-warning'}`}>
                {report.checksPassed} Passed • {report.checksFailed} Warnings
              </span>
            </div>

            <div className="diag-report-list">
              {Object.entries(report.details).map(([key, val], i) => (
                <div key={i} className="info-row" style={{ padding: '10px 14px', background: 'var(--bg-elevated)', borderRadius: '6px' }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                    <CheckCircle size={16} style={{ color: 'var(--accent)' }} />
                    <span className="font-semibold" style={{ textTransform: 'capitalize' }}>{key.replace('_', ' ')}</span>
                  </div>
                  <span className="font-mono">{val}</span>
                </div>
              ))}
            </div>
          </div>
        ) : (
          <div className="glass-card card-padding" style={{ textAlign: 'center', color: 'var(--text-muted)', padding: '32px' }}>
            Click "Run Full Health Check" above to audit system environment, binary paths, and script integrity.
          </div>
        )}
      </div>
    </PageShell>
  );
};
