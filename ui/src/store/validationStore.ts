import { create } from 'zustand';
import { ImpactAssessment, validateConfiguration } from '../lib/validation';
import { AppConfig } from './configStore';
import { SystemHardware } from './hardwareStore';

interface ValidationState {
  assessments: ImpactAssessment[];
  validate: (config: AppConfig | null, hardware: SystemHardware | null, activeModelSizeGb?: number) => AppConfig | null;
  getParamAssessment: (param: string) => ImpactAssessment | undefined;
}

export const useValidationStore = create<ValidationState>((set, get) => ({
  assessments: [],

  validate: (config, hardware, activeModelSizeGb) => {
    if (!config) return null;
    const { assessments, correctedConfig } = validateConfiguration(config, hardware, activeModelSizeGb);
    set({ assessments });
    return correctedConfig;
  },

  getParamAssessment: (param) => {
    return get().assessments.find((a) => a.param === param);
  },
}));
