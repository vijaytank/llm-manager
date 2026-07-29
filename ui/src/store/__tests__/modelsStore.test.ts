import { describe, it, expect, vi } from 'vitest';
import { useModelsStore } from '../modelsStore';

vi.mock('@tauri-apps/api/core', () => ({
  invoke: vi.fn(async (cmd: string) => {
    if (cmd === 'scan_models') {
      return [
        {
          name: 'ornith-1.0-9b-Q4_K_M',
          filename: 'ornith-1.0-9b-Q4_K_M.gguf',
          path: 'F:\\llama\\models\\ornith-1.0-9b-Q4_K_M.gguf',
          fileSizeGb: 5.2,
          quantization: 'Q4_K_M',
          template: 'chatml.jinja',
          templateMatchMethod: 'binary-header',
          calculatedContext: 32768,
          status: 'Ready',
          isMmproj: false,
        },
        {
          name: 'mmproj-Qwythos-9B-v2-BF16',
          filename: 'mmproj-Qwythos-9B-v2-BF16.gguf',
          path: 'F:\\llama\\models\\mmproj-Qwythos-9B-v2-BF16.gguf',
          fileSizeGb: 0.9,
          quantization: 'Q4_K_M',
          template: 'mmproj.jinja',
          templateMatchMethod: 'mmproj-projector',
          calculatedContext: 32768,
          status: 'Multimodal Projector',
          isMmproj: true,
        },
      ];
    }
    return [];
  }),
}));

describe('modelsStore', () => {
  it('starts with empty models array', () => {
    const models = useModelsStore.getState().models;
    expect(models).toEqual([]);
  });

  it('scans and populates models directory with LLM models & mmproj vision adapters', async () => {
    await useModelsStore.getState().fetchModels('F:\\llama\\models');
    const models = useModelsStore.getState().models;

    expect(models.length).toBe(2);
    expect(models[0].name).toBe('ornith-1.0-9b-Q4_K_M');
    expect(models[0].isMmproj).toBe(false);

    expect(models[1].name).toBe('mmproj-Qwythos-9B-v2-BF16');
    expect(models[1].isMmproj).toBe(true);
    expect(models[1].status).toBe('Multimodal Projector');
  });
});
