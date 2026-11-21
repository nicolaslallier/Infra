"""Tests for litellm/cloud_pii.py against a stub presidio-analyzer (needs litellm).

Run: uv run -q --no-project --with pyyaml --with "litellm[proxy]==<tag>" python scripts/test_cloud_pii.py
"""
import asyncio
import copy
import hashlib
import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "litellm"))
from fastapi import HTTPException  # noqa: E402
from litellm.proxy._types import UserAPIKeyAuth  # noqa: E402

import cloud_pii as cp  # noqa: E402

EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.]+")
NAME = "Marie Tremblay"
LOCAL, CLOUD = "qwen3.8:27b-mlx", "cloud-anthropic"


class Stub(ThreadingHTTPServer):
    """Stands in for presidio-analyzer: emails and one person's name."""

    def __init__(self):
        self.calls = 0
        self.delay = 0.0

        class H(BaseHTTPRequestHandler):
            def do_POST(h):  # noqa: N805
                body = json.loads(h.rfile.read(int(h.headers["Content-Length"])))
                self.calls += 1
                if self.delay:
                    time.sleep(self.delay)
                text, wanted = body["text"], body.get("entities") or []
                out = []
                if "EMAIL_ADDRESS" in wanted:
                    out += [{"entity_type": "EMAIL_ADDRESS", "start": m.start(), "end": m.end(), "score": 0.9}
                            for m in EMAIL.finditer(text)]
                if "PERSON" in wanted and NAME in text:
                    i = text.index(NAME)
                    out.append({"entity_type": "PERSON", "start": i, "end": i + len(NAME), "score": 0.9})
                data = json.dumps(out).encode()
                h.send_response(200)
                h.send_header("Content-Type", "application/json")
                h.send_header("Content-Length", str(len(data)))
                h.end_headers()
                h.wfile.write(data)

            def log_message(h, *args):  # noqa: N805
                pass

        super().__init__(("127.0.0.1", 0), H)
        threading.Thread(target=self.serve_forever, daemon=True).start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server_address[1]}"


STUB = Stub()


def guard(url=None, **kw):
    return cp.CloudPIIGate(
        presidio_analyzer_api_base=url or STUB.url,
        policy_path=os.path.join(ROOT, "litellm", "pii_policy.yaml"),
        mcp_policy_path=os.path.join(ROOT, "litellm", "mcp_policy.yaml"), **kw,
    )


def call(g, model, messages=None, team="apps", extra=None, call_type="acompletion", auth=True):
    """Run the pre-call hook as the proxy would: the authenticated key's team_id is the team."""
    data = {"model": model, "messages": messages if messages is not None else [], **(extra or {})}
    key = UserAPIKeyAuth(team_id=team) if auth else None
    return asyncio.run(g.async_pre_call_hook(user_api_key_dict=key, cache=None, data=data, call_type=call_type))


def text(g, model, t, team="apps", **kw):
    """Masked form of one user message."""
    return call(g, model, [{"role": "user", "content": t}], team=team, **kw)["messages"][0]["content"]


def refused(fn, code):
    try:
        fn()
    except HTTPException as e:
        assert e.status_code == code, e.status_code
        return
    raise AssertionError("not refused")


def test_local_alias_passes_untouched_without_calling_presidio():
    before = STUB.calls
    msgs = [{"role": "user", "content": "a@b.co"}]
    tools = [{"name": "t", "cache_control": {"type": "ephemeral"}}]
    want = copy.deepcopy({"model": LOCAL, "messages": msgs, "tools": tools})
    want["cache"] = {"namespace": "apps"}  # the only addition: the per-team cache namespace
    assert call(guard(), LOCAL, msgs, extra={"tools": tools}) == want  # otherwise byte-identical
    assert STUB.calls == before


def test_cloud_alias_masks_identifiers():
    assert text(guard(), CLOUD, "write to a@b.co now", team="dev-sessions") == "write to <EMAIL_ADDRESS> now"


def test_cloud_alias_masks_names_for_famille_not_dev_sessions():
    assert text(guard(), CLOUD, f"salut {NAME}", team="famille") == "salut <PERSON>"
    assert text(guard(), CLOUD, f"salut {NAME}", team="dev-sessions") == f"salut {NAME}"


