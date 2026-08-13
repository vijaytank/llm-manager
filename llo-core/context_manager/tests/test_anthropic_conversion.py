import pytest
from context_manager.proxy import (
    convert_anthropic_to_openai_messages,
    convert_openai_to_anthropic_response,
    convert_anthropic_tools_to_openai,
    convert_anthropic_tool_choice_to_openai,
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

def test_convert_anthropic_tools_and_tool_results():
    tools = [
        {
            "name": "ReadFile",
            "description": "Read file contents",
            "input_schema": {"type": "object", "properties": {"path": {"type": "string"}}}
        }
    ]
    converted_tools = convert_anthropic_tools_to_openai(tools)
    assert len(converted_tools) == 1
    assert converted_tools[0]["function"]["name"] == "ReadFile"
    assert converted_tools[0]["function"]["parameters"]["properties"]["path"]["type"] == "string"

    anthropic_payload = {
        "messages": [
            {
                "role": "assistant",
                "content": [
                    {"type": "text", "text": "Reading main.py"},
                    {"type": "tool_use", "id": "call_123", "name": "ReadFile", "input": {"path": "main.py"}}
                ]
            },
            {
                "role": "user",
                "content": [
                    {"type": "tool_result", "tool_use_id": "call_123", "content": "print('hello')"}
                ]
            }
        ]
    }
    msgs = convert_anthropic_to_openai_messages(anthropic_payload)
    assert len(msgs) == 2
    assert msgs[0]["role"] == "assistant"
    assert msgs[0]["tool_calls"][0]["function"]["name"] == "ReadFile"
    assert msgs[1]["role"] == "tool"
    assert msgs[1]["tool_call_id"] == "call_123"
    assert msgs[1]["content"] == "print('hello')"

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

def test_convert_openai_tool_calls_to_anthropic_response():
    openai_resp = {
        "id": "chatcmpl-tool",
        "choices": [
            {
                "message": {
                    "role": "assistant",
                    "content": "Reading file now.",
                    "tool_calls": [
                        {
                            "id": "call_abc",
                            "type": "function",
                            "function": {"name": "ReadFile", "arguments": "{\"path\":\"config.json\"}"}
                        }
                    ]
                },
                "finish_reason": "tool_calls"
            }
        ],
        "usage": {"prompt_tokens": 100, "completion_tokens": 30}
    }
    res = convert_openai_to_anthropic_response(openai_resp, "claude-3-5-sonnet-20241022")
    assert res["stop_reason"] == "tool_use"
    assert len(res["content"]) == 2
    assert res["content"][0]["type"] == "text"
    assert res["content"][1]["type"] == "tool_use"
    assert res["content"][1]["name"] == "ReadFile"
    assert res["content"][1]["input"] == {"path": "config.json"}

