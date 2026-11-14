"""Plain-assert tests for litellm_provision.py (no framework, no network).

Run: uv run -q --no-project --with pyyaml python scripts/test_litellm_provision.py
"""
import copy
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import litellm_provision as lp  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EMB = "qwen3-embedding:0.6b"

SPEC = {
    "cad_to_usd": 0.72,
    "global_budget_cad": 200,
    "teams": {
        "admin": {"max_budget_cad": 30, "models": ["qwen3.8:27b-mlx", "cloud-anthropic", EMB]},
        "famille": {"max_budget_cad": 30, "models": ["qwen3.8:27b-mlx", "cloud-gemini", EMB]},
        "apps": {"max_budget_cad": 70, "models": ["qwen3.8:27b-mlx", "cloud-anthropic", EMB]},
        "dev-sessions": {"max_budget_cad": 70, "models": ["qwen3.8:27b-mlx", "cloud-anthropic", EMB]},
    },
    "users": [{"email": "a@example.test", "team": "famille"}],
    "keys": [
        {"alias": "jarvis", "team": "apps", "user": None},
        {"alias": "a-perso", "team": "famille", "user": "a@example.test"},
    ],
}
CONFIG = {
    "model_list": [{"model_name": n} for n in ("qwen3.8:27b-mlx", "cloud-anthropic", "cloud-gemini", EMB)],
    "litellm_settings": {"max_budget": 144.0, "budget_duration": "30d"},
}


def spec(**changes):
    s = copy.deepcopy(SPEC)
    s.update(changes)
    return s


def errors(s=None, c=None):
    return lp.validate(s if s is not None else SPEC, c if c is not None else CONFIG)


def has(errs, fragment):
    return any(fragment in e for e in errs)


def test_to_usd_converts_and_rounds():
    assert lp.to_usd(200, 0.72) == 144.0
    assert lp.to_usd(30, 0.7234) == 21.7


def test_valid_spec_passes():
    assert errors() == [], errors()


def test_team_caps_must_sum_to_global():
    s = copy.deepcopy(SPEC)
    s["teams"]["apps"]["max_budget_cad"] = 80
    assert has(errors(s), "sum"), errors(s)


def test_unknown_model_alias_is_rejected():
    s = copy.deepcopy(SPEC)
    s["teams"]["apps"]["models"].append("cloud-antropic")
    assert has(errors(s), "cloud-antropic"), errors(s)


def test_missing_embedding_model_is_rejected():
    s = copy.deepcopy(SPEC)
    s["teams"]["famille"]["models"].remove(EMB)
    assert has(errors(s), EMB), errors(s)


def test_team_without_cap_is_rejected():
    s = copy.deepcopy(SPEC)
    del s["teams"]["apps"]["max_budget_cad"]
    assert has(errors(s), "apps"), errors(s)


def test_non_positive_rate_is_rejected():
    assert has(errors(spec(cad_to_usd=0)), "cad_to_usd")
    assert has(errors(spec(cad_to_usd=-1)), "cad_to_usd")


def test_key_with_unknown_team_is_rejected():
    s = copy.deepcopy(SPEC)
    s["keys"].append({"alias": "x", "team": "nope", "user": None})
    assert has(errors(s), "nope"), errors(s)


def test_config_cap_must_match_spec():
    c = copy.deepcopy(CONFIG)
    c["litellm_settings"]["max_budget"] = 200  # CAD written where USD belongs
    assert has(errors(c=c), "max_budget"), errors(c=c)
    c = copy.deepcopy(CONFIG)
    c["litellm_settings"]["budget_duration"] = "7d"
    assert has(errors(c=c), "budget_duration"), errors(c=c)


def test_repo_files_are_consistent():
    s = lp.load_spec(os.path.join(ROOT, "litellm", "teams.yaml"))
    c = lp.load_spec(os.path.join(ROOT, "litellm", "config.yaml"))
    assert lp.validate(s, c) == [], lp.validate(s, c)


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
