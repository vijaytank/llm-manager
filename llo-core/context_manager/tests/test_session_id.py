from unittest.mock import MagicMock

from context_manager.proxy import extract_session_id

def test_extract_session_id_from_header():
    request = MagicMock()
    request.headers.get.side_effect = lambda k, d=None: "header_session_123" if k == "x-llm-session-id" else d
    body = {}
    sid = extract_session_id(request, body)
    assert sid == "header_session_123"

def test_extract_session_id_from_body():
    request = MagicMock()
    request.headers.get.return_value = None
    body = {"metadata": {"session_id": "body_session_456"}}
    sid = extract_session_id(request, body)
    assert sid == "body_session_456"

def test_extract_session_id_fallback():
    request = MagicMock()
    request.headers.get.return_value = None
    request.client.host = "127.0.0.1"
    body = {}
    sid = extract_session_id(request, body)
    assert sid.startswith("session_")
