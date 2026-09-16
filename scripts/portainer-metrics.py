#!/usr/bin/env python3
"""Host-side exporter that polls Portainer's API and serves it as Prometheus
metrics.

Portainer CE exposes no /metrics endpoint of its own, so a "health of the stacks
Portainer manages" view has to be built from its REST API instead of a pull. Two
constraints make that awkward:

    * The API is only authenticated with a full-admin access token, and that
      token is a Docker-daemon-root secret. CLAUDE.md "Portainer-managed stack"
      holds it in .portainer.env and forbids it reaching any container -- .env is
      handed to containers via postgres's env_file. So this exporter runs on the
      HOST, never inside a container: it reads .portainer.env from disk (like
      scripts/portainer-stack.sh does) and Prometheus reaches it via the
      host.docker.internal bridge. The token therefore never appears in any
      container's filesystem, env, or process list.
    * The API sits behind the box's 9443 self-signed TLS, so verification is off,
      exactly as the existing api() helper in portainer-stack.sh uses -k.

Stdlib only, so it runs under the Mac's system python3 with no install step.
"""
import argparse
import http.server
import json
import ssl
import sys
import time
import urllib.error
import urllib.request

# Portainer REST API shapes used below (the create body in portainer-stack.sh is
# the other side of these same fields):
#   GET /api/status                      -> {"version": str, "ramTotal": int, ...}
#   GET /api/endpoints                   -> [{"Id", "Type", "Name"}, ...]  (Type==1 = local docker)
#   GET /api/endpoints/{id}/stacks       -> [stack objects]
# A stack object carries Id, Name, Status (1 = stopped, 2 = running), and, for a
# repository stack, a RepositoryURL plus a git Snapshot/SnapshotRaw and a
# SnapshotUpdateTimestamp for the last successful redeploy.
LOCAL_ENDPOINT_TYPE = 1
STATUS_STOPPED = 1
STATUS_RUNNING = 2

DEFAULT_BIND = "0.0.0.0"
DEFAULT_PORT = 9999
DEFAULT_INTERVAL = 30