def test_cache_namespace_is_the_authenticated_team():
    # A client cannot pick another team's namespace; its own ttl is kept.
    for model in (CLOUD, LOCAL):
        out = call(guard(), model, team="famille", extra={"cache": {"namespace": "admin", "ttl": 5}})
        assert out["cache"] == {"namespace": "famille", "ttl": 5}, out
    # teamless: never a shared namespace (the master key and unassigned keys must not share hits)
    assert call(guard(), CLOUD, team=None)["cache"]["namespace"] == "key:anonymous"


def test_unknown_alias_is_masked():
    assert text(guard(), "gpt-x", "a@b.co") == "<EMAIL_ADDRESS>"


def test_no_team_masks_names():
    assert text(guard(), CLOUD, f"salut {NAME}", team=None) == "salut <PERSON>"
    assert text(guard(), CLOUD, f"salut {NAME}", auth=False) == "salut <PERSON>"


def test_a_team_alias_is_not_the_team():
    # Aliases can be duplicated or renamed; the policy is keyed on the team's id.
    g = guard()
    key = UserAPIKeyAuth(team_id="some-uuid", team_alias="dev-sessions")
    data = {"model": CLOUD, "messages": [{"role": "user", "content": f"salut {NAME}"}]}
    out = asyncio.run(g.async_pre_call_hook(user_api_key_dict=key, cache=None, data=data, call_type="acompletion"))
    assert out["messages"][0]["content"] == "salut <PERSON>"  # unknown id: the strictest default


def test_client_supplied_team_in_the_body_is_ignored():
    spoof = {"metadata": {"user_api_key_team_id": "dev-sessions", "user_api_key_team_alias": "dev-sessions"},
             "litellm_metadata": {"user_api_key_team_id": "dev-sessions"}}
    assert text(guard(), CLOUD, f"salut {NAME}", team="famille", extra=spoof) == "salut <PERSON>"
    assert text(guard(), CLOUD, f"salut {NAME}", team=None, extra=spoof) == "salut <PERSON>"


def test_presidio_down_refuses_cloud_and_passes_local():
    g = guard(url="http://127.0.0.1:1")
    refused(lambda: text(g, CLOUD, "a@b.co"), 503)
    assert text(g, LOCAL, "a@b.co") == "a@b.co"


def test_a_hung_presidio_is_refused_not_awaited_forever():
    STUB.delay = 1.0
    try:
        refused(lambda: text(guard(timeout=0.2), CLOUD, "a@b.co"), 503)
    finally:
        STUB.delay = 0.0


def test_image_block_refused_for_cloud_even_without_text_passes_for_local():
    msg = [{"role": "user", "content": [{"type": "image", "source": {"data": "AAAA"}}]}]
    refused(lambda: call(guard(), CLOUD, copy.deepcopy(msg)), 400)
    refused(lambda: call(guard(), "gpt-x", copy.deepcopy(msg)), 400)
    call(guard(), LOCAL, msg)


def test_unknown_block_type_refused_for_cloud():
    msg = [{"role": "user", "content": [{"type": "document", "source": {"data": "x"}}]}]
    refused(lambda: call(guard(), CLOUD, msg), 400)


def test_long_text_with_email_on_chunk_boundary_is_masked():
    t = "a" * 40 + " bob@example.com " + "b" * 60
    out = text(guard(chunk_chars=50, chunk_overlap=20), CLOUD, t, team="dev-sessions")
    assert "bob@example.com" not in out and "<EMAIL_ADDRESS>" in out, out


def test_vector_store_ids_on_cloud_request_refused():
    refused(lambda: call(guard(), CLOUD, extra={"vector_store_ids": ["second-brain"]}), 400)
    refused(lambda: call(guard(), CLOUD, extra={"tools": [{"type": "file_search"}]}), 400)
    call(guard(), LOCAL, extra={"vector_store_ids": ["second-brain"]})


def test_system_tool_result_and_tool_use_text_are_masked_in_place():
    msgs = [
        {"role": "system", "content": "boss: a@b.co"},
        {"role": "assistant", "content": [{"type": "tool_use", "id": "1", "name": "mail", "input": {"to": "a@b.co", "n": 2}}]},
        {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "1", "content": [{"type": "text", "text": "from a@b.co"}]}]},
        {"role": "assistant", "content": None, "tool_calls": [{"function": {"name": "f", "arguments": '{"e": "a@b.co"}'}}]},
    ]
    data = call(guard(), CLOUD, msgs, extra={"system": [{"type": "text", "text": "sys a@b.co"}]})
    flat = json.dumps(data)
    assert "a@b.co" not in flat and flat.count("<EMAIL_ADDRESS>") == 5, flat
    assert data["messages"][1]["content"][0]["input"]["n"] == 2  # non-strings untouched


