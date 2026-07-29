import React from 'react';
import { invoke } from '@tauri-apps/api/core';
import { getCurrentWindow } from '@tauri-apps/api/window';
import { Play, Square, Activity, Minus } from 'lucide-react';
import { useServerStore } from '../../store/serverStore';
import './TopBar.css';

interface TopBarProps {
  title: string;
}

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
      await invoke('run_health_check');
    } catch (e) {
      console.error(e);
    }
  };

  const handleMinimizeToTray = async () => {
    await getCurrentWindow().hide();
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
        <button
          className="btn btn-outline"
          onClick={handleMinimizeToTray}
          title="Minimize to system tray"
        >
          <Minus size={16} /> Hide to Tray
        </button>
      </div>
    </header>
  );
};
