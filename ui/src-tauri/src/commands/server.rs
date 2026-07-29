use tauri::{AppHandle, Emitter};
use std::fs::File;
use std::io::{BufRead, BufReader, Seek, SeekFrom};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use tokio::time::sleep;
use crate::scripts::run_powershell_script;

static IS_RUNNING: AtomicBool = AtomicBool::new(false);

fn get_log_path() -> PathBuf {
    let root = crate::scripts::get_workspace_root();
    root.join("llama-server.log")
}

fn get_err_log_path() -> PathBuf {
    let root = crate::scripts::get_workspace_root();
    root.join("llama-server.err.log")
}

fn classify_log_level(line: &str, default: &'static str) -> &'static str {
    let trimmed = line.trim_start();
    if let Some(space_pos) = trimmed.find(' ') {
        if let Some(severity_char) = trimmed[space_pos + 1..].chars().next() {
            return match severity_char {
                'I' => "INFO",
                'W' => "WARN",
                'E' => "ERROR",
                _ => default,
            };
        }
    }
    default
}

async fn emit_log_file_lines(app: AppHandle, path: PathBuf, default_level: &'static str) {
    let mut missing_count = 0;
    let file_label = if default_level == "ERROR" { "stderr" } else { "stdout" };

    loop {
        if !IS_RUNNING.load(Ordering::SeqCst) {
            return;
        }

        if !path.exists() {
            missing_count += 1;
            if missing_count == 5 {
                let _ = app.emit("server-log", serde_json::json!({
                    "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
                    "level": "WARN",
                    "message": format!("Waiting for llama-server {} log file: {}", file_label, path.display()),
                }));
            }
            sleep(Duration::from_millis(300)).await;
            continue;
        }

        missing_count = 0;

        let file = match File::open(&path) {
            Ok(f) => f,
            Err(err) => {
                let _ = app.emit("server-log", serde_json::json!({
                    "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
                    "level": "WARN",
                    "message": format!("Failed to open llama-server {} log file {}: {}", file_label, path.display(), err),
                }));
                sleep(Duration::from_millis(300)).await;
                continue;
            }
        };

        let mut reader = BufReader::new(file);
        let mut current_pos = match reader.seek(SeekFrom::End(0)) {
            Ok(pos) => pos,
            Err(err) => {
                let _ = app.emit("server-log", serde_json::json!({
                    "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
                    "level": "WARN",
                    "message": format!("Failed to seek llama-server {} log file {}: {}", file_label, path.display(), err),
                }));
                sleep(Duration::from_millis(300)).await;
                continue;
            }
        };

        let _ = app.emit("server-log", serde_json::json!({
            "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
            "level": "INFO",
            "message": format!("Start tailing llama-server {} log: {}", file_label, path.display()),
        }));

        loop {
            if !IS_RUNNING.load(Ordering::SeqCst) {
                return;
            }

            let mut line = String::new();
            match reader.read_line(&mut line) {
                Ok(0) => {
                    if let Ok(metadata) = std::fs::metadata(&path) {
                        if metadata.len() < current_pos {
                            let _ = app.emit("server-log", serde_json::json!({
                                "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
                                "level": "INFO",
                                "message": format!("Detected llama-server {} log rotation/truncate: {}", file_label, path.display()),
                            }));
                            break;
                        }
                    }
                    sleep(Duration::from_millis(300)).await;
                }
                Ok(_) => {
                    current_pos = match reader.seek(SeekFrom::Current(0)) {
                        Ok(pos) => pos,
                        Err(_) => current_pos,
                    };
                    let trimmed = line.trim_end();
                    if !trimmed.is_empty() {
                        let level = classify_log_level(trimmed, default_level);
                        let _ = app.emit("server-log", serde_json::json!({
                            "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
                            "level": level,
                            "message": trimmed,
                        }));
                    }
                }
                Err(err) => {
                    let _ = app.emit("server-log", serde_json::json!({
                        "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
                        "level": "WARN",
                        "message": format!("Error reading llama-server {} log: {}", file_label, err),
                    }));
                    sleep(Duration::from_secs(1)).await;
                    break;
                }
            }
        }
    }
}

#[tauri::command]
pub async fn start_server(app: AppHandle, port: Option<u16>) -> Result<String, String> {
    let p = port.unwrap_or(8080);
    IS_RUNNING.store(true, Ordering::SeqCst);

    let _ = app.emit("server-status-changed", "running");
    let _ = app.emit("server-log", serde_json::json!({
        "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
        "level": "INFO",
        "message": format!("Starting llama-server process on port {}...", p)
    }));

    let port_str = p.to_string();
    tokio::task::spawn_blocking(move || {
        let _ = run_powershell_script("script/start-server.ps1", &["-Port", &port_str]);
    });

    let app_clone = app.clone();
    let stdout_path = get_log_path();
    let stderr_path = get_err_log_path();

    tokio::spawn(async move {
        emit_log_file_lines(app_clone.clone(), stdout_path, "INFO").await;
    });

    tokio::spawn(async move {
        emit_log_file_lines(app.clone(), stderr_path, "ERROR").await;
    });

    Ok(format!("Server started on port {}", p))
}

#[tauri::command]
pub async fn stop_server(app: AppHandle) -> Result<String, String> {
    IS_RUNNING.store(false, Ordering::SeqCst);

    let _ = app.emit("server-status-changed", "stopped");
    let _ = app.emit("server-log", serde_json::json!({
        "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
        "level": "INFO",
        "message": "Stopping llama-server process..."
    }));

    tokio::task::spawn_blocking(move || {
        let _ = run_powershell_script("script/stop-server.ps1", &[]);
    });

    Ok("Server stopped successfully".to_string())
}

#[tauri::command]
pub fn get_server_status() -> String {
    if IS_RUNNING.load(Ordering::SeqCst) {
        "running".to_string()
    } else {
        "stopped".to_string()
    }
}

#[tauri::command]
pub fn get_active_model_info() -> Result<serde_json::Value, String> {
    let root = crate::scripts::get_workspace_root();
    let config_path = root.join("llo-config.json");
    let config_raw = std::fs::read_to_string(&config_path).map_err(|e| format!("Failed to read config: {}", e))?;
    let config_value: serde_json::Value = serde_json::from_str(&config_raw).map_err(|e| format!("Failed to parse config: {}", e))?;
    let active_model = config_value.get("active_model").and_then(|v| v.as_str()).unwrap_or("");
    let models_path = root.join("models-preset.ini");
    Ok(serde_json::json!({
        "active_model": active_model,
        "models_preset_path": models_path.to_string_lossy(),
    }))
}

#[tauri::command]
pub fn launch_claude_terminal(port: Option<u16>, model: Option<String>) -> Result<String, String> {
    let p = port.unwrap_or(8080);
    let base_url = format!("http://127.0.0.1:{}", p);
    let m = model.unwrap_or_else(|| "local".to_string());

    let script = format!(
        "$env:ANTHROPIC_BASE_URL='{}'; $env:ANTHROPIC_AUTH_TOKEN='local'; $env:CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY='1'; claude --model {}",
        base_url, m
    );

    let executable = if cfg!(target_os = "windows") { "powershell.exe" } else { "pwsh" };
    let mut command = std::process::Command::new(executable);
    command.arg("-NoExit").arg("-Command").arg(&script);
    command.spawn().map_err(|e| format!("Failed to launch terminal: {}", e))?;

    Ok("Terminal launched successfully".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_initial_server_status() {
        assert_eq!(get_server_status(), "stopped");
    }

    #[test]
    fn test_classify_log_level() {
        assert_eq!(classify_log_level("0.00.030.349 I log_info: info details", "ERROR"), "INFO");
        assert_eq!(classify_log_level("0.00.030.349 W log_warn: warning details", "INFO"), "WARN");
        assert_eq!(classify_log_level("0.00.030.349 E log_error: error details", "INFO"), "ERROR");
        assert_eq!(classify_log_level("some other message", "INFO"), "INFO");
    }
}
