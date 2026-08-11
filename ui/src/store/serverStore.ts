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
  configSnapshot: string | null;
  setStatus: (status: ServerStatus) => void;
  setPort: (port: number) => void;
  addLog: (log: LogEntry) => void;
  clearLogs: () => void;
  setConfigSnapshot: (snapshot: string | null) => void;
}

export const useServerStore = create<ServerState>((set) => ({
  status: 'stopped',
  port: 8080,
  logs: [],
  configSnapshot: null,
  setStatus: (status) => set({ status }),
  setPort: (port) => set({ port }),
  addLog: (log) => set((state) => ({ logs: [...state.logs.slice(-499), log] })),
  clearLogs: () => set({ logs: [] }),
  setConfigSnapshot: (configSnapshot) => set({ configSnapshot }),
}));
