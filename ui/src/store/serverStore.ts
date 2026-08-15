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
  pendingRestart: boolean;
  setStatus: (status: ServerStatus) => void;
  setPort: (port: number) => void;
  addLog: (log: LogEntry) => void;
  clearLogs: () => void;
  setConfigSnapshot: (snapshot: string | null) => void;
  setPendingRestart: (pending: boolean) => void;
}

export const useServerStore = create<ServerState>((set) => ({
  status: 'stopped',
  port: 8080,
  logs: [],
  configSnapshot: null,
  pendingRestart: false,
  setStatus: (status) => set((state) => ({
    status,
    pendingRestart: status === 'running' ? false : state.pendingRestart,
  })),
  setPort: (port) => set({ port }),
  addLog: (log) => set((state) => ({ logs: [...state.logs.slice(-499), log] })),
  clearLogs: () => set({ logs: [] }),
  setConfigSnapshot: (configSnapshot) => set({ configSnapshot }),
  setPendingRestart: (pendingRestart) => set({ pendingRestart }),
}));