def test_other_free_text_fields_are_masked():
    msgs = [
        {"role": "user", "name": "a@b.co", "content": "x"},
        {"role": "assistant", "content": None, "function_call": {"name": "f", "arguments": '{"e": "a@b.co"}'}},
    ]
    tools = [
        {"type": "function", "function": {"name": "t", "description": "mail a@b.co", "parameters": {"properties": {"p": {"description": "e.g. a@b.co"}}}}},
        {"name": "anth", "description": "to a@b.co", "input_schema": {"properties": {"q": {"description": "a@b.co"}}}},
    ]
    extra = {"instructions": "a@b.co", "user": "a@b.co", "tools": tools,
             "prediction": {"type": "content", "content": "a@b.co"}, "prompt": {"id": "p", "variables": {"who": "a@b.co"}}}
    flat = json.dumps(call(guard(), CLOUD, msgs, extra=extra))
    assert "a@b.co" not in flat, flat


def test_a_token_array_embedding_input_is_refused_for_cloud():
    refused(lambda: call(guard(), "cloud-emb", extra={"input": [[1, 2, 3]]}, call_type="aembedding"), 400)
    assert call(guard(), "cloud-emb", extra={"input": ["a@b.co"]}, call_type="aembedding")["input"] == ["<EMAIL_ADDRESS>"]


def test_thinking_blocks_are_passed_through_unchanged():
    block = {"type": "thinking", "thinking": "je compare les deux options", "signature": "sig"}
    data = call(guard(), CLOUD, [{"role": "assistant", "content": [copy.deepcopy(block)]}])
    assert data["messages"][0]["content"][0] == block  # a signed block must stay byte-identical


def test_a_thinking_block_carrying_personal_information_is_refused():
    # Signed blocks cannot be altered, but a client can write anything in one: scan, and refuse.
    for block in ({"type": "thinking", "thinking": "mail a@b.co", "signature": "sig"},
                  {"type": "redacted_thinking", "data": "a@b.co"}):
        refused(lambda: call(guard(), CLOUD, [{"role": "assistant", "content": [copy.deepcopy(block)]}]), 400)


def test_message_level_thinking_blocks_are_scanned_strictly():
    ok = {"type": "thinking", "thinking": "je compare", "signature": "s"}
    msg = lambda blocks: [{"role": "assistant", "content": "x", "thinking_blocks": blocks}]  # noqa: E731
    assert call(guard(), CLOUD, msg([copy.deepcopy(ok)]))["messages"][0]["thinking_blocks"] == [ok]
    refused(lambda: call(guard(), CLOUD, msg([{**ok, "thinking": "mail a@b.co"}])), 400)


def test_reasoning_content_is_masked():
    out = call(guard(), CLOUD, [{"role": "assistant", "content": "x", "reasoning_content": "mail a@b.co"}])
    assert out["messages"][0]["reasoning_content"] == "mail <EMAIL_ADDRESS>"


def test_a_message_field_that_cannot_be_scanned_is_refused_for_cloud():
    msg = [{"role": "user", "content": "x", "weird": {"a": "b"}}]
    refused(lambda: call(guard(), CLOUD, copy.deepcopy(msg)), 400)
    call(guard(), LOCAL, msg)


def test_malformed_blocks_are_refused_not_skipped():
    ok = {"type": "thinking", "thinking": "je compare", "signature": "s"}
    for bad in ({**ok, "thinking": ["a@b.co"]}, {**ok, "note": "a@b.co"}, {"type": "text", "text": ["a@b.co"]},
                {"type": "redacted_thinking", "data": {"x": "a@b.co"}}):
        refused(lambda: call(guard(), CLOUD, [{"role": "assistant", "content": [copy.deepcopy(bad)]}]), 400)


def test_every_string_of_an_allowed_field_is_scanned():
    msgs = [
        {"role": "assistant", "content": None, "tool_calls": [{"id": "a@b.co", "type": "function", "function": {"name": "a@b.co", "arguments": "{}"}}]},
        {"role": "tool", "tool_call_id": "a@b.co", "name": "a@b.co", "content": "x"},
        {"role": "assistant", "content": [
            {"type": "tool_use", "id": "a@b.co", "name": "a@b.co", "input": {}},
            {"type": "text", "text": "x", "citations": [{"cited_text": "a@b.co"}]},
        ]},
        {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "a@b.co", "content": "x"}]},
    ]
    flat = json.dumps(call(guard(), CLOUD, msgs))
    assert "a@b.co" not in flat and flat.count("<EMAIL_ADDRESS>") == 8, flat


