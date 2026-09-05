import pytest
import asyncio
from unittest.mock import MagicMock, AsyncMock, patch
from fastapi.testclient import TestClient

from context_manager.proxy import app, extract_session_id
from context_manager.context_engine import ContextEngine, SessionState


def test_malformed_json_returns_400():
    with TestClient(app) as client:
        client.app.state.config.enabled = True
        # 1. Invalid JSON body to chat/completions
        resp = client.post(
            "/v1/chat/completions",
            content="this is not valid json {{{",
            headers={"Content-Type": "application/json"}
        )
        assert resp.status_code == 400
        data = resp.json()
        assert "error" in data
        assert "Invalid JSON in request body" in data["error"]["message"]

        # 2. Invalid JSON body to count_tokens
        resp_tokens = client.post(
            "/v1/messages/count_tokens",
            content="{invalid-json-tokens:",
            headers={"Content-Type": "application/json"}
        )
        assert resp_tokens.status_code == 400
        data_tokens = resp_tokens.json()
        assert "error" in data_tokens
        assert "Invalid JSON in request body" in data_tokens["error"]["message"]


def test_session_id_uuid_fallback():
    request1 = MagicMock()
    request1.headers.get.return_value = None
    request1.client.host = "192.168.1.100"
    request1.url.path = "/v1/chat/completions"

    request2 = MagicMock()
    request2.headers.get.return_value = None
    request2.client.host = "192.168.1.100"
    request2.url.path = "/v1/chat/completions"

    sid1 = extract_session_id(request1, {})
    sid2 = extract_session_id(request2, {})

    assert sid1.startswith("session_")
    assert sid2.startswith("session_")
    # Must NOT collide under NAT / same IP
    assert sid1 != sid2


@pytest.mark.asyncio
async def test_summarizer_failure_returns_uncorrupted_messages():
    engine = ContextEngine(keep_turns=2)
    session = SessionState(session_id="test_robust_sess")
    
    # 5 conversation turns (exceeding keep_turns=2)
    messages = [
        {"role": "user", "content": "Hello 1"},
        {"role": "assistant", "content": "Hi 1"},
        {"role": "user", "content": "Hello 2"},
        {"role": "assistant", "content": "Hi 2"},
        {"role": "user", "content": "Hello 3"},
    ]

    # Mock _request_summary to fail with RuntimeError
    with patch.object(engine, "_request_summary", side_effect=RuntimeError("llama-server 500 internal error")):
        result = await engine.compress(session, messages, ctx_limit=100)
        
        # Result should fall back to clamped messages
        assert len(result) > 0
        # Crucially: session.summary_block must NOT contain stub strings
        assert session.summary_block is None
        # session.summary_up_to_turn should not have advanced
        assert session.summary_up_to_turn == 0
        # No fake summary message should be stored in session
        assert not any("Compressed History Summary" in str(m.get("content", "")) for m in session.messages)


def test_tokenizer_repo_override_propagated():
    engine = ContextEngine(tokenizer_repo_override="custom/repo-name")
    messages = [{"role": "user", "content": "Test prompt text"}]
    
    with patch.object(engine.tokenizer_cache, "count_tokens", return_value=5) as mock_count:
        count = engine.count_tokens_messages(messages, model_alias="test-model")
        assert count == 5 + 4  # 5 tokens + 4 per-message overhead
        mock_count.assert_called_once_with("Test prompt text", "test-model", override_repo="custom/repo-name")


@pytest.mark.asyncio
async def test_background_eviction_lifecycle():
    engine = ContextEngine()
    assert engine._eviction_task is None

    engine.start_background_tasks()
    assert engine._running is True
    assert engine._eviction_task is not None
    assert not engine._eviction_task.done()

    await engine.stop_background_tasks()
    assert engine._running is False
    assert engine._eviction_task is None
