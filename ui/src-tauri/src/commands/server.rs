use crate::scripts::run_powershell_script;
use notify::{Config, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use std::fs::File;
use std::io::{BufReader, Read, Seek, SeekFrom};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use tauri::{AppHandle, Emitter};
use tokio::time::sleep;

static IS_RUNNING: AtomicBool = AtomicBool::new(false);
static IS_STARTING: AtomicBool = AtomicBool::new(false);
static ACTIVE_PORT: std::sync::atomic::AtomicU16 = std::sync::atomic::AtomicU16::new(8080);
static LOG_TAIL_TASKS: std::sync::Mutex<Vec<tokio::task::JoinHandle<()>>> =
    std::sync::Mutex::new(Vec::new());
static LIFECYCLE_MUTEX: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

async fn abort_log_tailers() {
    let handles = {
        if let Ok(mut tasks) = LOG_TAIL_TASKS.lock() {
            tasks.drain(..).collect::<Vec<_>>()
        } else {
            Vec::new()
        }
    };
    for h in handles {
        h.abort();
        let _ = h.await;
    }
}

fn get_log_path() -> PathBuf {
    crate::scripts::get_user_log_dir().join("llama-server.log")
}

fn get_err_log_path() -> PathBuf {
    crate::scripts::get_user_log_dir().join("llama-server.err.log")
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
    let file_label = if default_level == "ERROR" {
        "stderr"
    } else {
        "stdout"
    };

    // Wait for log file to exist
    let mut missing_count = 0;
    while !path.exists() {
        if !IS_RUNNING.load(Ordering::SeqCst) && !IS_STARTING.load(Ordering::SeqCst) {
            return;
        }
        missing_count += 1;
        if missing_count == 20 {
            let _ = app.emit("server-log", serde_json::json!({
                "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
                "level": "WARN",
                "message": format!("Waiting for llama-server {} log file: {}", file_label, path.display()),
            }));
        }
        sleep(Duration::from_millis(300)).await;
    }

    // Read existing content from end of file
    let file = match File::open(&path) {
        Ok(f) => f,
        Err(err) => {
            let _ = app.emit("server-log", serde_json::json!({
                "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
                "level": "WARN",
                "message": format!("Failed to open llama-server {} log file {}: {}", file_label, path.display(), err),
            }));
            return;
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
            return;
        }
    };

    let _ = app.emit(
        "server-log",
        serde_json::json!({
            "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
            "level": "INFO",
            "message": format!("Start tailing llama-server {} log: {}", file_label, path.display()),
        }),
    );

    // Set up file watcher using notify crate
    let (tx, mut rx) = tokio::sync::mpsc::channel::<notify::Result<notify::Event>>(100);
    let path_clone = path.clone();

    let mut watcher =
        match RecommendedWatcher::new(
            move |res| {
                let _ = tx.blocking_send(res);
            },
            Config::default().with_poll_interval(Duration::from_millis(200)),
        ) {
            Ok(w) => w,
            Err(err) => {
                let _ = app.emit("server-log", serde_json::json!({
                "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
                "level": "WARN",
                "message": format!("Failed to create file watcher for {}: {}", file_label, err),
            }));
                // Fall back to polling
                return emit_log_file_lines_polling(app, path, default_level).await;
            }
        };

    if let Err(err) = watcher.watch(&path_clone, RecursiveMode::NonRecursive) {
        let _ = app.emit(
            "server-log",
            serde_json::json!({
                "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
                "level": "WARN",
                "message": format!("Failed to watch {} log file: {}", file_label, err),
            }),
        );
        let _ = watcher.unwatch(&path_clone);
        // Fall back to polling
        return emit_log_file_lines_polling(app, path, default_level).await;
    }

    let _ = app.emit(
        "server-log",
        serde_json::json!({
            "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
            "level": "INFO",
            "message": format!("File watcher active for llama-server {} log", file_label),
        }),
    );

    // Process events from watcher
    loop {
        if !IS_RUNNING.load(Ordering::SeqCst) && !IS_STARTING.load(Ordering::SeqCst) {
            break;
        }

        tokio::select! {
            Some(event_result) = rx.recv() => {
                match event_result {
                    Ok(event) => {
                        // Check for write events (modify, create)
                        let is_write = matches!(event.kind,
                            EventKind::Modify(_) |
                            EventKind::Create(_) |
                            EventKind::Any
                        );

                        if is_write {
                            // Read new content from file
                            let file = match File::open(&path) {
                                Ok(f) => f,
                                Err(err) => {
                                    let _ = app.emit("server-log", serde_json::json!({
                                        "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
                                        "level": "WARN",
                                        "message": format!("Failed to open {} log file: {}", file_label, err),
                                    }));
                                    sleep(Duration::from_millis(300)).await;
                                    continue;
                                }
                            };

                            let mut reader = BufReader::new(file);
                            if let Err(err) = reader.seek(SeekFrom::Start(current_pos)) {
                                let _ = app.emit("server-log", serde_json::json!({
                                    "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
                                    "level": "WARN",
                                    "message": format!("Failed to seek {} log file: {}", file_label, err),
                                }));
                                sleep(Duration::from_millis(300)).await;
                                continue;
                            }

                            let mut new_lines = String::new();
                            match reader.read_to_string(&mut new_lines) {
                                Ok(_) => {
                                    if let Ok(pos) = reader.stream_position() {
                                        current_pos = pos;
                                    }

                                    for line in new_lines.lines() {
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
                                }
                                Err(err) => {
                                    let _ = app.emit("server-log", serde_json::json!({
                                        "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
                                        "level": "WARN",
                                        "message": format!("Error reading {} log: {}", file_label, err),
                                    }));
                                }
                            }

                            // Check for log rotation/truncate
                            if let Ok(metadata) = std::fs::metadata(&path) {
                                if metadata.len() < current_pos {
                                    let _ = app.emit("server-log", serde_json::json!({
                                        "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
                                        "level": "INFO",
                                        "message": format!("Detected llama-server {} log rotation/truncate: {}", file_label, path.display()),
                                    }));
                                    current_pos = 0;
                                }
                            }
                        }
                    }
                    Err(err) => {
                        let _ = app.emit("server-log", serde_json::json!({
                            "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
                            "level": "WARN",
                            "message": format!("File watcher error for {}: {}", file_label, err),
                        }));
                    }
                }
            }
            _ = sleep(Duration::from_millis(500)) => {
                // Periodic check for file existence (handles case where file is deleted/recreated)
                if !path.exists() {
                    let _ = app.emit("server-log", serde_json::json!({
                        "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
                        "level": "INFO",
                        "message": format!("Log file {} no longer exists, waiting...", file_label),
                    }));
                    // Wait for file to reappear
                    while !path.exists() {
                        if !IS_RUNNING.load(Ordering::SeqCst) && !IS_STARTING.load(Ordering::SeqCst) {
                            return;
                        }
                        sleep(Duration::from_millis(300)).await;
                    }
                    // Re-read from beginning
                    current_pos = 0;
                }
            }
        }
    }

    // Clean up watcher
    let _ = watcher.unwatch(&path_clone);
}

async fn emit_log_file_lines_polling(app: AppHandle, path: PathBuf, default_level: &'static str) {
    let file_label = if default_level == "ERROR" {
        "stderr"
    } else {
        "stdout"
    };
    let mut current_pos = 0u64;

    loop {
        if !IS_RUNNING.load(Ordering::SeqCst) && !IS_STARTING.load(Ordering::SeqCst) {
            return;
        }

        if !path.exists() {
            let _ = app.emit("server-log", serde_json::json!({
                "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
                "level": "INFO",
                "message": format!("Waiting for llama-server {} log file: {}", file_label, path.display()),
            }));
            sleep(Duration::from_millis(300)).await;
            continue;
        }

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
        if let Err(err) = reader.seek(SeekFrom::Start(current_pos)) {
            let _ = app.emit("server-log", serde_json::json!({
                "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
                "level": "WARN",
                "message": format!("Failed to seek llama-server {} log file {}: {}", file_label, path.display(), err),
            }));
            sleep(Duration::from_millis(300)).await;
            continue;
        }

        let mut new_lines = String::new();
        match reader.read_to_string(&mut new_lines) {
            Ok(_) => {
                if let Ok(pos) = reader.stream_position() {
                    current_pos = pos;
                }

                for line in new_lines.lines() {
                    let trimmed = line.trim_end();
                    if !trimmed.is_empty() {
                        let level = classify_log_level(trimmed, default_level);
                        let _ = app.emit(
                            "server-log",
                            serde_json::json!({
                                "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
                                "level": level,
                                "message": trimmed,
                            }),
                        );
                    }
                }
            }
            Err(err) => {
                let _ = app.emit("server-log", serde_json::json!({
                    "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
                    "level": "WARN",
                    "message": format!("Error reading llama-server {} log: {}", file_label, err),
                }));
                sleep(Duration::from_secs(1)).await;
            }
        }

        // Check for log rotation/truncate
        if let Ok(metadata) = std::fs::metadata(&path) {
            if metadata.len() < current_pos {
                let _ = app.emit("server-log", serde_json::json!({
                    "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
                    "level": "INFO",
                    "message": format!("Detected llama-server {} log rotation/truncate: {}", file_label, path.display()),
                }));
                current_pos = 0;
            }
        }

        sleep(Duration::from_millis(300)).await;
    }
}

#[tauri::command]
pub async fn start_server(app: AppHandle, port: Option<u16>) -> Result<String, String> {
    let _guard = LIFECYCLE_MUTEX.lock().await;

    if IS_RUNNING.load(Ordering::SeqCst)
        || IS_STARTING
            .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .is_err()
    {
        return Err("Server process is already running or starting".to_string());
    }

    let p = port.unwrap_or(8080);
    ACTIVE_PORT.store(p, Ordering::SeqCst);
    abort_log_tailers().await;

    let _ = app.emit("server-status-changed", "starting");
    let _ = app.emit(
        "server-log",
        serde_json::json!({
            "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
            "level": "INFO",
            "message": format!("Starting llama-server process on port {}...", p)
        }),
    );

    let port_str = p.to_string();
    let user_data_dir = crate::scripts::get_user_data_dir();
    let config_file = user_data_dir.join("llo-config.json");
    let log_dir = crate::scripts::get_user_log_dir();
    let config_file_str = config_file.to_string_lossy().to_string();
    let log_dir_str = log_dir.to_string_lossy().to_string();

    // Read models_dir from the user's config so SetupRouter.ps1 scans the right place
    let models_dir_str = {
        let cfg_json = std::fs::read_to_string(&config_file).unwrap_or_default();
        let v: serde_json::Value = serde_json::from_str(&cfg_json).unwrap_or_default();
        v.get("models_dir")
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string()
    };

    let app_err = app.clone();
    tokio::task::spawn_blocking(move || {
        let result = run_powershell_script(
            "script/start-server.ps1",
            &[
                "-Port",
                &port_str,
                "-ConfigFile",
                &config_file_str,
                "-LogDir",
                &log_dir_str,
                "-ModelsDir",
                &models_dir_str,
            ],
        );
        match result {
            Ok(_) => {
                if IS_STARTING.load(Ordering::SeqCst) {
                    IS_RUNNING.store(true, Ordering::SeqCst);
                    IS_STARTING.store(false, Ordering::SeqCst);
                    let _ = app_err.emit("server-status-changed", "running");
                } else {
                    IS_RUNNING.store(false, Ordering::SeqCst);
                    let _ = app_err.emit(
                        "server-log",
                        serde_json::json!({
                            "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
                            "level": "INFO",
                            "message": "Server startup was cancelled by stop request."
                        }),
                    );
                }
            }
            Err(e) => {
                IS_RUNNING.store(false, Ordering::SeqCst);
                IS_STARTING.store(false, Ordering::SeqCst);
                let _ = app_err.emit(
                    "server-log",
                    serde_json::json!({
                        "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
                        "level": "ERROR",
                        "message": format!("start-server.ps1 failed:\n{}", e)
                    }),
                );
                let _ = app_err.emit("server-status-changed", "stopped");
            }
        }
    });

    let app_clone = app.clone();
    let stdout_path = get_log_path();
    let stderr_path = get_err_log_path();

    let t1 = tokio::spawn(async move {
        emit_log_file_lines(app_clone.clone(), stdout_path, "INFO").await;
    });

    let t2 = tokio::spawn(async move {
        emit_log_file_lines(app.clone(), stderr_path, "ERROR").await;
    });

    if let Ok(mut tasks) = LOG_TAIL_TASKS.lock() {
        tasks.push(t1);
        tasks.push(t2);
    }

    Ok(format!("Server launch initiated on port {}", p))
}

#[tauri::command]
pub async fn stop_server(app: AppHandle) -> Result<String, String> {
    let _guard = LIFECYCLE_MUTEX.lock().await;

    // Prevent double-stop if already stopped
    if !IS_RUNNING.load(Ordering::SeqCst) && !IS_STARTING.load(Ordering::SeqCst) {
        return Ok("Server already stopped".to_string());
    }

    IS_RUNNING.store(false, Ordering::SeqCst);
    IS_STARTING.store(false, Ordering::SeqCst);
    abort_log_tailers().await;

    let _ = app.emit("server-status-changed", "stopping");
    let _ = app.emit(
        "server-log",
        serde_json::json!({
            "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
            "level": "INFO",
            "message": "Stopping llama-server process..."
        }),
    );

    let app_clone = app.clone();
    let config_file = crate::scripts::get_user_data_dir().join("llo-config.json");
    let config_file_str = config_file.to_string_lossy().to_string();
    tokio::task::spawn_blocking(move || {
        let _ = run_powershell_script("script/stop-server.ps1", &["-ConfigFile", &config_file_str]);
        let _ = app_clone.emit("server-status-changed", "stopped");
        let _ = app_clone.emit(
            "server-log",
            serde_json::json!({
                "timestamp": chrono::Local::now().format("%H:%M:%S").to_string(),
                "level": "INFO",
                "message": "llama-server process stopped."
            }),
        );
    });

    Ok("Stop request sent".to_string())
}

pub fn check_server_status_internal() -> String {
    if IS_STARTING.load(Ordering::SeqCst) {
        let p = ACTIVE_PORT.load(Ordering::SeqCst);
        let port = if p > 0 { p } else { 8080 };
        if std::net::TcpStream::connect_timeout(
            &std::net::SocketAddr::from(([127, 0, 0, 1], port)),
            Duration::from_millis(150),
        )
        .is_ok()
        {
            IS_RUNNING.store(true, Ordering::SeqCst);
            IS_STARTING.store(false, Ordering::SeqCst);
            return "running".to_string();
        }
        return "starting".to_string();
    }

    if IS_RUNNING.load(Ordering::SeqCst) {
        let p = ACTIVE_PORT.load(Ordering::SeqCst);
        let port = if p > 0 { p } else { 8080 };
        if std::net::TcpStream::connect_timeout(
            &std::net::SocketAddr::from(([127, 0, 0, 1], port)),
            Duration::from_millis(150),
        )
        .is_err()
        {
            IS_RUNNING.store(false, Ordering::SeqCst);
            return "stopped".to_string();
        }
        return "running".to_string();
    }

    "stopped".to_string()
}

#[tauri::command]
pub fn get_server_status() -> String {
    check_server_status_internal()
}

#[tauri::command]
pub fn get_active_model_info() -> Result<serde_json::Value, String> {
    let config_path = crate::commands::config::get_config_path();
    let active_model = if config_path.exists() {
        let config_raw = std::fs::read_to_string(&config_path).unwrap_or_default();
        let config_value: serde_json::Value = serde_json::from_str(&config_raw).unwrap_or_default();
        config_value
            .get("active_model")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string()
    } else {
        String::new()
    };

    let user_data_dir = crate::scripts::get_user_data_dir();
    let root = crate::scripts::get_workspace_root();
    let preset_candidates = vec![
        user_data_dir.join("models-preset.ini"),
        root.join("models-preset.ini"),
        root.join("resources").join("models-preset.ini"),
    ];

    let models_path = preset_candidates
        .into_iter()
        .find(|p| p.exists())
        .unwrap_or_else(|| user_data_dir.join("models-preset.ini"));

    Ok(serde_json::json!({
        "active_model": active_model,
        "models_preset_path": models_path.to_string_lossy(),
    }))
}

#[tauri::command]
pub fn launch_claude_terminal(port: Option<u16>, model: Option<String>) -> Result<String, String> {
    let p = port.unwrap_or(8080);

    // Check if Context Manager Proxy is enabled in config
    let config_path = crate::commands::config::get_config_path();
    let target_port = if config_path.exists() {
        let config_raw = std::fs::read_to_string(&config_path).unwrap_or_default();
        let config_value: serde_json::Value = serde_json::from_str(&config_raw).unwrap_or_default();
        let cm = config_value.get("context_manager");
        let enabled = cm
            .and_then(|c| c.get("enabled"))
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        let proxy_port = cm
            .and_then(|c| c.get("proxy_port"))
            .and_then(|v| v.as_u64())
            .map(|v| v as u16)
            .unwrap_or(8090);
        if enabled {
            proxy_port
        } else {
            p
        }
    } else {
        p
    };

    let base_url = format!("http://127.0.0.1:{}", target_port);
    let m = model.unwrap_or_else(|| "local".to_string());

    let script = format!(
        "$env:ANTHROPIC_BASE_URL='{}'; $env:ANTHROPIC_AUTH_TOKEN='local'; $env:CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC='1'; $env:CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY='1'; claude --model $env:_LLO_MODEL",
        base_url
    );

    let executable = if cfg!(target_os = "windows") {
        "powershell.exe"
    } else {
        "pwsh"
    };
    let mut command = std::process::Command::new(executable);
    command
        .arg("-NoExit")
        .arg("-Command")
        .arg(&script)
        .env("_LLO_MODEL", &m);
    command
        .spawn()
        .map_err(|e| format!("Failed to launch terminal: {}", e))?;

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
        assert_eq!(
            classify_log_level("0.00.030.349 I log_info: info details", "ERROR"),
            "INFO"
        );
        assert_eq!(
            classify_log_level("0.00.030.349 W log_warn: warning details", "INFO"),
            "WARN"
        );
        assert_eq!(
            classify_log_level("0.00.030.349 E log_error: error details", "INFO"),
            "ERROR"
        );
        assert_eq!(classify_log_level("some other message", "INFO"), "INFO");
    }
}
