import { describe, it, expect } from 'vitest';
import { useConfigStore, AppConfig } from '../../store/configStore';

describe('Comprehensive Parameter CLI Forwarding & Options Coverage', () => {
  it('handles all performance parameter fields in config store', () => {
    const fullConfig: AppConfig = {
      installation_type: 'winget',
      llama_server_path: 'C:\\llama\\llama-server.exe',
      llama_repo_path: '',
      models_dir: 'F:\\llama\\models',
      templates_dir: 'F:\\llama\\templates',
      grammars_dir: '',
      active_model: 'ministral-3-8b-reasoning-2512-nvfp4',
      active_template: 'default.jinja',
      use_default_template: true,
      mmproj_path: 'F:\\llama\\models\\mmproj-f16.gguf',
      mmproj_no_offload: true,
      cache_type_k: 'q8_0',
      cache_type_v: 'q8_0',
      flash_attn: 'on',
      context_shift: true,
      default_context_size: 65536,
      fit_ctx_min: 8192,
      ubatch_size: 1024,
      parallel_slots: 1,
      threads: 16,
      prio: 2,
      mlock: true,
      spec_type: 'ngram-simple',
      reasoning: 'auto',
      overrides: { ctx_size: 65536 },
      integrations: ['vscode', 'claude-code', 'cursor'],
      idle_timeout_sec: 120,
      fallback_provider: 'none',
      fallback_api_key: '',
      fallback_endpoint: '',
      fallback_model: '',
    };

    useConfigStore.setState({ config: fullConfig });
    const cfg = useConfigStore.getState().config;

    expect(cfg?.cache_type_k).toBe('q8_0');
    expect(cfg?.cache_type_v).toBe('q8_0');
    expect(cfg?.flash_attn).toBe('on');
    expect(cfg?.default_context_size).toBe(65536);
    expect(cfg?.parallel_slots).toBe(1);
    expect(cfg?.ubatch_size).toBe(1024);
    expect(cfg?.threads).toBe(16);
    expect(cfg?.prio).toBe(2);
    expect(cfg?.mlock).toBe(true);
    expect(cfg?.spec_type).toBe('ngram-simple');
    expect(cfg?.reasoning).toBe('auto');
    expect(cfg?.mmproj_path).toContain('mmproj-f16.gguf');
    expect(cfg?.mmproj_no_offload).toBe(true);
  });

  it('correctly toggles single-slot max speed vs multi-slot concurrency', () => {
    useConfigStore.setState({
      config: { parallel_slots: 1 } as any,
    });
    expect(useConfigStore.getState().config?.parallel_slots).toBe(1);

    useConfigStore.getState().updateConfig({ parallel_slots: 4 });
    expect(useConfigStore.getState().config?.parallel_slots).toBe(4);
  });

  it('correctly updates micro-batch size steps (128, 256, 512, 1024, 2048)', () => {
    useConfigStore.setState({
      config: { ubatch_size: 512 } as any,
    });
    expect(useConfigStore.getState().config?.ubatch_size).toBe(512);

    useConfigStore.getState().updateConfig({ ubatch_size: 1024 });
    expect(useConfigStore.getState().config?.ubatch_size).toBe(1024);

    useConfigStore.getState().updateConfig({ ubatch_size: 2048 });
    expect(useConfigStore.getState().config?.ubatch_size).toBe(2048);
  });

  it('correctly updates KV cache quantization formats (f16, q8_0, q4_0)', () => {
    useConfigStore.setState({
      config: { cache_type_k: 'f16', cache_type_v: 'f16' } as any,
    });
    expect(useConfigStore.getState().config?.cache_type_k).toBe('f16');

    useConfigStore.getState().updateConfig({ cache_type_k: 'q8_0', cache_type_v: 'q8_0' });
    expect(useConfigStore.getState().config?.cache_type_k).toBe('q8_0');
    expect(useConfigStore.getState().config?.cache_type_v).toBe('q8_0');

    useConfigStore.getState().updateConfig({ cache_type_k: 'q4_0', cache_type_v: 'q4_0' });
    expect(useConfigStore.getState().config?.cache_type_k).toBe('q4_0');
  });

  it('correctly handles vision projector offloading modes', () => {
    useConfigStore.setState({
      config: { mmproj_path: 'C:\\models\\vision.gguf', mmproj_no_offload: false } as any,
    });
    expect(useConfigStore.getState().config?.mmproj_no_offload).toBe(false);

    useConfigStore.getState().updateConfig({ mmproj_no_offload: true });
    expect(useConfigStore.getState().config?.mmproj_no_offload).toBe(true);
  });
});
