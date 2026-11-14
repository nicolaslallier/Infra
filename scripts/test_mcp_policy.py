"""Plain-assert tests for litellm/mcp_policy.py (no framework, no network).

Run: uv run -q --no-project --with pyyaml python scripts/test_mcp_policy.py
"""
import copy
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "litellm"))
import mcp_policy as mp  # noqa: E402

P = {
    "servers": {
        "obsidian": {"teams": ["admin", "apps"], "tools": ["list_notes", "read_note", "search_notes"]},
        "github": {"teams": ["admin"], "tools": ["search_repositories", "create_or_update_file", "push_files", "issue_write"]},
    },
    "branch_guard": {"tools": ["create_or_update_file", "push_files"], "refuse_branches": ["main", "master"]},
}


def test_admin_reaches_both_servers():
    assert mp.refusal(P, "admin", "read_note", {}) is None
    assert mp.refusal(P, "admin", "search_repositories", {}) is None


def test_apps_reaches_obsidian_only():
    assert mp.refusal(P, "apps", "list_notes", {}) is None
    assert mp.refusal(P, "apps", "search_repositories", {}) is not None


def test_famille_and_dev_sessions_get_nothing():
    for team in ("famille", "dev-sessions", "inconnue"):
        assert mp.refusal(P, team, "read_note", {}) is not None


def test_no_team_gets_nothing():
    assert mp.refusal(P, None, "read_note", {}) is not None
    assert mp.refusal(P, "", "read_note", {}) is not None


def test_a_tool_on_no_list_is_refused():
    assert mp.refusal(P, "admin", "merge_pull_request", {}) is not None
    assert mp.refusal(P, "admin", None, {}) is not None
    assert mp.refusal(P, "admin", "", {}) is not None


def test_server_of_finds_the_server():
    assert mp.server_of(P, "read_note") == "obsidian"
    assert mp.server_of(P, "issue_write") == "github"
    assert mp.server_of(P, "nope") is None


def test_github_write_without_a_branch_is_refused():
    for args in (None, {}, {"branch": ""}, {"branch": None}):
        assert mp.refusal(P, "admin", "create_or_update_file", args) is not None


def test_github_write_to_main_or_master_is_refused():
    for b in ("main", "master"):
        for tool in ("create_or_update_file", "push_files"):
            assert mp.refusal(P, "admin", tool, {"branch": b}) is not None


def test_the_branch_is_normalised_before_it_is_compared():
    for b in ("refs/heads/main", "heads/main", "MAIN", "Main", "refs/heads/Master", " main ", "refs/tags/v1",
              "refs/pull/1/head", "bad branch", "x;rm", 123, ["main"], {"a": 1}, True):
        assert mp.refusal(P, "admin", "create_or_update_file", {"branch": b}) is not None, b
    for b in ("refs/heads/feature/x", "claude/feat-1", "fix_2.0"):
        assert mp.refusal(P, "admin", "push_files", {"branch": b}) is None, b


def test_github_write_to_a_feature_branch_passes():
    assert mp.refusal(P, "admin", "create_or_update_file", {"branch": "claude/x"}) is None
    assert mp.refusal(P, "admin", "issue_write", {}) is None  # not a branch-guarded tool


def test_tool_names_are_disjoint_across_servers():
    # The gate learns the server from the tool name alone, so a shared name would be ambiguous.
    seen: dict = {}
    for srv, v in mp.load_policy(os.path.join(ROOT, "litellm", "mcp_policy.yaml"))["servers"].items():
        for t in v["tools"]:
            assert t not in seen, (t, seen[t], srv)
            seen[t] = srv


def test_merge_pull_request_is_in_no_list():
    pol = mp.load_policy(os.path.join(ROOT, "litellm", "mcp_policy.yaml"))
    for srv, v in pol["servers"].items():
        assert "merge_pull_request" not in v["tools"], srv


def test_policy_teams_exist_in_teams_yaml():
    pol = mp.load_policy(os.path.join(ROOT, "litellm", "mcp_policy.yaml"))
    teams = set(mp.load_policy(os.path.join(ROOT, "litellm", "teams.yaml"))["teams"])
    for srv, v in pol["servers"].items():
        for t in v["teams"]:
            assert t in teams, (srv, t)


def test_the_real_policy_gives_the_agreed_access():
    pol = mp.load_policy(os.path.join(ROOT, "litellm", "mcp_policy.yaml"))
    assert pol["servers"]["obsidian"]["teams"] == ["admin", "apps"]
    assert pol["servers"]["github"]["teams"] == ["admin"]
    assert set(pol["branch_guard"]["tools"]) == {"create_or_update_file", "push_files"}
    assert set(pol["branch_guard"]["refuse_branches"]) == {"main", "master"}


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
