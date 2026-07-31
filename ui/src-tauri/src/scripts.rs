use std::path::PathBuf;
use std::process::Command;
use std::fs;

/// Returns the user data directory for writable files (config, logs) at runtime.
/// Uses `%APPDATA%\LLM Manager` on Windows, ensuring write permissions regardless of install dir.
pub fn get_user_data_dir() -> PathBuf {
    let base_dir = if let Ok(appdata) = std::env::var("APPDATA") {
        PathBuf::from(appdata)
    } else if let Ok(home) = std::env::var("USERPROFILE").or_else(|_| std::env::var("HOME")) {
        PathBuf::from(home).join(".config")
    } else {
        std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
    };

    let user_dir = base_dir.join("LLM Manager");
    let _ = fs::create_dir_all(&user_dir);
    user_dir
}

/// Returns the user log directory (`%APPDATA%\LLM Manager\logs`).
pub fn get_user_log_dir() -> PathBuf {
    let log_dir = get_user_data_dir().join("logs");
    let _ = fs::create_dir_all(&log_dir);
    log_dir
}

/// Returns the workspace root or release resource path for llo-core scripts & config.
pub fn get_workspace_root() -> PathBuf {
    // 1. Check CARGO_MANIFEST_DIR (Dev mode / cargo test)
    if let Ok(manifest_dir) = std::env::var("CARGO_MANIFEST_DIR") {
        let manifest_path = PathBuf::from(manifest_dir);
        if let Some(parent) = manifest_path.parent() {
            if let Some(root) = parent.parent() {
                if root.join("llo-core").exists() {
                    return root.to_path_buf();
                }
            }
            if parent.join("llo-core").exists() {
                return parent.to_path_buf();
            }
        }
    }
    
    // 2. Check current_exe location & parent directories (Release build / Installed binary)
    if let Ok(exe_path) = std::env::current_exe() {
        if let Some(exe_dir) = exe_path.parent() {
            let candidates = vec![
                exe_dir.to_path_buf(),
                exe_dir.join("resources"),
                exe_dir.join("_up_").join("_up_"),
                exe_dir.join("resources").join("_up_").join("_up_"),
            ];

            for cand in &candidates {
                if cand.join("llo-core").exists() || cand.join("script").exists() {
                    return cand.clone();
                }
            }

            if let Some(parent) = exe_dir.parent() {
                let parent_candidates = vec![
                    parent.to_path_buf(),
                    parent.join("resources"),
                    parent.join("_up_").join("_up_"),
                ];
                for cand in &parent_candidates {
                    if cand.join("llo-core").exists() || cand.join("script").exists() {
                        return cand.clone();
                    }
                }
            }
        }
    }

    // 3. Fallback: Walk up from current working directory
    let mut current = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    for _ in 0..5 {
        if current.join("llo-core").exists() || current.join("llo-config.json").exists() || current.join("script").exists() {
            return current;
        }
        if let Some(parent) = current.parent() {
            current = parent.to_path_buf();
        } else {
            break;
        }
    }

    std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."))
}

/// Executes a PowerShell script safely on Windows (`powershell.exe`) or macOS/Linux (`pwsh`).
#[allow(dead_code)]
pub fn run_powershell_script(script_relative_path: &str, args: &[&str]) -> Result<String, String> {
    let root = get_workspace_root();
    
    // Check multiple candidate locations for the target script
    let mut candidate_paths = vec![
        root.join(script_relative_path),
        root.join("resources").join(script_relative_path),
        root.join("_up_").join("_up_").join(script_relative_path),
    ];

    if let Ok(exe_path) = std::env::current_exe() {
        if let Some(exe_dir) = exe_path.parent() {
            candidate_paths.push(exe_dir.join(script_relative_path));
            candidate_paths.push(exe_dir.join("resources").join(script_relative_path));
            candidate_paths.push(exe_dir.join("_up_").join("_up_").join(script_relative_path));
            candidate_paths.push(exe_dir.join("resources").join("_up_").join("_up_").join(script_relative_path));
        }
    }

    let resolved_script = candidate_paths.into_iter().find(|p| p.exists());

    let script_full_path = match resolved_script {
        Some(path) => path,
        None => {
            return Err(format!(
                "Script not found: '{}'. Searched under workspace root '{:?}'",
                script_relative_path, root
            ));
        }
    };

    let executable = if cfg!(target_os = "windows") {
        "powershell.exe"
    } else {
        "pwsh"
    };

    let mut command = Command::new(executable);

    if cfg!(target_os = "windows") {
        command
            .arg("-ExecutionPolicy").arg("Bypass")
            .arg("-WindowStyle").arg("Hidden")
            .arg("-NonInteractive");

        // Prevent Windows from creating a visible console window for this child process.
        // 0x08000000 = CREATE_NO_WINDOW (only needed as an extra precaution on some setups)
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }

    command.arg("-File").arg(&script_full_path);

    for arg in args {
        command.arg(arg);
    }

    let output = command
        .output()
        .map_err(|e| format!("Failed to execute process {}: {}", executable, e))?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let stdout = String::from_utf8_lossy(&output.stdout);
        return Err(format!("Script failed with exit code {:?}:\nStdout: {}\nStderr: {}", output.status.code(), stdout, stderr));
    }

    let stdout_str = String::from_utf8_lossy(&output.stdout).to_string();
    Ok(stdout_str)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_get_workspace_root() {
        let root = get_workspace_root();
        assert!(root.exists(), "Workspace root path must exist");
        assert!(
            root.join("llo-core").exists() || root.join("resources").join("llo-core").exists(),
            "llo-core directory must be found at workspace root or resources"
        );
    }

    #[test]
    fn test_get_user_data_dir() {
        let dir = get_user_data_dir();
        assert!(dir.exists(), "User data dir must exist");
        assert!(dir.join("logs").exists() || get_user_log_dir().exists(), "User log dir must exist");
    }
}

