import json
import pytest
import respx
import httpx
from fastapi.testclient import TestClient

from context_manager.proxy import app


@respx.mock
def test_health_endpoint():
    with TestClient(app) as client:
        resp = client.get("/health")
        assert resp.status_code == 200
        data = resp.json()
        assert data["status"] == "ok"
        assert data["proxy"] == "llo-context-manager"


@respx.mock
def test_direct_passthrough_when_disabled():
    with TestClient(app) as client:
        client.app.state.config.enabled = False
        upstream_url = f"{client.app.state.config.llama_server_url}/v1/models"
        
        mock_route = respx.get(upstream_url).mock(
            return_value=httpx.Response(200, json={"object": "list", "data": [{"id": "test-model"}]})
        )

        resp = client.get("/v1/models")
        assert resp.status_code == 200
        assert mock_route.called
        assert resp.json()["data"][0]["id"] == "test-model"


@respx.mock
def test_anthropic_to_openai_roundtrip():
    with TestClient(app) as client:
        client.app.state.config.enabled = True
        upstream_url = f"{client.app.state.config.llama_server_url}/v1/chat/completions"

        # Upstream llama-server returns OpenAI format
        mock_route = respx.post(upstream_url).mock(
            return_value=httpx.Response(
                200,
                json={
                    "id": "chatcmpl-123",
                    "object": "chat.completion",
                    "choices": [
                        {
                            "index": 0,
                            "message": {
                                "role": "assistant",
                                "content": "Hello! I am your local model."
                            },
                            "finish_reason": "stop"
                        }
                    ],
                    "usage": {
                        "prompt_tokens": 12,
                        "completion_tokens": 8,
                        "total_tokens": 20
                    }
                }
            )
        )

        anthropic_payload = {
            "model": "claude-3-5-sonnet",
            "max_tokens": 100,
            "messages": [
                {"role": "user", "content": "Say hello!"}
            ]
        }

        resp = client.post(
            "/v1/messages",
            json=anthropic_payload,
            headers={"x-api-key": "local-key"}
        )

        assert resp.status_code == 200
        assert mock_route.called
        data = resp.json()
        assert data["type"] == "message"
        assert data["role"] == "assistant"
        assert len(data["content"]) == 1
        assert data["content"][0]["type"] == "text"
        assert data["content"][0]["text"] == "Hello! I am your local model."


@respx.mock
def test_openai_chat_roundtrip():
    with TestClient(app) as client:
        client.app.state.config.enabled = True
        upstream_url = f"{client.app.state.config.llama_server_url}/v1/chat/completions"

        mock_route = respx.post(upstream_url).mock(
            return_value=httpx.Response(
                200,
                json={
                    "id": "chatcmpl-999",
                    "object": "chat.completion",
                    "choices": [
                        {
                            "index": 0,
                            "message": {
                                "role": "assistant",
                                "content": "OpenAI completion response."
                            },
                            "finish_reason": "stop"
                        }
                    ]
                }
            )
        )

        openai_payload = {
            "model": "local-gguf",
            "messages": [
                {"role": "user", "content": "Hello OpenAI route!"}
            ]
        }

        resp = client.post("/v1/chat/completions", json=openai_payload)
        assert resp.status_code == 200
        assert mock_route.called
        data = resp.json()
        assert data["choices"][0]["message"]["content"] == "OpenAI completion response."


@respx.mock
def test_compression_triggered_when_threshold_exceeded():
    with TestClient(app) as client:
        client.app.state.config.enabled = True
        client.app.state.config.warn_threshold = 0.5
        client.app.state.config.keep_turns = 2
        upstream_url = f"{client.app.state.config.llama_server_url}/v1/chat/completions"

        # 1. Mock summarizer call
        summarizer_route = respx.post(upstream_url).mock(
            return_value=httpx.Response(
                200,
                json={
                    "choices": [
                        {
                            "message": {
                                "role": "assistant",
                                "content": "- User asked several questions\n- Assistant answered them."
                            }
                        }
                    ]
                }
            )
        )

        # Build enough turns to trigger compression with small ctx_limit
        large_messages = [
            {"role": "user", "content": f"Turn question {i} " * 20}
            for i in range(10)
        ]

        payload = {
            "model": "qwen2.5-coder",
            "max_tokens": 100,
            "messages": large_messages
        }

        # First request triggers compression
        resp = client.post(
            "/v1/chat/completions",
            json=payload,
            headers={"x-llm-session-id": "roundtrip-session-test"}
        )
        assert resp.status_code == 200
        assert summarizer_route.called
