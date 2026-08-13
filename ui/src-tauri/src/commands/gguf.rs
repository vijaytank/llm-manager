use serde::{Deserialize, Serialize};
use std::fs::File;
use std::io::Read;
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct GgufMetadata {
    pub name: String,
    pub architecture: String,
    pub quantization: String,
    #[serde(rename = "contextLength")]
    pub context_length: u32,
    #[serde(rename = "blockCount")]
    pub block_count: u32,
    #[serde(rename = "fileSizeGb")]
    pub file_size_gb: f64,
    #[serde(rename = "modelVramGb")]
    pub model_vram_gb: f64,
    #[serde(rename = "kvCacheGbAt8k")]
    pub kv_cache_gb_at_8k: f64,
    #[serde(rename = "kvCacheGbAt32k")]
    pub kv_cache_gb_at_32k: f64,
    #[serde(rename = "kvCacheGbAt64k")]
    pub kv_cache_gb_at_64k: f64,
}

impl Default for GgufMetadata {
    fn default() -> Self {
        Self {
            name: "Unknown GGUF Model".to_string(),
            architecture: "llama".to_string(),
            quantization: "Q4_K_M".to_string(),
            context_length: 32768,
            block_count: 32,
            file_size_gb: 4.5,
            model_vram_gb: 4.5,
            kv_cache_gb_at_8k: 1.0,
            kv_cache_gb_at_32k: 4.0,
            kv_cache_gb_at_64k: 8.0,
        }
    }
}

fn read_u32<R: Read>(r: &mut R) -> Result<u32, String> {
    let mut b = [0u8; 4];
    r.read_exact(&mut b).map_err(|e| e.to_string())?;
    Ok(u32::from_le_bytes(b))
}

fn read_u64<R: Read>(r: &mut R) -> Result<u64, String> {
    let mut b = [0u8; 8];
    r.read_exact(&mut b).map_err(|e| e.to_string())?;
    Ok(u64::from_le_bytes(b))
}

fn read_string<R: Read>(r: &mut R) -> Result<String, String> {
    let len = read_u64(r)? as usize;
    if len > 10000 {
        return Err("String length unreasonably large in GGUF header".to_string());
    }
    let mut buf = vec![0u8; len];
    r.read_exact(&mut buf).map_err(|e| e.to_string())?;
    Ok(String::from_utf8_lossy(&buf).to_string())
}

fn skip_gguf_value<R: Read>(r: &mut R, val_type: u32) -> Result<(), String> {
    match val_type {
        0 | 1 | 7 => { let mut b = [0u8; 1]; r.read_exact(&mut b).map_err(|e| e.to_string())?; }
        2 | 3 => { let mut b = [0u8; 2]; r.read_exact(&mut b).map_err(|e| e.to_string())?; }
        4 | 5 | 6 => { let mut b = [0u8; 4]; r.read_exact(&mut b).map_err(|e| e.to_string())?; }
        8 => { let _ = read_string(r)?; }
        9 => {
            let elem_type = read_u32(r)?;
            let arr_len = read_u64(r)? as usize;
            for _ in 0..arr_len {
                skip_gguf_value(r, elem_type)?;
            }
        }
        10 | 11 | 12 => { let mut b = [0u8; 8]; r.read_exact(&mut b).map_err(|e| e.to_string())?; }
        _ => return Err(format!("Unknown GGUF value type: {}", val_type)),
    }
    Ok(())
}

