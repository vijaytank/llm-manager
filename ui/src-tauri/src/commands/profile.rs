use serde::{Deserialize, Serialize};
use crate::scripts::{run_powershell_script, get_workspace_root};

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
pub struct SystemHardwareProfile {
    #[serde(alias = "CPU")]
    pub cpu: CpuInfo,
    #[serde(alias = "RAM")]
    pub ram: serde_json::Value,
    #[serde(alias = "GPU")]
    pub gpu: GpuInfo,
}

#[tauri::command]
pub fn detect_hardware() -> Result<SystemHardwareProfile, String> {
    let script_res = run_powershell_script("llo-core/Profile.ps1", &["-Json"]);
    let output = match &script_res {
        Ok(s) => s.clone(),
        Err(e) => format!("SCRIPT EXECUTION ERROR: {}", e),
    };

    let log_path = get_workspace_root().join("hardware_debug.log");

    match serde_json::from_str::<SystemHardwareProfile>(&output) {
        Ok(profile) => {
            let _ = std::fs::write(&log_path, format!("--- HARDWARE PROBE SUCCESS ---\n{}\n", serde_json::to_string_pretty(&profile).unwrap_or_default()));
            Ok(profile)
        }
        Err(e) => {
            let _ = std::fs::write(&log_path, format!("--- HARDWARE PROBE SERDE ERROR ---\nError: {}\nRaw script_res: {:?}\nRaw output:\n{}\n", e, script_res, output));
            // Safe CPU-only baseline profile if live script execution output fails
            Ok(SystemHardwareProfile {
                cpu: CpuInfo {
                    name: "Host Processor".to_string(),
                    physical_cores: 4,
                    logical_cores: 8,
                    optimal_threads: 4,
                },
                ram: serde_json::json!({
                    "TotalGB": 8,
                    "BudgetMB": 6144
                }),
                gpu: GpuInfo {
                    name: "No Compatible GPU".to_string(),
                    total_vram_mb: 0,
                    adapter_class: "none".to_string(),
                    performance_tier: "cpu".to_string(),
                    reason: "CPU-only inference mode".to_string(),
                },
            })
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
