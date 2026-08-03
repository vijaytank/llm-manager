import React, { useState, useEffect } from 'react';
import { invoke } from '@tauri-apps/api/core';
import { Play, Square, Activity, RefreshCw, ZoomIn, ZoomOut, Palette } from 'lucide-react';
import { useServerStore } from '../../store/serverStore';
import { useConfigStore } from '../../store/configStore';
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
  const { status, port, configSnapshot, setConfigSnapshot } = useServerStore();
  const { config } = useConfigStore();
  const [restarting, setRestarting] = useState(false);
  const [theme, setTheme] = useState<string>('dark');
  const [showThemeMenu, setShowThemeMenu] = useState(false);

  const [fontScale, setFontScale] = useState<number>(() => {
    const saved = localStorage.getItem('llm_manager_font_scale');
    return saved ? parseFloat(saved) : 1.0;
  });

  useEffect(() => {
    document.documentElement.style.setProperty('--font-scale', fontScale.toString());
    localStorage.setItem('llm_manager_font_scale', fontScale.toString());
  }, [fontScale]);

  useEffect(() => {
    if (status === 'running' && config && !configSnapshot) {
      setConfigSnapshot(JSON.stringify(config));
    } else if (status === 'stopped') {
      setConfigSnapshot(null);
    }
  }, [status, config, configSnapshot, setConfigSnapshot]);

  const isConfigDirty = status === 'running' && !!configSnapshot && !!config && JSON.stringify(config) !== configSnapshot;

  const handleStart = async () => {
    try {
      if (config) {
        setConfigSnapshot(JSON.stringify(config));
      }
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

  const handleRestart = async () => {
    setRestarting(true);
    try {
      await invoke('stop_server');
      setTimeout(async () => {
        if (config) {
          setConfigSnapshot(JSON.stringify(config));
        }
        await invoke('start_server', { port });
        setRestarting(false);
      }, 1200);
    } catch (e) {
      console.error(e);
      setRestarting(false);
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

  const handleFontChange = (delta: number) => {
    setFontScale((prev) => Math.min(1.25, Math.max(0.8, Math.round((prev + delta) * 100) / 100)));
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

        {isConfigDirty && (
          <div className="topbar-dirty-banner">
            <span className="dirty-text">⚠️ Settings changed!</span>
            <button className="btn btn-warning btn-sm" onClick={handleRestart} disabled={restarting}>
              <RefreshCw size={13} className={restarting ? 'spin' : ''} /> {restarting ? 'Restarting...' : 'Restart Server'}
            </button>
          </div>
        )}
      </div>

      <div className="topbar-actions">
        {/* Font scale controls */}
        <div className="font-scale-controls">
          <button
            className="btn-icon"
            title="Decrease font size"
            onClick={() => handleFontChange(-0.05)}
            disabled={fontScale <= 0.8}
          >
            <ZoomOut size={15} />
          </button>
          <span className="font-scale-label">{Math.round(fontScale * 100)}%</span>
          <button
            className="btn-icon"
            title="Increase font size"
            onClick={() => handleFontChange(0.05)}
            disabled={fontScale >= 1.25}
          >
            <ZoomIn size={15} />
          </button>
        </div>

        {/* Theme dropdown */}
        <div className="theme-selector-wrapper">
          <button
            className="btn-icon"
            title="Theme Selection"
            onClick={() => setShowThemeMenu(!showThemeMenu)}
          >
            <Palette size={16} />
          </button>
          {showThemeMenu && (
            <div className="theme-menu glass-card">
              <div className="theme-menu-title">Select Theme</div>
              <button
                className={`theme-option ${theme === 'dark' ? 'active' : ''}`}
                onClick={() => {
                  setTheme('dark');
                  document.documentElement.dataset.theme = 'dark';
                  setShowThemeMenu(false);
                }}
              >
                🌙 Dark (Default)
              </button>
            </div>
          )}
        </div>

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
