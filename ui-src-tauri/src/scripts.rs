use std::path::PathBuf;
use std::process::Command;

/// Returns the workspace root path (parent of `ui/` directory or current pwd).
pub fn get_workspace_root() -> PathBuf {
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
    
    let mut current = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    for _ in 0..5 {
        if current.join("llo-core").exists() || current.join("llo-config.json").exists() {
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
    let script_full_path = root.join(script_relative_path);

    if !script_full_path.exists() {
        return Err(format!("Script not found at path: {:?}", script_full_path));
    }

    let executable = if cfg!(target_os = "windows") {
        "powershell.exe"
    } else {
        "pwsh"
    };

    let mut command = Command::new(executable);
    
    if cfg!(target_os = "windows") {
        command.arg("-ExecutionPolicy").arg("Bypass");
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
        assert!(root.join("llo-core").exists(), "llo-core directory must be found at workspace root");
    }
}
