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
import { useModelsStore } from './store/modelsStore';
import './styles/index.css';

export const App: React.FC = () => {
  const [activePage, setActivePage] = useState<PageId>('overview');
  const [collapsed, setCollapsed] = useState(false);
  const { config, fetchConfig } = useConfigStore();
  const { profile, fetchHardware } = useHardwareStore();
  const { setStatus, addLog } = useServerStore();
  const { validate } = useValidationStore();
  const { models } = useModelsStore();

  const activeModel = models.find((m) => m.name === config?.active_model);

  useEffect(() => {
    fetchConfig();
    fetchHardware();

    let cleanupFns: Array<() => void> = [];
    Promise.all([
      listen<string>('server-status-changed', (event) => {
        setStatus(event.payload as any);
      }),
      listen<any>('server-log', (event) => {
        addLog(event.payload);
      }),
      listen<string>('navigate-to', (event) => {
        setActivePage(event.payload as PageId);
      }),
    ]).then((unlistens) => {
      cleanupFns = unlistens;
    }).catch((err) => console.warn('Failed to register IPC event listeners:', err));

    return () => {
      cleanupFns.forEach((fn) => fn());
    };
  }, [fetchConfig, fetchHardware, setStatus, addLog]);

  // Real-time config & hardware safety validation
  useEffect(() => {
    if (config && profile) {
      validate(config, profile, activeModel?.fileSizeGb);
    }
  }, [config, profile, validate, activeModel?.fileSizeGb]);

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