/// Reads binary GGUF header metadata (magic, version, KV metadata count, KV entries) safely.
pub fn parse_gguf_file<P: AsRef<Path>>(path: P) -> Result<GgufMetadata, String> {
    let p = path.as_ref();
    let mut file = File::open(p).map_err(|e| format!("Failed to open model file {:?}: {}", p, e))?;
    
    let file_size = file.metadata().map_err(|e| e.to_string())?.len();
    let file_size_gb = (file_size as f64 / (1024.0 * 1024.0 * 1024.0) * 10.0).round() / 10.0;

    let mut magic = [0u8; 4];
    file.read_exact(&mut magic).map_err(|e| format!("Failed to read magic: {}", e))?;
    if &magic != b"GGUF" {
        return Err(format!("File {:?} is not a valid GGUF file (invalid magic)", p));
    }

    let _version = read_u32(&mut file)?;
    let _tensor_count = read_u64(&mut file)?;
    let kv_count = read_u64(&mut file)?;

    let filename = p.file_stem().unwrap_or_default().to_string_lossy().to_string();

    let mut architecture = "llama".to_string();
    let mut context_length: u32 = 0;
    let mut block_count: u32 = 0;
    let mut file_type: Option<u32> = None;

    // Parse binary KV entries up to kv_count
    for _ in 0..kv_count.min(500) {
        let key = match read_string(&mut file) {
            Ok(k) => k,
            Err(_) => break,
        };
        let val_type = match read_u32(&mut file) {
            Ok(vt) => vt,
            Err(_) => break,
        };

        if key == "general.architecture" && val_type == 8 {
            if let Ok(arch) = read_string(&mut file) {
                architecture = arch;
            }
        } else if (key == "llm.context_length" || key.ends_with(".context_length")) && (val_type == 4 || val_type == 5 || val_type == 10) {
            if val_type == 4 || val_type == 5 {
                if let Ok(val) = read_u32(&mut file) { context_length = val; }
            } else if val_type == 10 {
                if let Ok(val) = read_u64(&mut file) { context_length = val as u32; }
            }
        } else if (key == "llm.block_count" || key.ends_with(".block_count")) && (val_type == 4 || val_type == 5 || val_type == 10) {
            if val_type == 4 || val_type == 5 {
                if let Ok(val) = read_u32(&mut file) { block_count = val; }
            } else if val_type == 10 {
                if let Ok(val) = read_u64(&mut file) { block_count = val as u32; }
            }
        } else if key == "general.file_type" && (val_type == 4 || val_type == 5) {
            if let Ok(val) = read_u32(&mut file) { file_type = Some(val); }
        } else {
            if skip_gguf_value(&mut file, val_type).is_err() {
                break;
            }
        }
    }

    // Fallbacks if metadata keys were missing from header
    if context_length == 0 {
        context_length = 32768;
    }
    if block_count == 0 {
        block_count = if file_size_gb > 20.0 { 64 } else if file_size_gb > 8.0 { 40 } else { 32 };
    }

    let quant = match file_type {
        Some(2) | Some(3) => "Q4_K_M".to_string(),
        Some(7) => "Q8_0".to_string(),
        _ => {
            let fn_lower = filename.to_lowercase();
            if fn_lower.contains("q8") { "Q8_0".to_string() }
            else if fn_lower.contains("q5") { "Q5_K_M".to_string() }
            else { "Q4_K_M".to_string() }
        }
    };

    let kv_dim = if block_count > 40 { 2048.0 } else { 1024.0 };
    let bytes_per_gb = 1024.0 * 1024.0 * 1024.0;

    let kv_8k = ((8192.0 * block_count as f64 * kv_dim * 4.0 / bytes_per_gb) * 10.0).round() / 10.0;
    let kv_32k = ((32768.0 * block_count as f64 * kv_dim * 4.0 / bytes_per_gb) * 10.0).round() / 10.0;
    let kv_64k = ((65536.0 * block_count as f64 * kv_dim * 4.0 / bytes_per_gb) * 10.0).round() / 10.0;

    Ok(GgufMetadata {
        name: filename,
        architecture,
        quantization: quant,
        context_length,
        block_count,
        file_size_gb,
        model_vram_gb: file_size_gb,
        kv_cache_gb_at_8k: kv_8k,
        kv_cache_gb_at_32k: kv_32k,
        kv_cache_gb_at_64k: kv_64k,
    })
}

#[tauri::command]
pub fn read_gguf_info(file_path: String) -> Result<GgufMetadata, String> {
    parse_gguf_file(file_path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn test_gguf_header_parser() {
        let temp_dir = std::env::temp_dir();
        let test_file = temp_dir.join("test_model_q4_k_m.gguf");
        {
            let mut f = File::create(&test_file).unwrap();
            f.write_all(b"GGUF").unwrap();
            f.write_all(&3u32.to_le_bytes()).unwrap();
            f.write_all(&vec![0u8; 1000]).unwrap();
        }

        let meta = parse_gguf_file(&test_file).expect("Should parse GGUF header");
        assert_eq!(meta.name, "test_model_q4_k_m");
        assert_eq!(meta.quantization, "Q4_K_M");
        assert_eq!(meta.kv_cache_gb_at_32k, 4.0);

        let _ = std::fs::remove_file(test_file);
    }
}
