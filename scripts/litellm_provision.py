#!/usr/bin/env python3
"""Apply litellm/teams.yaml (teams, users, keys, budgets) to a LiteLLM proxy.

Budgets are written in CAD in the file; LiteLLM counts in USD, so everything
sent to it goes through to_usd(). Run through `make litellm-provision`.
"""
import argparse
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

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
    elif not 0.5 <= rate <= 1.0:
        # CAD -> USD is about 0.7; 1.38 is the inverse and would raise the real cap by ~90%.
        errs.append(f"cad_to_usd {rate} is outside 0.5-1.0 (is it USD->CAD, inverted?)")
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


class ApiError(RuntimeError):
    pass


class Client:
    """The only network surface: bearer-authenticated JSON calls to the proxy."""

    def __init__(self, base_url: str, master_key: str, cafile: str | None = None):
        self.base = base_url.rstrip("/")
        self._key = master_key
        self._ctx = ssl.create_default_context(cafile=cafile) if cafile else None

    def request(self, method: str, path: str, body: dict | None = None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(
            self.base + path, data=data, method=method,
            headers={"Authorization": f"Bearer {self._key}", "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=30, context=self._ctx) as r:
                raw = r.read()
        except urllib.error.HTTPError as e:
            # Method, path, status and the server's own words: never the headers.
            raise ApiError(f"{method} {path} -> HTTP {e.code}: {e.read()[:300]!r}") from None
        except urllib.error.URLError as e:
            raise ApiError(f"{method} {path} -> {e.reason}") from None
        return json.loads(raw) if raw else {}


def _items(resp, field: str) -> list:
    if isinstance(resp, dict):
        resp = resp.get(field, [])
    return resp or []


def _list_keys(client, alias: str | None = None) -> list[dict]:
    """Full key objects (the default listing is hashed tokens), every page."""
    out, page = [], 1
    while True:
        q = f"return_full_object=true&size=100&page={page}"
        if alias is not None:
            q += f"&key_alias={urllib.parse.quote(alias)}"
        resp = client.request("GET", f"/key/list?{q}")
        rows = _items(resp, "keys")
        if any(not isinstance(r, dict) for r in rows):
            raise ApiError("GET /key/list did not return full key objects; cannot tell which keys exist")
        out += rows
        pages = resp.get("total_pages", 1) if isinstance(resp, dict) else 1
        if page >= (pages or 1):
            return out
        page += 1


def apply(spec: dict, client, rotate: str | None = None, log=None, emit=None) -> dict[str, str]:
    """Reconcile LiteLLM with the spec; returns {key_alias: new_key} for keys created or rotated.

    emit(alias, key) is called the moment a key is created: a key is shown once, so a
    later failure must not swallow the ones already made.
    """
    log = log or (lambda m: print(m, file=sys.stderr))
    keys = spec.get("keys") or []
    if rotate is not None and rotate not in {k["alias"] for k in keys}:
        raise ValueError(f"--rotate: no key with alias '{rotate}' in the spec")
    rate = spec["cad_to_usd"]

    existing = {t["team_alias"]: t for t in _items(client.request("GET", "/team/list"), "teams")}
    team_ids: dict[str, str] = {}
    for alias, t in spec["teams"].items():
        body = {
            "team_alias": alias, "models": t["models"],
            "max_budget": to_usd(t["max_budget_cad"], rate), "budget_duration": BUDGET_DURATION,
        }
        if alias in existing:
            team_ids[alias] = existing[alias]["team_id"]
            client.request("POST", "/team/update", {**body, "team_id": team_ids[alias]})
            log(f"team '{alias}': updated")
        else:
            team_ids[alias] = client.request("POST", "/team/new", body)["team_id"]
            log(f"team '{alias}': created")

    have_users = {u["user_id"] for u in _items(client.request("GET", "/user/list"), "users")}
    for u in spec.get("users") or []:
        body = {"user_id": u["email"], "user_email": u["email"], "user_role": "internal_user",
                "teams": [team_ids[u["team"]]]}
        if u["email"] in have_users:
            client.request("POST", "/user/update", body)
            log(f"user '{u['email']}': updated")
        else:
            client.request("POST", "/user/new", {**body, "auto_create_key": False, "send_invite_email": False})
            log(f"user '{u['email']}': created")

    new: dict[str, str] = {}
    for k in keys:
        # Do not trust the server to have filtered: match the alias ourselves.
        found_keys = [x for x in _list_keys(client, k["alias"]) if x.get("key_alias") == k["alias"]]
        present = bool(found_keys)
        if present and rotate == k["alias"]:
            client.request("POST", "/key/delete", {"key_aliases": [k["alias"]]})
            present = False
        if present:
            want_team = team_ids[k["team"]]
            if found_keys[0].get("team_id") != want_team:
                log(f"key '{k['alias']}': exists on team '{found_keys[0].get('team_id')}', "
                    f"the file says team '{k['team']}' ({want_team}); kept as is, fix it in the UI or rotate")
            else:
                log(f"key '{k['alias']}': exists, kept")
            continue
        body = {"key_alias": k["alias"], "team_id": team_ids[k["team"]]}
        if k.get("user"):
            body["user_id"] = k["user"]
        new[k["alias"]] = client.request("POST", "/key/generate", body)["key"]
        if emit:
            emit(k["alias"], new[k["alias"]])
        log(f"key '{k['alias']}': created")

    # Drift: reported, never deleted, and best effort (the keys are already made).
    try:
        in_file = {
            "team": set(spec["teams"]), "user": {u["email"] for u in spec.get("users") or []},
            "key": {k["alias"] for k in keys},
        }
        found = {
            "team": [t["team_alias"] for t in _items(client.request("GET", "/team/list"), "teams")],
            "user": [u["user_id"] for u in _items(client.request("GET", "/user/list"), "users")],
            "key": [x.get("key_alias") for x in _list_keys(client)],
        }
        for kind, names in found.items():
            for n in names:
                if n and n not in in_file[kind]:
                    log(f"drift: {kind} '{n}' exists in LiteLLM but not in teams.yaml (left alone)")
    except ApiError as e:
        log(f"drift check skipped: {e}")
    return new


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_URL = "https://litellm.infra.famillelallier.net"


def main(argv: list[str], env: dict, client=None) -> int:
    ap = argparse.ArgumentParser(description="Apply litellm/teams.yaml to LiteLLM.")
    ap.add_argument("--spec", default=os.path.join(ROOT, "litellm", "teams.yaml"))
    ap.add_argument("--config", default=os.path.join(ROOT, "litellm", "config.yaml"))
    ap.add_argument("--rotate", metavar="ALIAS", help="issue a new key for this alias")
    a = ap.parse_args(argv)

    master = env.get("LITELLM_MASTER_KEY", "")
    if not master:
        print("litellm_provision: LITELLM_MASTER_KEY is not set (source .env, or use make litellm-provision)", file=sys.stderr)
        return 1
    spec, config = load_spec(a.spec), load_spec(a.config)
    errs = validate(spec, config)
    if errs:
        for e in errs:
            print(f"litellm_provision: {e}", file=sys.stderr)
        return 1
    if client is None:
        ca = os.path.join(ROOT, "certs", "infra-ca.crt")
        client = Client(env.get("LITELLM_URL", DEFAULT_URL), master, ca if os.path.exists(ca) else None)
    try:
        # Each key is printed as it is made (stdout only; shown once, store it).
        apply(spec, client, rotate=a.rotate, emit=lambda alias, key: print(f"{alias}\t{key}", flush=True))
    except (ApiError, ValueError) as e:
        print(f"litellm_provision: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], dict(os.environ)))
