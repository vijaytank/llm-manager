import pytest
from context_manager.proxy import (
    convert_anthropic_to_openai_messages,
    convert_openai_to_anthropic_response,
)

def test_convert_anthropic_to_openai_messages_str_system():
    anthropic_payload = {
        "model": "claude-3-5-sonnet-20241022",
        "system": "You are a helpful coding assistant.",
        "messages": [
            {"role": "user", "content": "Hello world"}
        ]
    }
    msgs = convert_anthropic_to_openai_messages(anthropic_payload)
    assert len(msgs) == 2
    assert msgs[0] == {"role": "system", "content": "You are a helpful coding assistant."}
    assert msgs[1] == {"role": "user", "content": "Hello world"}

def test_convert_anthropic_to_openai_messages_list_blocks():
    anthropic_payload = {
        "model": "claude-3-5-sonnet-20241022",
        "system": [{"type": "text", "text": "System prompt text"}],
        "messages": [
            {"role": "user", "content": [{"type": "text", "text": "User text message"}]}
        ]
    }
    msgs = convert_anthropic_to_openai_messages(anthropic_payload)
    assert len(msgs) == 2
    assert msgs[0] == {"role": "system", "content": "System prompt text"}
    assert msgs[1] == {"role": "user", "content": "User text message"}

def test_convert_openai_to_anthropic_response():
    openai_resp = {
        "id": "chatcmpl-999",
        "choices": [
            {
                "message": {"role": "assistant", "content": "Here is the code output."},
                "finish_reason": "stop"
            }
        ],
        "usage": {"prompt_tokens": 50, "completion_tokens": 20}
    }
    res = convert_openai_to_anthropic_response(openai_resp, "claude-3-5-sonnet-20241022")
    assert res["id"] == "msg_chatcmpl-999"
    assert res["type"] == "message"
    assert res["role"] == "assistant"
    assert res["content"][0]["text"] == "Here is the code output."
    assert res["stop_reason"] == "end_turn"
    assert res["usage"]["input_tokens"] == 50
    assert res["usage"]["output_tokens"] == 20