def test_role_must_be_a_known_role():
    refused(lambda: call(guard(), CLOUD, [{"role": "a@b.co", "content": "x"}]), 400)
    call(guard(), CLOUD, [{"role": "developer", "content": "x"}])


def test_cache_control_must_have_the_known_shape():
    ok = {"type": "ephemeral", "ttl": "1h"}
    assert call(guard(), CLOUD, [{"role": "user", "content": [{"type": "text", "text": "x", "cache_control": dict(ok)}]}]) \
        ["messages"][0]["content"][0]["cache_control"] == ok
    for bad in ({"type": "ephemeral", "note": "a@b.co"}, {"type": "a@b.co"}, {"type": "ephemeral", "ttl": "a@b.co"}, "a@b.co"):
        refused(lambda: call(guard(), CLOUD, [{"role": "user", "content": [{"type": "text", "text": "x", "cache_control": copy.deepcopy(bad)}]}]), 400)
        refused(lambda: call(guard(), CLOUD, [{"role": "user", "content": "x", "cache_control": copy.deepcopy(bad)}]), 400)


def test_a_signature_is_scanned_strictly():
    blk = lambda sig: [{"role": "assistant", "content": [{"type": "thinking", "thinking": "ok", "signature": sig}]}]  # noqa: E731
    assert call(guard(), CLOUD, blk("EqQBCkYIARgC"))["messages"][0]["content"][0]["signature"] == "EqQBCkYIARgC"
    refused(lambda: call(guard(), CLOUD, blk("a@b.co")), 400)
    refused(lambda: call(guard(), CLOUD, blk({"x": "a@b.co"})), 400)


def test_wrong_types_in_allowed_fields_are_refused():
    for msg in ({"role": "assistant", "content": "x", "reasoning_content": ["a@b.co"]},
                {"role": "assistant", "content": {"text": "a@b.co"}},
                {"role": "assistant", "content": "x", "refusal": {"a": "a@b.co"}},
                {"role": "assistant", "content": None, "tool_calls": [{"id": "1", "function": {"name": "f", "arguments": {"e": "a@b.co"}}}]},
                {"role": "assistant", "content": None, "tool_calls": [{"id": "1", "function": {"name": "f", "arguments": "{}"}, "note": "a@b.co"}]}):
        refused(lambda: call(guard(), CLOUD, [copy.deepcopy(msg)]), 400)


def test_dict_keys_with_personal_information_are_refused():
    tool_use = lambda inp: [{"role": "assistant", "content": [{"type": "tool_use", "id": "t", "name": "n", "input": inp}]}]  # noqa: E731
    refused(lambda: call(guard(), CLOUD, tool_use({"a@b.co": "x"})), 400)
    refused(lambda: call(guard(), CLOUD, tool_use({"outer": {"a@b.co": 1}})), 400)
    refused(lambda: call(guard(), CLOUD, extra={"prompt": {"id": "p", "variables": {"a@b.co": "x"}}}), 400)
    cited = [{"role": "assistant", "content": [{"type": "text", "text": "x", "citations": [{"a@b.co": "y"}]}]}]
    refused(lambda: call(guard(), CLOUD, cited), 400)
    call(guard(), CLOUD, tool_use({"command": "ls", "args": {"path": "."}}))  # ordinary keys pass


def test_is_error_and_index_must_have_their_type():
    res = lambda v: [{"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t", "content": "x", "is_error": v}]}]  # noqa: E731
    call(guard(), CLOUD, res(True))
    refused(lambda: call(guard(), CLOUD, res("a@b.co")), 400)
    tc = lambda i: [{"role": "assistant", "content": None, "tool_calls": [{"id": "1", "index": i, "function": {"name": "f", "arguments": "{}"}}]}]  # noqa: E731
    call(guard(), CLOUD, tc(0))
    refused(lambda: call(guard(), CLOUD, tc("a@b.co")), 400)
    refused(lambda: call(guard(), CLOUD, tc(True)), 400)  # a bool is not an index


