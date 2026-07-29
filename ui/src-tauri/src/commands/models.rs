use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use crate::scripts::get_workspace_root;
use crate::commands::gguf::parse_gguf_file;

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

/// Recursively collects all .gguf files in a directory tree.
fn collect_gguf_files_recursive(dir: &Path, files: &mut Vec<PathBuf>) {
    if let Ok(entries) = fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                collect_gguf_files_recursive(&path, files);
            } else if path.is_file() && path.extension().and_then(|s| s.to_str()) == Some("gguf") {
                files.push(path);
            }
        }
    }
}

#[tauri::command]
pub fn scan_models(models_dir_path: Option<String>) -> Result<Vec<ModelInfo>, String> {
    let root = get_workspace_root();
    let target_dir = match models_dir_path {
        Some(p) if !p.is_empty() => PathBuf::from(p),
        _ => root.join("..").join("models"),
    };

    let mut models = Vec::new();
    let mut gguf_paths = Vec::new();

    if target_dir.exists() && target_dir.is_dir() {
        collect_gguf_files_recursive(&target_dir, &mut gguf_paths);
    }

    for path in gguf_paths {
        let filename = path.file_name().unwrap_or_default().to_string_lossy().to_string();
        let name = path.file_stem().unwrap_or_default().to_string_lossy().to_string();
        let lower_fn = filename.to_lowercase();
        let is_mmproj = lower_fn.contains("mmproj") || lower_fn.contains("vision-projector");

        let (quant, ctx, tmpl) = match parse_gguf_file(&path) {
            Ok(meta) => (meta.quantization, meta.context_length, format!("{}.jinja", meta.architecture)),
            Err(_) => (
                if lower_fn.contains("q4_k_m") { "Q4_K_M".to_string() } else { "GGUF".to_string() },
                32768,
                "chatml.jinja".to_string(),
            ),
        };

        let size_bytes = fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
        let file_size_gb = (size_bytes as f64 / (1024.0 * 1024.0 * 1024.0) * 10.0).round() / 10.0;

        models.push(ModelInfo {
            name,
            filename,
            path: path.to_string_lossy().to_string(),
            file_size_gb,
            quantization: quant,
            template: tmpl,
            template_match_method: if is_mmproj { "mmproj-projector".to_string() } else { "binary-header".to_string() },
            calculated_context: ctx,
            status: if is_mmproj { "Multimodal Projector".to_string() } else { "Ready".to_string() },
            is_mmproj,
        });
    }

    Ok(models)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_model_info_serialization() {
        let model = ModelInfo {
            name: "TestModel".to_string(),
            filename: "test.gguf".to_string(),
            path: "/path/test.gguf".to_string(),
            file_size_gb: 4.5,
            quantization: "Q4_K_M".to_string(),
            template: "default.jinja".to_string(),
            template_match_method: "fallback".to_string(),
            calculated_context: 16384,
            status: "Ready".to_string(),
            is_mmproj: false,
        };

        let json = serde_json::to_string(&model).unwrap();
        assert!(json.contains("\"fileSizeGb\":4.5"));
        assert!(json.contains("\"isMmproj\":false"));
    }

    #[test]
    fn test_scan_models_recursive() {
        let temp_dir = std::env::temp_dir().join("recursive_models_test");
        let sub_dir = temp_dir.join("subfolder");
        let _ = std::fs::create_dir_all(&sub_dir);

        let test_file = sub_dir.join("mmproj-model-f16.gguf");
        let _ = std::fs::write(&test_file, b"GGUF_TEST");

        let res = scan_models(Some(temp_dir.to_string_lossy().to_string())).unwrap();
        assert_eq!(res.len(), 1);
        assert_eq!(res[0].is_mmproj, true);

        let _ = std::fs::remove_dir_all(temp_dir);
    }
}
