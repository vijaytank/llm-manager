import { create } from 'zustand';

export type ServerStatus = 'stopped' | 'starting' | 'running' | 'stopping';

export interface LogEntry {
  timestamp: string;
  level: 'INFO' | 'WARN' | 'ERROR';
  message: string;
}

interface ServerState {
  status: ServerStatus;
  port: number;
  logs: LogEntry[];
  setStatus: (status: ServerStatus) => void;
  setPort: (port: number) => void;
  addLog: (log: LogEntry) => void;
  clearLogs: () => void;
}

export const useServerStore = create<ServerState>((set) => ({
  status: 'stopped',
  port: 8080,
  logs: [
    { timestamp: '14:32:01', level: 'INFO', message: 'LLM Manager server state initialized' },
    { timestamp: '14:32:02', level: 'INFO', message: 'Ready to launch server process' }
  ],
  setStatus: (status) => set({ status }),
  setPort: (port) => set({ port }),
  addLog: (log) => set((state) => ({ logs: [...state.logs.slice(-4999), log] })),
  clearLogs: () => set({ logs: [] }),
}));