def load_env_file(path):
    """Read KEY=VALUE lines from a gitignored env file into a dict.

    Same shape as .portainer.env. Comment text is stripped first, so the
    "change-me" placeholder that lives inside a # comment in .env.example can
    never leak in.
    """
    out = {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for raw in fh:
                line = raw.split("#", 1)[0].strip()
                if not line or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                out[key.strip()] = value.strip().strip('"').strip("'")
    except OSError:
        pass
    return out


def get_json(base, path, key, timeout=10):
    """Fetch JSON from the Portainer API. Returns (data, error_str).

    error_str is None on success and a short reason otherwise -- the caller turns
    that into controlplane_up 0 / a scrape-error counter rather than aborting, so
    a blip shows up on the dashboard instead of silently dropping the target.
    """
    req = urllib.request.Request(f"{base}{path}", headers={"Accept": "application/json"})
    if key:
        # Sent as a header, never a query string or argv, so it cannot land in a
        # process list -- mirroring portainer-stack.sh's -K config-file trick.
        req.add_header("X-API-Key", key)
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            return json.loads(resp.read().decode("utf-8")), None
    except urllib.error.HTTPError as exc:
        return None, f"http {exc.code}"
    except (urllib.error.URLError, OSError) as exc:
        return None, f"{type(exc).__name__}: {exc}"
    except (ValueError, json.JSONDecodeError):
        return None, "invalid json"


def collect(base, key, last):
    """Poll the API once and fold the result into the mutable state dict `last`.

    `last` carries counters and the stack list across scrapes, so a single failed
    poll keeps the last good reading: the metrics show the real last state until
    a fresh one arrives, instead of flickering to zero on every blip.
    """
    last["scrape_total"] = last.get("scrape_total", 0) + 1

    status, err = get_json(base, "/api/status", key)
    if err is not None:
        last["scrape_errors_total"] = last.get("scrape_errors_total", 0) + 1
        last["controlplane_up"] = 0
        last["error"] = err
        return last
    last["controlplane_up"] = 1
    last["error"] = ""
    if isinstance(status, dict):
        last["version"] = str(status.get("version", last.get("version", "")))
        last["ram_total"] = status.get("ramTotal")

    endpoints, err = get_json(base, "/api/endpoints", key)
    if err is not None:
        last["scrape_errors_total"] = last.get("scrape_errors_total", 0) + 1
        last["error"] = f"/api/endpoints {err}"
        return last
    local = [e for e in (endpoints or []) if e.get("Type") == LOCAL_ENDPOINT_TYPE]
    last["endpoint_local"] = len(local)
    last["endpoint_total"] = len(endpoints or [])

    # Every stack across every endpoint id we can reach. A missing local endpoint
    # just contributes no stacks; the last good list is kept on error paths.
    stacks = []
    for ep in local:
        listed, err = get_json(base, f"/api/endpoints/{ep.get('Id')}/stacks", key)
        if err is not None:
            last["scrape_errors_total"] = last.get("scrape_errors_total", 0) + 1
            last["error"] = f"stacks ep{ep.get('Id')} {err}"
            continue
        for st in listed or []:
            st.setdefault("endpoint_id", ep.get("Id"))
            stacks.append(st)
    last["stacks"] = stacks
    return last


def render(state):
    """Render the state dict as Prometheus text exposition format."""
    now = time.time()
    out = []

    out.append("# HELP portainer_api_last_success_timestamp_seconds Last API poll that fully succeeded.")
    out.append("# TYPE portainer_api_last_success_timestamp_seconds timestamp")
    out.append(f"portainer_api_last_success_timestamp_seconds {state.get('last_success_timestamp', now):.0f}")

    out.append("# HELP portainer_controlplane_up 1 when Portainer's API answered the last poll.")
    out.append("# TYPE portainer_controlplane_up gauge")
    out.append(f"portainer_controlplane_up {int(state.get('controlplane_up', 0))}")

    out.append("# HELP portainer_exporter_scrape_total Total polls attempted by the exporter.")
    out.append("# TYPE portainer_exporter_scrape_total counter")
    out.append(f"portainer_exporter_scrape_total {int(state.get('scrape_total', 0))}")

    out.append("# HELP portainer_exporter_scrape_errors_total Polls that hit an error.")
    out.append("# TYPE portainer_exporter_scrape_errors_total counter")
    out.append(f"portainer_exporter_scrape_errors_total {int(state.get('scrape_errors_total', 0))}")

    out.append("# HELP portainer_version Portainer API version string (always gauge 1).")
    out.append("# TYPE portainer_version gauge")
    out.append(f'portainer_version{{version=\"{_label(state.get("version", ""))}\"}} 1')

    out.append("# HELP portainer_ram_total_bytes Total host RAM reported via /api/status.")
    out.append("# TYPE portainer_ram_total_bytes gauge")
    if state.get("ram_total") is not None:
        out.append(f"portainer_ram_total_bytes {float(state['ram_total'])}")

    out.append("# HELP portainer_endpoint_count Endpoints Portainer tracks, by type.")
    out.append("# TYPE portainer_endpoint_count gauge")
    out.append(f'portainer_endpoint_count{{type=\"local\"}} {int(state.get("endpoint_local", 0))}')
    out.append(f'portainer_endpoint_count{{type=\"total\"}} {int(state.get("endpoint_total", 0))}')

    out.append("# HELP portainer_stack_count Stacks by status (1=stopped 2=running).")
    out.append("# TYPE portainer_stack_count gauge")

    out.append("# HELP portainer_stack_running 1 when the named stack is running.")
    out.append("# TYPE portainer_stack_running gauge")
    out.append("# HELP portainer_stack_status Portainer status code per stack (1=stopped 2=running).")
    out.append("# TYPE portainer_stack_status gauge")
    out.append("# HELP portainer_stack_repository 1 when the named stack pulls from a git repo.")
    out.append("# TYPE portainer_stack_repository gauge")
    out.append("# HELP portainer_stack_last_deploy_timestamp_seconds Last successful git snapshot update of a stack.")
    out.append("# TYPE portainer_stack_last_deploy_timestamp_seconds timestamp")

    stacks = sorted(state.get("stacks", []), key=lambda s: str(s.get("Name", "")))
    by_status = {STATUS_STOPPED: 0, STATUS_RUNNING: 0, "unknown": 0}
    for st in stacks:
        by_status[st.get("Status")] = by_status.get(st.get("Status"), 0) + 1
    out.append(f'portainer_stack_count{{status=\"stopped\"}} {by_status[STATUS_STOPPED]}')
    out.append(f'portainer_stack_count{{status=\"running\"}} {by_status[STATUS_RUNNING]}')
    out.append(f'portainer_stack_count{{status=\"unknown\"}} {by_status["unknown"]}')

    for st in stacks:
        name = _label(st.get("Name", "unknown"))
        running = 1 if st.get("Status") == STATUS_RUNNING else 0
        out.append(f'portainer_stack_running{{stack=\"{name}\"}} {running}')
        out.append(f'portainer_stack_status{{stack=\"{name}\"}} {st.get("Status", 0)}')
        repo = st.get("RepositoryURL") or st.get("Repository") or ""
        out.append(f'portainer_stack_repository{{stack=\"{name}\"}} {1 if repo else 0}')
        ts = st.get("SnapshotUpdateTimestamp") or st.get("LastUpdateTimestamp") or st.get("Updated")
        if ts:
            try:
                out.append(f'portainer_stack_last_deploy_timestamp_seconds{{stack=\"{name}\"}} {float(ts):.0f}')
            except (TypeError, ValueError):
                pass

    return "\n".join(out) + "\n"


def _label(value):
    """Escape a value for use inside a Prometheus label (\\, " and newlines)."""
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def serve(base, key, bind, port, interval, state):
    """Run the HTTP server; each scrape re-polls the API then renders metrics.

    Polling is lazy inside the handler rather than a background thread, so a
    stuck poll can never desync the served metrics from the request that asked
    for them, and there is no shared-state locking to get wrong. The state and
    its inputs ride on the server instance, so the handler keeps the plain
    (request, client_address, server) constructor http.server expects.
    """
    state.setdefault("last_poll", 0)
    server = _MetricsServer((bind, port), _MetricsHandler)
    server.state = state
    server.base = base
    server.key = key
    server.interval = interval
    server.serve_forever()


class _MetricsServer(http.server.ThreadingHTTPServer):
     # A plain HTTPServer subclass; these per-instance fields are set by serve()
     # and read by the handler. Declared here so static analysis is happy.
    state: dict = {}
    base: str = ""
    key: str = ""
    interval: int = 0


class _MetricsHandler(http.server.BaseHTTPRequestHandler):
        # Data the handler needs lives on the server (set in serve()), which keeps
        # the standard request-handling constructor signature.
    def do_GET(self):            # noqa: N802 (http.server's expected name)
        server = self.server
        if not self.path.rstrip("/").endswith("/metrics"):
            self.send_response(404)
            self.end_headers()
            return
        state = server.state
        now = time.time()
            # Skip re-polling tighter than the interval: the 15s scrape window is
            # shorter than the default 30s poll window.
        if now - state.get("last_poll", 0) >= server.interval:
            state["last_poll"] = now
            collect(server.base, server.key, state)
            if state.get("controlplane_up") == 1:
                state["last_success_timestamp"] = now
        body = render(state).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):           # silence the default access log
        return