def test_pass_through_is_refused_whatever_model_the_body_names():
    # The body's `model` does not decide where a pass-through request goes.
    refused(lambda: call(guard(), LOCAL, call_type="pass_through_endpoint"), 400)
    refused(lambda: call(guard(), CLOUD, call_type="pass_through_endpoint"), 400)
    refused(lambda: call(guard(), None, call_type="pass_through_endpoint"), 400)


def test_a_cloud_fallback_on_a_local_request_is_refused():
    for key in ("fallbacks", "context_window_fallbacks", "content_policy_fallbacks"):
        refused(lambda: call(guard(), LOCAL, extra={key: ["cloud-openai"]}), 400)
        refused(lambda: call(guard(), LOCAL, extra={key: [{LOCAL: ["cloud-openai"]}]}), 400)
        refused(lambda: call(guard(), LOCAL, extra={key: ["no-such-alias"]}), 400)  # unknown = not local
    assert call(guard(), LOCAL, extra={"fallbacks": ["gemma4:26b-a4b-it-qat"]})["model"] == LOCAL
    assert call(guard(), CLOUD, extra={"fallbacks": ["cloud-openai"]})["model"] == CLOUD  # masked anyway


def test_endpoints_without_masking_are_refused_toward_non_local_models():
    for ct in ("amoderation", "agenerate_content", "acreate_file", "acreate_batch", "aimage_edit", "pass_through_endpoint"):
        refused(lambda: call(guard(), CLOUD, call_type=ct), 400)
    refused(lambda: call(guard(), None, call_type="pass_through_endpoint"), 400)  # no model: not local
    for ct in ("acompletion", "atext_completion", "aembedding", "aresponses", "anthropic_messages"):
        call(guard(), CLOUD, call_type=ct)
    call(guard(), LOCAL, call_type="amoderation")  # a local model keeps every endpoint


def test_masking_is_cached_per_text():
    g = guard()
    text(g, CLOUD, "a@b.co", team="dev-sessions")
    before = STUB.calls
    assert text(g, CLOUD, "a@b.co", team="dev-sessions") == "<EMAIL_ADDRESS>"
    assert STUB.calls == before


def test_overlapping_spans_are_merged_so_no_tail_leaks():
    t = "Marie Tremblay marie@example.com x"
    assert cp._replace(t, [(0, 20, "PERSON"), (15, 32, "EMAIL_ADDRESS")]) == "<PERSON> x"


def test_provider_token_counting_is_turned_off():
    # /v1/messages/count_tokens would post the whole conversation to Anthropic without any hook.
    from litellm.proxy import proxy_server

    assert asyncio.run(proxy_server._try_provider_token_count(None, "anthropic", "m", [], None, None, "m")) is None


def mcp_call(g, tool, team="admin", args=None, auth=True):
    """What the proxy hands the gate for an MCP tool call (observed on LiteLLM 1.83.14)."""
    data = {"model": "mcp-tool-call", "messages": [{"role": "user", "content": f"Tool: {tool}"}],
            "mcp_tool_name": tool, "mcp_arguments": args or {}}
    key = UserAPIKeyAuth(team_id=team) if auth else None
    return asyncio.run(g.async_pre_call_hook(user_api_key_dict=key, cache=None, data=data, call_type="call_mcp_tool"))


def test_an_mcp_call_is_allowed_for_a_team_with_access():
    assert mcp_call(guard(), "read_note", team="admin")["mcp_tool_name"] == "read_note"
    assert mcp_call(guard(), "read_note", team="apps")["mcp_tool_name"] == "read_note"
    assert mcp_call(guard(), "search_repositories", team="admin")["mcp_tool_name"] == "search_repositories"


def test_an_mcp_call_is_refused_with_403_for_a_team_without_access():
    for tool, team in (("read_note", "famille"), ("read_note", "dev-sessions"), ("search_repositories", "apps"),
                       ("create_or_update_file", "apps")):
        try:
            mcp_call(guard(), tool, team=team, args={"branch": "feat"})
            raise AssertionError(f"{tool}/{team} not refused")
        except HTTPException as e:
            assert e.status_code == 403, e.status_code


def test_an_mcp_call_without_a_team_is_refused():
    refused(lambda: mcp_call(guard(), "read_note", team=None), 403)  # no team: the master key or a loose key


def test_merge_pull_request_is_refused_even_for_admin():
    refused(lambda: mcp_call(guard(), "merge_pull_request", team="admin"), 403)  # on no list


