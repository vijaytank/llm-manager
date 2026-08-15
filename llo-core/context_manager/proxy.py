import hashlib
import json
import os
import uuid
import httpx
from contextlib import asynccontextmanager
from fastapi import FastAPI, Request, Response
from fastapi.responses import StreamingResponse, JSONResponse
from typing import Optional, Dict, Any, List

from .config import load_config, ContextManagerConfig
from .preset_reader import read_preset_ctx_limit
from .context_engine import ContextEngine


@asynccontextmanager
async def lifespan(app: FastAPI):
    cfg = load_config()
    eng = ContextEngine(
        warn_threshold=cfg.warn_threshold,
        keep_turns=cfg.keep_turns,
        llama_server_url=cfg.llama_server_url,
        summary_max_tokens=cfg.summary_max_tokens,
        summarize_with_model=cfg.summarize_with_model,
    )
    limits = httpx.Limits(max_connections=100, max_keepalive_connections=20)
    http_client = httpx.AsyncClient(limits=limits, timeout=600.0)
    app.state.config = cfg
    app.state.engine = eng
    app.state.http_client = http_client
    try:
        yield
    finally:
        await http_client.aclose()

app = FastAPI(title="LLO Context Manager Proxy", version="0.2.0", lifespan=lifespan)

def get_config(request: Optional[Request] = None) -> ContextManagerConfig:
    if request and hasattr(request.app.state, "config"):
        return request.app.state.config
    raise RuntimeError("Config not initialized — proxy called outside request context")

def get_engine(request: Optional[Request] = None) -> ContextEngine:
    if request and hasattr(request.app.state, "engine"):
        return request.app.state.engine
    raise RuntimeError("Engine not initialized — proxy called outside request context")

def get_http_client(request: Optional[Request] = None) -> httpx.AsyncClient:
    if request and hasattr(request.app.state, "http_client"):
        return request.app.state.http_client
    raise RuntimeError("HTTP client not initialized — ensure lifespan is running")

def extract_session_id(request: Request, body: Dict[str, Any]) -> str:
    # 1. Header x-llm-session-id or x-session-id
    for key in ("x-llm-session-id", "x-session-id"):
        sid = request.headers.get(key)
        if sid and sid.strip():
            return sid.strip()

    # 2. Body metadata.session_id
    metadata = body.get("metadata", {})
    if isinstance(metadata, dict):
        body_sid = metadata.get("session_id")
        if body_sid and isinstance(body_sid, str) and body_sid.strip():
            return body_sid.strip()

    # 3. Request header x-request-id
    req_id = request.headers.get("x-request-id")
    if req_id and req_id.strip():
        return f"session_{req_id.strip()}"

    # 4. Fallback: Hash of client_ip + user-agent + path
    client_ip = request.client.host if request.client else "unknown"
    user_agent = request.headers.get("user-agent", "unknown")
    raw = f"{client_ip}:{user_agent}:{request.url.path}"
    return "session_" + hashlib.md5(raw.encode("utf-8")).hexdigest()[:12]

@app.get("/health")
async def health_check(request: Request):
    cfg = get_config(request)
    return {
        "status": "ok",
        "proxy": "llo-context-manager",
        "upstream_llama_server": cfg.llama_server_url,
        "warn_threshold": cfg.warn_threshold,
        "keep_turns": cfg.keep_turns
    }

