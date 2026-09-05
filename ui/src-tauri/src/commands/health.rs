use serde::{Deserialize, Serialize};
use crate::scripts::run_powershell_script;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HealthItem {
    pub title: String,
    pub description: String,
    pub status: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HealthReport {
    #[serde(rename = "timestamp")]
    pub timestamp: String,
    #[serde(rename = "passedCount")]
    pub passed_count: u32,
    #[serde(rename = "totalCount")]
    pub total_count: u32,
    pub items: Vec<HealthItem>,
}

pub fn parse_health_output(script_output: &str) -> HealthReport {
    if let Ok(json_items) = serde_json::from_str::<Vec<HealthItem>>(script_output) {
        let passed_count = json_items.iter().filter(|i| i.status == "passed").count() as u32;
        let total_count = json_items.len() as u32;
        return HealthReport {
            timestamp: chrono::Local::now().format("%H:%M:%S").to_string(),
            passed_count,
            total_count,
            items: json_items,
        };
    }

    let raw_desc = if script_output.trim().is_empty() {
        "Diagnostics script exited without returning JSON output".to_string()
    } else {
        let truncated = if script_output.len() > 1024 {
            format!("{}...", &script_output[..1024])
        } else {
            script_output.trim().to_string()
        };
        format!("Diagnostics script output was not valid JSON:\n{}", truncated)
    };

    let items = vec![HealthItem {
        title: "Diagnostics Output Error".to_string(),
        description: raw_desc,
        status: "failed".to_string(),
    }];

    HealthReport {
        timestamp: chrono::Local::now().format("%H:%M:%S").to_string(),
        passed_count: 0,
        total_count: 1,
        items,
    }
}

#[tauri::command]
pub fn run_health_check() -> Result<HealthReport, String> {
    let config_file = crate::scripts::get_user_data_dir().join("llo-config.json");
    let config_file_str = config_file.to_string_lossy().to_string();
    let script_output = match run_powershell_script("script/test-health.ps1", &["-ConfigFile", &config_file_str, "-Json"]) {
        Ok(out) => out,
        Err(e) => e,
    };

    Ok(parse_health_output(&script_output))
}

#[tauri::command]
pub fn audit_scripts() -> Result<String, String> {
    let config_file = crate::scripts::get_user_data_dir().join("llo-config.json");
    let config_file_str = config_file.to_string_lossy().to_string();
    let output = match run_powershell_script("script/verify-scripts.ps1", &["-ConfigFile", &config_file_str]) {
        Ok(out) => out,
        Err(e) => format!("Audit completed with notes:\n{}", e),
    };
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_health_report_serialization() {
        let report = HealthReport {
            timestamp: "12:00:00".to_string(),
            passed_count: 4,
            total_count: 5,
            items: vec![],
        };

        let json = serde_json::to_string(&report).unwrap();
        assert!(json.contains("\"passedCount\":4"));
    }

    #[test]
    fn test_parse_health_output_invalid_json_emits_failed_item() {
        let raw_err = "PowerShell error: Cannot bind parameter\nAt line 123";
        let report = parse_health_output(raw_err);
        assert_eq!(report.passed_count, 0);
        assert_eq!(report.total_count, 1);
        assert_eq!(report.items.len(), 1);
        assert_eq!(report.items[0].status, "failed");
        assert_eq!(report.items[0].title, "Diagnostics Output Error");
        assert!(report.items[0].description.contains("Cannot bind parameter"));
    }

    #[test]
    fn test_parse_health_output_valid_json() {
        let json_data = r#"[
            {"title": "Config Check", "description": "OK", "status": "passed"},
            {"title": "RAM Check", "description": "Low", "status": "warning"}
        ]"#;
        let report = parse_health_output(json_data);
        assert_eq!(report.passed_count, 1);
        assert_eq!(report.total_count, 2);
        assert_eq!(report.items.len(), 2);
        assert_eq!(report.items[0].status, "passed");
        assert_eq!(report.items[1].status, "warning");
    }
}
