import configparser
import os
from pathlib import Path
from typing import Optional

def read_preset_ctx_limit(preset_path: Optional[str] = None, model_alias: Optional[str] = None) -> int:
    """Reads ctx-size for model_alias from models-preset.ini, falling back to [*] section or 65536."""
    if not preset_path:
        appdata = os.getenv("APPDATA")
        userprofile = os.getenv("USERPROFILE")
        home = os.getenv("HOME")
        
        candidates = []
        if appdata:
            candidates.append(Path(appdata) / "LLM Manager" / "models-preset.ini")
        if userprofile:
            candidates.append(Path(userprofile) / ".config" / "LLM Manager" / "models-preset.ini")
        if home:
            candidates.append(Path(home) / ".config" / "LLM Manager" / "models-preset.ini")
            
        workspace_root = Path(__file__).resolve().parent.parent.parent
        candidates.append(workspace_root / "models-preset.ini")

        for cand in candidates:
            if cand.is_file():
                preset_path = str(cand)
                break

    if not preset_path or not Path(preset_path).is_file():
        return 65536

    config = configparser.ConfigParser()
    try:
        config.read(preset_path, encoding="utf-8-sig")
        
        # 1. Check exact model section if provided
        if model_alias and config.has_section(model_alias):
            if config.has_option(model_alias, "ctx-size"):
                return config.getint(model_alias, "ctx-size")
            if config.has_option(model_alias, "ctx_size"):
                return config.getint(model_alias, "ctx_size")

        # 2. Check normalized alias matches in sections
        if model_alias:
            norm_target = model_alias.lower().replace("_", "-")
            for sec in config.sections():
                if sec.lower().replace("_", "-") == norm_target:
                    if config.has_option(sec, "ctx-size"):
                        return config.getint(sec, "ctx-size")
                    if config.has_option(sec, "ctx_size"):
                        return config.getint(sec, "ctx_size")

        # 3. Check fallback section [*] or [DEFAULT]
        if config.has_section("*") and config.has_option("*", "fit-ctx"):
            return config.getint("*", "fit-ctx")

    except Exception as e:
        print(f"[ContextManager] Error reading preset INI file {preset_path}: {e}")

    return 65536
