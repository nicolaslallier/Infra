"""Plain-assert tests for litellm_provision.py (no framework, no network).

Run: uv run -q --no-project --with pyyaml python scripts/test_litellm_provision.py
"""
import copy
import os
import sys
import urllib.parse

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


class FakeClient:
    """In-memory LiteLLM admin API, shaped as the v1.83 docs describe it."""

    def __init__(self):
        self.teams, self.users, self.keys, self.calls = {}, {}, {}, []
        self.n = 0

    def request(self, method, path, body=None):
        self.calls.append((method, path, body))
        route = path.split("?")[0]
        if (method, route) == ("GET", "/team/list"):
            return list(self.teams.values())
        if (method, route) == ("POST", "/team/new"):
            tid = f"id-{body['team_alias']}"
            self.teams[tid] = {**body, "team_id": tid}
            return {"team_id": tid}
        if (method, route) == ("POST", "/team/update"):
            self.teams[body["team_id"]].update(body)
            return {}
        if (method, route) == ("GET", "/user/list"):
            return {"users": list(self.users.values())}
        if (method, route) == ("POST", "/user/new"):
            self.users[body["user_id"]] = dict(body)
            return {"user_id": body["user_id"]}
        if (method, route) == ("POST", "/user/update"):
            self.users[body["user_id"]].update(body)
            return {}
        if (method, route) == ("GET", "/key/list"):
            want = urllib.parse.parse_qs(urllib.parse.urlsplit(path).query).get("key_alias")
            return {"keys": [dict(v) for v in self.keys.values() if not want or v["key_alias"] == want[0]]}
        if (method, route) == ("POST", "/key/generate"):
            self.n += 1
            key = f"sk-fake-{self.n}"
            self.keys[key] = {**body, "token": key}
            return {"key": key}
        if (method, route) == ("POST", "/key/delete"):
            for a in body["key_aliases"]:
                self.keys = {k: v for k, v in self.keys.items() if v["key_alias"] != a}
            return {}
        raise AssertionError(f"unexpected call {method} {path}")

    def posted(self, route):
        return [b for m, p, b in self.calls if m == "POST" and p == route]


def test_first_run_creates_teams_users_and_keys():
    c = FakeClient()
    new = lp.apply(SPEC, c, log=lambda m: None)
    by_alias = {t["team_alias"]: t for t in c.teams.values()}
    assert set(by_alias) == set(SPEC["teams"]), by_alias
    assert by_alias["apps"]["max_budget"] == lp.to_usd(70, 0.72) == 50.4
    assert by_alias["apps"]["budget_duration"] == "30d"
    assert by_alias["famille"]["models"] == SPEC["teams"]["famille"]["models"]
    u = c.users["a@example.test"]
    assert u["user_email"] == "a@example.test" and u["user_role"] == "internal_user"
    assert u["auto_create_key"] is False and u["send_invite_email"] is False
    assert set(new) == {"jarvis", "a-perso"} and all(v.startswith("sk-") for v in new.values())
    perso = next(v for v in c.keys.values() if v["key_alias"] == "a-perso")
    assert perso["user_id"] == "a@example.test" and perso["team_id"] == "id-famille"
    assert "max_budget" not in perso  # a key has no cap of its own


def test_second_run_creates_no_key_and_returns_empty():
    c = FakeClient()
    lp.apply(SPEC, c, log=lambda m: None)
    before = len(c.posted("/key/generate"))
    assert lp.apply(SPEC, c, log=lambda m: None) == {}
    assert len(c.posted("/key/generate")) == before


def test_changed_cap_is_pushed_to_existing_team():
    c = FakeClient()
    lp.apply(SPEC, c, log=lambda m: None)
    s = copy.deepcopy(SPEC)
    s["teams"]["apps"]["max_budget_cad"] = 60
    lp.apply(s, c, log=lambda m: None)
    assert c.teams["id-apps"]["max_budget"] == lp.to_usd(60, 0.72)
    assert len(c.posted("/team/new")) == 4  # updated, not recreated


def test_rotate_issues_a_new_key_for_one_alias():
    c = FakeClient()
    first = lp.apply(SPEC, c, log=lambda m: None)
    new = lp.apply(SPEC, c, rotate="jarvis", log=lambda m: None)
    assert set(new) == {"jarvis"} and new["jarvis"] != first["jarvis"]
    assert c.posted("/key/delete") == [{"key_aliases": ["jarvis"]}]
    assert sorted(v["key_alias"] for v in c.keys.values()) == ["a-perso", "jarvis"]
    try:
        lp.apply(SPEC, c, rotate="nope", log=lambda m: None)
        raise AssertionError("unknown alias accepted")
    except ValueError as e:
        assert "nope" in str(e)


def test_objects_absent_from_file_are_reported_not_deleted():
    c = FakeClient()
    c.teams["id-old"] = {"team_alias": "old-team", "team_id": "id-old"}
    c.keys["sk-x"] = {"key_alias": "stray", "token": "sk-x"}
    c.users["z@example.test"] = {"user_id": "z@example.test"}
    logs = []
    lp.apply(SPEC, c, log=logs.append)
    text = "\n".join(logs)
    assert "old-team" in text and "stray" in text and "z@example.test" in text, text
    assert c.posted("/key/delete") == [] and "sk-x" in c.keys and "id-old" in c.teams


def test_no_secret_in_error_messages():
    import io
    import urllib.error

    def boom(req, timeout=None, context=None):
        raise urllib.error.HTTPError(req.full_url, 401, "Unauthorized", {}, io.BytesIO(b'{"error":"bad key"}'))

    real = lp.urllib.request.urlopen
    lp.urllib.request.urlopen = boom
    try:
        lp.Client("https://litellm.test", "sk-master-secret").request("GET", "/team/list")
        raise AssertionError("no error raised")
    except lp.ApiError as e:
        assert "sk-master-secret" not in str(e) and "401" in str(e), str(e)
    finally:
        lp.urllib.request.urlopen = real


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
