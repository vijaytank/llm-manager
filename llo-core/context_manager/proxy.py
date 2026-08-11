import hashlib
import json
import os
import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import StreamingResponse, JSONResponse
from typing import Optional, Dict, Any, List

from .config import load_config
from .preset_reader import read_preset_ctx_limit
from .context_engine import ContextEngine

app = FastAPI(title="LLO Context Manager Proxy", version="0.2.0")

config = load_config()
engine = ContextEngine(
    warn_threshold=config.warn_threshold,
    keep_turns=config.keep_turns,
    llama_server_url=config.llama_server_url,
    summary_max_tokens=config.summary_max_tokens,
    summarize_with_model=config.summarize_with_model,
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

def convert_anthropic_to_openai_messages(anthropic_body: Dict[str, Any]) -> List[Dict[str, Any]]:
    openai_messages = []
    
    # System prompt extraction
    system_param = anthropic_body.get("system")
    if system_param:
        if isinstance(system_param, str) and system_param.strip():
            openai_messages.append({"role": "system", "content": system_param})
        elif isinstance(system_param, list):
            sys_texts = []
            for block in system_param:
                if isinstance(block, str):
                    sys_texts.append(block)
                elif isinstance(block, dict) and block.get("type") == "text":
                    sys_texts.append(block.get("text", ""))
            if sys_texts:
                openai_messages.append({"role": "system", "content": "\n".join(sys_texts)})

    # Conversation turns extraction
    raw_messages = anthropic_body.get("messages", [])
    for msg in raw_messages:
        role = msg.get("role", "user")
        content = msg.get("content", "")
        
        if isinstance(content, str):
            openai_messages.append({"role": role, "content": content})
        elif isinstance(content, list):
            parts = []
            for block in content:
                if isinstance(block, str):
                    parts.append(block)
                elif isinstance(block, dict):
                    b_type = block.get("type")
                    if b_type == "text":
                        parts.append(block.get("text", ""))
                    elif b_type == "tool_use":
                        parts.append(f"[Tool Call: {block.get('name')} {json.dumps(block.get('input', {}))}]")
                    elif b_type == "tool_result":
                        res_content = block.get("content", "")
                        if isinstance(res_content, list):
                            res_content = " ".join([b.get("text", "") for b in res_content if isinstance(b, dict)])
                        parts.append(f"[Tool Result: {res_content}]")
            openai_messages.append({"role": role, "content": "\n".join(parts)})

    return openai_messages

def convert_openai_to_anthropic_response(openai_resp: Dict[str, Any], model: str) -> Dict[str, Any]:
    choices = openai_resp.get("choices", [])
    text_content = ""
    finish_reason = "end_turn"
    
    if choices:
        msg = choices[0].get("message", {})
        text_content = msg.get("content", "") or ""
        reason = choices[0].get("finish_reason")
        if reason == "length":
            finish_reason = "max_tokens"

    usage = openai_resp.get("usage", {})
    input_tokens = usage.get("prompt_tokens", 0)
    output_tokens = usage.get("completion_tokens", 0)

    return {
        "id": f"msg_{openai_resp.get('id', '12345')}",
        "type": "message",
        "role": "assistant",
        "content": [
            {
                "type": "text",
                "text": text_content
            }
        ],
        "model": model,
        "stop_reason": finish_reason,
        "stop_sequence": None,
        "usage": {
            "input_tokens": input_tokens,
            "output_tokens": output_tokens
        }
    }

async def forward_stream_anthropic(response: httpx.Response, client: httpx.AsyncClient, model: str):
    msg_id = f"msg_{os.urandom(8).hex()}"
    try:
        # Emit message_start
        yield f"event: message_start\ndata: {json.dumps({'type': 'message_start', 'message': {'id': msg_id, 'type': 'message', 'role': 'assistant', 'content': [], 'model': model, 'stop_reason': None, 'stop_sequence': None, 'usage': {'input_tokens': 0, 'output_tokens': 0}}})}\n\n".encode("utf-8")
        
        # Emit content_block_start
        yield f"event: content_block_start\ndata: {json.dumps({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}})}\n\n".encode("utf-8")

        async for line_bytes in response.aiter_lines():
            if not line_bytes:
                continue
            line = line_bytes.strip()
            if line.startswith("data:"):
                data_str = line[5:].strip()
                if data_str == "[DONE]":
                    break
                try:
                    chunk_json = json.loads(data_str)
                    choices = chunk_json.get("choices", [])
                    if choices:
                        delta = choices[0].get("delta", {})
                        content_piece = delta.get("content")
                        if content_piece:
                            delta_evt = {
                                "type": "content_block_delta",
                                "index": 0,
                                "delta": {
                                    "type": "text_delta",
                                    "text": content_piece
                                }
                            }
                            yield f"event: content_block_delta\ndata: {json.dumps(delta_evt)}\n\n".encode("utf-8")
                except Exception:
                    pass

        # Emit content_block_stop
        yield f"event: content_block_stop\ndata: {json.dumps({'type': 'content_block_stop', 'index': 0})}\n\n".encode("utf-8")

        # Emit message_delta
        yield f"event: message_delta\ndata: {json.dumps({'type': 'message_delta', 'delta': {'stop_reason': 'end_turn', 'stop_sequence': None}, 'usage': {'output_tokens': 0}})}\n\n".encode("utf-8")

        # Emit message_stop
        yield f"event: message_stop\ndata: {json.dumps({'type': 'message_stop'})}\n\n".encode("utf-8")
    finally:
        await response.aclose()
        await client.aclose()

async def forward_stream_openai(response: httpx.Response, client: httpx.AsyncClient):
    try:
        async for chunk in response.aiter_bytes():
            yield chunk
    finally:
        await response.aclose()
        await client.aclose()

@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD"])
async def proxy_all(request: Request, path: str):
    clean_path = path.lstrip("/")
    is_anthropic_messages = clean_path.startswith("v1/messages") or clean_path.endswith("messages")
    is_openai_chat = clean_path.endswith("chat/completions") or clean_path.endswith("completions")

    # Handle Anthropic count_tokens endpoint
    if clean_path.endswith("count_tokens"):
        try:
            body = await request.json()
        except Exception:
            body = {}
        messages = convert_anthropic_to_openai_messages(body)
        model_alias = body.get("model", "")
        token_count = engine.count_tokens_messages(messages, model_alias=model_alias)
        return JSONResponse({"input_tokens": token_count})

    # Non-chat routes: direct passthrough
    if not (is_anthropic_messages or is_openai_chat):
        upstream_url = f"{config.llama_server_url}/{clean_path}"
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

    # Inspect request body
    try:
        body = await request.json()
    except Exception:
        body = {}

    model_alias = body.get("model", "")
    max_tokens = body.get("max_tokens", 512)
    is_stream = body.get("stream", False)
    session_id = extract_session_id(request, body)

    # Convert messages to normalized format for ContextEngine
    if is_anthropic_messages:
        messages = convert_anthropic_to_openai_messages(body)
    else:
        messages = body.get("messages", [])

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
    else:
        rebuilt_messages = messages

    # Target upstream OpenAI endpoint on llama-server
    upstream_url = f"{config.llama_server_url}/v1/chat/completions"
    upstream_body = {
        "model": model_alias,
        "messages": rebuilt_messages,
        "max_tokens": max_tokens if isinstance(max_tokens, int) else 512,
        "stream": is_stream
    }
    if "temperature" in body:
        upstream_body["temperature"] = body["temperature"]
    if "top_p" in body:
        upstream_body["top_p"] = body["top_p"]

    req_headers = {k: v for k, v in request.headers.items() if k.lower() not in ("host", "content-length")}
    req_headers["content-type"] = "application/json"

    client = httpx.AsyncClient(timeout=600.0)
    req = client.build_request(
        method="POST",
        url=upstream_url,
        headers=req_headers,
        content=json.dumps(upstream_body).encode("utf-8")
    )

    resp = await client.send(req, stream=is_stream)

    if is_stream:
        if is_anthropic_messages:
            return StreamingResponse(
                forward_stream_anthropic(resp, client, model_alias),
                status_code=resp.status_code,
                media_type="text/event-stream"
            )
        else:
            return StreamingResponse(
                forward_stream_openai(resp, client),
                status_code=resp.status_code,
                media_type=resp.headers.get("content-type", "text/event-stream")
            )
    else:
        content_bytes = await resp.aread()
        await resp.aclose()
        await client.aclose()
        
        if is_anthropic_messages and resp.status_code == 200:
            try:
                openai_json = json.loads(content_bytes.decode("utf-8"))
                anthropic_resp = convert_openai_to_anthropic_response(openai_json, model_alias)
                return JSONResponse(anthropic_resp, status_code=200)
            except Exception:
                pass

        return Response(
            content=content_bytes,
            status_code=resp.status_code,
            headers=dict(resp.headers)
        )
