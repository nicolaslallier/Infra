"""Who may call which MCP tool or A2A agent (pure, no LiteLLM import).

The gate (cloud_pii.py) asks `refusal()` for every `call_mcp_tool`. It learns only the tool's
name (LiteLLM's hook carries the unprefixed name and no server), so each server lists its
tools here, the lists are disjoint, and a tool on no list is refused. That is also what keeps
`merge_pull_request` out. See docs/superpowers/specs/2026-11-14-litellm-mcp-design.md.
"""
import hashlib
import re

import yaml


def load_policy(path: str) -> dict:
    with open(path) as f:
        return yaml.safe_load(f)


def server_of(policy: dict, tool_name: str | None) -> str | None:
    for server, v in policy["servers"].items():
        if tool_name in v["tools"]:
            return server
    return None


def refusal(policy: dict, team_id: str | None, tool_name: str | None, arguments: dict | None) -> str | None:
    """A reason to refuse the call, or None when it is allowed."""
    if not tool_name:
        return "an MCP call without a tool name"
    server = server_of(policy, tool_name)
    if server is None:
        return f"tool '{tool_name}' is not on any MCP server's allowlist"
    if not team_id or team_id not in policy["servers"][server]["teams"]:
        return f"this key's team may not call tools of the '{server}' MCP server"
    guard = policy.get("branch_guard") or {}
    if tool_name in guard.get("tools", []):
        refused = guard.get("refuse_branches", [])
        if _default_branch(((arguments or {}).get("branch")), refused):
            return f"'{tool_name}' needs a real branch, not {', '.join(refused)}"
    return None


def agent_refusal(policy: dict, team_id: str | None, agent_id: str | None) -> str | None:
    """A reason to refuse an A2A call, or None. LiteLLM hands the hook the agent's id, which for an
    agent of config.yaml is sha256(agent_name); an id matching no listed agent is refused."""
    for name, v in (policy.get("agents") or {}).items():
        if agent_id == hashlib.sha256(name.encode()).hexdigest():
            if team_id and team_id in (v.get("teams") or []):
                return None
            return f"this key's team may not call the '{name}' agent"
    return "an agent that is not on the agent allowlist"


def _default_branch(branch, refused: list[str]) -> bool:
    """True when `branch` must be refused: missing, not text, odd characters, a ref other than a
    plain branch, or a default branch once the usual spellings are normalised (refs/heads/main, Main...)."""
    if not isinstance(branch, str) or not branch.strip():
        return True
    name = branch.strip()
    for prefix in ("refs/heads/", "heads/"):
        if name.lower().startswith(prefix):
            name = name[len(prefix):]
    if name.lower().startswith("refs/") or not re.fullmatch(r"[A-Za-z0-9._/-]+", name):
        return True
    return name.lower() in {r.lower() for r in refused}
