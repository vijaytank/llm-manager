import { create } from 'zustand';
import { invoke } from '@tauri-apps/api/core';

export interface ModelInfo {
  name: string;
  filename: string;
  path: string;
  fileSizeGb: number;
  quantization: string;
  template: string;
  templateMatchMethod: string;
  calculatedContext: number;
  status: string;
  isMmproj: boolean;
}

interface ModelsState {
  models: ModelInfo[];
  loading: boolean;
  error: string | null;
  fetchModels: (modelsDir?: string) => Promise<void>;
}

export const useModelsStore = create<ModelsState>((set) => ({
  models: [],
  loading: false,
  error: null,

  fetchModels: async (modelsDir) => {
    set({ loading: true, error: null });
    try {
      const models = await invoke<ModelInfo[]>('scan_models', { modelsDirPath: modelsDir });
      set({ models, loading: false });
    } catch (err: any) {
      set({ error: err.toString(), loading: false });
    }
  },
}));