# Self-test fixtures: the parse + render pipeline with no network, so the logic
# is verifiable even with Docker down -- the "test" for this config-only repo.
FIXTURE_STACKS = [
        {"Id": 1, "Name": "infra", "Status": 2, "RepositoryURL":
         "https://github.com/nicolaslallier/Infra", "SnapshotUpdateTimestamp": "1700000000"},
        {"Id": 2, "Name": "stale", "Status": 1, "SnapshotUpdateTimestamp": "1600000000"},
]


def selftest():
    """Exercise every code path that does not need a live API; assert outputs."""
        # --- render on a healthy fake state ---
    state = {
        "controlplane_up": 1, "scrape_total": 3, "scrape_errors_total": 1,
        "version": "2.21.4", "ram_total": 16384, "endpoint_local": 1,
        "endpoint_total": 2, "stacks": [dict(FIXTURE_STACKS[0]), dict(FIXTURE_STACKS[1])],
        "last_success_timestamp": 1700000000, "error": "",
    }
    text = render(state)
    assert "portainer_controlplane_up 1" in text, text
    assert 'portainer_stack_running{stack="infra"} 1' in text, text
    assert 'portainer_stack_running{stack="stale"} 0' in text, text
    assert 'portainer_stack_count{status="running"} 1' in text, text
    assert 'portainer_stack_count{status="stopped"} 1' in text, text
    assert 'repository=' not in text or 'portainer_stack_repository{stack="infra"} 1' in text, text
    assert 'portainer_stack_last_deploy_timestamp_seconds{stack="infra"} ' in text, text
    assert "portainer_api_last_success_timestamp_seconds 1700000000" in text, text

        # --- every metric sample has a matching HELP/TYPE block (well-formed) ---
    typed = [ln.split(" ")[2] for ln in text.splitlines() if ln.startswith("# TYPE")]
    samples = [ln.split("{")[0].split(" ")[0] for ln in text.splitlines()
                if ln and not ln.startswith("#")]
    for name in samples:
        assert name in typed, f"missing TYPE for {name}\n{text}"
        assert any(ln.startswith(f"# HELP {name} ") for ln in text.splitlines()), f"missing HELP for {name}"

        # --- a failed poll keeps the last good reading and flags the blip ---
    dead = "http://127.0.0.1:1"
    s2 = dict(state)
    collect(dead, "k", s2)
    assert s2["controlplane_up"] == 0, s2
    assert s2["scrape_errors_total"] >= 1, s2
    assert len(s2["stacks"]) == 2, "a failed poll must keep the last good stacks"

        # --- label escaping ---
    assert _label('a"b\\c') == 'a\\"b\\\\c', _label('a"b\\c')

        # --- the comment placeholder in .env.example never leaks through ---
    import os
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".env", delete=False) as fh:
        fh.write("# PORTAINER_API_KEY=change-me\nPORTAINER_API_KEY=realkey\n\nLAN_IP=1.2.3.4\n")
        path = fh.name
    parsed = load_env_file(path)
    os.unlink(path)
    assert parsed.get("PORTAINER_API_KEY") == "realkey", parsed
    assert parsed.get("LAN_IP") == "1.2.3.4", parsed
    return "ok"


