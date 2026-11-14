"""Who may call which MCP tool (pure, no LiteLLM import).

The gate (cloud_pii.py) asks `refusal()` for every `call_mcp_tool`. It learns only the tool's
name (LiteLLM's hook carries the unprefixed name and no server), so each server lists its
tools here, the lists are disjoint, and a tool on no list is refused. That is also what keeps
`merge_pull_request` out. See docs/superpowers/specs/2026-11-14-litellm-mcp-design.md.
"""
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
        branch = (arguments or {}).get("branch")
        if not branch or branch in guard.get("refuse_branches", []):
            return f"'{tool_name}' needs a branch other than {', '.join(guard.get('refuse_branches', []))}"
    return None
