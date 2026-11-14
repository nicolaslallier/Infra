"""cloud-pii: mask personal information on requests to non-local models only.

Mounted into the litellm container next to pii_policy.py (see config.yaml `guardrails:`).
The policy (pii_policy.yaml) says which aliases are local; everything else is masked, so an
alias added in the admin UI under a free name is masked, not leaked. Fails closed.
Design: docs/superpowers/specs/2026-11-14-litellm-cloud-pii-design.md
"""
import os
from typing import Any

from fastapi import HTTPException
from litellm.integrations.custom_guardrail import CustomGuardrail
from litellm.integrations.custom_logger import CustomLogger
from litellm.proxy.guardrails.guardrail_hooks.presidio import _OPTIONAL_PresidioPIIMasking

from pii_policy import chunk_text, decide, entities_for, load_policy

TEXT_TYPES = {"text", "input_text", "output_text"}  # content blocks Presidio can read


def _refuse(detail: str) -> HTTPException:
    return HTTPException(status_code=400, detail=f"cloud-pii: {detail}")


def _add(slots: list, container: Any, key: Any) -> None:
    if isinstance(container[key], str):
        slots.append((container, key))


def _string_leaves(node: Any, slots: list) -> None:
    items = node.items() if isinstance(node, dict) else enumerate(node) if isinstance(node, list) else ()
    for k, v in list(items):
        if isinstance(v, str):
            slots.append((node, k))
        else:
            _string_leaves(v, slots)


def _blocks(content: Any, slots: list) -> None:
    """Text-bearing spots of a content list; a block Presidio cannot read is refused."""
    for i, b in enumerate(content):
        if isinstance(b, str):
            slots.append((content, i))
        elif not isinstance(b, dict):
            raise _refuse("unreadable content block")
        elif b.get("type") in TEXT_TYPES:
            _add(slots, b, "text") if "text" in b else None
        elif b.get("type") == "tool_use":
            _string_leaves(b.get("input"), slots)
        elif b.get("type") == "tool_result":
            c = b.get("content")
            if isinstance(c, str):
                slots.append((b, "content"))
            elif isinstance(c, list):
                _blocks(c, slots)
        elif b.get("type") == "thinking":
            _add(slots, b, "thinking") if "thinking" in b else None
        elif b.get("type") == "redacted_thinking":
            pass  # opaque, nothing to read
        else:
            raise _refuse(f"'{b.get('type')}' content is not sent to a non-local model (it cannot be scanned)")


def _slots(data: dict) -> list:
    """Every string in the request that can carry text, as (container, key)."""
    slots: list = []
    for field in ("system", "prompt", "input"):
        v = data.get(field)
        if isinstance(v, str):
            slots.append((data, field))
        elif isinstance(v, list):
            for i, item in enumerate(v):
                if isinstance(item, str):
                    slots.append((v, i))
                elif isinstance(item, dict) and "content" in item:
                    if isinstance(item["content"], str):
                        slots.append((item, "content"))
                    elif isinstance(item["content"], list):
                        _blocks(item["content"], slots)
                elif isinstance(item, dict):
                    _blocks([item], slots)
    for m in data.get("messages") or []:
        c = m.get("content")
        if isinstance(c, str):
            slots.append((m, "content"))
        elif isinstance(c, list):
            _blocks(c, slots)
        for tc in m.get("tool_calls") or []:
            fn = tc.get("function") if isinstance(tc, dict) else None
            if isinstance(fn, dict):
                _add(slots, fn, "arguments") if "arguments" in fn else None
    return slots


def check_sendable(data: dict, images: list | None = None) -> list:
    """Refuse what cannot be scanned (400); otherwise return the request's text slots."""
    if images:
        raise _refuse("images are not sent to a non-local model (they cannot be scanned)")
    if data.get("vector_store_ids") or any(
        isinstance(t, dict) and t.get("type") == "file_search" for t in data.get("tools") or []
    ):
        raise _refuse("vector stores are not combined with a non-local model yet")
    return _slots(data)


def _replace(text: str, spans: list[tuple[int, int, str]]) -> str:
    """Replace detected spans by <ENTITY_TYPE> (Presidio's default), longest first on overlap."""
    keep: list[tuple[int, int, str]] = []
    for s, e, t in sorted(spans, key=lambda x: (x[0], -x[1])):
        if not keep or s >= keep[-1][1]:
            keep.append((s, e, t))
    for s, e, t in reversed(keep):
        text = text[:s] + f"<{t}>" + text[e:]
    return text


