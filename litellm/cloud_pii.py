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

import mcp_policy
from pii_policy import chunk_text, decide, entities_for, load_policy

TEXT_TYPES = {"text", "input_text", "output_text"}  # content blocks Presidio can read
# Endpoints whose request body this module knows how to read and mask. Anything else, toward a
# non-local model, is refused rather than guessed at (moderations, files, batches, images,
# Gemini-native generateContent, provider pass-through...).
ALLOWED_CALL_TYPES = {
    "completion", "acompletion", "text_completion", "atext_completion",
    "embedding", "aembedding", "responses", "aresponses", "anthropic_messages",
}
# The message fields this module reads. Any other field, toward a non-local model, is refused
# rather than guessed at: it could carry free text that would leave unscanned.
MESSAGE_KEYS = {
    "role", "content", "name", "tool_calls", "tool_call_id", "function_call",
    "thinking_blocks", "reasoning_content", "refusal", "cache_control",
}
ROLES = {"system", "user", "assistant", "tool", "function", "developer"}
CACHE_TTLS = {"5m", "1h"}
FALLBACK_KEYS = ("fallbacks", "context_window_fallbacks", "content_policy_fallbacks")


def _refuse(detail: str) -> HTTPException:
    return HTTPException(status_code=400, detail=f"cloud-pii: {detail}")


def _add(slots: list, container: Any, key: Any) -> None:
    if isinstance(container[key], str):
        slots.append((container, key))


def _items(node: Any):
    return node.items() if isinstance(node, dict) else enumerate(node) if isinstance(node, list) else ()


KEY = "key"  # slot marker: a dict key to check, not a value to mask


def _string_leaves(node: Any, slots: list) -> None:
    """Every string value of a JSON-like tree is masked; every dict key is checked."""
    for k, v in list(_items(node)):
        if isinstance(node, dict) and isinstance(k, str):
            slots.append((node, k, KEY))
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


def _check_cache_control(node: dict) -> None:
    """cache_control is a control field, not free text: only its known shape may pass."""
    v = node.get("cache_control")
    if v is not None and not (
        isinstance(v, dict) and set(v) <= {"type", "ttl"} and v.get("type") == "ephemeral" and v.get("ttl", "5m") in CACHE_TTLS
    ):
        raise _refuse("an unexpected cache_control cannot be scanned")


def _str(node: dict, key: str, slots: list, strict: bool = False) -> None:
    """A string field: scanned (masked, or strictly checked if signed); any other type is refused."""
    v = node.get(key)
    if v is None:
        return
    if not isinstance(v, str):
        raise _refuse(f"'{key}' is not a string and cannot be scanned")
    slots.append((node, key, True) if strict else (node, key))


def _rest(node: dict, known: set, slots: list) -> None:
    """Whatever a block carries beyond the fields we know (citations, ...): scan every string."""
    for k, v in list(node.items()):
        if k in known:
            continue
        slots.append((node, k, KEY))
        if isinstance(v, str):
            slots.append((node, k))
        else:
            _string_leaves(v, slots)


def _blocks(content: Any, slots: list) -> None:
    """Text-bearing spots of a content list; a block Presidio cannot read is refused."""
    for i, b in enumerate(content):
        if isinstance(b, str):
            slots.append((content, i))
            continue
        if not isinstance(b, dict):
            raise _refuse("unreadable content block")
        _check_cache_control(b)
        t = b.get("type")
        if t in TEXT_TYPES:
            _str(b, "text", slots)
            _rest(b, {"type", "text", "cache_control"}, slots)
        elif t == "tool_use":
            _str(b, "id", slots)
            _str(b, "name", slots)
            _string_leaves(b.get("input"), slots)
            _rest(b, {"type", "id", "name", "input", "cache_control"}, slots)
        elif t == "tool_result":
            _str(b, "tool_use_id", slots)
            c = b.get("content")
            if isinstance(c, str):
                slots.append((b, "content"))
            elif isinstance(c, list):
                _blocks(c, slots)
            elif c is not None:
                raise _refuse("a tool_result whose content is not text or blocks cannot be scanned")
            if "is_error" in b and not isinstance(b["is_error"], bool):
                raise _refuse("is_error must be a boolean")
            _rest(b, {"type", "tool_use_id", "content", "cache_control", "is_error"}, slots)
        elif t in ("thinking", "redacted_thinking"):
            # Signed: altering a field breaks the signature, so each is scanned and the request
            # refused if it carries personal information (strict slots), never masked.
            if set(b) - {"type", "thinking", "signature", "data", "cache_control"}:
                raise _refuse("a thinking block with unexpected fields cannot be scanned")
            for field in ("thinking", "data", "signature"):
                _str(b, field, slots, strict=True)
        else:
            raise _refuse(f"'{t}' content is not sent to a non-local model (it cannot be scanned)")


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
        unknown = set(m) - MESSAGE_KEYS
        if unknown:
            raise _refuse(f"message field '{sorted(unknown)[0]}' is not sent to a non-local model (it cannot be scanned)")
        if m.get("role") not in ROLES:
            raise _refuse("an unknown message role cannot be scanned")
        _check_cache_control(m)
        tb = m.get("thinking_blocks")
        if isinstance(tb, list):
            _blocks(tb, slots)
        elif tb is not None:
            raise _refuse("thinking_blocks must be a list")
        for field in ("reasoning_content", "refusal", "name", "tool_call_id"):
            _str(m, field, slots)
        fc = m.get("function_call")
        if fc is not None:
            if not isinstance(fc, dict) or set(fc) - {"name", "arguments"}:
                raise _refuse("an unexpected function_call cannot be scanned")
            _str(fc, "name", slots)
            _str(fc, "arguments", slots)
        c = m.get("content")
        if isinstance(c, str):
            slots.append((m, "content"))
        elif isinstance(c, list):
            _blocks(c, slots)
        elif c is not None:
            raise _refuse("message content that is not text or blocks cannot be scanned")
        tcs = m.get("tool_calls")
        if tcs is not None and not isinstance(tcs, list):
            raise _refuse("tool_calls must be a list")
        for tc in tcs or []:
            fn = tc.get("function") if isinstance(tc, dict) else None
            if (not isinstance(tc, dict) or set(tc) - {"id", "type", "function", "index", "cache_control"}
                    or tc.get("type") not in (None, "function") or not isinstance(fn, dict) or set(fn) - {"name", "arguments"}):
                raise _refuse("an unexpected tool call cannot be scanned")
            _check_cache_control(tc)
            if "index" in tc and (not isinstance(tc["index"], int) or isinstance(tc["index"], bool)):
                raise _refuse("a tool call index must be an integer")
            _str(tc, "id", slots)
            _str(fn, "name", slots)
            _str(fn, "arguments", slots)
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


