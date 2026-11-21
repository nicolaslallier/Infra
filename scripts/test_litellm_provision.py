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


# Models of the Portail's LiteLLM key (created by hand, see README "Portail (AI repo)").
PORTAIL_MODELS = ("qwen3.8:27b-mlx",)


def test_portail_models_fit_portail_budget():
    # The Portail reads for 840 s (PORTAIL_LLM_DELAI_S in OpenBao infra/portail). One attempt per order
    # level, so the worst case is the sum of the deployments' timeouts.
    c = lp.load_spec(os.path.join(ROOT, "litellm", "config.yaml"))
    for name in PORTAIL_MODELS:
        ps = [m["litellm_params"] for m in c["model_list"] if m["model_name"] == name]
        assert ps, name
        assert all(p.get("num_retries") == 0 for p in ps), (name, ps)
        timeouts = [p.get("timeout") for p in ps]
        assert None not in timeouts and sum(timeouts) < 840, (name, timeouts)


class FakeClient:
    """In-memory LiteLLM admin API, shaped as the v1.83 docs describe it."""

    def __init__(self):
        self.teams, self.users, self.keys, self.calls = {}, {}, {}, []
        self.n = 0
        self.fail_when = None  # callable(method, path) -> bool: raise ApiError
        self.ignore_filter = False  # a server that ignores ?key_alias=
        self.hash_only = False  # a server that never returns full key objects

    def request(self, method, path, body=None):
        if self.fail_when and self.fail_when(method, path):
            raise lp.ApiError(f"{method} {path} -> HTTP 500: boom")
        self.calls.append((method, path, body))
        route = path.split("?")[0]
        if (method, route) == ("GET", "/team/list"):
            return list(self.teams.values())
        if (method, route) == ("POST", "/team/new"):
            tid = body.get("team_id") or f"uuid-{body['team_alias']}"  # a server id unless one is asked for
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
            q = urllib.parse.parse_qs(urllib.parse.urlsplit(path).query)
            want = None if self.ignore_filter else q.get("key_alias")
            rows = [v for v in self.keys.values() if not want or v["key_alias"] == want[0]]
            if q.get("return_full_object") == ["true"] and not self.hash_only:
                return {"keys": [dict(v) for v in rows]}
            return {"keys": [v["token"] for v in rows]}  # hashed tokens only, like the real default
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
    assert perso["user_id"] == "a@example.test" and perso["team_id"] == "famille"
    assert "max_budget" not in perso  # a key has no cap of its own


def test_teams_are_created_with_their_alias_as_id():
    # The PII policy is keyed on the team id; an alias can be duplicated or renamed, an id cannot.
    c = FakeClient()
    lp.apply(SPEC, c, log=lambda m: None)
    assert [b["team_id"] for b in c.posted("/team/new")] == [b["team_alias"] for b in c.posted("/team/new")]


def test_an_existing_team_with_another_id_is_warned_about():
    c = FakeClient()
    c.teams["uuid-1"] = {"team_alias": "apps", "team_id": "uuid-1"}
    logs = []
    lp.apply(SPEC, c, log=logs.append)
    assert any("apps" in m and "uuid-1" in m and "strictest" in m for m in logs), logs


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
    assert c.teams["apps"]["max_budget"] == lp.to_usd(60, 0.72)
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


def test_inverted_rate_is_rejected():
    assert has(errors(spec(cad_to_usd=1.38)), "cad_to_usd")
    assert has(errors(spec(cad_to_usd=0.3)), "cad_to_usd")


def test_keys_created_before_a_late_failure_are_still_emitted():
    c = FakeClient()
    c.fail_when = lambda m, p: m == "GET" and p.startswith("/key/list") and "key_alias" not in p
    emitted, logs = [], []
    new = lp.apply(SPEC, c, log=logs.append, emit=lambda a, k: emitted.append(a))
    assert sorted(emitted) == ["a-perso", "jarvis"] and sorted(new) == sorted(emitted), emitted
    assert any("drift" in m and "boom" in m for m in logs), logs  # best effort, not fatal


def test_main_prints_keys_created_before_a_failure():
    c = FakeClient()
    c.fail_when = lambda m, p: m == "POST" and p == "/key/generate" and len(c.keys) >= 1
    code, out, err = _run_main([], {"LITELLM_MASTER_KEY": "sk-master"}, c)
    real = lp.load_spec(os.path.join(ROOT, "litellm", "teams.yaml"))
    assert code == 1 and len(out.splitlines()) == 1 and out.startswith(real["keys"][0]["alias"] + "\t"), (code, out, err)


def test_hashed_key_listing_fails_loudly():
    c = FakeClient()
    lp.apply(SPEC, c, log=lambda m: None)  # empty server: nothing to hash yet
    c.hash_only = True
    try:
        lp.apply(SPEC, c, log=lambda m: None)
        raise AssertionError("hashed key listing accepted")
    except lp.ApiError as e:
        assert "full" in str(e), str(e)


def test_key_presence_does_not_trust_the_server_filter():
    c = FakeClient()
    c.ignore_filter = True
    new = lp.apply(SPEC, c, log=lambda m: None)
    assert sorted(new) == ["a-perso", "jarvis"], new


def test_existing_key_on_another_team_is_reported_not_replaced():
    c = FakeClient()
    c.keys["sk-pre"] = {"key_alias": "jarvis", "team_id": "id-other", "token": "sk-pre"}
    logs = []
    new = lp.apply(SPEC, c, log=logs.append)
    assert "jarvis" not in new and c.posted("/key/delete") == [], new
    assert any("jarvis" in m and "team" in m and "id-other" in m for m in logs), logs


def _run_main(argv, env, client):
    import contextlib
    import io

    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = lp.main(argv, env, client)
    return code, out.getvalue(), err.getvalue()


def test_main_fails_naming_missing_master_key():
    c = FakeClient()
    code, out, err = _run_main([], {"LITELLM_MASTER_KEY": ""}, c)
    assert code == 1 and "LITELLM_MASTER_KEY" in err and out == "" and c.calls == [], (code, out, err)


def test_main_prints_keys_on_stdout_only():
    c = FakeClient()
    code, out, err = _run_main([], {"LITELLM_MASTER_KEY": "sk-master"}, c)
    real = lp.load_spec(os.path.join(ROOT, "litellm", "teams.yaml"))
    lines = out.splitlines()
    assert code == 0 and len(lines) == len(real["keys"]), (code, out, err)
    for line in lines:
        alias, key = line.split("\t")
        assert key.startswith("sk-") and alias in {k["alias"] for k in real["keys"]}, line
    assert "created" in err and "sk-" not in err, err


def test_main_refuses_invalid_spec_before_any_request():
    import tempfile

    import yaml

    bad = lp.load_spec(os.path.join(ROOT, "litellm", "teams.yaml"))
    bad["teams"]["apps"]["max_budget_cad"] += 10
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
        yaml.safe_dump(bad, f)
    try:
        c = FakeClient()
        code, out, err = _run_main(["--spec", f.name], {"LITELLM_MASTER_KEY": "sk-master"}, c)
    finally:
        os.unlink(f.name)
    assert code == 1 and "sum" in err and out == "" and c.calls == [], (code, out, err)


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
