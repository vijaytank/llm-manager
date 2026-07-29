import { create } from 'zustand';
import { invoke } from '@tauri-apps/api/core';

export interface SystemHardware {
  cpuName: string;
  physicalCores: number;
  logicalCores: number;
  totalRamGb: number;
  gpuName: string;
  vramGb: number;
  adapterClass: 'none' | 'integrated' | 'dedicated';
  performanceTier: 'cpu' | 'low' | 'mid' | 'high';
}

interface HardwareState {
  profile: SystemHardware | null;
  loading: boolean;
  fetchHardware: () => Promise<void>;
  setProfile: (profile: SystemHardware) => void;
}

export const useHardwareStore = create<HardwareState>((set) => ({
  profile: null,
  loading: false,

  fetchHardware: async () => {
    set({ loading: true });
    try {
      const raw = await invoke<any>('detect_hardware');
      
      const vramMb = raw.gpu?.totalVramMb ?? raw.gpu?.total_vram_mb ?? 0;
      const rawAdapterClass = (raw.gpu?.adapterClass ?? raw.gpu?.adapter_class ?? 'none').toString().toLowerCase();
      const rawPerformanceTier = (raw.gpu?.performanceTier ?? raw.gpu?.performance_tier ?? 'cpu').toString().toLowerCase();

      const adapterClass = rawAdapterClass === 'dedicated' ? 'dedicated' : rawAdapterClass === 'integrated' ? 'integrated' : 'none';
      const performanceTier = rawPerformanceTier === 'high' ? 'high' : rawPerformanceTier === 'mid' ? 'mid' : rawPerformanceTier === 'low' ? 'low' : 'cpu';

      const profile: SystemHardware = {
        cpuName: raw.cpu?.name || raw.cpu?.Name || 'Host Processor',
        physicalCores: raw.cpu?.physicalCores || raw.cpu?.physical_cores || raw.cpu?.PhysicalCores || 4,
        logicalCores: raw.cpu?.logicalCores || raw.cpu?.logical_cores || raw.cpu?.LogicalCores || 4,
        totalRamGb: raw.ram?.TotalGB || raw.ram?.totalGb || raw.ram?.total_gb || 8,
        gpuName: raw.gpu?.name || raw.gpu?.Name || (adapterClass === 'none' ? 'No Compatible GPU' : 'Graphics Adapter'),
        vramGb: Math.round(vramMb / 1024),
        adapterClass,
        performanceTier,
      };
      set({ profile, loading: false });
    } catch {
      set({ loading: false });
    }
  },

  setProfile: (profile) => set({ profile }),
}));
