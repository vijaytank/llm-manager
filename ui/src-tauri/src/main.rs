// Prevents additional console window on Windows in release
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod commands;
mod scripts;
mod tray;

use commands::config::{load_config, save_config};
use commands::profile::detect_hardware;
use commands::server::{start_server, stop_server, get_server_status, get_active_model_info, launch_claude_terminal};
use commands::models::scan_models;
use commands::health::{run_health_check, audit_scripts};
use commands::gguf::read_gguf_info;

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            if let Err(e) = tray::setup_system_tray(app.handle()) {
                eprintln!("Failed to setup system tray: {}", e);
            }
            Ok(())
        })
        .on_window_event(|window, event| match event {
            tauri::WindowEvent::CloseRequested { api, .. } => {
                let _ = window.hide();
                api.prevent_close();
            }
            _ => {}
        })
        .invoke_handler(tauri::generate_handler![
            load_config,
            save_config,
            detect_hardware,
            start_server,
            stop_server,
            get_server_status,
            get_active_model_info,
            launch_claude_terminal,
            scan_models,
            run_health_check,
            audit_scripts,
            read_gguf_info
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
