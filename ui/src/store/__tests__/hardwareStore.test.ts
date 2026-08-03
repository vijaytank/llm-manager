import { describe, it, expect, vi } from 'vitest';
import { useHardwareStore } from '../hardwareStore';

// Mock Tauri invoke for testing fetchHardware IPC bridge
vi.mock('@tauri-apps/api/core', () => ({
  invoke: vi.fn(async (cmd: string) => {
    if (cmd === 'detect_hardware') {
      return {
        cpu: {
          name: 'Intel Core Ultra 7 255H',
          physicalCores: 16,
          logicalCores: 16,
          optimalThreads: 8,
        },
        ram: {
          TotalGB: 24,
          TotalMB: 24000,
          BudgetMB: 18000,
        },
        gpu: {
          name: 'NVIDIA GeForce RTX 5060 Laptop GPU',
          totalVramMb: 8151,
          adapterClass: 'dedicated',
          performanceTier: 'mid',
          reason: 'Dedicated GPU ~8 GB VRAM',
        },
      };
    }
    return null;
  }),
}));

describe('hardwareStore', () => {
  it('starts with null profile before detection', () => {
    const profile = useHardwareStore.getState().profile;
    expect(profile).toBeNull();
  });

  it('fetches hardware profile via Tauri IPC and parses dedicated GPU with 8GB VRAM', async () => {
    await useHardwareStore.getState().fetchHardware();
    const profile = useHardwareStore.getState().profile;

    expect(profile).not.toBeNull();
    expect(profile?.cpuName).toBe('Intel Core Ultra 7 255H');
    expect(profile?.totalRamGb).toBe(24);
    expect(profile?.gpuName).toBe('NVIDIA GeForce RTX 5060 Laptop GPU');
    expect(profile?.vramGb).toBe(8);
    expect(profile?.adapterClass).toBe('dedicated');
    expect(profile?.performanceTier).toBe('mid');
  });

  it('updates hardware profile manually', () => {
    useHardwareStore.getState().setProfile({
      cpuName: 'AMD Ryzen 7 7800X3D',
      physicalCores: 8,
      logicalCores: 16,
      totalRamGb: 64,
      gpuName: 'NVIDIA RTX 4090',
      vramGb: 24,
      adapterClass: 'dedicated',
      performanceTier: 'high',
    });

    const updated = useHardwareStore.getState().profile;
    expect(updated?.cpuName).toBe('AMD Ryzen 7 7800X3D');
    expect(updated?.vramGb).toBe(24);
  });
});
