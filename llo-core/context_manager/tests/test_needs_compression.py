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

def test_needs_compression_exact_threshold_boundary():
    engine = ContextEngine(warn_threshold=0.70)
    short_msg = [{"role": "user", "content": "test"}]
    prompt_tokens = engine.count_tokens_messages(short_msg) # content (1) + msg framing (4) = 5
    threshold = int(1000 * 0.70) # 700

    # exact boundary: prompt_tokens + requested == 700 -> True
    assert engine.needs_compression(short_msg, max_tokens_requested=threshold - prompt_tokens, ctx_limit=1000)
    # one below boundary: prompt_tokens + requested == 699 -> False
    assert not engine.needs_compression(short_msg, max_tokens_requested=threshold - prompt_tokens - 1, ctx_limit=1000)