def test_a_github_write_to_a_default_branch_is_refused():
    for args in ({}, {"branch": ""}, {"branch": "main"}, {"branch": "master"}):
        for tool in ("create_or_update_file", "push_files"):
            refused(lambda: mcp_call(guard(), tool, args=dict(args)), 403)
    mcp_call(guard(), "create_or_update_file", args={"branch": "claude/feature"})
    mcp_call(guard(), "push_files", args={"branch": "claude/feature"})


def a2a_call(g, agent_id, team="admin", auth=True):
    """What the A2A route hands the gate (litellm 1.108.14, a2a_endpoints.py)."""
    data = {"jsonrpc": "2.0", "id": 1, "method": "SendMessage", "agent_id": agent_id,
            "model": "a2a_agent/agent-test", "custom_llm_provider": "a2a_agent",
            "params": {"message": {"parts": [{"text": "Marie Tremblay, a@b.co"}]}}}
    key = UserAPIKeyAuth(team_id=team) if auth else None
    return asyncio.run(g.async_pre_call_hook(user_api_key_dict=key, cache=None, data=data, call_type="asend_message"))


def test_the_config_agent_id_is_sha256_of_its_name():
    from litellm.proxy.agent_endpoints.agent_registry import global_agent_registry
    assert global_agent_registry._create_agent_id({"agent_name": "agent-test"}) == hashlib.sha256(b"agent-test").hexdigest()


def test_an_a2a_call_is_allowed_for_admin_only_and_not_masked():
    at = hashlib.sha256(b"agent-test").hexdigest()
    before = STUB.calls
    out = a2a_call(guard(), at)
    assert out["params"]["message"]["parts"][0]["text"] == "Marie Tremblay, a@b.co" and STUB.calls == before
    for team in ("famille", "apps", "dev-sessions", None):
        refused(lambda: a2a_call(guard(), at, team=team), 403)
    refused(lambda: a2a_call(guard(), at, auth=False), 403)
    for other in ("agent-test", hashlib.sha256(b"other").hexdigest(), None):
        refused(lambda: a2a_call(guard(), other), 403)


def test_an_agent_as_a_model_is_refused_for_everyone():
    for model in ("a2a/agent-test", "A2A/agent-test", "a2a_agent/agent-test", "A2A_Agent/agent-test",
                  " a2a/agent-test", "a2a/other", "agent-test", "Agent-Test"):
        for team in ("admin", "apps"):
            refused(lambda: call(guard(), model, [{"role": "user", "content": "x"}], team=team), 403)
    for provider in ("a2a_agent", "A2A"):  # the provider named in the body, whatever the model
        refused(lambda: call(guard(), LOCAL, [{"role": "user", "content": "x"}], team="admin",
                             extra={"custom_llm_provider": provider}), 403)
    call(guard(), LOCAL, [{"role": "user", "content": "a2a/ in text is fine"}], team="admin")
    for model in (LOCAL, CLOUD):
        for fb in ({"fallbacks": ["a2a/agent-test"]}, {"context_window_fallbacks": [{LOCAL: ["agent-test"]}]}):
            refused(lambda: call(guard(), model, [{"role": "user", "content": "x"}], team="admin",
                                 extra=copy.deepcopy(fb)), 403)


def test_mcp_arguments_are_not_masked_and_need_no_model():
    out = mcp_call(guard(), "issue_write", args={"body": "write to a@b.co"})
    assert out["mcp_arguments"]["body"] == "write to a@b.co"  # the owner's own action


def test_hosted_mcp_tools_in_a_chat_request_are_refused_unless_they_go_through_litellm():
    foreign = {"tools": [{"type": "mcp", "server_label": "x", "server_url": "https://evil.example/mcp"}]}
    refused(lambda: call(guard(), CLOUD, extra=copy.deepcopy(foreign)), 400)
    refused(lambda: call(guard(), LOCAL, extra=copy.deepcopy(foreign)), 400)  # LiteLLM would connect to it itself
    refused(lambda: call(guard(), CLOUD, extra={"tools": [{"type": "mcp", "server_label": "x"}]}), 400)  # no url at all
    ok = {"tools": [{"type": "mcp", "server_label": "litellm", "server_url": "litellm_proxy/mcp/obsidian"}]}
    call(guard(), CLOUD, extra=copy.deepcopy(ok))  # goes through the gateway, so through call_mcp_tool


