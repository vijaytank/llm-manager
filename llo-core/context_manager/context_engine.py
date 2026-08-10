import hashlib
import json
import httpx
from dataclasses import dataclass, field
from typing import List, Dict, Any, Optional

try:
    from .tokenizer_cache import TokenizerCache
except ImportError:
    from tokenizer_cache import TokenizerCache

SUMMARIZER_SYSTEM_PROMPT = """
You are a precise technical summarizer for multi-turn developer conversations.
Your job is to compress conversation history (and, if provided, a PRIOR_SUMMARY)
into a compact, factual record that can be used later to reconstruct context.
Do not invent, infer, or assume facts that were not explicitly stated.

INPUT:
- CONVERSATION: the new turns to summarize.
- PRIOR_SUMMARY (optional): a previous summary in this same format. If present,
  merge it with the new turns rather than starting over. Preserve older facts
  that are still valid; overwrite only what the new turns explicitly change.

WHAT TO PRESERVE (verbatim where possible):
- Key decisions and their rationale
- File paths, function/class/variable names, API endpoints, config values, versions
- Code snippets central to the task or final solution (keep only the latest
  working version of a snippet; drop superseded drafts unless an earlier
  rejected approach is needed to explain why the current one was chosen)
- User constraints, requirements, and preferences
- Open tasks / TODOs / unresolved issues, with current status
- Durable environment/setup facts (stack, dependency versions, directory
  structure, tool configs) even if never framed as a "decision"

CONFLICT RESOLUTION:
- Order bullets chronologically within a topic.
- If a later statement contradicts, updates, or supersedes an earlier one
  (decision, constraint, requirement, or TODO status), the newer one wins.
  Do not keep both — replace, don't append.
- If the same fact is restated multiple times without change, keep it once.

ORGANIZATION:
- Group bullets by topic (feature, bug, file/module, task, or environment/setup).
- Within each topic, order chronologically per the conflict rule above.
- Omit any topic heading that would have no content.

CODE SNIPPETS:
- Bullets are otherwise flat (one fact per line), but a code snippet may span
  multiple indented lines under its bullet as the sole exception.
- Prefer short, central snippets (signatures, key logic) over full file dumps.
- For long snippets, keep the signature/interface and truncate the body with
  "..." if it is not essential to reconstructing the decision.

STYLE:
- Terse bullet points only. No explanations, commentary, or restated prompt text.
- No greetings or meta-text ("Here is the summary", etc.).
- Do not speculate about user intent beyond what was explicitly stated.
- "- " prefixes and code indentation are literal formatting characters, not
  rendered markdown — output remains plain text.

LENGTH CONSTRAINT (critical):
- Target under {max_tokens} tokens. Token counts can't be measured exactly, so
  use ~4 characters ≈ 1 token as a working estimate and treat the limit as a
  ceiling to compress toward, not a value to hit exactly.
- If everything cannot fit, prioritize in this order:
  1) Final decisions and their rationale
  2) User constraints / requirements
  3) File paths, identifiers, and central code snippets
  4) Open tasks and follow-ups
  5) Secondary discussion and exploration
- When approaching the limit, compress low-priority detail (merge related
  bullets, shorten rationale, truncate code) rather than dropping any
  decision, constraint, or requirement.

OUTPUT FORMAT:
- Plain text.
- Top-level topics as headings in ALL CAPS.
- Under each topic, a flat list of bullet points ("- " prefix), with the
  single exception of indented multi-line code under a bullet.
"""

@dataclass
class SessionState:
    session_id: str
    messages: List[Dict[str, Any]] = field(default_factory=list)
    summary_block: Optional[str] = None
    summary_up_to_turn: int = 0
    last_compress_hash: str = ""

