use tauri::{
    menu::{Menu, MenuItem, PredefinedMenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Emitter, Manager,
};

pub fn setup_system_tray(app: &AppHandle) -> Result<(), Box<dyn std::error::Error>> {
    let open_item = MenuItem::with_id(app, "open_dashboard", "Open Dashboard", true, None::<&str>)?;
    let separator = PredefinedMenuItem::separator(app)?;
    let start_item = MenuItem::with_id(app, "start_server", "▶  Start Server", true, None::<&str>)?;
    let stop_item = MenuItem::with_id(app, "stop_server", "⏹  Stop Server", true, None::<&str>)?;
    let separator2 = PredefinedMenuItem::separator(app)?;
    let quit_item = MenuItem::with_id(app, "quit", "Quit LLM Manager", true, None::<&str>)?;

    let menu = Menu::with_items(
        app,
        &[
            &open_item,
            &separator,
            &start_item,
            &stop_item,
            &separator2,
            &quit_item,
        ],
    )?;

    let mut builder = TrayIconBuilder::new()
        .menu(&menu)
        // Right-click shows the OS context menu; left-click is handled by our on_tray_icon_event
        .show_menu_on_left_click(false);

    if let Some(icon) = app.default_window_icon() {
        builder = builder.icon(icon.clone());
    }

    let _tray = builder
        .on_menu_event(move |app_handle, event| match event.id.as_ref() {
            "open_dashboard" => {
                show_and_focus_window(app_handle);
            }
            "start_server" => {
                let handle = app_handle.clone();
                tokio::spawn(async move {
                    let _ = crate::commands::server::start_server(handle, Some(8080)).await;
                });
            }
            "stop_server" => {
                let handle = app_handle.clone();
                tokio::spawn(async move {
                    let _ = crate::commands::server::stop_server(handle).await;
                });
            }
            "quit" => {
                std::process::exit(0);
            }
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            // Only open dashboard on left-click; right-click shows the context menu automatically
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                let app = tray.app_handle();
                show_and_focus_window(app);
            }
        })
        .build(app)?;

    Ok(())
}

fn show_and_focus_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
    }
    // Emit event to route frontend to the overview/dashboard tab
    let _ = app.emit("navigate-to", "overview");
}
