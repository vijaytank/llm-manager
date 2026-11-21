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
  Sparkles,
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

interface NavSection {
  title?: string;
  items: { id: PageId; label: string; icon: React.ComponentType<any>; badge?: string }[];
}

const NAV_SECTIONS: NavSection[] = [
  {
    title: 'WORKSPACE',
    items: [
      { id: 'overview', label: 'Overview', icon: LayoutDashboard },
      { id: 'models', label: 'Models', icon: Boxes },
      { id: 'performance', label: 'Performance', icon: Cpu },
    ],
  },
  {
    title: 'CONNECTIVITY',
    items: [
      { id: 'integrations', label: 'Integrations', icon: Plug },
      { id: 'logs', label: 'Logs', icon: Terminal },
    ],
  },
  {
    title: 'MAINTENANCE',
    items: [
      { id: 'diagnostics', label: 'Diagnostics', icon: Activity },
      { id: 'settings', label: 'Settings', icon: Settings },
      { id: 'setup', label: 'Setup Wizard', icon: Wand2 },
    ],
  },
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
          <div className="logo-icon-wrapper">
            <Sparkles className="logo-icon" size={18} />
          </div>
          {!collapsed && (
            <div className="logo-info">
              <span className="logo-text">LLM Manager</span>
              <span className="logo-tag">v1.2</span>
            </div>
          )}
        </div>
        <button className="collapse-btn" onClick={onToggleCollapse} title="Toggle Sidebar">
          {collapsed ? <ChevronRight size={16} /> : <ChevronLeft size={16} />}
        </button>
      </div>

      <nav className="sidebar-nav">
        {NAV_SECTIONS.map((section, sIdx) => (
          <div key={sIdx} className="nav-section">
            {!collapsed && section.title && (
              <div className="nav-section-title">{section.title}</div>
            )}
            {section.items.map(item => {
              const Icon = item.icon;
              const isActive = activePage === item.id;
              return (
                <button
                  key={item.id}
                  className={`nav-item ${isActive ? 'active' : ''}`}
                  onClick={() => onSelectPage(item.id)}
                  title={collapsed ? item.label : undefined}
                >
                  <Icon className="nav-icon" size={18} />
                  {!collapsed && <span className="nav-label">{item.label}</span>}
                  {!collapsed && item.badge && <span className="nav-badge">{item.badge}</span>}
                </button>
              );
            })}
          </div>
        ))}
      </nav>
    </aside>
  );
};
