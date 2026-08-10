import hashlib
import json
import os
import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import StreamingResponse, JSONResponse
from typing import Optional, Dict, Any

try:
    from .config import load_config
    from .preset_reader import read_preset_ctx_limit
    from .context_engine import ContextEngine
except ImportError:
    from config import load_config
    from preset_reader import read_preset_ctx_limit
    from context_engine import ContextEngine

app = FastAPI(title="LLO Context Manager Proxy", version="0.1.0")

config = load_config()
engine = ContextEngine(
    warn_threshold=config.warn_threshold,
    keep_turns=config.keep_turns,
    llama_server_url=config.llama_server_url,
    summary_max_tokens=config.summary_max_tokens
)

def extract_session_id(request: Request, body: Dict[str, Any]) -> str:
    # 1. Header x-llm-session-id
    header_sid = request.headers.get("x-llm-session-id")
    if header_sid and header_sid.strip():
        return header_sid.strip()

    # 2. Body metadata.session_id
    metadata = body.get("metadata", {})
    if isinstance(metadata, dict):
        body_sid = metadata.get("session_id")
        if body_sid and isinstance(body_sid, str) and body_sid.strip():
            return body_sid.strip()

    # 3. Fallback: Hash of client_ip + user-agent
    client_ip = request.client.host if request.client else "unknown"
    user_agent = request.headers.get("user-agent", "unknown")
    raw = f"{client_ip}:{user_agent}"
    return "session_" + hashlib.md5(raw.encode("utf-8")).hexdigest()[:12]

@app.get("/health")
async def health_check():
    return {
        "status": "ok",
        "proxy": "llo-context-manager",
        "upstream_llama_server": config.llama_server_url,
        "warn_threshold": config.warn_threshold,
        "keep_turns": config.keep_turns
    }

async def forward_stream(response: httpx.Response):
    async for chunk in response.aiter_bytes():
        yield chunk

@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD"])
async def proxy_all(request: Request, path: str):
    upstream_url = f"{config.llama_server_url}/{path}"
    
    # Non-chat completions routes: direct passthrough
    if not (path.endswith("chat/completions") or path.endswith("completions")):
        async with httpx.AsyncClient(timeout=300.0) as client:
            req_content = await request.body()
            resp = await client.request(
                method=request.method,
                url=upstream_url,
                headers={k: v for k, v in request.headers.items() if k.lower() != "host"},
                content=req_content
            )
            return Response(
                content=resp.content,
                status_code=resp.status_code,
                headers=dict(resp.headers)
            )

    # Chat completion route: inspect and compress if needed
    try:
        body = await request.json()
    except Exception:
        body = {}

    messages = body.get("messages", [])
    model_alias = body.get("model", "")
    max_tokens = body.get("max_tokens", 512)
    is_stream = body.get("stream", False)

    session_id = extract_session_id(request, body)

    # Determine ctx_limit
    ctx_limit = config.ctx_limit
    if ctx_limit <= 0:
        ctx_limit = read_preset_ctx_limit(model_alias=model_alias)

    # Run context compression check
    if messages:
        rebuilt_messages = await engine.maybe_compress(
            session_id=session_id,
            messages=messages,
            max_tokens_requested=max_tokens if isinstance(max_tokens, int) else 512,
            ctx_limit=ctx_limit,
            model_alias=model_alias
        )
        body["messages"] = rebuilt_messages

    req_headers = {k: v for k, v in request.headers.items() if k.lower() not in ("host", "content-length")}
    req_headers["content-type"] = "application/json"

    client = httpx.AsyncClient(timeout=600.0)
    req = client.build_request(
        method=request.method,
        url=upstream_url,
        headers=req_headers,
        content=json.dumps(body).encode("utf-8")
    )

    resp = await client.send(req, stream=is_stream)

    if is_stream:
        return StreamingResponse(
            forward_stream(resp),
            status_code=resp.status_code,
            media_type=resp.headers.get("content-type", "text/event-stream"),
            background=None
        )
    else:
        content = await resp.aread()
        await resp.aclose()
        await client.aclose()
        return Response(
            content=content,
            status_code=resp.status_code,
            headers=dict(resp.headers)
        )
