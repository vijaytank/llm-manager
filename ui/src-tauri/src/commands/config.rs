use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;
use crate::scripts::{get_workspace_root, get_user_data_dir};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AppConfig {
    #[serde(default = "default_installation_type")]
    pub installation_type: String,

    #[serde(default)]
    pub llama_server_path: String,

    #[serde(default)]
    pub llama_repo_path: String,

    #[serde(default)]
    pub models_dir: String,

    #[serde(default)]
    pub templates_dir: String,

    #[serde(default)]
    pub grammars_dir: String,

    #[serde(default)]
    pub active_model: String,

    #[serde(default)]
    pub use_default_template: bool,

    #[serde(default = "default_cache_type")]
    pub cache_type_k: String,

    #[serde(default = "default_cache_type")]
    pub cache_type_v: String,

    #[serde(default = "default_flash_attn")]
    pub flash_attn: String,

    #[serde(default = "default_true")]
    pub context_shift: bool,

    #[serde(default = "default_context_size")]
    pub default_context_size: u32,

    #[serde(default = "default_fit_ctx_min")]
    pub fit_ctx_min: u32,

    #[serde(default = "default_ubatch_size")]
    pub ubatch_size: u32,

    #[serde(default = "default_parallel_slots")]
    pub parallel_slots: i32,

    // Advanced SYSTEM_COMMANDS.md Tuning Parameters
    #[serde(default)]
    pub threads: u32,

    #[serde(default)]
    pub prio: i32,

    #[serde(default)]
    pub mlock: bool,

    #[serde(default = "default_spec_type")]
    pub spec_type: String,

    #[serde(default = "default_spec_ngram_size")]
    pub spec_ngram_simple_size_n: u32,

    #[serde(default = "default_true")]
    pub cache_prompt: bool,

    #[serde(default = "default_cache_reuse")]
    pub cache_reuse: u32,

    #[serde(default)]
    pub cache_ram: u32,

    #[serde(default = "default_idle_timeout_i32")]
    pub sleep_idle_seconds: i32,

    #[serde(default = "default_auto")]
    pub reasoning: String,

    #[serde(default = "default_auto")]
    pub reasoning_format: String,

    #[serde(default = "default_neg_one")]
    pub reasoning_budget: i32,

    #[serde(default)]
    pub overrides: serde_json::Value,

    #[serde(default = "default_integrations")]
    pub integrations: Vec<String>,

    #[serde(default = "default_idle_timeout")]
    pub idle_timeout_sec: u32,

    #[serde(default = "default_fallback_provider")]
    pub fallback_provider: String,

    #[serde(default)]
    pub fallback_api_key: String,

    #[serde(default)]
    pub fallback_endpoint: String,

    #[serde(default)]
    pub fallback_model: String,
}

fn default_installation_type() -> String { "none".to_string() }
fn default_cache_type() -> String { "f16".to_string() }
fn default_flash_attn() -> String { "auto".to_string() }
fn default_true() -> bool { true }
fn default_context_size() -> u32 { 32768 }
fn default_fit_ctx_min() -> u32 { 8192 }
fn default_ubatch_size() -> u32 { 512 }
fn default_parallel_slots() -> i32 { -1 }
fn default_integrations() -> Vec<String> { vec!["server-only".to_string()] }
fn default_idle_timeout() -> u32 { 60 }
fn default_idle_timeout_i32() -> i32 { 60 }
fn default_fallback_provider() -> String { "none".to_string() }
fn default_spec_type() -> String { "ngram-simple".to_string() }
fn default_spec_ngram_size() -> u32 { 12 }
fn default_cache_reuse() -> u32 { 256 }
fn default_auto() -> String { "auto".to_string() }
fn default_neg_one() -> i32 { -1 }

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            installation_type: default_installation_type(),
            llama_server_path: String::new(),
            llama_repo_path: String::new(),
            models_dir: String::new(),
            templates_dir: String::new(),
            grammars_dir: String::new(),
            active_model: String::new(),
            use_default_template: false,
            cache_type_k: default_cache_type(),
            cache_type_v: default_cache_type(),
            flash_attn: default_flash_attn(),
            context_shift: default_true(),
            default_context_size: default_context_size(),
            fit_ctx_min: default_fit_ctx_min(),
            ubatch_size: default_ubatch_size(),
            parallel_slots: default_parallel_slots(),
            threads: 0,
            prio: 0,
            mlock: false,
            spec_type: default_spec_type(),
            spec_ngram_simple_size_n: default_spec_ngram_size(),
            cache_prompt: default_true(),
            cache_reuse: default_cache_reuse(),
            cache_ram: 0,
            sleep_idle_seconds: default_idle_timeout_i32(),
            reasoning: default_auto(),
            reasoning_format: default_auto(),
            reasoning_budget: default_neg_one(),
            overrides: serde_json::json!({}),
            integrations: default_integrations(),
            idle_timeout_sec: default_idle_timeout(),
            fallback_provider: default_fallback_provider(),
            fallback_api_key: String::new(),
            fallback_endpoint: String::new(),
            fallback_model: String::new(),
        }
    }
}

pub fn get_config_path() -> PathBuf {
    get_user_data_dir().join("llo-config.json")
}

#[tauri::command]
pub fn load_config() -> Result<AppConfig, String> {
    let user_config_path = get_config_path();
    
    if !user_config_path.exists() {
        // Copy initial default config from bundled resources if available
        let root = get_workspace_root();
        let bundled_candidates = vec![
            root.join("llo-config.json"),
            root.join("resources").join("llo-config.json"),
        ];

        if let Some(bundled_path) = bundled_candidates.into_iter().find(|p| p.exists()) {
            let _ = fs::copy(&bundled_path, &user_config_path);
        }
    }

    if !user_config_path.exists() {
        return Ok(AppConfig::default());
    }

    let contents = fs::read_to_string(&user_config_path)
        .map_err(|e| format!("Failed to read llo-config.json at {:?}: {}", user_config_path, e))?;

    let config: AppConfig = serde_json::from_str(&contents)
        .map_err(|e| format!("Failed to parse llo-config.json: {}", e))?;

    Ok(config)
}

#[tauri::command]
pub fn save_config(config: AppConfig) -> Result<(), String> {
    let path = get_config_path();
    let contents = serde_json::to_string_pretty(&config)
        .map_err(|e| format!("Failed to serialize config: {}", e))?;

    fs::write(&path, contents)
        .map_err(|e| format!("Failed to write llo-config.json at {:?}: {}", path, e))?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_config_serialization() {
        let config = AppConfig::default();
        let json = serde_json::to_string(&config).expect("Must serialize default config");
        assert!(json.contains("\"installation_type\":\"none\""));
        assert!(json.contains("\"default_context_size\":32768"));
        assert!(json.contains("\"spec_type\":\"ngram-simple\""));
    }

    #[test]
    fn test_deserialize_partial_json() {
        let raw = r#"{"installation_type": "winget", "default_context_size": 65536}"#;
        let config: AppConfig = serde_json::from_str(raw).expect("Must deserialize partial JSON");
        assert_eq!(config.installation_type, "winget");
        assert_eq!(config.default_context_size, 65536);
        assert_eq!(config.fit_ctx_min, 8192);
        assert_eq!(config.spec_type, "ngram-simple");
    }
}