class CloudPII(CustomGuardrail):
    # System prompts hold personal information too: never let the framework skip them.
    skip_system_message_in_guardrail = False

    def __init__(
        self,
        presidio_analyzer_api_base: str | None = None,
        presidio_anonymizer_api_base: str | None = None,
        policy_path: str | None = None,
        chunk_chars: int = 100_000,
        chunk_overlap: int = 200,
        **kwargs,
    ):
        super().__init__(**kwargs)
        self.policy = load_policy(policy_path or os.environ.get("PII_POLICY_PATH", "/app/pii_policy.yaml"))
        self.chunk_chars, self.chunk_overlap = chunk_chars, chunk_overlap
        # Presidio's entities, language and thresholds are instance state, so one helper per
        # (group, language) rather than mutating a shared one under concurrent requests.
        self._helpers: dict[tuple[str, str], _OPTIONAL_PresidioPIIMasking] = {}
        for name, group in self.policy["groups"].items():
            for lang in group["languages"]:
                self._helpers[(name, lang)] = _OPTIONAL_PresidioPIIMasking(
                    presidio_analyzer_api_base=presidio_analyzer_api_base,
                    presidio_anonymizer_api_base=presidio_anonymizer_api_base,
                    pii_entities_config={e: "MASK" for e in entities_for(self.policy, (name,))},
                    presidio_score_thresholds=group.get("thresholds"),
                    presidio_language=lang,
                    guardrail_name=f"cloud-pii-{name}-{lang}",
                    event_hook="pre_call",
                    default_on=False,
                )

    @staticmethod
    def _team(request_data: dict) -> str | None:
        for key in ("metadata", "litellm_metadata"):
            alias = (request_data.get(key) or {}).get("user_api_key_team_alias")
            if alias:
                return alias
        return None

    async def _mask(self, text: str, groups: tuple[str, ...], request_data: dict, memo: dict) -> str:
        if (text, groups) in memo:
            return memo[(text, groups)]
        spans: list[tuple[int, int, str]] = []
        for g in groups:
            for lang in self.policy["groups"][g]["languages"]:
                helper = self._helpers[(g, lang)]
                for start, end in chunk_text(text, self.chunk_chars, self.chunk_overlap):
                    found = await helper.analyze_text(text=text[start:end], presidio_config=None, request_data=request_data)
                    for r in helper.filter_analyze_results_by_score(found):
                        t = r["entity_type"]
                        spans.append((start + r["start"], start + r["end"], str(getattr(t, "value", t))))
        memo[(text, groups)] = _replace(text, spans)
        return memo[(text, groups)]

    async def apply_guardrail(self, inputs, request_data, input_type, logging_obj=None):
        if input_type != "request":
            return inputs  # the model's answer is not rewritten (non-goal)
        model = inputs.get("model") or request_data.get("model")
        decision = decide(self.policy, model, self._team(request_data))
        if not decision.mask:
            return inputs  # local: the data never leaves the Macs

        slots = check_sendable(request_data, inputs.get("images"))  # refuse before touching anything

        memo: dict = {}
        try:
            for container, key in slots:
                container[key] = await self._mask(container[key], decision.groups, request_data, memo)
            # The framework writes inputs["texts"] back over the messages: keep them consistent.
            inputs["texts"] = [await self._mask(t, decision.groups, request_data, memo) for t in inputs.get("texts", [])]
        except HTTPException:
            raise
        except Exception:
            # Fail closed, and never put the text in the error.
            raise HTTPException(status_code=503, detail="cloud-pii: PII scanning unavailable, request refused") from None
        return inputs


class CloudPIIGate(CustomLogger):
    """Refusals for every request, text or not.

    LiteLLM calls a guardrail only when it finds text in the request, so an image-only (or
    otherwise text-less) request would skip CloudPII entirely. This pre-call callback runs
    regardless and applies the same refusals; masking stays in CloudPII.
    Registered with `litellm_settings.callbacks: cloud_pii.gate`.
    """

    def __init__(self, policy_path: str | None = None):
        super().__init__()
        self._path = policy_path
        self._policy: dict | None = None  # loaded on first use: importing must not need the file

    @property
    def policy(self) -> dict:
        if self._policy is None:
            self._policy = load_policy(self._path or os.environ.get("PII_POLICY_PATH", "/app/pii_policy.yaml"))
        return self._policy

    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        if decide(self.policy, data.get("model"), None).mask:
            check_sendable(data)
        return data


gate = CloudPIIGate()
