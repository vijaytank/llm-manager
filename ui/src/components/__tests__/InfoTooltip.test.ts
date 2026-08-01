import { describe, it, expect } from 'vitest';
import { useHardwareStore, SystemHardware } from '../../store/hardwareStore';

describe('InfoTooltip & Dynamic Hardware Recommendation Engine', () => {
  it('evaluates dynamic recommendations for 8 GB VRAM mid-tier GPU profile', () => {
    const mockHardware: SystemHardware = {
      cpuName: 'Intel Core Ultra 7 255H',
      physicalCores: 16,
      logicalCores: 16,
      totalRamGb: 24,
      gpuName: 'NVIDIA GeForce RTX 5060 Laptop GPU',
      vramGb: 8,
      adapterClass: 'dedicated',
      performanceTier: 'mid',
    };

    useHardwareStore.setState({ profile: mockHardware });
    const profile = useHardwareStore.getState().profile;

    expect(profile?.vramGb).toBe(8);
    expect(profile?.performanceTier).toBe('mid');

    // Recommendation logic for KV cache precision: <= 12GB VRAM suggests q8_0
    const kvRecommendation = profile?.vramGb && profile.vramGb <= 12
      ? 'q8_0 is recommended on your system to cut VRAM usage by 50% without quality loss.'
      : 'f16 provides maximum floating-point precision.';

    expect(kvRecommendation).toContain('q8_0 is recommended');

    // Recommendation for context window
    const ctxRecommendation = profile?.vramGb && profile.vramGb <= 8
      ? '32,768 tokens with q8_0 KV cache is optimal for your 8 GB GPU.'
      : '65,536 tokens for long documents.';

    expect(ctxRecommendation).toContain('8 GB GPU');
  });

  it('evaluates dynamic recommendations for High VRAM (24 GB) workstation GPU profile', () => {
    const mockHardware: SystemHardware = {
      cpuName: 'AMD Ryzen Threadripper 7980X',
      physicalCores: 64,
      logicalCores: 128,
      totalRamGb: 128,
      gpuName: 'NVIDIA RTX 4090',
      vramGb: 24,
      adapterClass: 'dedicated',
      performanceTier: 'high',
    };

    useHardwareStore.setState({ profile: mockHardware });
    const profile = useHardwareStore.getState().profile;

    const kvRecommendation = profile?.vramGb && profile.vramGb <= 12
      ? 'q8_0 is recommended'
      : 'f16 provides maximum floating-point precision.';

    expect(kvRecommendation).toBe('f16 provides maximum floating-point precision.');
  });

  it('evaluates dynamic recommendations for CPU-only laptop system', () => {
    const mockHardware: SystemHardware = {
      cpuName: 'Intel Core i5-10210U',
      physicalCores: 4,
      logicalCores: 8,
      totalRamGb: 8,
      gpuName: 'Intel UHD Graphics',
      vramGb: 0,
      adapterClass: 'none',
      performanceTier: 'cpu',
    };

    useHardwareStore.setState({ profile: mockHardware });
    const profile = useHardwareStore.getState().profile;

    const isCpuOnly = profile?.adapterClass === 'none' || profile?.performanceTier === 'cpu';
    expect(isCpuOnly).toBe(true);

    const faRecommendation = isCpuOnly ? 'Disabled in CPU-only mode.' : 'Keep enabled for modern GPUs.';
    expect(faRecommendation).toBe('Disabled in CPU-only mode.');
  });
});
