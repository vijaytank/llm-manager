import React from 'react';
import { TopBar } from './TopBar';
import './PageShell.css';

interface PageShellProps {
  title: string;
  children: React.ReactNode;
}

export const PageShell: React.FC<PageShellProps> = ({ title, children }) => {
  return (
    <div className="page-shell">
      <TopBar title={title} />
      <main className="page-content">{children}</main>
    </div>
  );
};
