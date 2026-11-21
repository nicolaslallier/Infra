"""Tests for the LiteLLM vhost's closed routes (skills, A2A but agent-test) and their docs. Stdlib only.

Run: python3 scripts/test_litellm_routes.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONF = open(os.path.join(ROOT, "nginx", "conf.d", "litellm.conf")).read()


def blocked_block():
    """(regex, offset) of the `location ~*` block that returns 403 and names skills."""
    for m in re.finditer(r"location\s+~\*\s+(\S+)\s*\{([^}]*)\}", CONF):
        if "return 403" in m.group(2) and "skills" in m.group(1):
            return m.group(1), m.start()
    raise AssertionError("no case-insensitive 403 location for skills in litellm.conf")


def test_skills_and_a2a_are_refused():
    pattern = blocked_block()[0]
    for path in ("/v1/skills", "/v1/skills/abc", "/V1/Skills", "/a2a/x", "/a2a/x/message/send",
                 "/v1/a2a/x/message/send", "/A2A/x"):
        assert re.search(pattern, path, re.I), path


def test_ordinary_routes_pass():
    pattern = blocked_block()[0]
    for path in ("/v1/chat/completions", "/v1/messages", "/v1/models", "/v1/memory", "/v1/memory/k",
                 "/mcp", "/ui", "/v1/agents", "/v1/agents/x", "/v1/skillset", "/a2ax"):
        assert not re.search(pattern, path, re.I), path


def test_the_block_comes_before_the_catch_all():
    assert blocked_block()[1] < CONF.index("location / {")


def test_only_agent_test_message_send_is_reopened_post_only_before_the_catch_all():
    exact = re.findall(r"location\s+=\s+(\S*a2a\S*)\s*\{(.*?)\n    \}", CONF, re.S | re.I)
    assert [p for p, _ in exact] == ["/v1/a2a/agent-test/message/send"], exact
    body = exact[0][1]
    assert "limit_except POST { deny all; }" in body and "proxy_pass $upstream;" in body
    assert "return 403" not in body
    assert CONF.index("location = /v1/a2a/agent-test/message/send") < CONF.index("location / {")
    # every other A2A location is a 403
    others = [m for m in re.finditer(r"location\s+(?!=)\S*\s*(\S*a2a\S*)\s*\{([^}]*)\}", CONF, re.I)]
    assert others and all("return 403" in m.group(2) for m in others), others


def test_the_regex_still_closes_every_other_a2a_path():
    pattern = blocked_block()[0]
    for path in ("/v1/a2a/agent-test/.well-known/agent-card.json", "/a2a/agent-test/message/send",
                 "/a2a/agent-test", "/v1/a2a/other/message/send", "/v1/a2a/agent-test/message/stream"):
        assert re.search(pattern, path, re.I), path


def test_docs_say_memory_is_per_team_skills_are_closed_and_one_agent_is_open():
    claude = open(os.path.join(ROOT, "CLAUDE.md")).read()
    readme = open(os.path.join(ROOT, "README.md")).read()
    assert "/v1/a2a/agent-test/message/send" in claude and "/v1/a2a/agent-test/message/send" in readme
    assert "AGENT_TEST_LITELLM_KEY" in readme and "make app-images" in readme
    for needle in ("/v1/memory", "/v1/skills", "A2A", "admin-only"):
        assert needle in claude, f"CLAUDE.md does not mention {needle}"
    for needle in ("## LiteLLM: memory, skills, agents", "/v1/memory", "users: []", "litellm:4000",
                   "allowed_routes", "master key", "globally unique"):
        assert needle in readme, f"README.md does not mention {needle}"


def test_cache_ping_is_get_only_and_the_rest_of_cache_stays_closed():
    ping = re.search(r"location\s+=\s+/cache/ping\s*\{(.*?)\n    \}", CONF, re.S)
    assert ping, "no exact location for /cache/ping"
    assert "limit_except GET { deny all; }" in ping.group(1)
    assert "proxy_pass $upstream;" in ping.group(1)
    assert re.search(r"location\s+~\*\s+\^/cache\(/\|\$\)\s*\{\s*return 403;", CONF)


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
