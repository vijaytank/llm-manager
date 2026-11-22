use crate::scripts::run_powershell_script;
use serde::{Deserialize, Serialize};

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

fn rotate_and_write_log(log_path: &std::path::Path, content: &str) {
    const MAX_SIZE: u64 = 10 * 1024 * 1024; // 10MB
    const MAX_BACKUPS: usize = 5;

    if let Ok(meta) = std::fs::metadata(log_path) {
        if meta.len() >= MAX_SIZE {
            for i in (1..MAX_BACKUPS).rev() {
                let from = log_path.with_extension(format!("log.{}", i));
                let to = log_path.with_extension(format!("log.{}", i + 1));
                if from.exists() {
                    let _ = std::fs::rename(from, to);
                }
            }
            let first_backup = log_path.with_extension("log.1");
            let _ = std::fs::rename(log_path, first_backup);
        }
    }

    let _ = std::fs::write(log_path, content);
}

#[tauri::command]
pub fn detect_hardware() -> Result<SystemHardwareProfile, String> {
    let script_res = run_powershell_script("llo-core/Profile.ps1", &["-Json"])?;
    let log_path = crate::scripts::get_user_log_dir().join("hardware_debug.log");

    match serde_json::from_str::<SystemHardwareProfile>(&script_res) {
        Ok(profile) => {
            rotate_and_write_log(
                &log_path,
                &format!(
                    "--- HARDWARE PROBE SUCCESS ---\n{}\n",
                    serde_json::to_string_pretty(&profile).unwrap_or_default()
                ),
            );
            Ok(profile)
        }
        Err(e) => {
            rotate_and_write_log(
                &log_path,
                &format!(
                    "--- HARDWARE PROBE SERDE ERROR ---\nError: {}\nRaw script_res:\n{}\n",
                    e, script_res
                ),
            );
            Err(format!(
                "Hardware probe output parsing error: {}. Output was: {}",
                e, script_res
            ))
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
        println!(
            "\n=== LIVE TAURI IPC JSON OUTPUT ===\n{}\n==================================",
            json_str
        );
        assert!(
            !live_profile.cpu.name.is_empty(),
            "CPU name must be populated"
        );
        assert!(
            live_profile.cpu.physical_cores > 0,
            "Physical cores must be > 0"
        );
        assert!(
            live_profile.cpu.logical_cores > 0,
            "Logical cores must be > 0"
        );
        assert!(live_profile.ram.total_gb > 0.0, "Total RAM must be > 0");
        assert!(
            ["none", "integrated", "dedicated"].contains(&live_profile.gpu.adapter_class.as_str()),
            "Adapter class must be a valid classification"
        );
        assert!(
            ["cpu", "low", "mid", "high"].contains(&live_profile.gpu.performance_tier.as_str()),
            "Performance tier must be a valid tier"
        );
        if live_profile.gpu.adapter_class == "dedicated" {
            assert!(live_profile.gpu.total_vram_mb > 0);
        }
    }
}
