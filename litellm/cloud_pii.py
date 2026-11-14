"""cloud-pii: mask personal information on requests to non-local models only.

One pre-call callback (`litellm_settings.callbacks: [cloud_pii.gate]` in config.yaml), mounted
next to pii_policy.py. It is a callback and not a guardrail on purpose: LiteLLM hands a
guardrail only the text its per-endpoint handler finds (nothing for a request without text,
no `system` or `tool_use` on /v1/messages) and rewrites `tools` on the way back, whereas a
callback always runs, sees the whole request and receives the authenticated key itself.

The policy (pii_policy.yaml) lists the local aliases; everything else is masked, so an alias
added in the admin UI under a free name is masked, not leaked. Fails closed.
Design: docs/superpowers/specs/2026-11-14-litellm-cloud-pii-design.md
"""
import asyncio
import hashlib
import os
from collections import OrderedDict
from typing import Any

from fastapi import HTTPException
from litellm.integrations.custom_logger import CustomLogger
from litellm.proxy.guardrails.guardrail_hooks.presidio import _OPTIONAL_PresidioPIIMasking

from pii_policy import chunk_text, decide, entities_for, load_policy

TEXT_TYPES = {"text", "input_text", "output_text"}  # content blocks Presidio can read
# Endpoints whose request body this module knows how to read and mask. Anything else, toward a
# non-local model, is refused rather than guessed at (moderations, files, batches, images,
# Gemini-native generateContent, provider pass-through...).
ALLOWED_CALL_TYPES = {
    "completion", "acompletion", "text_completion", "atext_completion",
    "embedding", "aembedding", "responses", "aresponses", "anthropic_messages",
}
FALLBACK_KEYS = ("fallbacks", "context_window_fallbacks", "content_policy_fallbacks")


def _refuse(detail: str) -> HTTPException:
    return HTTPException(status_code=400, detail=f"cloud-pii: {detail}")


def _add(slots: list, container: Any, key: Any) -> None:
    if isinstance(container[key], str):
        slots.append((container, key))


def _items(node: Any):
    return node.items() if isinstance(node, dict) else enumerate(node) if isinstance(node, list) else ()


def _string_leaves(node: Any, slots: list) -> None:
    for k, v in list(_items(node)):
        if isinstance(v, str):
            slots.append((node, k))
        else:
            _string_leaves(v, slots)


def _descriptions(node: Any, slots: list) -> None:
    """Tool definitions are sent to the provider too: their `description` strings, at any depth."""
    for k, v in list(_items(node)):
        if k == "description" and isinstance(v, str):
            slots.append((node, k))
        else:
            _descriptions(v, slots)


def _blocks(content: Any, slots: list) -> None:
    """Text-bearing spots of a content list; a block Presidio cannot read is refused."""
    for i, b in enumerate(content):
        if isinstance(b, str):
            slots.append((content, i))
        elif not isinstance(b, dict):
            raise _refuse("unreadable content block")
        elif b.get("type") in TEXT_TYPES:
            if "text" in b:
                _add(slots, b, "text")
        elif b.get("type") == "tool_use":
            _string_leaves(b.get("input"), slots)
        elif b.get("type") == "tool_result":
            c = b.get("content")
            if isinstance(c, str):
                slots.append((b, "content"))
            elif isinstance(c, list):
                _blocks(c, slots)
        elif b.get("type") in ("thinking", "redacted_thinking"):
            pass  # signed model output from an already-masked prompt: altering it breaks the signature
        else:
            raise _refuse(f"'{b.get('type')}' content is not sent to a non-local model (it cannot be scanned)")


def _slots(data: dict) -> list:
    """Every string in the request that can carry text, as (container, key)."""
    slots: list = []
    for field in ("system", "prompt", "input", "instructions", "user"):
        v = data.get(field)
        if isinstance(v, str):
            slots.append((data, field))
        elif isinstance(v, dict) and field == "prompt":  # Responses API prompt template
            _string_leaves(v.get("variables"), slots)
        elif isinstance(v, list):
            for i, item in enumerate(v):
                if isinstance(item, str):
                    slots.append((v, i))
                elif isinstance(item, (int, list)):
                    raise _refuse("token arrays cannot be scanned")
                elif isinstance(item, dict) and "content" in item:
                    if isinstance(item["content"], str):
                        slots.append((item, "content"))
                    elif isinstance(item["content"], list):
                        _blocks(item["content"], slots)
                elif isinstance(item, dict):
                    _blocks([item], slots)
    prediction = data.get("prediction")
    if isinstance(prediction, dict):
        if isinstance(prediction.get("content"), str):
            slots.append((prediction, "content"))
        elif isinstance(prediction.get("content"), list):
            _blocks(prediction["content"], slots)
    _descriptions(data.get("tools"), slots)
    for m in data.get("messages") or []:
        if isinstance(m.get("name"), str):
            slots.append((m, "name"))
        fc = m.get("function_call")
        if isinstance(fc, dict) and isinstance(fc.get("arguments"), str):
            slots.append((fc, "arguments"))
        c = m.get("content")
        if isinstance(c, str):
            slots.append((m, "content"))
        elif isinstance(c, list):
            _blocks(c, slots)
        for tc in m.get("tool_calls") or []:
            fn = tc.get("function") if isinstance(tc, dict) else None
            if isinstance(fn, dict) and "arguments" in fn:
                _add(slots, fn, "arguments")
    return slots


def _strings(node: Any):
    """Every string in a JSON-like tree, dict keys included."""
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for k, v in node.items():
            yield from _strings(k)
            yield from _strings(v)
    elif isinstance(node, list):
        for v in node:
            yield from _strings(v)


