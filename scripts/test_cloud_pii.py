"""Tests for litellm/cloud_pii.py against a stub presidio-analyzer (needs litellm).

Run: uv run -q --no-project --with pyyaml --with "litellm[proxy]==<tag>" python scripts/test_cloud_pii.py
"""
import asyncio
import copy
import json
import os
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "litellm"))
from fastapi import HTTPException  # noqa: E402

import cloud_pii as cp  # noqa: E402

EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.]+")
NAME = "Marie Tremblay"
LOCAL, CLOUD = "qwen3.8:27b-mlx", "cloud-anthropic"


class Stub(ThreadingHTTPServer):
    """Stands in for presidio-analyzer: emails and one person's name."""

    def __init__(self):
        self.calls = 0

        class H(BaseHTTPRequestHandler):
            def do_POST(h):  # noqa: N805
                body = json.loads(h.rfile.read(int(h.headers["Content-Length"])))
                self.calls += 1
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

            def log_message(h, *a):  # noqa: N805
                pass

        super().__init__(("127.0.0.1", 0), H)
        threading.Thread(target=self.serve_forever, daemon=True).start()

    @property
    def url(self):
        return f"http://127.0.0.1:{self.server_address[1]}"


STUB = Stub()


def guard(url=None, **kw):
    u = url or STUB.url
    return cp.CloudPII(
        guardrail_name="cloud-pii", event_hook="pre_call", default_on=True,
        presidio_analyzer_api_base=u, presidio_anonymizer_api_base=u,
        policy_path=os.path.join(ROOT, "litellm", "pii_policy.yaml"), **kw,
    )


def run(g, model, texts, team="apps", messages=None, extra=None, images=None, input_type="request"):
    meta = {"user_api_key_team_alias": team} if team else {}
    data = {"model": model, "messages": messages if messages is not None else [], "metadata": meta, **(extra or {})}
    inputs = {"texts": list(texts), "model": model}
    if images:
        inputs["images"] = images
    out = asyncio.run(g.apply_guardrail(inputs=inputs, request_data=data, input_type=input_type))
    return out, data


def refused(fn, code):
    try:
        fn()
    except HTTPException as e:
        assert e.status_code == code, e.status_code
        return
    raise AssertionError("not refused")


def test_local_alias_passes_untouched_without_calling_presidio():
    before = STUB.calls
    out, data = run(guard(), LOCAL, ["write to a@b.co"], messages=[{"role": "user", "content": "a@b.co"}])
    assert out["texts"] == ["write to a@b.co"] and data["messages"][0]["content"] == "a@b.co"
    assert STUB.calls == before


def test_cloud_alias_masks_identifiers():
    out, _ = run(guard(), CLOUD, ["write to a@b.co now"], team="dev-sessions")
    assert out["texts"] == ["write to <EMAIL_ADDRESS> now"], out


def test_cloud_alias_masks_names_for_famille_not_dev_sessions():
    assert run(guard(), CLOUD, [f"salut {NAME}"], team="famille")[0]["texts"] == ["salut <PERSON>"]
    assert run(guard(), CLOUD, [f"salut {NAME}"], team="dev-sessions")[0]["texts"] == [f"salut {NAME}"]


def test_unknown_alias_is_masked():
    assert run(guard(), "gpt-x", ["a@b.co"])[0]["texts"] == ["<EMAIL_ADDRESS>"]


def test_no_team_masks_names():
    assert run(guard(), CLOUD, [f"salut {NAME}"], team=None)[0]["texts"] == ["salut <PERSON>"]


def test_presidio_down_refuses_cloud_and_passes_local():
    g = guard(url="http://127.0.0.1:1")
    refused(lambda: run(g, CLOUD, ["a@b.co"]), 503)
    assert run(g, LOCAL, ["a@b.co"])[0]["texts"] == ["a@b.co"]


