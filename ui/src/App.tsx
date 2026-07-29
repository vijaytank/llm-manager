import React, { useState, useEffect } from 'react';
import { listen } from '@tauri-apps/api/event';
import { Sidebar, PageId } from './components/layout/Sidebar';
import { OverviewPage } from './pages/Overview';
import { SetupPage } from './pages/Setup';
import { ModelsPage } from './pages/Models';
import { PerformancePage } from './pages/Performance';
import { IntegrationsPage } from './pages/Integrations';
import { DiagnosticsPage } from './pages/Diagnostics';
import { LogsPage } from './pages/Logs';
import { SettingsPage } from './pages/Settings';
import { useConfigStore } from './store/configStore';
import { useHardwareStore } from './store/hardwareStore';
import { useServerStore } from './store/serverStore';
import { useValidationStore } from './store/validationStore';
import './styles/index.css';

export const App: React.FC = () => {
  const [activePage, setActivePage] = useState<PageId>('overview');
  const [collapsed, setCollapsed] = useState(false);
  const { config, fetchConfig } = useConfigStore();
  const { profile, fetchHardware } = useHardwareStore();
  const { setStatus, addLog } = useServerStore();
  const { validate } = useValidationStore();

  useEffect(() => {
    fetchConfig();
    fetchHardware();

    const unlistenStatus = listen<string>('server-status-changed', (event) => {
      setStatus(event.payload as any);
    });

    const unlistenLogs = listen<any>('server-log', (event) => {
      addLog(event.payload);
    });

    const unlistenNav = listen<string>('navigate-to', (event) => {
      setActivePage(event.payload as PageId);
    });

    return () => {
      unlistenStatus.then((fn) => fn());
      unlistenLogs.then((fn) => fn());
      unlistenNav.then((fn) => fn());
    };
  }, [fetchConfig, fetchHardware, setStatus, addLog]);

  // Real-time config & hardware safety validation
  useEffect(() => {
    if (config && profile) {
      validate(config, profile);
    }
  }, [config, profile, validate]);

  // Smart Routing: First time installation -> Setup Step 1. Returning user -> Overview Dashboard
  useEffect(() => {
    if (config) {
      const isFirstTime = config.installation_type === 'none' || !config.llama_server_path;
      if (isFirstTime) {
        setActivePage('setup');
      }
    }
  }, [config]);

  const renderPage = () => {
    switch (activePage) {
      case 'overview':
        return <OverviewPage />;
      case 'setup':
        return <SetupPage onComplete={() => setActivePage('overview')} />;
      case 'models':
        return <ModelsPage />;
      case 'performance':
        return <PerformancePage />;
      case 'integrations':
        return <IntegrationsPage />;
      case 'diagnostics':
        return <DiagnosticsPage />;
      case 'logs':
        return <LogsPage />;
      case 'settings':
        return <SettingsPage />;
      default:
        return <OverviewPage />;
    }
  };

  return (
    <div style={{ display: 'flex', width: '100vw', height: '100vh', overflow: 'hidden' }}>
      <Sidebar
        activePage={activePage}
        onSelectPage={setActivePage}
        collapsed={collapsed}
        onToggleCollapse={() => setCollapsed(!collapsed)}
      />
      {renderPage()}
    </div>
  );
};

export default App;