def main():
    ap = argparse.ArgumentParser(description="Portainer API -> Prometheus metrics (host-side).")
    ap.add_argument("--selftest", action="store_true",
                    help="run the offline parser/render checks and exit")
    ap.add_argument("--once", action="store_true", help="poll once, print /metrics, exit")
    ap.add_argument("--base-url", help="Portainer base e.g. https://<LAN_IP>:9443 (else .env / 127.0.0.1:9443)")
    ap.add_argument("--config", default=".portainer.env",
                    help="gitignored env file holding PORTAINER_API_KEY")
    ap.add_argument("--bind", default=DEFAULT_BIND)
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--interval", type=int, default=DEFAULT_INTERVAL)
    args = ap.parse_args()

    if args.selftest:
        print(selftest())
        return 0

    env = load_env_file(args.config)
    key = env.get("PORTAINER_API_KEY", "")
    base = args.base_url or env.get("PORTAINER_BASE_URL") or "https://127.0.0.1:9443"
    if not key or key == "change-me":
        print("portainer-metrics: no usable PORTAINER_API_KEY in "
              f"{args.config} -- control-plane reads down. Create an access "
              "token (Portainer -> My account -> Access tokens).", file=sys.stderr)

    state = {"controlplane_up": 0, "last_success_timestamp": time.time(),
             "last_poll": 0, "error": "not yet polled", "stacks": []}
    collect(base, key, state)
    if state.get("controlplane_up") == 1:
        state["last_success_timestamp"] = time.time()

    if args.once:
        print(render(state))
        return 0

    up = "up" if state.get("controlplane_up") == 1 else "down"
    print(f"portainer-metrics: control-plane {up}; serving {args.bind}:{args.port} "
          f"(poll {args.interval}s from {base})", file=sys.stderr)
    serve(base, key, args.bind, args.port, args.interval, state)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
