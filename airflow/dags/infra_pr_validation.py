"""Nightly validation of this repo's open pull requests.

Why this lives in Airflow and not in GitHub Actions: a GitHub-hosted runner
cannot reach `infra-net`, the Docker daemon this stack runs on, or anything on
the LAN. Airflow is already on that machine, so it is the only scheduler that
can eventually bring the stack up for real. This first DAG does not do that
yet -- it runs the file-level checks -- but it establishes the plumbing that
the smoke test will reuse: a workspace the nested containers can see, a clone
step, and a single upserted comment per PR.

How a run works, per open PR:

  1. clone the PR's head into $WORKSPACE_ROOT/pr-<n>-<run> (in a container --
     the Airflow image ships no `git`)
  2. render a throwaway .env, seal key and certs into it
     (scripts/ci-fake-env.sh, from the PR's own checkout, so a PR that breaks
     that script fails here)
  3. run each check, most of them in the same image the real service uses
  4. post or update one comment on the PR

The load-bearing detail is WORKSPACE_ROOT. Checks run as sibling containers,
so their `-v <path>:/repo` is resolved by the *daemon*, against the host
filesystem -- not against this container's. A clone written to an ordinary
temp dir in here would be invisible to them, and Docker would silently
auto-create an empty directory in its place (the same trap `${INFRA_DIR}`
exists for, see "Portainer-managed stack" in CLAUDE.md). Mounting the
workspace at *the same path* inside and outside makes the two agree with no
translation. Consequence: this DAG assumes Airflow and the daemon share a
filesystem. It does not work against a remote DOCKER_HOST.

Setup, once:
  - docker socket + workspace mount on airflow-scheduler (docker-compose.yml)
  - Airflow Variables `infra_ci_github_token` (a PAT with pull_requests:write)
    and, optionally, `infra_ci_repo`
  - unpause the DAG: it arrives paused
    (AIRFLOW__CORE__DAGS_ARE_PAUSED_AT_CREATION is "true")
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import urllib.error
import urllib.request
from datetime import timedelta
from typing import Any

import pendulum
from airflow.sdk import Variable, dag, task

# Bind-mounted from the host at this same path (see the module docstring).
WORKSPACE_ROOT = "/tmp/infra-ci"

GITHUB_API = "https://api.github.com"

# Lets a later run find the comment it wrote last time instead of stacking a
# new one on every night's run. Invisible in the rendered comment.
COMMENT_MARKER = "<!-- infra-pr-validation -->"

# Images are pinned by tag rather than digest on purpose: these are throwaway
# validation containers, and a check that silently stops matching the image
# the stack actually deploys is worse than one that follows it.
IMG_GIT = "alpine/git:latest"
IMG_SHELLCHECK = "koalaman/shellcheck-alpine:stable"
IMG_DOCKER_CLI = "docker:28-cli"
IMG_NGINX = "nginx:alpine-otel"  # must match docker-compose.yml's nginx image
IMG_PROMETHEUS = "prom/prometheus:latest"


# --------------------------------------------------------------------------
# GitHub
# --------------------------------------------------------------------------


def _gh(path: str, token: str, method: str = "GET", body: dict | None = None) -> Any:
    """One GitHub REST call. urllib rather than requests: stdlib, no doubt
    about what the Airflow image ships."""
    url = path if path.startswith("http") else f"{GITHUB_API}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read()
    return json.loads(raw) if raw else None


# --------------------------------------------------------------------------
# Docker
# --------------------------------------------------------------------------


def _docker_run(
    image: str,
    command: list[str],
    volumes: dict[str, dict[str, str]],
    working_dir: str | None = None,
    user: str | None = None,
) -> tuple[int, str]:
    """Run one container to completion; return (exit code, combined output).

    create/start/wait/logs rather than containers.run() because run() raises on
    a non-zero exit and hands back only stderr -- and here a non-zero exit is
    the normal, interesting outcome that has to be reported with its full
    output, not an exception.
    """
    import docker  # imported here so DAG parsing never depends on the provider

    client = docker.from_env()
    try:
        client.images.get(image)
    except docker.errors.ImageNotFound:
        client.images.pull(image)

    container = client.containers.create(
        image=image,
        command=command,
        volumes=volumes,
        working_dir=working_dir,
        user=user,
        network_mode="bridge",
    )
    try:
        container.start()
        status = container.wait(timeout=600)
        logs = container.logs(stdout=True, stderr=True).decode("utf-8", "replace")
        return int(status.get("StatusCode", 1)), logs
    finally:
        try:
            container.remove(force=True)
        except Exception:  # noqa: BLE001 - a leaked container must not fail the check
            pass


def _checks(workspace: str) -> list[dict[str, Any]]:
    """The container-run checks, as data.

    Each one mounts the workspace the way the real service mounts the repo, so
    a check exercises the same paths the deployed container would see -- that
    is the whole point of running `nginx -t` in `nginx:alpine-otel` rather than
    in some generic linter image.
    """
    ro = lambda path: {"bind": path, "mode": "ro"}  # noqa: E731

    return [
        {
            "name": "shellcheck",
            "image": IMG_SHELLCHECK,
            "command": [
                "sh",
                "-c",
                "shellcheck -S warning scripts/*.sh postgres/initdb/*.sh",
            ],
            "working_dir": "/repo",
            "volumes": {workspace: ro("/repo")},
        },
        {
            # Catches a ${VAR:?} with nothing behind it and a malformed
            # service block -- the two ways a deploy dies before any container
            # starts. Both compose projects, since portainer's is separate.
            "name": "compose config",
            "image": IMG_DOCKER_CLI,
            "command": [
                "sh",
                "-c",
                "docker compose --env-file .env -f docker-compose.yml config -q && "
                "docker compose --env-file .env -f docker-compose.portainer.yml config -q",
            ],
            "working_dir": "/repo",
            "volumes": {
                workspace: ro("/repo"),
                "/var/run/docker.sock": ro("/var/run/docker.sock"),
            },
        },
        {
            # The highest-value check in this repo: every `make up`
            # force-recreates nginx, so a typo in a new vhost takes down all
            # ingress at deploy time rather than at review time.
            "name": "nginx -t",
            "image": IMG_NGINX,
            "command": ["nginx", "-t"],
            "working_dir": None,
            "volumes": {
                f"{workspace}/nginx/nginx.conf": ro("/etc/nginx/nginx.conf"),
                f"{workspace}/nginx/conf.d": ro("/etc/nginx/conf.d"),
                f"{workspace}/nginx/stream.d": ro("/etc/nginx/stream.d"),
                f"{workspace}/nginx/snippets": ro("/etc/nginx/snippets"),
                f"{workspace}/certs": ro("/etc/nginx/certs"),
            },
        },
        {
            # Mounted at /etc/prometheus, not /repo: prometheus.yml names its
            # file_sd targets by their in-container absolute path, and promtool
            # checks that those files exist.
            "name": "promtool",
            "image": IMG_PROMETHEUS,
            "command": ["check", "config", "/etc/prometheus/prometheus.yml"],
            "working_dir": None,
            "entrypoint": "promtool",
            "volumes": {
                f"{workspace}/monitoring/prometheus/prometheus.yml": ro(
                    "/etc/prometheus/prometheus.yml"
                ),
                f"{workspace}/monitoring/prometheus/targets": ro("/etc/prometheus/targets"),
            },
        },
    ]


# --------------------------------------------------------------------------
# Checks that need no container
# --------------------------------------------------------------------------


def _check_json_yaml(workspace: str) -> tuple[int, str]:
    """Grafana dashboards and Keycloak realms are JSON that nothing parses
    until the container boots: a broken dashboard leaves Grafana up and simply
    missing it, with the error buried in its log."""
    import glob

    import yaml

    problems: list[str] = []
    checked = 0

    patterns_json = [
        "monitoring/grafana/provisioning/dashboards/json/*.json",
        "keycloak/realm-import/*.json",
    ]
    patterns_yaml = ["monitoring/**/*.yml", "*.yml"]

    for pattern in patterns_json:
        for path in sorted(glob.glob(os.path.join(workspace, pattern))):
            checked += 1
            try:
                with open(path, encoding="utf-8") as handle:
                    json.load(handle)
            except Exception as exc:  # noqa: BLE001
                problems.append(f"{os.path.relpath(path, workspace)}: {exc}")

    for pattern in patterns_yaml:
        for path in sorted(glob.glob(os.path.join(workspace, pattern), recursive=True)):
            checked += 1
            try:
                with open(path, encoding="utf-8") as handle:
                    list(yaml.safe_load_all(handle))
            except Exception as exc:  # noqa: BLE001
                problems.append(f"{os.path.relpath(path, workspace)}: {exc}")

    if problems:
        return 1, "\n".join(problems)
    return 0, f"{checked} JSON/YAML files parse"


def _check_env_script(workspace: str) -> tuple[int, str]:
    """The repo's own preflight, run against the .env ci-fake-env.sh just
    rendered. It asserts that every key .env.example defines is present and
    correctly shaped, which is exactly what a PR adding a service forgets."""
    proc = subprocess.run(
        ["bash", "scripts/check-env.sh"],
        cwd=workspace,
        capture_output=True,
        text=True,
        timeout=120,
        env={**os.environ, "SKIP_DOCKER_CHECK": "1"},
    )
    return proc.returncode, (proc.stdout + proc.stderr).strip() or "ok"


# --------------------------------------------------------------------------
# DAG
# --------------------------------------------------------------------------


@dag(
    dag_id="infra_pr_validation",
    schedule="0 3 * * *",
    start_date=pendulum.datetime(2026, 1, 1, tz="America/Toronto"),
    catchup=False,
    max_active_runs=1,
    tags=["ci", "infra"],
    doc_md=__doc__,
)
def infra_pr_validation() -> None:
    @task
    def list_open_prs() -> list[dict[str, Any]]:
        token = Variable.get("infra_ci_github_token")
        repo = Variable.get("infra_ci_repo", default="nicolaslallier/Infra")

        prs = _gh(f"/repos/{repo}/pulls?state=open&per_page=50", token)
        selected = [
            {
                "repo": repo,
                "number": pr["number"],
                "title": pr["title"],
                "head_sha": pr["head"]["sha"],
                "head_ref": pr["head"]["ref"],
                "clone_url": pr["head"]["repo"]["clone_url"] if pr["head"]["repo"] else None,
            }
            for pr in prs
            if not pr.get("draft")
        ]
        print(f"{len(selected)} open non-draft PR(s) on {repo}")
        return selected

    @task(
        retries=1,
        retry_delay=timedelta(minutes=2),
        execution_timeout=timedelta(minutes=25),
    )
    def run_checks(pr: dict[str, Any]) -> dict[str, Any]:
        from airflow.sdk import get_current_context

        run_id = get_current_context()["run_id"]
        safe_run = "".join(c if c.isalnum() else "-" for c in run_id)[-40:]
        workspace = os.path.join(WORKSPACE_ROOT, f"pr-{pr['number']}-{safe_run}")

        token = Variable.get("infra_ci_github_token")
        results: list[dict[str, Any]] = []

        try:
            os.makedirs(workspace, exist_ok=True)

            # The Airflow image has no git, so the clone runs in a container
            # too -- as this process's uid, or the checkout lands root-owned
            # and the steps below cannot write .env into it.
            clone_url = f"https://x-access-token:{token}@github.com/{pr['repo']}.git"
            code, out = _docker_run(
                image=IMG_GIT,
                command=[
                    "clone",
                    "--depth",
                    "1",
                    "--branch",
                    pr["head_ref"],
                    clone_url,
                    "/work",
                ],
                volumes={workspace: {"bind": "/work", "mode": "rw"}},
                user=f"{os.getuid()}:{os.getgid()}",
            )
            if code != 0:
                # Never let a token reach a task log or a PR comment.
                out = out.replace(token, "***")
                return {
                    "pr": pr,
                    "results": [{"name": "clone", "code": code, "output": out}],
                }

            # Throwaway .env / seal key / certs, from the PR's own copy of the
            # script -- so a PR that breaks it fails right here.
            prep = subprocess.run(
                ["bash", "scripts/ci-fake-env.sh", workspace],
                cwd=workspace,
                capture_output=True,
                text=True,
                timeout=120,
                env={**os.environ, "CI_FAKE_ENV_FORCE": "1"},
            )
            results.append(
                {
                    "name": "prepare workspace",
                    "code": prep.returncode,
                    "output": (prep.stdout + prep.stderr).strip(),
                }
            )
            if prep.returncode != 0:
                return {"pr": pr, "results": results}

            for name, fn in (
                ("check-env", _check_env_script),
                ("json/yaml", _check_json_yaml),
            ):
                code, out = fn(workspace)
                results.append({"name": name, "code": code, "output": out})

            for check in _checks(workspace):
                kwargs = {
                    "image": check["image"],
                    "command": check["command"],
                    "volumes": check["volumes"],
                    "working_dir": check.get("working_dir"),
                }
                if check.get("entrypoint"):
                    # promtool is a second binary in the prometheus image.
                    kwargs["command"] = [check["entrypoint"], *check["command"]]
                code, out = _docker_run(**kwargs)
                results.append({"name": check["name"], "code": code, "output": out})

            return {"pr": pr, "results": results}
        finally:
            shutil.rmtree(workspace, ignore_errors=True)

    @task(retries=2, retry_delay=timedelta(minutes=1))
    def post_report(outcome: dict[str, Any]) -> None:
        token = Variable.get("infra_ci_github_token")
        pr = outcome["pr"]
        results = outcome["results"]
        failed = [r for r in results if r["code"] != 0]

        header = (
            f"{COMMENT_MARKER}\n"
            f"### {'❌' if failed else '✅'} Validation infra — `{pr['head_sha'][:7]}`\n\n"
            f"| check | résultat |\n|---|---|\n"
        )
        rows = ""
        for r in results:
            verdict = "✅" if r["code"] == 0 else f"❌ (exit {r['code']})"
            rows += f"| `{r['name']}` | {verdict} |\n"
        details = ""
        for r in failed:
            body = r["output"][-3000:] or "(aucune sortie)"
            details += f"\n<details><summary><code>{r['name']}</code></summary>\n\n```\n{body}\n```\n\n</details>\n"

        footer = "\n<sub>Posté par la DAG Airflow <code>infra_pr_validation</code>.</sub>"
        comment = header + rows + details + footer

        existing = _gh(f"/repos/{pr['repo']}/issues/{pr['number']}/comments?per_page=100", token)
        mine = next((c for c in existing if COMMENT_MARKER in (c.get("body") or "")), None)

        if mine:
            _gh(
                f"/repos/{pr['repo']}/issues/comments/{mine['id']}",
                token,
                method="PATCH",
                body={"body": comment},
            )
        else:
            _gh(
                f"/repos/{pr['repo']}/issues/{pr['number']}/comments",
                token,
                method="POST",
                body={"body": comment},
            )

        if failed:
            raise RuntimeError(
                f"PR #{pr['number']}: {len(failed)} check(s) en échec — "
                + ", ".join(r["name"] for r in failed)
            )

    post_report.expand(outcome=run_checks.expand(pr=list_open_prs()))


infra_pr_validation()
