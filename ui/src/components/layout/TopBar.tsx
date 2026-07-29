import React from 'react';
import { invoke } from '@tauri-apps/api/core';
import { Play, Square, Activity } from 'lucide-react';
import { useServerStore } from '../../store/serverStore';
import './TopBar.css';

interface TopBarProps {
  title: string;
}

interface HealthReportLike {
  passedCount?: number;
  totalCount?: number;
}

export const buildHealthLogEntry = (report?: HealthReportLike | null, error?: unknown) => {
  if (error) {
    const message = error instanceof Error
      ? error.message
      : typeof error === 'string'
        ? error
        : (error as { message?: string } | undefined)?.message ?? 'Unknown error';

    return {
      level: 'ERROR' as const,
      message: `Health check error: ${message}`,
    };
  }

  const passedCount = typeof report?.passedCount === 'number' ? report.passedCount : '?';
  const totalCount = typeof report?.totalCount === 'number' ? report.totalCount : '?';

  return {
    level: 'INFO' as const,
    message: `Health check completed: ${passedCount}/${totalCount} checks passed`,
  };
};

export const TopBar: React.FC<TopBarProps> = ({ title }) => {
  const { status, port } = useServerStore();

  const handleStart = async () => {
    try {
      await invoke('start_server', { port });
    } catch (e) {
      console.error(e);
    }
  };

  const handleStop = async () => {
    try {
      await invoke('stop_server');
    } catch (e) {
      console.error(e);
    }
  };

  const handleHealth = async () => {
    try {
      const report = await invoke<HealthReportLike>('run_health_check');
      const entry = buildHealthLogEntry(report);
      useServerStore.getState().addLog({
        timestamp: new Date().toLocaleTimeString('en-GB', { hour12: false }),
        level: entry.level,
        message: entry.message,
      });
    } catch (e) {
      const entry = buildHealthLogEntry(undefined, e);
      useServerStore.getState().addLog({
        timestamp: new Date().toLocaleTimeString('en-GB', { hour12: false }),
        level: entry.level,
        message: entry.message,
      });
    }
  };

  return (
    <header className="topbar">
      <div className="topbar-left">
        <h1 className="page-title">{title}</h1>
        <div className="status-indicator">
          {status === 'running' && <span className="badge badge-success">● Running</span>}
          {status === 'stopped' && <span className="badge badge-error">● Stopped</span>}
          {status === 'starting' && <span className="badge badge-warning">● Starting...</span>}
          <span className="port-label">:{port}</span>
        </div>
      </div>

      <div className="topbar-actions">
        {status === 'stopped' ? (
          <button className="btn btn-primary" onClick={handleStart}>
            <Play size={16} /> Start Server
          </button>
        ) : (
          <button className="btn btn-outline btn-danger" onClick={handleStop}>
            <Square size={16} /> Stop
          </button>
        )}
        <button className="btn btn-outline" onClick={handleHealth}>
          <Activity size={16} /> Run Health Check
        </button>
      </div>
    </header>
  );
};
