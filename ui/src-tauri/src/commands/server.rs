use tauri::{AppHandle, Emitter};
use std::sync::atomic::{AtomicBool, Ordering};
use crate::scripts::run_powershell_script;

static IS_RUNNING: AtomicBool = AtomicBool::new(false);

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
}
