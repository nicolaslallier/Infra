#!/usr/bin/env python3
"""Apply litellm/teams.yaml (teams, users, keys, budgets) to a LiteLLM proxy.

Budgets are written in CAD in the file; LiteLLM counts in USD, so everything
sent to it goes through to_usd(). Run through `make litellm-provision`.
"""
import yaml

EMBEDDING_MODEL = "qwen3-embedding:0.6b"  # the MCP filter and `second-brain` need it
BUDGET_DURATION = "30d"


def load_spec(path: str) -> dict:
    with open(path) as f:
        return yaml.safe_load(f)


def to_usd(cad: float, rate: float) -> float:
    return round(cad * rate, 2)


def _number(v) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def validate(spec: dict, config: dict) -> list[str]:
    """Every problem found, as a message; empty when the spec is safe to apply."""
    errs: list[str] = []
    rate, total = spec.get("cad_to_usd"), spec.get("global_budget_cad")
    if not _number(rate) or rate <= 0:
        errs.append(f"cad_to_usd must be a positive number, got {rate!r}")
    if not _number(total) or total <= 0:
        errs.append(f"global_budget_cad must be a positive number, got {total!r}")

    known = {m["model_name"] for m in config.get("model_list", [])}
    teams = spec.get("teams") or {}
    caps = 0.0
    for alias, t in teams.items():
        cap = t.get("max_budget_cad")
        # A team without a cap is unlimited to LiteLLM, which is the failure to prevent.
        if not _number(cap) or cap <= 0:
            errs.append(f"team '{alias}': max_budget_cad must be a positive number, got {cap!r}")
        else:
            caps += cap
        models = t.get("models") or []
        for m in models:
            if m not in known:
                errs.append(f"team '{alias}': model '{m}' is not in config.yaml model_list")
        if EMBEDDING_MODEL not in models:
            errs.append(f"team '{alias}': models must include {EMBEDDING_MODEL}")
    if _number(total) and abs(caps - total) > 1e-9:
        errs.append(f"sum of team caps ({caps}) differs from global_budget_cad ({total})")

    emails = {u["email"] for u in spec.get("users") or []}
    for u in spec.get("users") or []:
        if u.get("team") not in teams:
            errs.append(f"user '{u.get('email')}': unknown team '{u.get('team')}'")
    for k in spec.get("keys") or []:
        if k.get("team") not in teams:
            errs.append(f"key '{k.get('alias')}': unknown team '{k.get('team')}'")
        if k.get("user") is not None and k["user"] not in emails:
            errs.append(f"key '{k.get('alias')}': unknown user '{k['user']}'")

    settings = config.get("litellm_settings") or {}
    if _number(rate) and rate > 0 and _number(total):
        want = to_usd(total, rate)
        if settings.get("max_budget") != want:
            errs.append(
                f"config.yaml litellm_settings.max_budget is {settings.get('max_budget')!r}, "
                f"teams.yaml says {want} USD ({total} CAD x {rate})"
            )
    if settings.get("budget_duration") != BUDGET_DURATION:
        errs.append(f"config.yaml litellm_settings.budget_duration must be {BUDGET_DURATION}")
    return errs