class ContextEngine:
    def __init__(
        self,
        warn_threshold: float = 0.70,
        keep_turns: int = 6,
        llama_server_url: str = "http://127.0.0.1:8080",
        summary_max_tokens: int = 768,
        tokenizer_cache: Optional[TokenizerCache] = None,
    ):
        self.warn_threshold = warn_threshold
        self.keep_turns = keep_turns
        self.llama_server_url = llama_server_url.rstrip('/')
        self.summary_max_tokens = summary_max_tokens
        self.tokenizer_cache = tokenizer_cache or TokenizerCache()
        self.sessions: Dict[str, SessionState] = {}

    def get_or_create_session(self, session_id: str) -> SessionState:
        if session_id not in self.sessions:
            self.sessions[session_id] = SessionState(session_id=session_id)
        return self.sessions[session_id]

    def count_tokens_messages(self, messages: List[Dict[str, Any]], model_alias: str = "") -> int:
        total = 0
        for msg in messages:
            content = msg.get("content")
            if isinstance(content, str):
                total += self.tokenizer_cache.count_tokens(content, model_alias)
            elif isinstance(content, list):
                # Handle structured content (e.g. text blocks)
                for item in content:
                    if isinstance(item, dict) and "text" in item:
                        total += self.tokenizer_cache.count_tokens(item["text"], model_alias)
        # Account for per-message framing overhead (~4 tokens per turn)
        total += len(messages) * 4
        return total

    def needs_compression(
        self,
        messages: List[Dict[str, Any]],
        max_tokens_requested: int,
        ctx_limit: int,
        model_alias: str = ""
    ) -> bool:
        if ctx_limit <= 0:
            ctx_limit = 65536

        prompt_tokens = self.count_tokens_messages(messages, model_alias)
        total_projected = prompt_tokens + max(0, max_tokens_requested)
        threshold = int(ctx_limit * self.warn_threshold)
        return total_projected >= threshold

    def _compute_hash(self, session_id: str, to_summarize: List[Dict[str, Any]]) -> str:
        raw = f"{session_id}:{len(to_summarize)}:" + json.dumps(to_summarize, sort_keys=True)
        return hashlib.sha256(raw.encode("utf-8")).hexdigest()

    async def _request_summary(
        self,
        conversation_text: str,
        model_alias: str,
        prior_summary: Optional[str] = None
    ) -> str:
        prompt_system = SUMMARIZER_SYSTEM_PROMPT.format(max_tokens=self.summary_max_tokens)

        # Build structured user message matching the prompt's INPUT contract
        user_parts = []
        if prior_summary:
            user_parts.append(f"PRIOR_SUMMARY:\n{prior_summary}")
        user_parts.append(f"CONVERSATION:\n{conversation_text}")
        user_content = "\n\n".join(user_parts)

        payload = {
            "messages": [
                {"role": "system", "content": prompt_system},
                {"role": "user", "content": user_content}
            ],
            "max_tokens": self.summary_max_tokens,
            "temperature": 0.2,
            "stream": False
        }
        if model_alias:
            payload["model"] = model_alias

        url = f"{self.llama_server_url}/v1/chat/completions"
        try:
            async with httpx.AsyncClient(timeout=60.0) as client:
                resp = await client.post(url, json=payload)
                if resp.status_code == 200:
                    res_json = resp.json()
                    choices = res_json.get("choices", [])
                    if choices and "message" in choices[0]:
                        return choices[0]["message"].get("content", "").strip()
                print(f"[ContextEngine] Summarizer call returned status {resp.status_code}: {resp.text}")
        except Exception as e:
            print(f"[ContextEngine] Summarizer request failed: {e}")

        # Fallback summary if LLM call fails
        return f"[Summary of previous conversation up to turn: {len(conversation_text.splitlines())} lines]"

    async def compress(
        self,
        session: SessionState,
        messages: List[Dict[str, Any]],
        model_alias: str = ""
    ) -> List[Dict[str, Any]]:
        if not messages:
            return messages

        # 1. Separate system prompts, existing compressed blocks, and conversation turns
        system_prompts = []
        conversation_turns = []

        for msg in messages:
            role = msg.get("role", "")
            name = msg.get("name", "")
            if role == "system" and name != "compressed_history":
                system_prompts.append(msg)
            elif role == "system" and name == "compressed_history":
                continue # Replaced by new summary
            else:
                conversation_turns.append(msg)

        # 2. If conversation turns are few but message is huge, adapt keep_turns
        effective_keep = self.keep_turns
        if len(conversation_turns) > 2 and len(conversation_turns) <= effective_keep:
            effective_keep = max(1, len(conversation_turns) - 1)

        if len(conversation_turns) <= effective_keep:
            # Apply safety clamp if single prompt turn is oversized
            max_allowed = int(self._get_ctx_limit_from_messages(messages) * 0.85)
            return self._clamp_message_tokens(messages, max_allowed, model_alias)

        split_idx = len(conversation_turns) - effective_keep
        to_summarize = conversation_turns[:split_idx]
        recent_window = conversation_turns[split_idx:]

        # Idempotency check
        current_hash = self._compute_hash(session.session_id, to_summarize)
        if current_hash == session.last_compress_hash and session.messages:
            return session.messages

        # Build conversation text from turns to summarize (no prior summary mixed in)
        conversation_lines = []
        for turn in to_summarize:
            r = turn.get("role", "user")
            c = turn.get("content", "")
            if isinstance(c, list):
                c = " ".join([item.get("text", "") for item in c if isinstance(item, dict)])
            conversation_lines.append(f"{r.capitalize()}: {c}")

        conversation_text = "\n\n".join(conversation_lines)

        # Call summarizer — prior_summary passed separately so the model
        # can apply PRIOR_SUMMARY merge semantics from the system prompt
        new_summary = await self._request_summary(
            conversation_text,
            model_alias,
            prior_summary=session.summary_block
        )

        # Update session state
        session.summary_block = new_summary
        session.summary_up_to_turn += len(to_summarize)
        session.last_compress_hash = current_hash

        # Reconstruct rebuilt messages
        summary_msg = {
            "role": "system",
            "name": "compressed_history",
            "content": f"[Compressed History Summary]:\n{new_summary}"
        }

        rebuilt = system_prompts + [summary_msg] + recent_window
        session.messages = rebuilt

        # Persist checkpoint to disk
        self._save_checkpoint_to_disk(session)

        # Ensure total payload does not exceed safety ceiling
        max_allowed = int(self._get_ctx_limit_from_messages(messages) * 0.85)
        return self._clamp_message_tokens(rebuilt, max_allowed, model_alias)

    def _get_ctx_limit_from_messages(self, messages: List[Dict[str, Any]]) -> int:
        return 32768

    def _clamp_message_tokens(self, messages: List[Dict[str, Any]], max_allowed_tokens: int, model_alias: str = "") -> List[Dict[str, Any]]:
        total = self.count_tokens_messages(messages, model_alias)
        if total <= max_allowed_tokens:
            return messages

        clamped = []
        excess_tokens = total - max_allowed_tokens
        excess_chars = excess_tokens * 4

        for msg in messages:
            c_msg = dict(msg)
            content = c_msg.get("content")
            if isinstance(content, str) and len(content) > 1000 and excess_chars > 0:
                new_len = max(500, len(content) - excess_chars - 300)
                c_msg["content"] = content[:new_len] + "\n\n[... Truncated by Context Manager Proxy to fit context limit ...]"
                excess_chars = 0  # Truncated main payload
            clamped.append(c_msg)

        return clamped

    def _save_checkpoint_to_disk(self, session: SessionState):
        try:
            import os
            appdata = os.getenv("APPDATA") or os.getenv("USERPROFILE") or "."
            cp_dir = os.path.join(appdata, "LLM Manager", "checkpoints")
            os.makedirs(cp_dir, exist_ok=True)
            filepath = os.path.join(cp_dir, f"{session.session_id}.json")
            data = {
                "session_id": session.session_id,
                "summary_block": session.summary_block,
                "summary_up_to_turn": session.summary_up_to_turn,
                "last_compress_hash": session.last_compress_hash,
                "message_count": len(session.messages)
            }
            with open(filepath, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2)
        except Exception as e:
            print(f"[ContextEngine] Failed to save checkpoint to disk: {e}")

    async def maybe_compress(
        self,
        session_id: str,
        messages: List[Dict[str, Any]],
        max_tokens_requested: int,
        ctx_limit: int,
        model_alias: str = ""
    ) -> List[Dict[str, Any]]:
        session = self.get_or_create_session(session_id)
        if self.needs_compression(messages, max_tokens_requested, ctx_limit, model_alias):
            print(f"[ContextEngine] Context limit threshold reached ({self.count_tokens_messages(messages, model_alias)} tokens). Triggering compression for session '{session_id}'...")
            return await self.compress(session, messages, model_alias)
        # Apply safety clamp even if threshold is not reached to prevent 400 Context Exceeded crashes on huge single messages
        max_allowed = int((ctx_limit if ctx_limit > 0 else 32768) * 0.85)
        return self._clamp_message_tokens(messages, max_allowed, model_alias)
