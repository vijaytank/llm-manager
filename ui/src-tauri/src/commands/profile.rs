use serde::{Deserialize, Serialize};
use crate::scripts::run_powershell_script;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CpuInfo {
    #[serde(alias = "Name")]
    pub name: String,
    #[serde(alias = "PhysicalCores")]
    pub physical_cores: u32,
    #[serde(alias = "LogicalCores")]
    pub logical_cores: u32,
    #[serde(alias = "OptimalThreads")]
    pub optimal_threads: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GpuInfo {
    #[serde(alias = "Name")]
    pub name: String,
    #[serde(alias = "TotalVramMB")]
    pub total_vram_mb: u32,
    #[serde(alias = "AdapterClass")]
    pub adapter_class: String,
    #[serde(alias = "PerformanceTier")]
    pub performance_tier: String,
    #[serde(default, alias = "TierReason", alias = "reason")]
    pub reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RamInfo {
    #[serde(alias = "TotalGB", alias = "total_gb")]
    pub total_gb: f64,
    #[serde(alias = "SafeBudgetMB", alias = "safe_budget_mb")]
    pub safe_budget_mb: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SystemHardwareProfile {
    #[serde(alias = "CPU")]
    pub cpu: CpuInfo,
    #[serde(alias = "RAM")]
    pub ram: RamInfo,
    #[serde(alias = "GPU")]
    pub gpu: GpuInfo,
}

#[tauri::command]
pub fn detect_hardware() -> Result<SystemHardwareProfile, String> {
    let script_res = run_powershell_script("llo-core/Profile.ps1", &["-Json"])?;
    let log_path = crate::scripts::get_user_log_dir().join("hardware_debug.log");

    match serde_json::from_str::<SystemHardwareProfile>(&script_res) {
        Ok(profile) => {
            let _ = std::fs::write(&log_path, format!("--- HARDWARE PROBE SUCCESS ---\n{}\n", serde_json::to_string_pretty(&profile).unwrap_or_default()));
            Ok(profile)
        }
        Err(e) => {
            let _ = std::fs::write(&log_path, format!("--- HARDWARE PROBE SERDE ERROR ---\nError: {}\nRaw script_res:\n{}\n", e, script_res));
            Err(format!("Hardware probe output parsing error: {}. Output was: {}", e, script_res))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_profile_deserialization() {
        let raw_json = r#"{
            "cpu": {
                "name": "Intel Core i9-13900K",
                "physicalCores": 24,
                "logicalCores": 32,
                "optimalThreads": 8
            },
            "ram": { "TotalGB": 32 },
            "gpu": {
                "name": "NVIDIA GeForce RTX 4070",
                "totalVramMb": 12288,
                "adapterClass": "dedicated",
                "performanceTier": "high",
                "reason": "Dedicated GPU > 8GB VRAM"
            }
        }"#;

        let profile: SystemHardwareProfile = serde_json::from_str(raw_json).unwrap();
        assert_eq!(profile.cpu.name, "Intel Core i9-13900K");
        assert_eq!(profile.gpu.performance_tier, "high");
        assert_eq!(profile.gpu.total_vram_mb, 12288);
    }

    #[test]
    fn test_live_hardware_detection() {
        let live_profile = detect_hardware().expect("Live hardware detection must succeed");
        let json_str = serde_json::to_string_pretty(&live_profile).unwrap();
        println!("\n=== LIVE TAURI IPC JSON OUTPUT ===\n{}\n==================================", json_str);
        assert_ne!(live_profile.gpu.name, "No Compatible GPU");
        assert!(live_profile.gpu.total_vram_mb > 0);
        assert_eq!(live_profile.gpu.adapter_class, "dedicated");
    }
}