def test_image_block_refused_for_cloud_passes_for_local():
    msg = [{"role": "user", "content": [{"type": "image", "source": {"data": "AAAA"}}]}]
    refused(lambda: run(guard(), CLOUD, [], messages=msg, images=["AAAA"]), 400)
    refused(lambda: run(guard(), CLOUD, [], messages=copy.deepcopy(msg)), 400)  # even when the framework listed none
    run(guard(), LOCAL, [], messages=msg, images=["AAAA"])


def test_unknown_block_type_refused_for_cloud():
    msg = [{"role": "user", "content": [{"type": "document", "source": {"data": "x"}}]}]
    refused(lambda: run(guard(), CLOUD, [], messages=msg), 400)


def test_long_text_with_email_on_chunk_boundary_is_masked():
    text = "a" * 40 + " bob@example.com " + "b" * 60
    out, _ = run(guard(chunk_chars=50, chunk_overlap=20), CLOUD, [text], team="dev-sessions")
    assert "bob@example.com" not in out["texts"][0] and "<EMAIL_ADDRESS>" in out["texts"][0], out


def test_vector_store_ids_on_cloud_request_refused():
    refused(lambda: run(guard(), CLOUD, ["q"], extra={"vector_store_ids": ["second-brain"]}), 400)
    refused(lambda: run(guard(), CLOUD, ["q"], extra={"tools": [{"type": "file_search"}]}), 400)
    run(guard(), LOCAL, ["q"], extra={"vector_store_ids": ["second-brain"]})


def test_system_tool_result_and_tool_use_text_are_masked_in_place():
    msgs = [
        {"role": "system", "content": "boss: a@b.co"},
        {"role": "assistant", "content": [{"type": "tool_use", "id": "1", "name": "mail", "input": {"to": "a@b.co", "n": 2}}]},
        {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "1", "content": [{"type": "text", "text": "from a@b.co"}]}]},
        {"role": "assistant", "content": None, "tool_calls": [{"function": {"name": "f", "arguments": '{"e": "a@b.co"}'}}]},
    ]
    _, data = run(guard(), CLOUD, [], messages=msgs, extra={"system": [{"type": "text", "text": "sys a@b.co"}]})
    flat = json.dumps(data)
    assert "a@b.co" not in flat and flat.count("<EMAIL_ADDRESS>") == 5, flat
    assert data["messages"][1]["content"][0]["input"]["n"] == 2  # non-strings untouched


def test_response_input_type_is_left_alone():
    out, _ = run(guard(), CLOUD, ["a@b.co"], input_type="response")
    assert out["texts"] == ["a@b.co"]


def gate_call(model, data):
    g = cp.CloudPIIGate(policy_path=os.path.join(ROOT, "litellm", "pii_policy.yaml"))
    data = {"model": model, **data}
    return asyncio.run(g.async_pre_call_hook(user_api_key_dict=None, cache=None, data=data, call_type="completion"))


IMAGE_ONLY = {"messages": [{"role": "user", "content": [{"type": "image", "source": {"data": "AAAA"}}]}]}


def test_gate_refuses_a_request_without_text_that_carries_an_image():
    # LiteLLM calls the guardrail only when it finds text; an image-only request would skip it.
    refused(lambda: gate_call(CLOUD, copy.deepcopy(IMAGE_ONLY)), 400)
    refused(lambda: gate_call("gpt-x", copy.deepcopy(IMAGE_ONLY)), 400)
    assert gate_call(LOCAL, copy.deepcopy(IMAGE_ONLY))["model"] == LOCAL


def test_gate_refuses_vector_stores_on_cloud_but_not_local():
    refused(lambda: gate_call(CLOUD, {"vector_store_ids": ["second-brain"]}), 400)
    assert gate_call(LOCAL, {"vector_store_ids": ["second-brain"]})["model"] == LOCAL


def test_gate_leaves_text_to_the_guardrail():
    data = {"messages": [{"role": "user", "content": "a@b.co"}]}
    assert gate_call(CLOUD, data)["messages"][0]["content"] == "a@b.co"  # masking is not its job


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
