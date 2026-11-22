import { create } from 'zustand';
import { invoke } from '@tauri-apps/api/core';
import { useServerStore } from './serverStore';

export interface ContextManagerSettings {
  enabled: boolean;
  warn_threshold: number;
  keep_turns: number;
  proxy_port: number;
  ctx_limit: number;
  tokenizer_repo: string;
  summary_max_tokens: number;
  summarize_with_model: string;
}

export interface AppConfig {
  installation_type: string;
  llama_server_path: string;
  llama_repo_path: string;
  models_dir: string;
  templates_dir: string;
  grammars_dir: string;
  active_model: string;
  use_default_template: boolean;
  fit_ctx_min: number;
  // Legacy / optional flat keys (moved to overrides)
  cache_type_k?: string;
  cache_type_v?: string;
  flash_attn?: string;
  context_shift?: boolean;
  default_context_size?: number;
  ubatch_size?: number;
  parallel_slots?: number;

  // Context Manager Proxy
  context_manager?: ContextManagerSettings;

  // SYSTEM_COMMANDS.md Advanced Parameters
  threads?: number;
  prio?: number;
  mlock?: boolean;
  spec_type?: string;
  spec_ngram_simple_size_n?: number;
  cache_prompt?: boolean;
  cache_reuse?: number;
  cache_ram?: number;
  sleep_idle_seconds?: number;
  reasoning?: string;
  reasoning_format?: string;
  reasoning_budget?: number;

  overrides: Record<string, any>;
  integrations: string[];
  idle_timeout_sec: number;
  fallback_provider: string;
  fallback_api_key: string;
  fallback_endpoint: string;
  fallback_model: string;
  mmproj_path?: string;
  mmproj_no_offload?: boolean;
  active_template?: string;
}

export type DeepPartial<T> = {
  [P in keyof T]?: NonNullable<T[P]> extends any[]
    ? NonNullable<T[P]>
    : NonNullable<T[P]> extends object
      ? DeepPartial<NonNullable<T[P]>>
      : T[P];
};

interface ConfigState {
  config: AppConfig | null;
  loading: boolean;
  error: string | null;
  fetchConfig: () => Promise<void>;
  updateConfig: (partial: DeepPartial<AppConfig>) => void;
  saveConfig: () => Promise<void>;
}

function isObject(item: any): item is Record<string, any> {
  return item !== null && typeof item === 'object' && !Array.isArray(item);
}

export function deepMergeConfig<T extends Record<string, any>>(
  target: T,
  source: DeepPartial<T> | Partial<T>
): T {
  const output: any = { ...target };
  for (const key of Object.keys(source)) {
    const sourceVal = (source as any)[key];
    const targetVal = (target as any)[key];
    if (isObject(sourceVal) && isObject(targetVal)) {
      output[key] = deepMergeConfig(targetVal, sourceVal);
    } else if (sourceVal !== undefined) {
      output[key] = sourceVal;
    }
  }
  return output as T;
}

export const useConfigStore = create<ConfigState>((set, get, api) => {
  if (api) {
    api.getInitialState = () => api.getState();
  }
  return {
    config: null,
    loading: false,
    error: null,

    fetchConfig: async () => {
      set({ loading: true, error: null });
      try {
        const config = await invoke<AppConfig>('load_config');
        set({ config, loading: false });
      } catch (err: any) {
        set({ error: err.toString(), loading: false });
      }
    },

    updateConfig: partial => {
      const current = get().config || ({} as AppConfig);
      set({ config: deepMergeConfig(current, partial) });
    },

    saveConfig: async () => {
      const current = get().config;
      if (!current) return;
      set({ loading: true, error: null });
      try {
        await invoke('save_config', { config: current });
        set({ loading: false });
        if (useServerStore.getState().status === 'running') {
          useServerStore.getState().setPendingRestart(true);
        }
      } catch (err: any) {
        set({ error: err.toString(), loading: false });
      }
    },
  };
});