def convert_anthropic_tools_to_openai(anthropic_tools: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    openai_tools = []
    for tool in anthropic_tools:
        if not isinstance(tool, dict):
            continue
        name = tool.get("name")
        if not name:
            continue
        description = tool.get("description", "")
        parameters = tool.get("input_schema") or tool.get("parameters") or {"type": "object", "properties": {}}
        openai_tools.append({
            "type": "function",
            "function": {
                "name": name,
                "description": description,
                "parameters": parameters
            }
        })
    return openai_tools

def convert_anthropic_tool_choice_to_openai(tool_choice: Any) -> Any:
    if isinstance(tool_choice, dict):
        tc_type = tool_choice.get("type")
        if tc_type == "auto":
            return "auto"
        elif tc_type == "any":
            return "required"
        elif tc_type == "tool":
            name = tool_choice.get("name")
            if name:
                return {"type": "function", "function": {"name": name}}
    elif isinstance(tool_choice, str):
        return tool_choice
    return None

def normalize_system_messages(messages: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    system_contents = []
    non_system_messages = []
    
    for msg in messages:
        if not isinstance(msg, dict):
            continue
        if msg.get("role") == "system":
            content = msg.get("content", "")
            if content:
                system_contents.append(str(content))
        else:
            non_system_messages.append(msg)
            
    if system_contents:
        combined_system = {"role": "system", "content": "\n\n".join(system_contents)}
        return [combined_system] + non_system_messages
    return non_system_messages

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
            text_parts = []
            tool_calls = []
            tool_results = []

            for block in content:
                if isinstance(block, str):
                    text_parts.append(block)
                elif isinstance(block, dict):
                    b_type = block.get("type")
                    if b_type == "text":
                        text_parts.append(block.get("text", ""))
                    elif b_type == "tool_use":
                        t_id = block.get("id") or f"toolu_{uuid.uuid4().hex[:16]}"
                        t_name = block.get("name", "")
                        t_input = block.get("input", {})
                        tool_calls.append({
                            "id": t_id,
                            "type": "function",
                            "function": {
                                "name": t_name,
                                "arguments": json.dumps(t_input) if isinstance(t_input, dict) else str(t_input)
                            }
                        })
                    elif b_type == "tool_result":
                        res_id = block.get("tool_use_id", "")
                        res_content = block.get("content", "")
                        if isinstance(res_content, list):
                            res_content = "\n".join([
                                b.get("text", "") for b in res_content if isinstance(b, dict) and b.get("type") == "text"
                            ])
                        tool_results.append({
                            "role": "tool",
                            "tool_call_id": res_id,
                            "content": str(res_content)
                        })
                    else:
                        text_parts.append(f"[Unsupported content block type: {b_type}]")

            if role == "assistant":
                o_msg: Dict[str, Any] = {
                    "role": "assistant",
                    "content": "\n".join(text_parts) if text_parts else ""
                }
                if tool_calls:
                    o_msg["tool_calls"] = tool_calls
                openai_messages.append(o_msg)
            elif tool_results:
                if text_parts:
                    openai_messages.append({"role": role, "content": "\n".join(text_parts)})
                for tr in tool_results:
                    openai_messages.append(tr)
            else:
                openai_messages.append({"role": role, "content": "\n".join(text_parts)})

    return openai_messages

def convert_openai_to_anthropic_response(
    openai_resp: Dict[str, Any],
    model: str,
    engine_instance: Optional[ContextEngine] = None,
    messages: Optional[List[Dict[str, Any]]] = None
) -> Dict[str, Any]:
    choices = openai_resp.get("choices", [])
    text_content = ""
    finish_reason = "end_turn"
    content_blocks = []
    
    if choices:
        choice0 = choices[0]
        msg = choice0.get("message", {})
        text_content = msg.get("content", "") or ""
        reason = choice0.get("finish_reason")

        if text_content:
            content_blocks.append({
                "type": "text",
                "text": text_content
            })

        tool_calls = msg.get("tool_calls")
        if tool_calls and isinstance(tool_calls, list):
            finish_reason = "tool_use"
            for tc in tool_calls:
                if not isinstance(tc, dict):
                    continue
                tc_id = tc.get("id") or f"toolu_{uuid.uuid4().hex[:16]}"
                fn = tc.get("function", {})
                fn_name = fn.get("name", "")
                fn_args_raw = fn.get("arguments", "{}")
                
                try:
                    if isinstance(fn_args_raw, dict):
                        input_dict = fn_args_raw
                    else:
                        input_dict = json.loads(fn_args_raw)
                except Exception:
                    input_dict = {}

                content_blocks.append({
                    "type": "tool_use",
                    "id": tc_id,
                    "name": fn_name,
                    "input": input_dict
                })
        elif reason == "length":
            finish_reason = "max_tokens"
        elif reason in ("tool_calls", "function_call"):
            finish_reason = "tool_use"

    if not content_blocks:
        content_blocks.append({
            "type": "text",
            "text": text_content
        })

    usage = openai_resp.get("usage", {})
    input_tokens = usage.get("prompt_tokens", 0)
    output_tokens = usage.get("completion_tokens", 0)

    # Use the provided engine instance for token counting, or fall back to
    # a lightweight TokenizerCache heuristic (avoids constructing a bare ContextEngine
    # with no config when called outside a request context).
    if engine_instance is not None:
        eng = engine_instance
        if input_tokens == 0 and messages:
            input_tokens = eng.count_tokens_messages(messages, model)
        if output_tokens == 0:
            output_tokens = eng.tokenizer_cache.count_tokens(text_content, model)
    else:
        from .tokenizer_cache import TokenizerCache
        _tc = TokenizerCache()
        if input_tokens == 0 and messages:
            # Character heuristic: ~4 chars per token across all messages
            raw_text = " ".join(str(m.get("content", "")) for m in messages)
            input_tokens = max(1, len(raw_text) // 4)
        if output_tokens == 0:
            output_tokens = _tc.count_tokens(text_content, model)

    raw_id = str(openai_resp.get("id", ""))
    msg_id = raw_id if raw_id.startswith("msg_") else (f"msg_{raw_id}" if raw_id else f"msg_{uuid.uuid4().hex[:16]}")

    return {
        "id": msg_id,
        "type": "message",
        "role": "assistant",
        "content": content_blocks,
        "model": model,
        "stop_reason": finish_reason,
        "stop_sequence": None,
        "usage": {
            "input_tokens": input_tokens,
            "output_tokens": max(1, output_tokens)
        }
    }

async def forward_stream_anthropic(
    response: httpx.Response,
    client: httpx.AsyncClient,
    model: str,
    input_tokens: int = 0,
    engine_instance: Optional[ContextEngine] = None,
    is_owned_client: bool = False
):
    msg_id = f"msg_{uuid.uuid4().hex[:16]}"
    output_token_count = 0
    # Use the provided engine instance for token counting, or fall back to
    # a lightweight TokenizerCache heuristic (avoids constructing a bare ContextEngine
    # with no config when called outside a request context).
    if engine_instance is not None:
        eng: Optional[ContextEngine] = engine_instance
    else:
        eng = None

    current_block_type = None
    current_block_index = -1
    active_tool_calls: Dict[int, Dict[str, Any]] = {}
    next_block_index = 0
    final_stop_reason = "end_turn"
    has_emitted_any_block = False

    try:
        yield f"event: message_start\ndata: {json.dumps({'type': 'message_start', 'message': {'id': msg_id, 'type': 'message', 'role': 'assistant', 'content': [], 'model': model, 'stop_reason': None, 'stop_sequence': None, 'usage': {'input_tokens': input_tokens, 'output_tokens': 1}}})}\n\n".encode("utf-8")

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
                        choice0 = choices[0]
                        delta = choice0.get("delta", {})
                        finish_reason = choice0.get("finish_reason")

                        if finish_reason:
                            if finish_reason in ("tool_calls", "function_call"):
                                final_stop_reason = "tool_use"
                            elif finish_reason == "length":
                                final_stop_reason = "max_tokens"

                        # 1. Text content delta
                        content_piece = delta.get("content")
                        if content_piece:
                            output_token_count += eng.tokenizer_cache.count_tokens(content_piece, model) if eng is not None else max(1, len(content_piece) // 4)
                            if current_block_type != "text":
                                if current_block_type is not None:
                                    yield f"event: content_block_stop\ndata: {json.dumps({'type': 'content_block_stop', 'index': current_block_index})}\n\n".encode("utf-8")
                                current_block_index = next_block_index
                                next_block_index += 1
                                current_block_type = "text"
                                has_emitted_any_block = True
                                yield f"event: content_block_start\ndata: {json.dumps({'type': 'content_block_start', 'index': current_block_index, 'content_block': {'type': 'text', 'text': ''}})}\n\n".encode("utf-8")

                            delta_evt = {
                                "type": "content_block_delta",
                                "index": current_block_index,
                                "delta": {
                                    "type": "text_delta",
                                    "text": content_piece
                                }
                            }
                            yield f"event: content_block_delta\ndata: {json.dumps(delta_evt)}\n\n".encode("utf-8")

                        # 2. Tool calls delta
                        tool_calls = delta.get("tool_calls")
                        if tool_calls and isinstance(tool_calls, list):
                            final_stop_reason = "tool_use"
                            for tc in tool_calls:
                                tc_idx = tc.get("index", 0)
                                fn_data = tc.get("function", {})
                                tc_id = tc.get("id")
                                fn_name = fn_data.get("name")
                                fn_args = fn_data.get("arguments")

                                if tc_idx not in active_tool_calls:
                                    if current_block_type is not None:
                                        yield f"event: content_block_stop\ndata: {json.dumps({'type': 'content_block_stop', 'index': current_block_index})}\n\n".encode("utf-8")

                                    anthropic_idx = next_block_index
                                    next_block_index += 1
                                    tool_id = tc_id or f"toolu_{uuid.uuid4().hex[:16]}"
                                    tool_name = fn_name or "tool"
                                    
                                    active_tool_calls[tc_idx] = {
                                        "id": tool_id,
                                        "name": tool_name,
                                        "anthropic_index": anthropic_idx
                                    }
                                    current_block_index = anthropic_idx
                                    current_block_type = "tool_use"
                                    has_emitted_any_block = True

                                    yield f"event: content_block_start\ndata: {json.dumps({'type': 'content_block_start', 'index': anthropic_idx, 'content_block': {'type': 'tool_use', 'id': tool_id, 'name': tool_name, 'input': {}}})}\n\n".encode("utf-8")

                                info = active_tool_calls[tc_idx]
                                if fn_args:
                                    tok_count = eng.tokenizer_cache.count_tokens(fn_args, model) if eng is not None else max(1, len(fn_args) // 4)
                                    output_token_count += tok_count
                                    delta_evt = {
                                        "type": "content_block_delta",
                                        "index": info["anthropic_index"],
                                        "delta": {
                                            "type": "input_json_delta",
                                            "partial_json": fn_args
                                        }
                                    }
                                    yield f"event: content_block_delta\ndata: {json.dumps(delta_evt)}\n\n".encode("utf-8")
                except Exception:
                    pass

        if not has_emitted_any_block:
            yield f"event: content_block_start\ndata: {json.dumps({'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}})}\n\n".encode("utf-8")
            yield f"event: content_block_stop\ndata: {json.dumps({'type': 'content_block_stop', 'index': 0})}\n\n".encode("utf-8")
        elif current_block_type is not None:
            yield f"event: content_block_stop\ndata: {json.dumps({'type': 'content_block_stop', 'index': current_block_index})}\n\n".encode("utf-8")

        yield f"event: message_delta\ndata: {json.dumps({'type': 'message_delta', 'delta': {'stop_reason': final_stop_reason, 'stop_sequence': None}, 'usage': {'output_tokens': max(1, output_token_count)}})}\n\n".encode("utf-8")
        yield f"event: message_stop\ndata: {json.dumps({'type': 'message_stop'})}\n\n".encode("utf-8")
    finally:
        await response.aclose()
        if is_owned_client:
            await client.aclose()

async def forward_stream_openai(response: httpx.Response, client: httpx.AsyncClient, is_owned_client: bool = False):
    try:
        async for chunk in response.aiter_bytes():
            yield chunk
    finally:
        await response.aclose()
        if is_owned_client:
            await client.aclose()

@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "HEAD"])
async def proxy_all(request: Request, path: str):
    cfg = get_config(request)
    eng = get_engine(request)

    clean_path = path.lstrip("/")
    is_anthropic_messages = (
        clean_path == "v1/messages" or
        clean_path.startswith("v1/messages?") or
        clean_path.startswith("v1/messages/")
    )
    is_openai_chat = clean_path.endswith("chat/completions")

    # Handle Anthropic count_tokens endpoint
    if clean_path.endswith("count_tokens"):
        try:
            body = await request.json()
        except Exception:
            body = {}
        messages = convert_anthropic_to_openai_messages(body)
        model_alias = body.get("model", "")
        token_count = eng.count_tokens_messages(messages, model_alias=model_alias)
        return JSONResponse({"input_tokens": token_count})

    client = get_http_client(request)
    is_owned_client = not hasattr(request.app.state, "http_client")

    # Non-chat routes or when context manager is disabled: direct passthrough
    if not (is_anthropic_messages or is_openai_chat) or not cfg.enabled:
        upstream_url = f"{cfg.llama_server_url}/{clean_path}"
        try:
            req_content = await request.body()
            req = client.build_request(
                method=request.method,
                url=upstream_url,
                headers={k: v for k, v in request.headers.items() if k.lower() != "host"},
                content=req_content
            )
            resp = await client.send(req, stream=True)
        except Exception:
            if is_owned_client:
                await client.aclose()
            raise

        if resp.headers.get("content-type", "").startswith("text/event-stream"):
            return StreamingResponse(
                forward_stream_openai(resp, client, is_owned_client=is_owned_client),
                status_code=resp.status_code,
                media_type=resp.headers.get("content-type", "text/event-stream")
            )
        else:
            content_bytes = await resp.aread()
            await resp.aclose()
            if is_owned_client:
                await client.aclose()
            return Response(content=content_bytes, status_code=resp.status_code, headers=dict(resp.headers))

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

    # Calculate input prompt tokens for usage tracking
    input_tokens = eng.count_tokens_messages(messages, model_alias)

    # Determine ctx_limit
    ctx_limit = cfg.ctx_limit
    if ctx_limit <= 0:
        ctx_limit = read_preset_ctx_limit(model_alias=model_alias)

    # Run context compression check
    if messages:
        rebuilt_messages = await eng.maybe_compress(
            session_id=session_id,
            messages=messages,
            max_tokens_requested=max_tokens if isinstance(max_tokens, int) else 512,
            ctx_limit=ctx_limit,
            model_alias=model_alias,
            http_client=client
        )
    else:
        rebuilt_messages = messages

    # Ensure system messages are combined into a single system prompt at index 0 for Jinja templates
    rebuilt_messages = normalize_system_messages(rebuilt_messages)

    # Route Anthropic requests to /v1/chat/completions, otherwise preserve path
    if is_anthropic_messages:
        upstream_url = f"{cfg.llama_server_url}/v1/chat/completions"
    else:
        upstream_url = f"{cfg.llama_server_url}/{clean_path}"

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

    # Convert and pass tools/tool_choice if present
    tools = body.get("tools")
    if tools and isinstance(tools, list):
        upstream_body["tools"] = convert_anthropic_tools_to_openai(tools)

    tool_choice = body.get("tool_choice")
    if tool_choice:
        converted_tc = convert_anthropic_tool_choice_to_openai(tool_choice)
        if converted_tc:
            upstream_body["tool_choice"] = converted_tc

    req_headers = {k: v for k, v in request.headers.items() if k.lower() not in ("host", "content-length")}
    req_headers["content-type"] = "application/json"

    try:
        req = client.build_request(
            method="POST",
            url=upstream_url,
            headers=req_headers,
            content=json.dumps(upstream_body).encode("utf-8")
        )
        resp = await client.send(req, stream=is_stream)
    except Exception:
        if is_owned_client:
            await client.aclose()
        raise

    if resp.status_code != 200:
        content_bytes = await resp.aread()
        await resp.aclose()
        if is_owned_client:
            await client.aclose()

        err_text = content_bytes.decode("utf-8", errors="replace")
        if is_anthropic_messages:
            return JSONResponse(
                {
                    "type": "error",
                    "error": {
                        "type": "invalid_request_error",
                        "message": f"Upstream llama-server returned error ({resp.status_code}): {err_text}"
                    }
                },
                status_code=resp.status_code
            )
        else:
            return Response(
                content=content_bytes,
                status_code=resp.status_code,
                headers=dict(resp.headers)
            )

    if is_stream:
        if is_anthropic_messages:
            return StreamingResponse(
                forward_stream_anthropic(resp, client, model_alias, input_tokens, eng, is_owned_client=is_owned_client),
                status_code=200,
                media_type="text/event-stream"
            )
        else:
            return StreamingResponse(
                forward_stream_openai(resp, client, is_owned_client=is_owned_client),
                status_code=200,
                media_type=resp.headers.get("content-type", "text/event-stream")
            )
    else:
        content_bytes = await resp.aread()
        await resp.aclose()
        if is_owned_client:
            await client.aclose()
        
        if is_anthropic_messages:
            try:
                openai_json = json.loads(content_bytes.decode("utf-8"))
                anthropic_resp = convert_openai_to_anthropic_response(openai_json, model_alias, eng, messages)
                return JSONResponse(anthropic_resp, status_code=200)
            except Exception:
                pass

        return Response(
            content=content_bytes,
            status_code=resp.status_code,
            headers=dict(resp.headers)
        )

