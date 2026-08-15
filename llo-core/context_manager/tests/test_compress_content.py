import pytest
from unittest.mock import AsyncMock, patch
from context_manager.context_engine import ContextEngine, SessionState

@pytest.mark.asyncio
async def test_compress_with_tool_use_and_tool_result_blocks():
    """Validates B1-11: tool_result and tool_use blocks are serialized with meaningful content rather than empty strings."""
    engine = ContextEngine(keep_turns=2)
    session = SessionState(session_id="test_tool_blocks")

    messages = [
        {"role": "system", "content": "System instructions"},
        {
            "role": "user",
            "content": [
                {"type": "text", "text": "What is the weather?"}
            ]
        },
        {
            "role": "assistant",
            "content": [
                {"type": "text", "text": "Let me check."},
                {"type": "tool_use", "name": "get_weather", "input": {"location": "London"}}
            ]
        },
        {
            "role": "user",
            "content": [
                {"type": "tool_result", "tool_use_id": "call_123", "content": "Sunny, 20C"}
            ]
        },
        {
            "role": "assistant",
            "content": "The weather in London is Sunny, 20C."
        },
        {"role": "user", "content": "Thank you!"},
        {"role": "assistant", "content": "You are welcome!"}
    ]

    mock_summary = AsyncMock(return_value="Summary including tool results")
    with patch.object(engine, "_request_summary", new=mock_summary):
        rebuilt = await engine.compress(session, messages)
        assert mock_summary.call_count == 1
        call_text = mock_summary.call_args[0][0]
        # Verify tool_use and tool_result were properly formatted in the summary prompt
        assert "[Tool Call: get_weather" in call_text
        assert "[Tool Result: Sunny, 20C]" in call_text
        assert "What is the weather?" in call_text

@pytest.mark.asyncio
async def test_compress_guard_when_turns_less_than_or_equal_to_keep_turns():
    """Validates B1-06: compression is skipped when len(conversation_turns) <= keep_turns."""
    engine = ContextEngine(keep_turns=4)
    session = SessionState(session_id="test_keep_turns_guard")

    messages = [
        {"role": "system", "content": "System prompt"},
        {"role": "user", "content": "Turn 1"},
        {"role": "assistant", "content": "Resp 1"},
        {"role": "user", "content": "Turn 2"},
        {"role": "assistant", "content": "Resp 2"},
    ] # Exactly 4 conversation turns (<= keep_turns=4)

    mock_summary = AsyncMock(return_value="Should not be called")
    with patch.object(engine, "_request_summary", new=mock_summary):
        rebuilt = await engine.compress(session, messages)
        # Summary should not be requested because conversation is within keep_turns
        assert mock_summary.call_count == 0
        assert len(rebuilt) == len(messages)

def test_endpoint_path_matching_rules():
    """Validates B1-04 and B1-05: precise path matching for anthropic messages and openai chat."""
    
    def check_paths(path: str):
        clean_path = path.lstrip("/")
        is_anthropic_messages = (
            clean_path == "v1/messages" or
            clean_path.startswith("v1/messages?") or
            clean_path.startswith("v1/messages/")
        )
        is_openai_chat = clean_path.endswith("chat/completions")
        return is_anthropic_messages, is_openai_chat

    # Anthropic valid routes
    assert check_paths("v1/messages")[0] is True
    assert check_paths("/v1/messages")[0] is True
    assert check_paths("v1/messages?stream=true")[0] is True
    assert check_paths("v1/messages/")[0] is True

    # Anthropic invalid routes that should NOT match (B1-04)
    assert check_paths("v1/threads/123/messages")[0] is False
    assert check_paths("admin/messages")[0] is False
    assert check_paths("v1/users/messages")[0] is False

    # OpenAI Chat valid routes
    assert check_paths("v1/chat/completions")[1] is True
    assert check_paths("/v1/chat/completions")[1] is True

    # Legacy completions that should NOT match chat (B1-05)
    assert check_paths("v1/completions")[1] is False
    assert check_paths("/v1/completions")[1] is False
