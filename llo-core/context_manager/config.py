import json
import os
from pathlib import Path
from typing import Optional
from pydantic import BaseModel, Field

class ContextManagerConfig(BaseModel):
    enabled: bool = Field(default=False, description="Enable or disable context manager proxy")
    warn_threshold: float = Field(default=0.70, description="Trigger compression when token count + max_tokens >= ctx_limit * warn_threshold")
    keep_turns: int = Field(default=6, description="Number of recent chat turns to preserve uncompressed")
    proxy_port: int = Field(default=8090, description="Port for context manager proxy server")
    llama_server_url: str = Field(default="http://127.0.0.1:8080", description="Upstream llama-server base URL")
    ctx_limit: int = Field(default=0, description="Context size limit; 0 means auto-read from models-preset.ini")
    tokenizer_repo: str = Field(default="", description="Explicit HuggingFace tokenizer repository override")
    summary_max_tokens: int = Field(default=768, description="Max token limit for summarization response")
    summarize_with_model: str = Field(default="same", description="Model to use for summarization")

def load_config(config_path: Optional[str] = None) -> ContextManagerConfig:
    """Load ContextManagerConfig from llo-config.json or system appdata path."""
    if not config_path:
        appdata = os.getenv("APPDATA")
        userprofile = os.getenv("USERPROFILE")
        home = os.getenv("HOME")
        
        candidates = []
        if appdata:
            candidates.append(Path(appdata) / "LLM Manager" / "llo-config.json")
        if userprofile:
            candidates.append(Path(userprofile) / ".config" / "LLM Manager" / "llo-config.json")
        if home:
            candidates.append(Path(home) / ".config" / "LLM Manager" / "llo-config.json")
        
        # Local workspace root fallback
        workspace_root = Path(__file__).resolve().parent.parent.parent
        candidates.append(workspace_root / "llo-config.json")
        
        for cand in candidates:
            if cand.is_file():
                config_path = str(cand)
                break

    if config_path and Path(config_path).is_file():
        try:
            with open(config_path, "r", encoding="utf-8-sig") as f:
                data = json.load(f)
                cm_data = data.get("context_manager", {})
                return ContextManagerConfig(**cm_data)
        except Exception as e:
            print(f"[ContextManager] Warning: failed to parse config at {config_path}: {e}")

    return ContextManagerConfig()
