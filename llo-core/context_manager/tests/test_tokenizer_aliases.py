from context_manager.tokenizer_cache import TokenizerCache, ALIAS_TO_HF_REPO

def test_cloud_model_aliases_not_in_hf_mapping():
    """Validates B1-07: cloud models (claude, gpt, openai) are not mapped to Qwen HF repo."""
    tc = TokenizerCache()

    # Cloud models must return None (so they fall back to character heuristic rather than mismatched Qwen tokenizer)
    assert tc.get_repo_for_alias("claude-sonnet-4-6") is None
    assert tc.get_repo_for_alias("claude-3-5-sonnet-20241022") is None
    assert tc.get_repo_for_alias("gpt-4o") is None
    assert tc.get_repo_for_alias("gpt-4-turbo") is None
    assert tc.get_repo_for_alias("openai-model") is None

    # Ensure none of these keys exist in the dictionary
    for cloud_key in ["claude", "gpt", "openai"]:
        assert cloud_key not in ALIAS_TO_HF_REPO

def test_local_model_aliases_in_hf_mapping():
    tc = TokenizerCache()

    assert tc.get_repo_for_alias("qwen2.5-coder-7b") == "Qwen/Qwen2.5-1.5B-Instruct"
    assert tc.get_repo_for_alias("llama-3.2-3b") == "meta-llama/Llama-3.2-1B"
    assert tc.get_repo_for_alias("phi-3-mini") == "microsoft/phi-2"
    assert tc.get_repo_for_alias("mistral-7b-instruct") == "mistralai/Mistral-7B-v0.1"

def test_character_heuristic_fallback_for_cloud_models():
    tc = TokenizerCache()
    text = "Hello world! This is a test for Claude tokenizer fallback counting."
    # Should calculate ~ len(text) // 4 without error
    tokens = tc.count_tokens(text, model_alias="claude-sonnet-4-6")
    expected = max(1, len(text) // 4)
    assert tokens == expected
