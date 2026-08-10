import sys
import asyncio
import pytest
from pathlib import Path
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from context_manager.context_engine import ContextEngine, SessionState

def test_compress_preserves_system_prompt_and_keep_turns():
    async def _test():
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

        assert len(rebuilt) == 4
        assert rebuilt[0]["role"] == "system"
        assert rebuilt[0]["content"] == "You are system instruction."
        assert rebuilt[1]["role"] == "system"
        assert rebuilt[1]["name"] == "compressed_history"
        assert "Mocked summary" in rebuilt[1]["content"]
        assert rebuilt[2]["content"] == "Turn 3"
        assert rebuilt[3]["content"] == "Resp 3"

    asyncio.run(_test())

def test_idempotency_does_not_retrigger_summary():
    async def _test():
        engine = ContextEngine(keep_turns=2)
        session = SessionState(session_id="test_idempotent_session")
        
        messages = [
            {"role": "system", "content": "Sys"},
            {"role": "user", "content": "Turn 1"},
            {"role": "assistant", "content": "Resp 1"},
            {"role": "user", "content": "Turn 2"},
            {"role": "assistant", "content": "Resp 2"}
        ]

        mock_summary = AsyncMock(return_value="Summary 1")
        with patch.object(engine, "_request_summary", new=mock_summary):
            first_call = await engine.compress(session, messages)
            assert mock_summary.call_count == 1

            second_call = await engine.compress(session, messages)
            assert mock_summary.call_count == 1
            assert first_call == second_call

    asyncio.run(_test())
