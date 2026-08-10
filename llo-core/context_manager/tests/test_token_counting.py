import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from context_manager.tokenizer_cache import TokenizerCache
from context_manager.context_engine import ContextEngine

def test_character_fallback_count():
    cache = TokenizerCache()
    text = "Hello world this is a test string"
    count = cache.count_tokens(text)
    assert count > 0

def test_count_messages():
    engine = ContextEngine()
    messages = [
        {"role": "system", "content": "You are a helpful assistant."},
        {"role": "user", "content": "Write a python function to compute fibonacci."}
    ]
    tokens = engine.count_tokens_messages(messages)
    assert tokens > 10
