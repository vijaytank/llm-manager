import React from 'react';
import {
  LayoutDashboard,
  Wand2,
  Boxes,
  Cpu,
  Plug,
  Activity,
  Terminal,
  Settings,
  ChevronLeft,
  ChevronRight,
  Sparkles
} from 'lucide-react';
import './Sidebar.css';

export type PageId =
  | 'overview'
  | 'setup'
  | 'models'
  | 'performance'
  | 'integrations'
  | 'diagnostics'
  | 'logs'
  | 'settings';

interface SidebarProps {
  activePage: PageId;
  onSelectPage: (page: PageId) => void;
  collapsed: boolean;
  onToggleCollapse: () => void;
}

const NAV_ITEMS: { id: PageId; label: string; icon: React.ComponentType<any> }[] = [
  { id: 'overview', label: 'Overview', icon: LayoutDashboard },
  { id: 'setup', label: 'Setup', icon: Wand2 },
  { id: 'models', label: 'Models', icon: Boxes },
  { id: 'performance', label: 'Performance', icon: Cpu },
  { id: 'integrations', label: 'Integrations', icon: Plug },
  { id: 'diagnostics', label: 'Diagnostics', icon: Activity },
  { id: 'logs', label: 'Logs', icon: Terminal },
  { id: 'settings', label: 'Settings', icon: Settings },
];

export const Sidebar: React.FC<SidebarProps> = ({
  activePage,
  onSelectPage,
  collapsed,
  onToggleCollapse,
}) => {
  return (
    <aside className={`sidebar ${collapsed ? 'collapsed' : ''}`}>
      <div className="sidebar-header">
        <div className="logo-container">
          <Sparkles className="logo-icon" />
          {!collapsed && <span className="logo-text">LLM Manager</span>}
        </div>
        <button className="collapse-btn" onClick={onToggleCollapse} title="Toggle Sidebar">
          {collapsed ? <ChevronRight size={18} /> : <ChevronLeft size={18} />}
        </button>
      </div>

      <nav className="sidebar-nav">
        {NAV_ITEMS.map((item) => {
          const Icon = item.icon;
          const isActive = activePage === item.id;
          return (
            <button
              key={item.id}
              className={`nav-item ${isActive ? 'active' : ''}`}
              onClick={() => onSelectPage(item.id)}
              title={collapsed ? item.label : undefined}
            >
              <Icon className="nav-icon" size={20} />
              {!collapsed && <span className="nav-label">{item.label}</span>}
            </button>
          );
        })}
      </nav>
    </aside>
  );
};
