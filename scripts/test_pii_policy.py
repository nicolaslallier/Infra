"""Plain-assert tests for litellm/pii_policy.py (no framework, no network).

Run: uv run -q --no-project --with pyyaml python scripts/test_pii_policy.py
"""
import copy
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "litellm"))
import pii_policy as pp  # noqa: E402

P = {
    "local_models": ["qwen3.8:27b-mlx", "qwen3-embedding:0.6b"],
    "groups": {
        "identifiants": {"entities": ["EMAIL_ADDRESS", "CA_SIN"], "thresholds": {"ALL": 0.5}, "languages": ["fr"]},
        "noms": {"entities": ["PERSON"], "languages": ["fr", "en"]},
    },
    "teams": {
        "admin": ["identifiants", "noms"],
        "famille": ["identifiants", "noms"],
        "dev-sessions": ["identifiants"],
    },
    "default": ["identifiants", "noms"],
}
TEAMS = {"teams": {"admin": {}, "famille": {}, "dev-sessions": {}}}
CONFIG = {
    "model_list": [
        {"model_name": "qwen3.8:27b-mlx", "litellm_params": {"model": "ollama_chat/qwen3.8:27b-mlx"}},
        {"model_name": "qwen3-embedding:0.6b", "litellm_params": {"model": "ollama/qwen3-embedding:0.6b"}},
        {"model_name": "cloud-anthropic", "litellm_params": {"model": "anthropic/claude-sonnet-5-5"}},
    ]
}


def errors(p=None, t=None, c=None):
    return pp.validate(p or P, t or TEAMS, c or CONFIG)


def has(errs, fragment):
    return any(fragment in e for e in errs)


def test_local_alias_is_not_masked():
    d = pp.decide(P, "qwen3.8:27b-mlx", "famille")
    assert d.mask is False and d.groups == (), d


def test_unknown_alias_is_masked():
    assert pp.decide(P, "gpt-x", "famille").mask is True
    assert pp.decide(P, None, "famille").mask is True


def test_cloud_alias_uses_team_groups():
    assert pp.decide(P, "cloud-anthropic", "dev-sessions").groups == ("identifiants",)
    assert pp.decide(P, "cloud-anthropic", "famille").groups == ("identifiants", "noms")


def test_no_team_gets_strictest():
    assert pp.decide(P, "cloud-anthropic", None).groups == ("identifiants", "noms")


def test_unknown_team_gets_default():
    p = copy.deepcopy(P)
    p["default"] = ["identifiants"]
    assert pp.decide(p, "cloud-anthropic", "inconnue").groups == ("identifiants",)


def test_entities_for_names_is_person_only():
    assert pp.entities_for(P, ("noms",)) == ["PERSON"]
    assert pp.entities_for(P, ("identifiants", "noms")) == ["EMAIL_ADDRESS", "CA_SIN", "PERSON"]


def test_valid_policy_passes():
    assert errors() == [], errors()


def test_validate_rejects_team_missing_from_teams_yaml():
    p = copy.deepcopy(P)
    p["teams"]["ancienne"] = ["identifiants"]
    assert has(errors(p=p), "ancienne"), errors(p=p)


def test_validate_rejects_team_missing_from_policy():
    t = copy.deepcopy(TEAMS)
    t["teams"]["renommee"] = {}  # renamed in teams.yaml, not here: would silently fall to default
    assert has(errors(t=t), "renommee"), errors(t=t)


def test_validate_rejects_local_model_not_in_config():
    p = copy.deepcopy(P)
    p["local_models"].append("fantome")
    assert has(errors(p=p), "fantome"), errors(p=p)


def test_validate_rejects_local_model_on_a_provider():
    p = copy.deepcopy(P)
    p["local_models"].append("cloud-anthropic")
    assert has(errors(p=p), "cloud-anthropic"), errors(p=p)


def test_validate_rejects_unknown_group():
    p = copy.deepcopy(P)
    p["teams"]["famille"] = ["identifiants", "secrets"]
    assert has(errors(p=p), "secrets"), errors(p=p)


def test_repo_policy_is_consistent():
    p = pp.load_policy(os.path.join(ROOT, "litellm", "pii_policy.yaml"))
    t = pp.load_policy(os.path.join(ROOT, "litellm", "teams.yaml"))
    c = pp.load_policy(os.path.join(ROOT, "litellm", "config.yaml"))
    assert pp.validate(p, t, c) == [], pp.validate(p, t, c)


def test_short_text_is_one_chunk():
    assert pp.chunk_text("abc") == [(0, 3)]
    assert pp.chunk_text("") == []


def test_chunks_cover_the_whole_text():
    text = ("x" * 37 + "\n") * 40
    spans = pp.chunk_text(text, max_chars=100, overlap=10)
    assert spans[0][0] == 0 and spans[-1][1] == len(text)
    covered = set()
    for s, e in spans:
        assert e - s <= 100 and s < e
        covered.update(range(s, e))
    assert covered == set(range(len(text)))


def test_chunks_cut_at_line_ends_when_possible():
    text = ("y" * 30 + "\n") * 20
    spans = pp.chunk_text(text, max_chars=100, overlap=10)
    assert len(spans) > 1
    for s, e in spans[:-1]:
        assert text[e - 1] == "\n", (s, e)


def test_email_across_a_boundary_lies_whole_inside_one_chunk():
    email = "bob@example.com"
    text = "a" * 40 + " " + email + " " + "b" * 60  # no newline: a hard cut at 50 splits it
    spans = pp.chunk_text(text, max_chars=50, overlap=20)
    assert any(email in text[s:e] for s, e in spans), spans


def test_overlap_not_smaller_than_chunk_is_rejected():
    try:
        pp.chunk_text("abc", max_chars=10, overlap=10)
        raise AssertionError("accepted")
    except ValueError:
        pass


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
