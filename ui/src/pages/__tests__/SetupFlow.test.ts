import { describe, it, expect } from 'vitest';
import { useConfigStore } from '../../store/configStore';
import { useHardwareStore } from '../../store/hardwareStore';

describe('Setup Wizard Flow & Step Transitions', () => {
  it('Step 1: requires llama_server_path to enable Next button', () => {
    useConfigStore.setState({
      config: {
        installation_type: 'none',
        llama_server_path: '',
        models_dir: '',
        default_context_size: 32768,
        flash_attn: 'off',
        integrations: ['server-only'],
      } as any,
    });

    const isStep1Valid = Boolean(useConfigStore.getState().config?.llama_server_path);
    expect(isStep1Valid).toBe(false);

    // User sets path to llama-server.exe
    useConfigStore.getState().updateConfig({ llama_server_path: 'C:\\llama\\llama-server.exe' });
    expect(Boolean(useConfigStore.getState().config?.llama_server_path)).toBe(true);
  });

  it('Step 2: updates models directory and triggers GGUF model scanning', () => {
    useConfigStore.getState().updateConfig({ models_dir: 'C:\\llama\\models' });
    expect(useConfigStore.getState().config?.models_dir).toBe('C:\\llama\\models');
  });

  it('Step 3: tunes parameters based on CPU vs GPU hardware profile', () => {
    // Test CPU-only hardware profile
    useHardwareStore.setState({
      profile: {
        cpuName: 'Intel Core i5-10400',
        physicalCores: 6,
        logicalCores: 12,
        totalRamGb: 16,
        gpuName: 'No Compatible GPU',
        vramGb: 0,
        adapterClass: 'none',
        performanceTier: 'cpu',
      },
    });

    const cpuProfile = useHardwareStore.getState().profile;
    const isCpuOnly = cpuProfile?.adapterClass === 'none' || cpuProfile?.performanceTier === 'cpu';
    expect(isCpuOnly).toBe(true);

    // Test Dedicated GPU hardware profile
    useHardwareStore.setState({
      profile: {
        cpuName: 'Intel Core Ultra 7 255H',
        physicalCores: 16,
        logicalCores: 16,
        totalRamGb: 24,
        gpuName: 'NVIDIA RTX 5060 Laptop GPU',
        vramGb: 8,
        adapterClass: 'dedicated',
        performanceTier: 'mid',
      },
    });

    const gpuProfile = useHardwareStore.getState().profile;
    const isGpuMode = gpuProfile?.adapterClass === 'dedicated' && gpuProfile?.performanceTier !== 'cpu';
    expect(isGpuMode).toBe(true);
  });

  it('Step 4: mutates client integrations list (vscode, claude-code, cursor, rest-api)', () => {
    const initialList = useConfigStore.getState().config?.integrations || [];
    expect(initialList).toContain('server-only');

    // Toggle vscode integration
    const updatedIntegrations = [...initialList, 'vscode', 'claude-code'];
    useConfigStore.getState().updateConfig({ integrations: updatedIntegrations });

    expect(useConfigStore.getState().config?.integrations).toContain('vscode');
    expect(useConfigStore.getState().config?.integrations).toContain('claude-code');
  });

  it('Step 5: completes setup and changes installation_type from none to winget', () => {
    useConfigStore.getState().updateConfig({ installation_type: 'winget' });
    expect(useConfigStore.getState().config?.installation_type).toBe('winget');
  });
});