def check_sendable(data: dict) -> list:
    """Refuse what cannot be scanned (400); otherwise return the request's text slots."""
    if data.get("vector_store_ids") or any(
        isinstance(t, dict) and t.get("type") == "file_search" for t in data.get("tools") or []
    ):
        raise _refuse("vector stores are not combined with a non-local model yet")
    return _slots(data)


def _replace(text: str, spans: list[tuple[int, int, str]]) -> str:
    """Replace detected spans by <ENTITY_TYPE> (Presidio's default).

    Overlapping spans are merged into one covering both, so no tail of the longer one survives.
    """
    merged: list[tuple[int, int, str]] = []
    for s, e, t in sorted(spans, key=lambda x: (x[0], -x[1])):
        if merged and s < merged[-1][1]:
            ms, me, mt = merged[-1]
            if e > me:
                merged[-1] = (ms, e, mt)
        else:
            merged.append((s, e, t))
    for s, e, t in reversed(merged):
        text = text[:s] + f"<{t}>" + text[e:]
    return text


def _use_local_token_counting() -> None:
    """Make /v1/messages/count_tokens (and friends) count locally.

    LiteLLM would otherwise post the whole conversation (messages, system, tools) to Anthropic's
    count-tokens API, and that route never runs a pre-call hook. Returning None from the single
    choke point makes it fall through to its local tokenizer.
    """
    try:
        from litellm.proxy import proxy_server
    except Exception:  # noqa: BLE001
        return

    async def _local_only(*args, **kwargs):
        return None

    proxy_server._try_provider_token_count = _local_only


class CloudPIIGate(CustomLogger):
    def __init__(
        self,
        presidio_analyzer_api_base: str | None = None,
        policy_path: str | None = None,
        chunk_chars: int = 100_000,
        chunk_overlap: int = 200,
        timeout: float = 15.0,
        cache_size: int = 512,
    ):
        super().__init__()
        self._path = policy_path
        self._analyzer = presidio_analyzer_api_base
        self._policy: dict | None = None  # loaded on first use: importing must not need the file
        self._helpers: dict[tuple[str, str], _OPTIONAL_PresidioPIIMasking] = {}
        self.chunk_chars, self.chunk_overlap, self.timeout = chunk_chars, chunk_overlap, timeout
        self._cache: OrderedDict = OrderedDict()
        self._cache_size = cache_size
        _use_local_token_counting()

    @property
    def policy(self) -> dict:
        if self._policy is None:
            self._policy = load_policy(self._path or os.environ.get("PII_POLICY_PATH", "/app/pii_policy.yaml"))
        return self._policy

    def _helper(self, group: str, lang: str) -> _OPTIONAL_PresidioPIIMasking:
        # Presidio's entities, language and thresholds are instance state, so one helper per
        # (group, language) rather than mutating a shared one under concurrent requests.
        if (group, lang) not in self._helpers:
            g = self.policy["groups"][group]
            self._helpers[(group, lang)] = _OPTIONAL_PresidioPIIMasking(
                presidio_analyzer_api_base=self._analyzer,
                presidio_anonymizer_api_base=self._analyzer,  # required by the helper, never called
                pii_entities_config={e: "MASK" for e in entities_for(self.policy, (group,))},
                presidio_score_thresholds=g.get("thresholds"),
                presidio_language=lang,
                guardrail_name=f"cloud-pii-{group}-{lang}",
                event_hook="pre_call",
                default_on=False,
            )
        return self._helpers[(group, lang)]

    async def _mask(self, text: str, groups: tuple[str, ...], data: dict) -> str:
        key = (hashlib.sha256(text.encode()).hexdigest(), groups)
        if key in self._cache:
            self._cache.move_to_end(key)
            return self._cache[key]
        spans: list[tuple[int, int, str]] = []
        for g in groups:
            for lang in self.policy["groups"][g]["languages"]:
                helper = self._helper(g, lang)
                for start, end in chunk_text(text, self.chunk_chars, self.chunk_overlap):
                    found = await asyncio.wait_for(
                        helper.analyze_text(text=text[start:end], presidio_config=None, request_data=data),
                        timeout=self.timeout,
                    )
                    for r in helper.filter_analyze_results_by_score(found):
                        t = r["entity_type"]
                        spans.append((start + r["start"], start + r["end"], str(getattr(t, "value", t))))
        self._cache[key] = _replace(text, spans)
        if len(self._cache) > self._cache_size:
            self._cache.popitem(last=False)
        return self._cache[key]

    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        model = data.get("model")
        # The team is the authenticated key's team_id, never anything the request body says; a
        # team alias can be duplicated or renamed, the id cannot. No team: the strictest set.
        team = getattr(user_api_key_dict, "team_id", None) or None
        decision = decide(self.policy, model, team)

        if not decision.mask:
            # A local request may carry its own fallbacks: if one names a cloud alias, the router
            # would retry there with the prompt we left unmasked. Every name must be local.
            for key in FALLBACK_KEYS:
                for name in _strings(data.get(key)):
                    if name not in self.policy["local_models"]:
                        raise _refuse(f"'{name}' is not a local model; it cannot be a fallback of a local request")
            return data  # local: the data never leaves the Macs

        if call_type not in ALLOWED_CALL_TYPES:
            raise _refuse(f"the '{call_type}' endpoint is not available toward a non-local model (it is not masked)")
        slots = check_sendable(data)  # refuse before touching anything
        try:
            for container, key in slots:
                container[key] = await self._mask(container[key], decision.groups, data)
        except HTTPException:
            raise
        except Exception:
            # Fail closed, and never put the text in the error.
            raise HTTPException(status_code=503, detail="cloud-pii: PII scanning unavailable, request refused") from None
        return data


gate = CloudPIIGate()
