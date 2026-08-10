import { create } from 'zustand';
import { invoke } from '@tauri-apps/api/core';

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
  cache_type_k: string;
  cache_type_v: string;
  flash_attn: string;
  context_shift: boolean;
  default_context_size: number;
  fit_ctx_min: number;
  ubatch_size: number;
  parallel_slots: number;

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

interface ConfigState {
  config: AppConfig | null;
  loading: boolean;
  error: string | null;
  fetchConfig: () => Promise<void>;
  updateConfig: (partial: Partial<AppConfig>) => void;
  saveConfig: () => Promise<void>;
}

export const useConfigStore = create<ConfigState>((set, get) => ({
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

  updateConfig: (partial) => {
    const current = get().config || ({} as AppConfig);
    set({ config: { ...current, ...partial } });
  },

  saveConfig: async () => {
    const current = get().config;
    if (!current) return;
    set({ loading: true, error: null });
    try {
      await invoke('save_config', { config: current });
      set({ loading: false });
    } catch (err: any) {
      set({ error: err.toString(), loading: false });
    }
  },
}));