def test_gateway_mcp_auto_execution_is_refused_toward_cloud_models():
    # require_approval "never" makes LiteLLM run the tool and send its RESULT upstream in an internal
    # call that never passes this gate: unmasked. Toward a cloud model the call must come back to the client.
    def tool(**kw):
        return {"tools": [{"type": "mcp", "server_label": "l", "server_url": "litellm_proxy", **kw}]}
    for kw in ({"require_approval": "never"}, {"require_approval": {"never": {"tool_names": ["read_note"]}}},
               {"require_approval": "anything"}, {"require_approval": None}):
        refused(lambda: call(guard(), CLOUD, extra=tool(**copy.deepcopy(kw))), 400)
    refused(lambda: call(guard(), CLOUD, extra={"extra_body": tool(require_approval="never")}), 400)
    call(guard(), CLOUD, extra=tool())  # absent: the client approves each call
    call(guard(), CLOUD, extra=tool(require_approval="always"))
    call(guard(), LOCAL, extra=tool(require_approval="never"))  # a local model sees real data anyway


def test_the_rest_call_shape_is_decided_like_the_mcp_route():
    def rest(body, team="admin"):
        return asyncio.run(guard().async_pre_call_hook(user_api_key_dict=UserAPIKeyAuth(team_id=team), cache=None,
                                                       data=body, call_type="call_mcp_tool"))
    rest({"name": "read_note", "arguments": {}, "server_id": "x"})
    refused(lambda: rest({"name": "read_note", "arguments": {}}, team="famille"), 403)
    refused(lambda: rest({"name": "merge_pull_request", "arguments": {}}), 403)
    refused(lambda: rest({"name": "push_files", "arguments": {"branch": "main"}}), 403)
    # both shapes at once, disagreeing: ambiguous, refused whichever one is the harmless one
    refused(lambda: rest({"mcp_tool_name": "read_note", "name": "push_files", "arguments": {}}, team="apps"), 403)
    refused(lambda: rest({"name": "push_files", "mcp_tool_name": "read_note", "mcp_arguments": {}}, team="admin"), 403)
    refused(lambda: rest({"mcp_tool_name": "create_or_update_file", "mcp_arguments": {"branch": "f"},
                          "arguments": {"branch": "main"}}), 403)


def test_provider_native_mcp_connectors_are_refused():
    # Anthropic's connector (`mcp_servers` + an `mcp_toolset` tool) and similar make the PROVIDER
    # contact a URL of the client's choosing, outside our MCP policy.
    servers = {"mcp_servers": [{"type": "url", "url": "https://evil.example/mcp", "name": "x"}]}
    refused(lambda: call(guard(), CLOUD, extra=copy.deepcopy(servers)), 400)
    refused(lambda: call(guard(), LOCAL, extra=copy.deepcopy(servers)), 400)
    refused(lambda: call(guard(), CLOUD, extra={"tools": [{"type": "mcp_toolset", "mcp_server_name": "x"}]}), 400)
    call(guard(), CLOUD, extra={"mcp_servers": []})  # empty is nothing


def test_mcp_connectors_hidden_in_extra_body_or_with_odd_casing_are_refused():
    inner = {"mcp_servers": [{"type": "url", "url": "https://evil.example/mcp", "name": "x"}]}
    refused(lambda: call(guard(), CLOUD, extra={"extra_body": copy.deepcopy(inner)}), 400)
    refused(lambda: call(guard(), LOCAL, extra={"extra_body": copy.deepcopy(inner)}), 400)
    refused(lambda: call(guard(), CLOUD, extra={"extra_body": {"tools": [{"type": "mcp_toolset"}]}}), 400)
    refused(lambda: call(guard(), CLOUD, extra={"tools": [{"type": "MCP_Toolset"}]}), 400)
    refused(lambda: call(guard(), CLOUD, extra={"tools": [{"type": "MCP", "server_url": "https://evil.example/mcp"}]}), 400)
    call(guard(), CLOUD, extra={"extra_body": {"top_k": 5}})  # ordinary extra_body content is not our business


def test_gate_exists_at_import_without_the_policy_file():
    assert isinstance(cp.gate, cp.CloudPIIGate)  # config.yaml registers `cloud_pii.gate`; /app/pii_policy.yaml is absent here


if __name__ == "__main__":
    failed = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"  ok    {name}")
            except Exception as e:  # noqa: BLE001
                failed += 1
                print(f"  FAIL  {name}: {e!r}")
    sys.exit(1 if failed else 0)
