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


def test_session_id_fallback_stable():
    request1 = MagicMock()
    request1.headers.get.side_effect = lambda k, d=None: "Mozilla/5.0" if k == "user-agent" else None
    request1.client.host = "192.168.1.100"
    request1.url.path = "/v1/chat/completions"

    request2 = MagicMock()
    request2.headers.get.side_effect = lambda k, d=None: "Mozilla/5.0" if k == "user-agent" else None
    request2.client.host = "192.168.1.100"
    request2.url.path = "/v1/chat/completions"

    request3 = MagicMock()
    request3.headers.get.side_effect = lambda k, d=None: "OtherClient/1.0" if k == "user-agent" else None
    request3.client.host = "192.168.1.200"
    request3.url.path = "/v1/chat/completions"

    sid1 = extract_session_id(request1, {})
    sid2 = extract_session_id(request2, {})
    sid3 = extract_session_id(request3, {})

    assert sid1.startswith("session_")
    assert sid2.startswith("session_")
    # Same client (IP + UA) maintains context continuity
    assert sid1 == sid2
    # Different clients get different session IDs
    assert sid1 != sid3


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
        # Failure flags and hash must be set to prevent tight retry loop
        assert session.summarization_failed is True
        assert session.last_compress_hash != ""
        # No fake summary message should be stored in session
        assert not any("Compressed History Summary" in str(m.get("content", "")) for m in session.messages)


@pytest.mark.asyncio
async def test_clamp_preserves_tool_calls():
    engine = ContextEngine()
    messages = [
        {"role": "user", "content": "Run tool"},
        {
            "role": "assistant",
            "content": "Calling tool",
            "tool_calls": [
                {
                    "id": "call_123",
                    "type": "function",
                    "function": {"name": "test_tool", "arguments": '{"key": "value"}'}
                }
            ]
        },
        {"role": "tool", "tool_call_id": "call_123", "content": "result of tool"},
        {"role": "user", "content": "Long message " * 500}
    ]
    clamped = engine._clamp_message_tokens(messages, max_allowed_tokens=50)
    # Tool call and tool response must not be corrupted or truncated
    assert clamped[1].get("tool_calls") == messages[1]["tool_calls"]
    assert clamped[2].get("content") == "result of tool"


@pytest.mark.asyncio
async def test_parse_sse_events_multiline():
    from context_manager.proxy import parse_sse_events
    import httpx

    # Test with a real httpx.Response and ByteStream (no AsyncMock) to ensure production streaming fidelity
    raw_bytes = (
        b"event: custom_event\n"
        b"data: first line\n"
        b"data: second line\n"
        b"\n"
        b": comment line to ignore\n"
        b"data: [DONE]\n"
        b"\n"
    )
    real_resp = httpx.Response(200, stream=httpx.ByteStream(raw_bytes))

    events = [e async for e in parse_sse_events(real_resp)]
    assert len(events) == 2
    assert events[0]["event"] == "custom_event"
    assert events[0]["data"] == "first line\nsecond line"
    assert events[1]["event"] == "message"
    assert events[1]["data"] == "[DONE]"


@pytest.mark.asyncio
async def test_summarizer_failure_auto_recovery_after_cooldown():
    import time
    engine = ContextEngine(keep_turns=2)
    session = SessionState(session_id="test_autorecovery_sess")

    messages = [
        {"role": "user", "content": "Turn 1"},
        {"role": "assistant", "content": "Ans 1"},
        {"role": "user", "content": "Turn 2"},
        {"role": "assistant", "content": "Ans 2"},
        {"role": "user", "content": "Turn 3"},
    ]

    # First attempt: summarizer throws error
    with patch.object(engine, "_request_summary", side_effect=RuntimeError("transient 503")):
        result1 = await engine.compress(session, messages, ctx_limit=200)
        assert session.summarization_failed is True
        assert session.summarization_failed_at is not None
        assert session.summary_block is None

    # Immediate second attempt without cooldown: remains in failure fallback
    with patch.object(engine, "_request_summary") as mock_summary:
        result2 = await engine.compress(session, messages, ctx_limit=200)
        # Should not have called _request_summary because cooldown hasn't expired and hash is same
        mock_summary.assert_not_called()
        assert session.summarization_failed is True

    # Simulate 65 seconds elapsed since failure
    session.summarization_failed_at = time.time() - 65.0

    # Third attempt after cooldown: auto-recovers and successfully generates summary
    with patch.object(engine, "_request_summary", return_value="Recovered summary block") as mock_summary:
        result3 = await engine.compress(session, messages, ctx_limit=200)
        mock_summary.assert_called_once()
        assert session.summarization_failed is False
        assert session.summarization_failed_at is None
        assert session.summary_block == "Recovered summary block"


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
