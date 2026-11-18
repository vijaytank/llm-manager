# Data models

**Active contributors:** vijay

Type definitions across PowerShell, Rust, TypeScript, and Python.

## SystemHardwareProfile

### PowerShell (`llo-core/Profile.ps1`)

```powershell
[pscustomobject]@{
    CPU = @{
        Name           = "Intel Core i9-13900K"
        PhysicalCores  = 24
        LogicalCores   = 32
        OptimalThreads = 8
    }
    RAM = @{
        TotalGB      = 64
        SafeBudgetMB = 57344
    }
    GPU = @{
        Name              = "NVIDIA GeForce RTX 4090"
        TotalVramMB       = 24576
        AdapterClass      = "dedicated"
        PerformanceTier   = "high"
        Reason            = "Dedicated GPU > 8GB VRAM"
        HasNvidiaSmi      = $true
        HasCudaBackend    = $true
        HasVulkanBackend  = $false
        UsableForInference= $true
        CudaDriver        = "550.90"
        BudgetVramMB      = 24576
    }
}
```

### Rust (`ui/src-tauri/src/commands/profile.rs`)

```rust
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CpuInfo {
    pub name: String,
    pub physical_cores: u32,
    pub logical_cores: u32,
    pub optimal_threads: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GpuInfo {
    pub name: String,
    pub total_vram_mb: u32,
    pub adapter_class: String,
    pub performance_tier: String,
    pub reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RamInfo {
    pub total_gb: f64,
    pub safe_budget_mb: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SystemHardwareProfile {
    pub cpu: CpuInfo,
    pub ram: RamInfo,
    pub gpu: GpuInfo,
}
```

### TypeScript (`ui/src/store/hardwareStore.ts`)

```typescript
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
```

## Inference Parameters

### PowerShell (`llo-core/SetupRouter.ps1`)

```powershell
@{
    n_gpu_layers   = 0 | -1
    flash_attn     = "on" | "off"
    use_fit        = $true | $false
    fit_target     = 0 | 512 | 1024
    fit_ctx_min    = 0 | 4096 | 8192
    cache_type_k   = "f16" | "q8_0" | "q4_0"
    cache_type_v   = "f16" | "q8_0" | "q4_0"
    ubatch_size    = 128 | 256 | 512 | 1024
    parallel       = 1 | 2
    spec_type      = "none" | "ngram-simple"
    context_shift  = $true | $false
    cache_reuse    = 0 | 256
    mmap           = 1
}
```

## ModelInfo

### Rust (`ui/src-tauri/src/commands/models.rs`)

```rust
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ModelInfo {
    pub name: String,
    pub filename: String,
    pub path: String,
    #[serde(rename = "fileSizeGb")]
    pub file_size_gb: f64,
    pub quantization: String,
    pub template: String,
    #[serde(rename = "templateMatchMethod")]
    pub template_match_method: String,
    #[serde(rename = "calculatedContext")]
    pub calculated_context: u32,
    pub status: String,
    #[serde(rename = "isMmproj")]
    pub is_mmproj: bool,
}
```

### TypeScript (`ui/src/store/modelsStore.ts`)

```typescript
export interface ModelInfo {
  name: string;
  filename: string;
  path: string;
  fileSizeGb: number;
  quantization: string;
  template: string;
  templateMatchMethod: string;
  calculatedContext: number;
  status: string;
  isMmproj: boolean;
}
```

## GgufMetadata

### Rust (`ui/src-tauri/src/commands/gguf.rs`)

```rust
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct GgufMetadata {
    pub name: String,
    pub architecture: String,
    pub quantization: String,
    #[serde(rename = "contextLength")]
    pub context_length: u32,
    #[serde(rename = "blockCount")]
    pub block_count: u32,
    #[serde(rename = "fileSizeGb")]
    pub file_size_gb: f64,
    #[serde(rename = "modelVramGb")]
    pub model_vram_gb: f64,
    #[serde(rename = "kvCacheGbAt8k")]
    pub kv_cache_gb_at_8k: f64,
    #[serde(rename = "kvCacheGbAt32k")]
    pub kv_cache_gb_at_32k: f64,
    #[serde(rename = "kvCacheGbAt64k")]
    pub kv_cache_gb_at_64k: f64,
}
```

## AppConfig

### Rust (`ui/src-tauri/src/commands/config.rs`)

```rust
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct AppConfig {
    pub installation_type: String,
    pub llama_server_path: String,
    pub llama_repo_path: String,
    pub models_dir: String,
    pub templates_dir: String,
    pub grammars_dir: String,
    pub active_model: String,
    pub use_default_template: bool,
    pub fit_ctx_min: u32,
    pub cache_type_k: String,
    pub cache_type_v: String,
    pub flash_attn: String,
    pub context_shift: bool,
    pub default_context_size: u32,
    pub ubatch_size: u32,
    pub parallel_slots: i32,
    pub threads: u32,
    pub prio: i32,
    pub mlock: bool,
    pub spec_type: String,
    pub spec_ngram_simple_size_n: u32,
    pub cache_prompt: bool,
    pub cache_reuse: u32,
    pub cache_ram: u32,
    pub sleep_idle_seconds: u32,
    pub reasoning: String,
    pub reasoning_format: String,
    pub reasoning_budget: u32,
    pub overrides: HashMap<String, serde_json::Value>,
    pub integrations: Vec<String>,
    pub idle_timeout_sec: u32,
    pub fallback_provider: String,
    pub fallback_api_key: String,
    pub fallback_endpoint: String,
    pub fallback_model: String,
    pub mmproj_path: String,
    pub mmproj_no_offload: bool,
    pub active_template: String,
    pub context_manager: ContextManagerSettings,
}
```

