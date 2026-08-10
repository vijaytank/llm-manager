import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from context_manager.context_engine import ContextEngine

def test_needs_compression_false_when_small():
    engine = ContextEngine(warn_threshold=0.70)
    messages = [
        {"role": "user", "content": "Hello"}
    ]
    assert not engine.needs_compression(messages, max_tokens_requested=512, ctx_limit=65536)

def test_needs_compression_true_when_large():
    engine = ContextEngine(warn_threshold=0.70)
    long_content = "Word " * 25000  # 25,000 tokens
    messages = [
        {"role": "user", "content": long_content}
    ]
    # 25,000 + 512 = 25,512 >= 30,000 * 0.70 (21,000) -> True!
    assert engine.needs_compression(messages, max_tokens_requested=512, ctx_limit=30000)
