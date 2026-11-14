"""Who is masked, and how, when a request leaves for a model (pure, no LiteLLM import).

The rule is inverted on purpose: everything is masked except the aliases in
`local_models`. An alias added in the admin UI under a free name is therefore
masked, never sent in clear. See docs/superpowers/specs/2026-11-14-litellm-cloud-pii-design.md.
"""
from dataclasses import dataclass

import yaml

PROVIDER_PREFIXES = ("anthropic/", "gemini/", "openai/")


@dataclass(frozen=True)
class Decision:
    mask: bool
    groups: tuple[str, ...]


def load_policy(path: str) -> dict:
    with open(path) as f:
        return yaml.safe_load(f)


def decide(policy: dict, model: str | None, team: str | None) -> Decision:
    if model is not None and model in policy["local_models"]:
        return Decision(False, ())
    if team is None:  # a key without a team, the master key: we do not know what to relax
        return Decision(True, tuple(policy["groups"]))
    return Decision(True, tuple(policy["teams"].get(team, policy["default"])))


def entities_for(policy: dict, groups: tuple[str, ...]) -> list[str]:
    return [e for g in groups for e in policy["groups"][g]["entities"]]


def validate(policy: dict, teams: dict, config: dict) -> list[str]:
    """Every inconsistency with teams.yaml and config.yaml; empty when safe."""
    errs: list[str] = []
    groups = set(policy.get("groups") or {})
    in_policy = set(policy.get("teams") or {})
    in_teams = set(teams.get("teams") or {})
    for t in sorted(in_policy - in_teams):
        errs.append(f"policy team '{t}' is not in teams.yaml")
    for t in sorted(in_teams - in_policy):
        errs.append(f"team '{t}' of teams.yaml has no entry in the policy (it would fall to default)")
    for where, gs in [(f"team '{t}'", g) for t, g in (policy.get("teams") or {}).items()] + [
        ("default", policy.get("default") or [])
    ]:
        for g in gs:
            if g not in groups:
                errs.append(f"{where}: unknown group '{g}'")

    by_name: dict[str, list[str]] = {}
    for m in config.get("model_list", []):
        by_name.setdefault(m["model_name"], []).append(str(m.get("litellm_params", {}).get("model", "")))
    for name in policy.get("local_models") or []:
        if name not in by_name:
            errs.append(f"local model '{name}' is not in config.yaml model_list")
        elif any(model.startswith(PROVIDER_PREFIXES) for model in by_name[name]):
            errs.append(f"local model '{name}' talks to a cloud provider; it must not be in local_models")
    return errs