### TypeScript (`ui/src/store/configStore.ts`)

```typescript
export interface ContextManagerSettings {
  enabled: boolean;
  warn_threshold: number;
  keep_turns: number;
  proxy_port: number;
  ctx_limit: number;
  tokenizer_repo: string;
  summary_max_tokens: number;
  summarize_with_model: string;
}

export interface AppConfig {
  installation_type: string;
  llama_server_path: string;
  llama_repo_path: string;
  models_dir: string;
  templates_dir: string;
  grammars_dir: string;
  active_model: string;
  use_default_template: boolean;
  fit_ctx_min: number;
  cache_type_k?: string;
  cache_type_v?: string;
  flash_attn?: string;
  context_shift?: boolean;
  default_context_size?: number;
  ubatch_size?: number;
  parallel_slots?: number;
  threads?: number;
  prio?: number;
  mlock?: boolean;
  spec_type?: string;
  spec_ngram_simple_size_n?: number;
  cache_prompt?: boolean;
  cache_reuse?: number;
  cache_ram?: number;
  sleep_idle_seconds?: number;
  reasoning?: string;
  reasoning_format?: string;
  reasoning_budget?: number;
  overrides: Record<string, any>;
  integrations: string[];
  idle_timeout_sec: number;
  fallback_provider: string;
  fallback_api_key: string;
  fallback_endpoint: string;
  fallback_model: string;
  mmproj_path?: string;
  mmproj_no_offload?: boolean;
  active_template?: string;
  context_manager?: ContextManagerSettings;
}
```

## ContextManagerConfig

### Python (`llo-core/context_manager/config.py`)

```python
class ContextManagerConfig(BaseModel):
    enabled: bool = Field(default=False, description="Enable context manager proxy")
    warn_threshold: float = Field(default=0.70, ge=0.0, le=1.0)
    keep_turns: int = Field(default=6, ge=1)
    proxy_port: int = Field(default=8090, ge=1, le=65535)
    llama_server_url: str = Field(default="http://127.0.0.1:8080")
    ctx_limit: int = Field(default=0, ge=0)
    tokenizer_repo: str = Field(default="")
    summary_max_tokens: int = Field(default=768, ge=1)
    summarize_with_model: str = Field(default="same")
    eviction_interval_sec: int = Field(default=300, ge=1)
    session_ttl_sec: int = Field(default=86400, ge=1)
```

## SessionState

### Python (`llo-core/context_manager/context_engine.py`)

```python
class SessionState:
    def __init__(self, session_id: str):
        self.session_id = session_id
        self.messages: List[Dict[str, Any]] = []
        self.compressed_history: List[Dict[str, Any]] = []
        self.last_accessed = time.time()
        self.checksum = ""
```

## LaunchCheck (Validation)

### TypeScript (`ui/src/lib/validation.ts`)

```typescript
export interface LaunchCheck {
  canLaunch: boolean;
  severity: 'ok' | 'warn' | 'caution' | 'block';
  title: string;
  message: string;
  autoTuneConfig?: Partial<AppConfig>;
}
```

## Health Check Result

### PowerShell (`script/test-health.ps1`)

```powershell
[pscustomobject]@{
    TestName = "PowerShell Script Syntax Validation"
    Success  = $true
    Detail   = "All scripts parsed successfully."
}
```

### Rust (`ui/src-tauri/src/commands/health.rs`)

```rust
#[derive(Serialize)]
pub struct HealthCheckResult {
    pub overall_pass: bool,
    pub checks: Vec<HealthCheck>,
}

#[derive(Serialize)]
pub struct HealthCheck {
    pub name: String,
    pub passed: bool,
    pub detail: String,
}
```

## Cross-language mapping

| Concept | PowerShell | Rust | TypeScript | Python |
|---------|------------|------|------------|--------|
| Hardware Profile | PSCustomObject | SystemHardwareProfile | SystemHardware | — |
| Inference Params | Hashtable | — | — | — |
| Model Info | — | ModelInfo | ModelInfo | — |
| GGUF Metadata | — | GgufMetadata | — | — |
| App Config | Hashtable/JSON | AppConfig | AppConfig | — |
| Context Manager Config | — | — | ContextManagerSettings | ContextManagerConfig |
| Session State | — | — | — | SessionState |
| Validation Result | — | — | LaunchCheck | — |
| Health Check | PSCustomObject | HealthCheckResult | — | — |
