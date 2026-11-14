"""Tests for the LiteLLM vhost's closed routes (skills, A2A) and their docs. Stdlib only.

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


def test_docs_say_memory_is_per_team_skills_are_closed_and_there_is_no_agent():
    claude = open(os.path.join(ROOT, "CLAUDE.md")).read()
    readme = open(os.path.join(ROOT, "README.md")).read()
    for needle in ("/v1/memory", "/v1/skills", "A2A"):
        assert needle in claude, f"CLAUDE.md does not mention {needle}"
    for needle in ("## LiteLLM: memory, skills, agents", "/v1/memory", "users: []", "litellm:4000"):
        assert needle in readme, f"README.md does not mention {needle}"


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
