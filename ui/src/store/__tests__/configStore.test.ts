import { describe, it, expect, beforeEach } from 'vitest';
import { useConfigStore } from '../configStore';

describe('configStore', () => {
  beforeEach(() => {
    useConfigStore.setState({
      config: {
        installation_type: 'none',
        llama_server_path: '',
        llama_repo_path: '',
        models_dir: '',
        templates_dir: '',
        grammars_dir: '',
        active_model: '',
        use_default_template: false,
        cache_type_k: 'f16',
        cache_type_v: 'f16',
        flash_attn: 'auto',
        context_shift: true,
        default_context_size: 32768,
        fit_ctx_min: 8192,
        ubatch_size: 512,
        parallel_slots: -1,
        overrides: {},
        integrations: ['server-only'],
        idle_timeout_sec: 60,
        fallback_provider: 'none',
        fallback_api_key: '',
        fallback_endpoint: '',
        fallback_model: '',
      },
      loading: false,
      error: null,
    });
  });

  it('initializes with default config state', () => {
    const config = useConfigStore.getState().config;
    expect(config?.installation_type).toBe('none');
    expect(config?.default_context_size).toBe(32768);
  });

  it('updates partial config correctly', async () => {
    await useConfigStore
      .getState()
      .updateConfig({ installation_type: 'winget', default_context_size: 65536 });
    const updated = useConfigStore.getState().config;
    expect(updated?.installation_type).toBe('winget');
    expect(updated?.default_context_size).toBe(65536);
    expect(updated?.fit_ctx_min).toBe(8192); // preserved
  });

  it('performs deep merge for nested properties without wiping siblings', () => {
    useConfigStore.getState().updateConfig({
      context_manager: {
        enabled: true,
        warn_threshold: 0.7,
        keep_turns: 6,
        proxy_port: 8090,
        ctx_limit: 4096,
        tokenizer_repo: 'meta-llama/Llama-3-8B',
        summary_max_tokens: 768,
        summarize_with_model: 'same',
      },
    });

    // Update only warn_threshold
    useConfigStore.getState().updateConfig({
      context_manager: {
        warn_threshold: 0.85,
      } as any,
    });

    const cm = useConfigStore.getState().config?.context_manager;
    expect(cm?.enabled).toBe(true);
    expect(cm?.warn_threshold).toBe(0.85);
    expect(cm?.keep_turns).toBe(6);
    expect(cm?.proxy_port).toBe(8090);
  });
});