def check_mcp_tools(data: dict, masked: bool = False) -> None:
    """A chat or Responses request may declare MCP servers or tools. A provider-native connector
    (`mcp_servers`, an `mcp_toolset` tool) makes the PROVIDER contact a URL of the client's choosing;
    a `{"type": "mcp", "server_url": ...}` tool names a foreign URL that the provider or LiteLLM
    would connect to. Both bypass our MCP policy. Only LiteLLM's own gateway (`litellm_proxy...`,
    whose calls go through `call_mcp_tool`) is allowed. Fields can also arrive inside `extra_body`,
    which clients merge into the request: it is checked the same way."""
    if data.get("mcp_servers"):
        raise _refuse("provider-native MCP servers (mcp_servers) are not available; use LiteLLM's gateway")
    for t in data.get("tools") or []:
        kind = str(t.get("type", "")).lower() if isinstance(t, dict) else ""
        if kind.startswith("mcp") and kind != "mcp":
            raise _refuse(f"the '{t.get('type')}' tool type is not available; use LiteLLM's gateway")
        if kind == "mcp":
            url = t.get("server_url")
            if not (isinstance(url, str) and url.startswith("litellm_proxy")):
                raise _refuse("an MCP tool must go through LiteLLM's gateway (server_url 'litellm_proxy...')")
            if masked and t.get("require_approval", "always") != "always":
                # LiteLLM would run the tool and send its result upstream in an internal call that
                # never passes this gate: the note's text would reach the cloud model unmasked.
                raise _refuse("toward a cloud model an MCP tool must keep require_approval 'always' (or unset), "
                              "so its result returns through this gate")
    extra = data.get("extra_body")
    if isinstance(extra, dict):
        check_mcp_tools(extra, masked)


def check_sendable(data: dict) -> list:
    """Refuse what cannot be scanned (400); otherwise return the request's text slots."""
    check_mcp_tools(data, masked=True)
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
        mcp_policy_path: str | None = None,
        chunk_chars: int = 100_000,
        chunk_overlap: int = 200,
        timeout: float = 15.0,
        cache_size: int = 512,
    ):
        super().__init__()
        self._path = policy_path
        self._mcp_path = mcp_policy_path
        self._mcp_policy: dict | None = None  # loaded on first use, like the PII policy
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

    @property
    def mcp_policy(self) -> dict:
        if self._mcp_policy is None:
            self._mcp_policy = mcp_policy.load_policy(
                self._mcp_path or os.environ.get("MCP_POLICY_PATH", "/app/mcp_policy.yaml"))
        return self._mcp_policy

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
        if call_type == "call_mcp_tool":
            # An MCP tool call has no model and runs on a server we host: it is a matter of who
            # may call what, decided by the authenticated key's team (the PII masking of what
            # comes back to a cloud model is done on the next chat request, as a tool_result).
            for new, old in (("mcp_tool_name", "name"), ("mcp_arguments", "arguments")):
                if new in data and old in data and data[new] != data[old]:
                    raise HTTPException(status_code=403, detail="mcp-policy: ambiguous tool call")
            reason = mcp_policy.refusal(
                self.mcp_policy, getattr(user_api_key_dict, "team_id", None) or None,
                data.get("mcp_tool_name") or data.get("name"),  # /mcp route / REST route bodies
                data.get("mcp_arguments") if "mcp_arguments" in data else data.get("arguments"))
            if reason:
                raise HTTPException(status_code=403, detail=f"mcp-policy: {reason}")
            return data
        if call_type == "pass_through_endpoint":
            # The body's `model` does not decide where a pass-through request goes, so it cannot
            # make the request local.
            raise _refuse("provider pass-through is not available (it is not masked)")
        model = data.get("model")
        # The team is the authenticated key's team_id, never anything the request body says; a
        # team alias can be duplicated or renamed, the id cannot. No team: the strictest set.
        team = getattr(user_api_key_dict, "team_id", None) or None
        decision = decide(self.policy, model, team)

        if not decision.mask:
            check_mcp_tools(data)
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
            for container, key, *flag in slots:
                if flag == [KEY]:  # a dict key cannot be masked without renaming it: refuse instead
                    if await self._mask(key, decision.groups, data) != key:
                        raise _refuse("a field name contains personal information and cannot be altered")
                    continue
                masked = await self._mask(container[key], decision.groups, data)
                if flag and masked != container[key]:
                    raise _refuse("a signed thinking block contains personal information and cannot be altered")
                if not flag:
                    container[key] = masked
        except HTTPException:
            raise
        except Exception:
            # Fail closed, and never put the text in the error.
            raise HTTPException(status_code=503, detail="cloud-pii: PII scanning unavailable, request refused") from None
        return data


gate = CloudPIIGate()
