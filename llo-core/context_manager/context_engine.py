import os
import hashlib
import json
import time
import asyncio
import httpx
from dataclasses import dataclass, field
from typing import List, Dict, Any, Optional

from .tokenizer_cache import TokenizerCache

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
- Chronological ordering within topics. Newer statements supersede older ones.
- Target under {max_tokens} tokens.
"""

@dataclass
class SessionState:
    session_id: str
    messages: List[Dict[str, Any]] = field(default_factory=list)
    summary_block: Optional[str] = None
    summary_up_to_turn: int = 0
    last_compress_hash: str = ""
    last_accessed: float = field(default_factory=time.time)
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)

class ContextEngine:
    def __init__(
        self,
        warn_threshold: float = 0.70,
        keep_turns: int = 6,
        llama_server_url: str = "http://127.0.0.1:8080",
        summary_max_tokens: int = 768,
        summarize_with_model: str = "same",
        tokenizer_cache: Optional[TokenizerCache] = None,
        tokenizer_repo_override: str = "",
    ):
        self.warn_threshold = warn_threshold
        self.keep_turns = keep_turns
        self.llama_server_url = llama_server_url.rstrip('/')
        self.summary_max_tokens = summary_max_tokens
        self.summarize_with_model = summarize_with_model
        self.tokenizer_repo_override = tokenizer_repo_override
        self.tokenizer_cache = tokenizer_cache or TokenizerCache()
        self.sessions: Dict[str, SessionState] = {}
        self._eviction_task: Optional[asyncio.Task] = None
        self._running: bool = False

    def start_background_tasks(self):
        if self._eviction_task is None or self._eviction_task.done():
            self._running = True
            self._eviction_task = asyncio.create_task(self._eviction_loop())

    async def stop_background_tasks(self):
        self._running = False
        if self._eviction_task and not self._eviction_task.done():
            self._eviction_task.cancel()
            try:
                await self._eviction_task
            except asyncio.CancelledError:
                pass
            self._eviction_task = None

    async def _eviction_loop(self, interval_seconds: float = 60.0, max_age_seconds: float = 86400.0):
        while self._running:
            try:
                await asyncio.sleep(interval_seconds)
                self._evict_stale_sessions(max_age_seconds)
            except asyncio.CancelledError:
                break
            except Exception as e:
                print(f"[ContextEngine] Error in eviction loop: {e}")

    def _get_checkpoint_path(self, session_id: str) -> str:
        appdata = (
            os.getenv("APPDATA") or
            (os.path.join(os.getenv("USERPROFILE", ""), ".config") if os.getenv("USERPROFILE") else None) or
            (os.path.join(os.getenv("HOME", ""), ".config") if os.getenv("HOME") else None) or
            "."
        )
        cp_dir = os.path.join(appdata, "LLM Manager", "checkpoints")
        os.makedirs(cp_dir, exist_ok=True)
        return os.path.join(cp_dir, f"{session_id}.json")

    def _load_checkpoint_from_disk(self, session_id: str) -> Optional[SessionState]:
        try:
            filepath = self._get_checkpoint_path(session_id)
            if not os.path.exists(filepath):
                return None
            with open(filepath, "r", encoding="utf-8-sig") as f:
                data = json.load(f)
            s = SessionState(session_id=session_id)
            s.summary_block = data.get("summary_block")
            s.summary_up_to_turn = data.get("summary_up_to_turn", 0)
            s.last_compress_hash = data.get("last_compress_hash", "")
            s.messages = data.get("messages", [])
            s.last_accessed = time.time()
            return s
        except Exception:
            return None

    def _evict_stale_sessions(self, max_age_seconds: float = 86400.0):
        now = time.time()
        stale_keys = [
            sid for sid, sess in self.sessions.items()
            if (now - sess.last_accessed) > max_age_seconds
        ]
        for sid in stale_keys:
            self.sessions.pop(sid, None)

    def get_or_create_session(self, session_id: str) -> SessionState:
        if session_id not in self.sessions:
            loaded = self._load_checkpoint_from_disk(session_id)
            self.sessions[session_id] = loaded if loaded else SessionState(session_id=session_id)
        session = self.sessions[session_id]
        session.last_accessed = time.time()
        return session

    def count_tokens_messages(self, messages: List[Dict[str, Any]], model_alias: str = "") -> int:
        override = self.tokenizer_repo_override or None
        total = 0
        for msg in messages:
            content = msg.get("content")
            if isinstance(content, str):
                total += self.tokenizer_cache.count_tokens(content, model_alias, override_repo=override)
            elif isinstance(content, list):
                for item in content:
                    if isinstance(item, dict) and "text" in item:
                        total += self.tokenizer_cache.count_tokens(item["text"], model_alias, override_repo=override)
            tool_calls = msg.get("tool_calls")
            if isinstance(tool_calls, list):
                for tc in tool_calls:
                    if isinstance(tc, dict):
                        fn = tc.get("function", {})
                        args = fn.get("arguments", "")
                        if isinstance(args, str):
                            total += self.tokenizer_cache.count_tokens(args, model_alias, override_repo=override)
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
        prior_summary: Optional[str] = None,
        http_client: Optional[httpx.AsyncClient] = None
    ) -> str:
        prompt_system = SUMMARIZER_SYSTEM_PROMPT.format(max_tokens=self.summary_max_tokens)

        user_parts = []
        if prior_summary:
            user_parts.append(f"PRIOR_SUMMARY:\n{prior_summary}")
        user_parts.append(f"CONVERSATION:\n{conversation_text}")
        user_content = "\n\n".join(user_parts)

        payload: Dict[str, Any] = {
            "messages": [
                {"role": "system", "content": prompt_system},
                {"role": "user", "content": user_content}
            ],
            "max_tokens": self.summary_max_tokens,
            "temperature": 0.2,
            "stream": False
        }
        
        # Don't pass external cloud model aliases to local llama-server
        if self.summarize_with_model and self.summarize_with_model != "same":
            payload["model"] = self.summarize_with_model
        elif model_alias and not (model_alias.startswith("claude-") or model_alias.startswith("gpt-")):
            payload["model"] = model_alias

        url = f"{self.llama_server_url}/v1/chat/completions"
        
        client = http_client or httpx.AsyncClient(timeout=120.0)
        own_client = http_client is None
        try:
            resp = await client.post(url, json=payload)
            if resp.status_code == 200:
                res_json = resp.json()
                choices = res_json.get("choices", [])
                if choices and "message" in choices[0]:
                    return choices[0]["message"].get("content", "").strip()
            err_msg = f"Summarizer call returned status {resp.status_code}: {resp.text}"
            print(f"[ContextEngine] {err_msg}")
            raise RuntimeError(err_msg)
        except Exception as e:
            if not isinstance(e, RuntimeError):
                print(f"[ContextEngine] Summarizer request failed: {e}")
                raise RuntimeError(f"Summarizer request failed: {e}") from e
            raise
        finally:
            if own_client:
                await client.aclose()


    async def maybe_compress(
        self,
        session_id: str,
        messages: List[Dict[str, Any]],
        max_tokens_requested: int,
        ctx_limit: int,
        model_alias: str = "",
        http_client: Optional[httpx.AsyncClient] = None
    ) -> List[Dict[str, Any]]:
        session = self.get_or_create_session(session_id)
        async with session.lock:
            if not self.needs_compression(messages, max_tokens_requested, ctx_limit, model_alias):
                return messages

            print(f"[ContextEngine] Context limit threshold reached ({self.count_tokens_messages(messages, model_alias)} tokens). Triggering compression for session '{session_id}'...")
            return await self.compress(session, messages, model_alias=model_alias, ctx_limit=ctx_limit, http_client=http_client)

    async def compress(
        self,
        session: SessionState,
        messages: List[Dict[str, Any]],
        model_alias: str = "",
        ctx_limit: int = 32768,
        http_client: Optional[httpx.AsyncClient] = None
    ) -> List[Dict[str, Any]]:
        if not messages:
            return messages

        system_prompts = []
        conversation_turns = []

        for msg in messages:
            role = msg.get("role", "")
            name = msg.get("name", "")
            if role == "system" and name != "compressed_history":
                system_prompts.append(msg)
            elif role == "system" and name == "compressed_history":
                continue
            else:
                conversation_turns.append(msg)

        if len(conversation_turns) <= self.keep_turns:
            max_allowed = int((ctx_limit if ctx_limit > 0 else 32768) * 0.85)
            return self._clamp_message_tokens(messages, max_allowed, model_alias)

        split_idx = len(conversation_turns) - self.keep_turns
        start_idx = min(session.summary_up_to_turn, split_idx)
        delta_turns = conversation_turns[start_idx:split_idx]
        recent_window = conversation_turns[split_idx:]

        if not delta_turns and session.messages:
            max_allowed = int((ctx_limit if ctx_limit > 0 else 32768) * 0.85)
            return self._clamp_message_tokens(session.messages, max_allowed, model_alias)

        # Idempotency check on delta turns
        current_hash = self._compute_hash(session.session_id, delta_turns)
        if current_hash == session.last_compress_hash and session.messages:
            max_allowed = int((ctx_limit if ctx_limit > 0 else 32768) * 0.85)
            return self._clamp_message_tokens(session.messages, max_allowed, model_alias)

        conversation_lines = []
        for turn in delta_turns:
            r = turn.get("role", "user")
            c = turn.get("content", "")
            if isinstance(c, list):
                parts = []
                for item in c:
                    if not isinstance(item, dict):
                        continue
                    item_type = item.get("type")
                    if item_type == "text":
                        parts.append(item.get("text", ""))
                    elif item_type == "tool_result":
                        parts.append(f"[Tool Result: {str(item.get('content', ''))}]")
                    elif item_type == "tool_use":
                        parts.append(f"[Tool Call: {item.get('name','')} {json.dumps(item.get('input',{}))}]")
                c = " ".join(parts)
            conversation_lines.append(f"{r.capitalize()}: {c}")

        conversation_text = "\n\n".join(conversation_lines)

        # Warning when conversation history tokens vastly exceed summary max
        conv_tokens = self.tokenizer_cache.count_tokens(
            conversation_text,
            model_alias,
            override_repo=self.tokenizer_repo_override or None
        )
        if conv_tokens > self.summary_max_tokens * 4:
            print(
                f"[ContextEngine] WARNING: Conversation history to summarize is large "
                f"({conv_tokens} tokens vs summary_max_tokens={self.summary_max_tokens}). "
                f"Aggressive compression may cause information loss."
            )

        try:
            new_summary = await self._request_summary(
                conversation_text,
                model_alias,
                prior_summary=session.summary_block,
                http_client=http_client
            )
        except RuntimeError as e:
            print(f"[ContextEngine] Summarization failed, falling back to message clamping without session corruption: {e}")
            max_allowed = int((ctx_limit if ctx_limit > 0 else 32768) * 0.85)
            return self._clamp_message_tokens(messages, max_allowed, model_alias)

        session.summary_block = new_summary
        session.summary_up_to_turn = split_idx
        session.last_compress_hash = current_hash

        if system_prompts:
            sys_contents = [str(m.get("content", "")) for m in system_prompts if m.get("content")]
            sys_contents.append(f"[Compressed History Summary]:\n{new_summary}")
            combined_system = {"role": "system", "content": "\n\n".join(sys_contents)}
            rebuilt = [combined_system] + recent_window
        else:
            summary_msg = {
                "role": "system",
                "content": f"[Compressed History Summary]:\n{new_summary}"
            }
            rebuilt = [summary_msg] + recent_window

        session.messages = rebuilt

        await asyncio.to_thread(self._save_checkpoint_to_disk, session)

        max_allowed = int((ctx_limit if ctx_limit > 0 else 32768) * 0.85)
        return self._clamp_message_tokens(rebuilt, max_allowed, model_alias)

    def _clamp_message_tokens(self, messages: List[Dict[str, Any]], max_allowed_tokens: int, model_alias: str = "") -> List[Dict[str, Any]]:
        total = self.count_tokens_messages(messages, model_alias)
        if total <= max_allowed_tokens:
            return messages

        excess_tokens = total - max_allowed_tokens
        clamped = []
        for msg in messages:
            c_msg = dict(msg)
            content = c_msg.get("content")
            if isinstance(content, str) and len(content) > 500:
                current_tokens = self.tokenizer_cache.count_tokens(content, model_alias)
                if current_tokens > 0 and excess_tokens > 0:
                    share = current_tokens / max(total, 1)
                    chars_to_remove = int(share * excess_tokens * 4)
                    if chars_to_remove > 0:
                        new_len = max(200, len(content) - chars_to_remove)
                        c_msg["content"] = content[:new_len] + "\n\n[... Truncated by Context Manager to fit context limit ...]"
                        excess_tokens -= max(0, current_tokens - max(1, new_len // 4))
            clamped.append(c_msg)

        # Safety verification check: if still exceeding limit after proportional pass, cut largest message
        total_after = self.count_tokens_messages(clamped, model_alias)
        if total_after > max_allowed_tokens:
            largest = max(
                (m for m in clamped if m.get("role") != "system"),
                key=lambda m: len(str(m.get("content", ""))),
                default=None
            )
            if largest and isinstance(largest.get("content"), str):
                excess_chars = (total_after - max_allowed_tokens) * 4
                curr_content = largest["content"]
                if len(curr_content) > 300:
                    new_len = max(200, len(curr_content) - excess_chars)
                    largest["content"] = curr_content[:new_len] + "\n\n[... Truncated by Context Manager ...]"

        return clamped

    def _save_checkpoint_to_disk(self, session: SessionState):
        try:
            filepath = self._get_checkpoint_path(session.session_id)
            data = {
                "session_id": session.session_id,
                "summary_block": session.summary_block,
                "summary_up_to_turn": session.summary_up_to_turn,
                "last_compress_hash": session.last_compress_hash,
                "message_count": len(session.messages),
                "messages": session.messages
            }
            with open(filepath, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2)
        except Exception as e:
            print(f"[ContextEngine] Failed to save checkpoint to disk: {e}")

