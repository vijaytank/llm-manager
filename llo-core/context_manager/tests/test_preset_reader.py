from context_manager.preset_reader import read_preset_ctx_limit

def test_preset_reader_with_existing_preset():
    ctx = read_preset_ctx_limit(model_alias="gemma-4-e4b-it-q4-k-m")
    assert isinstance(ctx, int)
    assert ctx > 0

def test_preset_reader_missing_file():
    ctx = read_preset_ctx_limit(preset_path="non_existent_file.ini", model_alias="unknown")
    assert ctx == 65536
