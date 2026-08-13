import pytest
from unittest.mock import AsyncMock, patch
from context_manager.context_engine import ContextEngine, SessionState

@pytest.mark.asyncio
async def test_compress_preserves_system_prompt_and_keep_turns():
    engine = ContextEngine(keep_turns=2)
    session = SessionState(session_id="test_session")
    
    messages = [
        {"role": "system", "content": "You are system instruction."},
        {"role": "user", "content": "Turn 1"},
        {"role": "assistant", "content": "Resp 1"},
        {"role": "user", "content": "Turn 2"},
        {"role": "assistant", "content": "Resp 2"},
        {"role": "user", "content": "Turn 3"},
        {"role": "assistant", "content": "Resp 3"}
    ]

    with patch.object(engine, "_request_summary", new=AsyncMock(return_value="Mocked summary of turns 1-2")):
        rebuilt = await engine.compress(session, messages)

    assert len(rebuilt) == 3
    assert rebuilt[0]["role"] == "system"
    assert "You are system instruction." in rebuilt[0]["content"]
    assert "Mocked summary of turns 1-2" in rebuilt[0]["content"]
    assert rebuilt[1]["content"] == "Turn 3"
    assert rebuilt[2]["content"] == "Resp 3"

@pytest.mark.asyncio
async def test_incremental_delta_slicing():
    engine = ContextEngine(keep_turns=2)
    session = SessionState(session_id="test_incremental")
    
    initial_messages = [
        {"role": "system", "content": "Sys"},
        {"role": "user", "content": "Turn 1"},
        {"role": "assistant", "content": "Resp 1"},
        {"role": "user", "content": "Turn 2"},
        {"role": "assistant", "content": "Resp 2"},
        {"role": "user", "content": "Turn 3"},
        {"role": "assistant", "content": "Resp 3"}
    ]

    mock_summary = AsyncMock(return_value="Summary 1")
    with patch.object(engine, "_request_summary", new=mock_summary):
        res1 = await engine.compress(session, initial_messages)
        assert mock_summary.call_count == 1
        assert session.summary_up_to_turn == 4

    # Extended conversation with 2 new turns
    extended_messages = initial_messages + [
        {"role": "user", "content": "Turn 4"},
        {"role": "assistant", "content": "Resp 4"}
    ]

    mock_summary2 = AsyncMock(return_value="Summary 2")
    with patch.object(engine, "_request_summary", new=mock_summary2):
        res2 = await engine.compress(session, extended_messages)
        assert mock_summary2.call_count == 1
        assert session.summary_up_to_turn == 6
        # Ensure only Turn 3 & Resp 3 (delta) were passed into conversation_text
        call_args = mock_summary2.call_args[0][0]
        assert "Turn 3" in call_args
        assert "Turn 1" not in call_args
