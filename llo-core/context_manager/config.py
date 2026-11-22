import json
import os
import logging
from pathlib import Path
from typing import Optional
from pydantic import BaseModel, Field

logger = logging.getLogger("context_manager.config")

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
    eviction_interval_sec: int = Field(default=300, description="How often to evict stale sessions (seconds)")
    session_ttl_sec: int = Field(default=86400, description="Session inactivity TTL (seconds)")
    # Connection pool settings
    http_max_connections: int = Field(default=100, description="Max concurrent connections in HTTP pool")
    http_max_keepalive: int = Field(default=20, description="Max keepalive connections in HTTP pool")
    http_timeout_sec: int = Field(default=600, description="HTTP request timeout in seconds")
    # Prometheus metrics
    metrics_enabled: bool = Field(default=True, description="Enable Prometheus metrics endpoint")
    # TLS settings (for local HTTPS)
    tls_enabled: bool = Field(default=False, description="Enable TLS/HTTPS for proxy")
    tls_cert_path: str = Field(default="", description="Path to TLS certificate file (PEM)")
    tls_key_path: str = Field(default="", description="Path to TLS private key file (PEM)")
    # Rate limiting
    rate_limit_enabled: bool = Field(default=True, description="Enable rate limiting")
    rate_limit_requests: int = Field(default=100, description="Max requests per window")
    rate_limit_window_sec: int = Field(default=60, description="Rate limit window in seconds")
    # Session ID validation
    session_id_min_length: int = Field(default=8, description="Minimum session ID length")
    session_id_max_length: int = Field(default=64, description="Maximum session ID length")
    session_id_allowed_chars: str = Field(default="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_", description="Allowed characters in session ID")

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
            err_msg = f"[ContextManager] Error: failed to parse config at {config_path}: {e}"
            logger.error(err_msg)
            if os.getenv("LLM_ENV") == "production" or os.getenv("ENVIRONMENT") == "production":
                raise RuntimeError(err_msg)

    return ContextManagerConfig()
