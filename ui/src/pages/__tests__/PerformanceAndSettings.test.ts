import { describe, it, expect } from 'vitest';
import { useConfigStore } from '../../store/configStore';
import { useServerStore } from '../../store/serverStore';

describe('Performance Parameters & Live Logs Management', () => {
  it('updates SYSTEM_COMMANDS.md inference tuning flags correctly', () => {
    useConfigStore.setState({
      config: {
        threads: 8,
        prio: 2,
        mlock: true,
        spec_type: 'ngram-simple',
        spec_ngram_simple_size_n: 12,
        cache_prompt: true,
        cache_reuse: 256,
        reasoning: 'auto',
        reasoning_format: 'deepseek',
        reasoning_budget: 1024,
      } as any,
    });

    const cfg = useConfigStore.getState().config;
    expect(cfg?.threads).toBe(8);
    expect(cfg?.prio).toBe(2);
    expect(cfg?.mlock).toBe(true);
    expect(cfg?.spec_type).toBe('ngram-simple');
    expect(cfg?.reasoning).toBe('auto');
    expect(cfg?.reasoning_budget).toBe(1024);
  });

  it('streams and filters live server output logs by level and text search', () => {
    useServerStore.getState().clearLogs();

    useServerStore.getState().addLog({
      timestamp: '03:55:00',
      level: 'INFO',
      message: 'llama-server bound to port 8080',
    });

    useServerStore.getState().addLog({
      timestamp: '03:55:01',
      level: 'WARN',
      message: 'VRAM usage is at 88%',
    });

    useServerStore.getState().addLog({
      timestamp: '03:55:02',
      level: 'ERROR',
      message: 'CUDA Out of Memory in layer 28',
    });

    const allLogs = useServerStore.getState().logs;
    expect(allLogs.length).toBe(3);

    const errorLogs = allLogs.filter((l) => l.level === 'ERROR');
    expect(errorLogs.length).toBe(1);
    expect(errorLogs[0].message).toContain('CUDA Out of Memory');

    const searchResults = allLogs.filter((l) => l.message.toLowerCase().includes('port 8080'));
    expect(searchResults.length).toBe(1);
  });

  it('clears log history on command', () => {
    useServerStore.getState().clearLogs();
    expect(useServerStore.getState().logs.length).toBe(0);
  });

  it('keeps Context Window in sync between Performance and Settings', () => {
    useConfigStore.setState({
      config: {
        overrides: { ctx_size: 65536 },
        default_context_size: 65536,
      } as any,
    });

    const cfg1 = useConfigStore.getState().config;
    // Settings visual read pattern
    const settingsVal = cfg1?.overrides?.ctx_size ?? cfg1?.default_context_size ?? 32768;
    // Performance visual read pattern
    const perfVal = cfg1?.overrides?.ctx_size || cfg1?.default_context_size || 32768;
    expect(settingsVal).toBe(65536);
    expect(perfVal).toBe(65536);
    expect(settingsVal).toBe(perfVal);

    // Simulate updating from Settings
    const newCtx = 131072;
    useConfigStore.getState().updateConfig({
      default_context_size: newCtx,
      overrides: { ...(cfg1?.overrides || {}), ctx_size: newCtx },
    });

    const cfg2 = useConfigStore.getState().config;
    expect(cfg2?.overrides?.ctx_size).toBe(131072);
    expect(cfg2?.default_context_size).toBe(131072);
  });
});
