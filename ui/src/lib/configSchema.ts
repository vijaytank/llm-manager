// JSON Schema for AppConfig - used for real-time validation in Settings JSON editor
export const appConfigSchema = {
  $schema: 'http://json-schema.org/draft-07/schema#',
  type: 'object',
  title: 'LLM Manager Configuration',
  properties: {
    installation_type: {
      type: 'string',
      enum: ['none', 'wizard', 'cli', 'gui'],
      description: 'Installation type marker',
    },
    llama_server_path: {
      type: 'string',
      description: 'Absolute path to llama-server executable',
    },
    llama_repo_path: {
      type: 'string',
      description: 'Path to llama.cpp repository',
    },
    models_dir: {
      type: 'string',
      description: 'Directory containing GGUF model files',
    },
    templates_dir: {
      type: 'string',
      description: 'Directory containing Jinja chat templates',
    },
    grammars_dir: {
      type: 'string',
      description: 'Directory containing GBNF grammar files',
    },
    active_model: {
      type: 'string',
      description: 'Currently selected model name',
    },
    use_default_template: {
      type: 'boolean',
      description: 'Use default.jinja template for all models',
    },
    fit_ctx_min: {
      type: 'integer',
      minimum: 2048,
      maximum: 262144,
      description: 'Minimum context size floor',
    },
    threads: {
      type: 'integer',
      minimum: 0,
      maximum: 64,
      description: 'CPU inference threads (0 = auto)',
    },
    prio: {
      type: 'integer',
      minimum: 0,
      maximum: 3,
      description: 'Process priority (0=normal, 1=medium, 2=high, 3=realtime)',
    },
    mlock: {
      type: 'boolean',
      description: 'Lock model in RAM (--mlock)',
    },
    spec_type: {
      type: 'string',
      enum: ['none', 'ngram-simple', 'ngram-map-k'],
      description: 'Speculative decoding type',
    },
    spec_ngram_simple_size_n: {
      type: 'integer',
      minimum: 2,
      maximum: 20,
      description: 'N-gram size for speculative decoding',
    },
    cache_prompt: {
      type: 'boolean',
      description: 'Enable prompt cache reuse',
    },
    cache_reuse: {
      type: 'integer',
      minimum: 0,
      description: 'Prompt cache reuse tokens',
    },
    cache_ram: {
      type: 'integer',
      minimum: 0,
      description: 'Cache RAM limit in MB',
    },
    sleep_idle_seconds: {
      type: 'integer',
      minimum: 0,
      description: 'Idle timeout in seconds',
    },
    reasoning: {
      type: 'string',
      enum: ['auto', 'on', 'off'],
      description: 'Reasoning tag handling',
    },
    reasoning_format: {
      type: 'string',
      enum: ['auto', 'deepseek', 'chatml'],
      description: 'Reasoning format',
    },
    reasoning_budget: {
      type: 'integer',
      minimum: -1,
      description: 'Reasoning token budget (-1 = unlimited)',
    },
    default_context_size: {
      type: 'integer',
      minimum: 2048,
      maximum: 262144,
      description: 'Default context window size',
    },
    ubatch_size: {
      type: 'integer',
      minimum: 1,
      maximum: 8192,
      description: 'Micro-batch size for prompt processing',
    },
    parallel_slots: {
      type: 'integer',
      minimum: 1,
      maximum: 16,
      description: 'Number of parallel inference slots',
    },
    overrides: {
      type: 'object',
      description: 'User overrides taking absolute priority over auto-derived values',
      additionalProperties: true,
    },
    integrations: {
      type: 'array',
      items: { type: 'string' },
      description: 'Enabled client integrations',
    },
    idle_timeout_sec: {
      type: 'integer',
      minimum: 60,
      maximum: 86400,
      description: 'Server idle timeout in seconds',
    },
    fallback_provider: {
      type: 'string',
      enum: ['none', 'ollama', 'openai', 'anthropic', 'nim'],
      description: 'Fallback cloud provider',
    },
    fallback_api_key: {
      type: 'string',
      description: 'API key for fallback provider',
    },
    fallback_endpoint: {
      type: 'string',
      format: 'uri',
      description: 'Custom endpoint for fallback provider',
    },
    fallback_model: {
      type: 'string',
      description: 'Model name for fallback provider',
    },
    mmproj_path: {
      type: 'string',
      description: 'Path to multimodal projector (mmproj) file',
    },
    mmproj_no_offload: {
      type: 'boolean',
      description: 'Keep mmproj on CPU instead of GPU',
    },
    active_template: {
      type: 'string',
      description: 'Active chat template filename',
    },
    context_manager: {
      type: 'object',
      properties: {
        enabled: { type: 'boolean' },
        warn_threshold: { type: 'number', minimum: 0.4, maximum: 0.95 },
        keep_turns: { type: 'integer', minimum: 2, maximum: 20 },
        proxy_port: { type: 'integer', minimum: 1024, maximum: 65535 },
        ctx_limit: { type: 'integer', minimum: 0, maximum: 2000000 },
        tokenizer_repo: { type: 'string' },
        summary_max_tokens: { type: 'integer', minimum: 256, maximum: 4096 },
        summarize_with_model: { type: 'string' },
      },
      required: [
        'enabled',
        'warn_threshold',
        'keep_turns',
        'proxy_port',
        'ctx_limit',
        'tokenizer_repo',
        'summary_max_tokens',
        'summarize_with_model',
      ],
    },
  },
  additionalProperties: false,
} as const;

export type ConfigSchema = typeof appConfigSchema;
