import os
import re
from pathlib import Path
from typing import Optional, Dict, Any

ALIAS_TO_HF_REPO: Dict[str, str] = {
    "gemma": "google/gemma-2-2b-it",
    "gemma2": "google/gemma-2-2b-it",
    "gemma3": "google/gemma-3-4b-it",
    "gemma4": "google/gemma-3-4b-it",
    "qwen": "Qwen/Qwen2.5-1.5B-Instruct",
    "qwen2": "Qwen/Qwen2.5-1.5B-Instruct",
    "qwen3": "Qwen/Qwen2.5-1.5B-Instruct",
    "qwythos": "Qwen/Qwen2.5-1.5B-Instruct",
    "ornith": "Qwen/Qwen2.5-1.5B-Instruct",
    "llama": "meta-llama/Llama-3.2-1B",
    "mistral": "mistralai/Mistral-7B-v0.1",
    "ministral": "mistralai/Mistral-7B-v0.1",
    "phi": "microsoft/phi-2",
    "deepseek": "deepseek-ai/DeepSeek-R1-Distill-Qwen-1.5B",
    # NOTE: Cloud model aliases (claude, gpt, openai) are intentionally excluded.
    # These models have proprietary tokenizers; the Qwen tokenizer would give ~10-15%
    # incorrect counts. The character heuristic (len // 4) is more honest.
}

class TokenizerCache:
    def __init__(self, cache_dir: Optional[str] = None):
        if not cache_dir:
            userprofile = os.getenv("USERPROFILE") or os.getenv("HOME") or "."
            cache_dir = os.path.join(userprofile, ".cache", "llm-manager", "tokenizers")
        self.cache_dir = Path(cache_dir)
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self._loaded_tokenizers: Dict[str, Any] = {}

    def get_repo_for_alias(self, model_alias: str, override_repo: Optional[str] = None) -> Optional[str]:
        if override_repo and override_repo.strip():
            return override_repo.strip()

        if not model_alias:
            return None

        alias_lower = model_alias.lower()
        for key, repo in ALIAS_TO_HF_REPO.items():
            if key in alias_lower:
                return repo

        return None

    def get_tokenizer(self, model_alias: str, override_repo: Optional[str] = None) -> Any:
        repo = self.get_repo_for_alias(model_alias, override_repo)
        if not repo:
            return None

        if repo in self._loaded_tokenizers:
            return self._loaded_tokenizers[repo]

        try:
            from tokenizers import Tokenizer
            
            repo_slug = re.sub(r'[^a-zA-Z0-9_-]', '_', repo)
            local_json = self.cache_dir / repo_slug / "tokenizer.json"

            if local_json.is_file():
                tok = Tokenizer.from_file(str(local_json))
                self._loaded_tokenizers[repo] = tok
                return tok

            # Try loading directly via huggingface_hub or tokenizers pretrained
            try:
                tok = Tokenizer.from_pretrained(repo)
                local_json.parent.mkdir(parents=True, exist_ok=True)
                tok.save(str(local_json))
                self._loaded_tokenizers[repo] = tok
                return tok
            except Exception as dl_err:
                print(f"[TokenizerCache] Failed to fetch tokenizer from HF repo '{repo}': {dl_err}")

        except ImportError:
            print("[TokenizerCache] Warning: 'tokenizers' package not installed. Using character heuristic.")
        except Exception as e:
            print(f"[TokenizerCache] Exception loading tokenizer for '{repo}': {e}")

        return None

    def count_tokens(self, text: str, model_alias: str = "", override_repo: Optional[str] = None) -> int:
        """Counts tokens for given text. Falls back to len(text)//4 if tokenizer is unavailable."""
        if not text:
            return 0

        tok = self.get_tokenizer(model_alias, override_repo)
        if tok is not None:
            try:
                encoding = tok.encode(text)
                return len(encoding.ids)
            except Exception as e:
                print(f"[TokenizerCache] Encoding error: {e}")

        # Heuristic fallback: ~4 characters per token
        return max(1, len(text) // 4)
