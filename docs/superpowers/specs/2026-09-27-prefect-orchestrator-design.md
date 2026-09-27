# Replace Airflow with Prefect; first AI pipeline

Status: draft 2026-09-27

## Goal

Swap the stack's orchestrator from Airflow 3 to Prefect 3, and ship the first
pipeline that calls a model: an inbox organizer for the Obsidian vault's S3
copy. Two flows, no framework: the existing nightly PR validation, ported
as-is, and the organizer. Pipeline #2 is decided only after #1 has run.

Constraints the design answers to: Python pipelines written as code (no
visual builder), running in Docker on this stack, calling a model and
external tools.

## Decisions

- **Prefect replaces Airflow, not beside it.** One scheduler, one UI, one
  metadata DB. Airflow and everything that exists only for it is removed.
- **`infra_pr_validation` is ported, not rewritten.** Same checks, same
  sibling-container images, same comment. Logic changes are out of scope.
- **Models are called directly: Ollama over HTTP.** `POST /api/chat` on
  `http://192.168.2.40:11434` (the instance LibreChat and the `AI` repo
  already use), with a JSON-schema `format` so the reply is structured and
  validated. Rejected: LibreChat's Agents API (a batch job would depend on a
  chat UI's stack and auth, and get free text back) and the MCP server at
  `:8000` (an agent loop adds nondeterminism to a fixed sequence of steps).
  **This is the calling convention for every later pipeline:** the flow owns
  control flow, the model owns only judgement.
- **Notes are S3 objects, not an Obsidian integration.** The organizer
  reads and writes Markdown in the `obsidian` bucket. No Local REST API
  plugin, no `192.168.1.142:27123` endpoint, no Obsidian process involved.
- **Two gates, both required.** Prefect's API auth
  (`PREFECT_SERVER_API_AUTH_STRING`) protects the API on `infra-net`; a
  fourth oauth2-proxy (`oauth2-proxy-prefect`, realm `infra`, group
  `prefect`) protects the browser vhost. Rejected: built-in auth alone
  (weaker than SSO for something with the Docker socket behind it) and
  generalising `oauth2-proxy-infra` across `*.infra` hosts (a refactor of a
  gate that just shipped).
- **`serve()` in one container, no work pool.** `prefect-flows` runs
  `serve.py`, which registers every deployment and its schedule and executes
  runs as subprocesses. Rejected: work pool + worker + `prefect.yaml` +
  deploy step (parts that pay off only when flows need different
  infrastructure) and a separate pipelines repo (the PR flow is *about* this
  repo, and its socket/workspace plumbing is documented here).
- **Organizer: enrich, then file.** Frontmatter gets `tags`, `summary`,
  `organized_at`; the note moves out of `Inbox/` into an existing top-level
  folder. The move is the idempotency marker — no state table.

## Constraints found

- **Prefect OSS's API is unauthenticated by default, and deployment `pull`
  steps can run shell commands.** `prefect-flows` holds the Docker socket, so
  an open API would give any container on `infra-net` (LibreChat, Jarvis,
  EA, …) root on the daemon via `prefect-server:4200` — a path NGINX is not
  on. This is why the API auth string is mandatory and gets a `:?` guard.
- **The runner never goes through NGINX.** oauth2-proxy gates people; the
  auth string gates the socket. Neither substitutes for the other.
- **Remotely Save also writes the bucket.** Two writers on a sync target is
  how conflict copies happen. A conflict needs both sides to edit the same
  object between two syncs, so the organizer only touches inbox notes quiet
  for `QUIET_MINUTES` (default 10). A heuristic, not a lock — the knob to
  raise if a conflict copy ever appears.
- **The `obsidian` bucket is versioned**, so every `PUT`/`DELETE` the flow
  makes is undoable. That is what makes copy-then-delete safe without a
  transaction.
- **Moving a note does not break links.** Obsidian's default `[[Note]]`
  resolves by basename, not path.
- **Keycloak realm import only runs against an empty realm.** The `prefect`
  client and group added to `infra-realm.json` reach the live cluster only
  through `kcadm` (see Cutover).
- **`serve()` does not backfill.** Runs scheduled while `prefect-server` is
  down are skipped. Acceptable for both flows.

## Design

### 1. Services (`docker-compose.yml`)

None of these gets a `ports:` entry (single-ingress rule; add them to the
list in `CLAUDE.md`).

- **`prefect-server`** — `prefecthq/prefect:<3.x.y>-python3.12`, pinned tag
  resolved at implementation. `prefect server start --host 0.0.0.0` on
  `:4200`.
  - `PREFECT_API_DATABASE_CONNECTION_URL:
    postgresql+asyncpg://prefect:${PREFECT_DB_PASSWORD}@postgres:5432/prefect`
    — a database/role `prefect` from the generic per-app provisioning.
  - `PREFECT_SERVER_API_AUTH_STRING: ${PREFECT_AUTH_STRING:?...}`.
  - `PREFECT_UI_API_URL: https://prefect.infra.famillelallier.net/api`.
- **`prefect-flows`** — same image, `command: python /opt/prefect/flows/serve.py`.
  - `EXTRA_PIP_PACKAGES: "docker boto3"` (the image installs them at
    start; no custom Dockerfile). `pyyaml` already ships with Prefect.
  - `PREFECT_API_URL: http://prefect-server:4200/api`,
    `PREFECT_API_AUTH_STRING: ${PREFECT_AUTH_STRING:?...}`.
  - `OLLAMA_URL` (default `http://192.168.2.40:11434`), `OLLAMA_MODEL`
    (default `qwen3.8:27b-mlx`), `OBSIDIAN_S3_ACCESS_KEY`,
    `OBSIDIAN_S3_SECRET_KEY`, `S3_ENDPOINT: http://s3:8333`.
  - Volumes, moved verbatim from `airflow-scheduler` with their comments:
    `${INFRA_DIR:-.}/prefect/flows:/opt/prefect/flows:ro`,
    `/var/run/docker.sock:/var/run/docker.sock`,
    `/tmp/infra-ci:/tmp/infra-ci` (identical on both sides — sibling
    containers' `-v` is resolved by the daemon). `group_add: ["0"]`.
  - `depends_on: prefect-server` (healthy: `/api/health`).
- **`oauth2-proxy-prefect`** — a copy of `oauth2-proxy-infra`: realm
  `infra`, `CLIENT_ID: prefect`, `ALLOWED_GROUPS: prefect`,
  `COOKIE_NAME: _oauth2_proxy_prefect`,
  `REDIRECT_URL: https://prefect.infra.famillelallier.net/oauth2/callback`,
  `CODE_CHALLENGE_METHOD: S256`, scopes `openid email profile` (PR #71).
  Client secret: **no** `:?` guard. Cookie secret: `:?` guard.

**Removed:** `airflow-init`, `airflow-apiserver`, `airflow-scheduler`,
`airflow-dag-processor`, the `x-airflow-common` anchor, the `airflow-logs`
volume, `airflow/`.

Not added: Prometheus metrics (Prefect has no native exporter; logs reach
Loki through Alloy already). Add when a dashboard is wanted.

### 2. NGINX, DNS, certificates

- `nginx/conf.d/prefect.conf` — the `s3-admin.conf` auth_request recipe,
  upstream `http://prefect-server:4200`, oauth2 upstream
  `http://oauth2-proxy-prefect:4180`. Browsers pass SSO, then Prefect's own
  password prompt; the UI's `Authorization: Basic` header rides through to
  the upstream.
- `nginx/conf.d/airflow.conf` deleted.
- `scripts/print-hosts-entries.sh`: `airflow` → `prefect`.
- No cert or DNS work: `prefect.infra.famillelallier.net` rides the
  `*.infra` wildcard in both `gen-certs.sh` and the `infra` zone.

### 3. Flows (`prefect/flows/`)

**`serve.py`** — imports both flows and calls:

```python
serve(
    pr_validation.to_deployment(name="nightly", cron="0 3 * * *",
                                timezone="America/Toronto"),
    organize_inbox.to_deployment(name="every-15m", interval=900),
)
```

**`pr_validation.py`** — port of `airflow/dags/infra_pr_validation.py`:

- `@dag` → `@flow`; `@task(retries=…)` keeps its retries.
- Airflow dynamic mapping → `run_checks.map(prs)`: a red PR is still its
  own failed task run.
- GitHub PAT: Airflow Variable `infra_ci_github_token` → Prefect `Secret`
  block `infra-ci-github-token`. Repo stays overridable, default
  `nicolaslallier/Infra`.
- `ci-fake-env.sh` still comes from the PR's own checkout.

**`organize_inbox.py`** — per run:

1. **Discover.** List `Inbox/*.md` with `LastModified` ≥ `QUIET_MINUTES`
   (default 10) old, at most `MAX_NOTES` (default 20) per run. List
   top-level folders (`Delimiter="/"`), excluding `Inbox/` and dot-folders
   (`.obsidian/`, `.trash/`).
2. **Classify** — one task per note, `retries=2`. `POST
   {OLLAMA_URL}/api/chat`, `stream: false`, `format`:
   `{tags: string[] (maxItems 5), summary: string, folder: enum[<folders>]}`.
   The enum is built at run time: the model can only pick an existing
   folder.
3. **Write.** Merge frontmatter with `pyyaml`: union of existing and new
   `tags`, set `summary` and `organized_at`, never drop an existing key. A
   note with no frontmatter gets one. `PUT <folder>/<name>.md`; **if that
   key exists, fail the note and leave it in `Inbox/`** — never overwrite.
   `DELETE` the inbox object only after a successful `PUT`.
4. **Result.** Notes succeed or fail independently; the run is `Failed` if
   any note failed.

S3 identity: a new `prefect` identity scoped to the `obsidian` bucket
(`make s3-provision app=prefect bucket=obsidian`), separate from Remotely
Save's `obsidian` identity so either can be revoked alone.

### 4. Secrets and preflight

New `.env.example` keys, validated by `check-env.sh`, rendered by
`ci-fake-env.sh` in the shapes `check-env` demands, round-tripped through
`vault-seed` / `vault-render` like every other key:

| Key | Shape / guard |
|---|---|
| `PREFECT_DB_PASSWORD` | url-safe (embedded in the asyncpg URL); added to `APP_DATABASES` as `prefect` |
| `PREFECT_AUTH_STRING` | `admin:<secret>`; `:?` guard |
| `PREFECT_OAUTH_CLIENT_SECRET` | no guard; `check-env.sh` entry `PREFECT_OAUTH_CLIENT_SECRET:oauth2-proxy-prefect:infra:prefect` beside the `S3_ADMIN_…` one |
| `PREFECT_OAUTH_COOKIE_SECRET` | `:?` guard; `openssl rand -base64 32 \| tr -- '+/' '-_'` |
| `OBSIDIAN_S3_ACCESS_KEY` / `OBSIDIAN_S3_SECRET_KEY` | from `make s3-provision app=prefect bucket=obsidian` |

All `AIRFLOW_*` keys and their checks are removed.

The GitHub PAT stays **out of `.env`** (it can write to GitHub and `.env` is
handed to containers wholesale and to Portainer). It lives in the Prefect
`Secret` block, stored in the `prefect` database. Moving it to
`infra/apps/prefect` in OpenBao remains the next move, out of scope here.

### 5. Keycloak (`infra` realm)

`keycloak/realm-import/infra-realm.json` gains group `prefect` and client
`prefect`, copied from `s3-admin`: confidential, PKCE S256, one exact
redirect URI `https://prefect.infra.famillelallier.net/oauth2/callback`,
post-logout redirect to the host, audience mapper `prefect-audience`.
`keycloak/CLAUDE.md` documents it next to `s3-admin`.

### 6. Documentation

`CLAUDE.md`, `AGENTS.md`, `README.md`: the Airflow service entry and the
"Airflow: nightly PR validation" section become Prefect ones (same
load-bearing points: same-path workspace, socket on one container only,
checks in the real images, `ci-fake-env.sh` from the PR). Add the API-auth
constraint above. Add the organizer and the Ollama calling convention.

### 7. Tests

The repo has no test step. One `prefect/flows/test_organize_inbox.py`,
plain `assert`s, run with `python`, over the pure functions:

- frontmatter merge: keeps unknown keys, unions tags, handles no
  frontmatter;
- folder listing: excludes `Inbox/` and dot-folders;
- destination path from folder + inbox key.

Everything else is verified by running the stack (Acceptance).

## Failure modes

| Case | Behaviour |
|---|---|
| Ollama down / `192.168.2.40` asleep | task retries twice, note fails, stays in `Inbox/`; next run retries it |
| Reply outside the schema / unknown folder | note fails, nothing written |
| `PUT` ok, `DELETE` failed | note in both places; next run hits "destination exists", fails loudly, nothing overwritten; remove the inbox copy by hand |
| Destination name taken | note fails, stays in `Inbox/`; rename by hand |
| `prefect-server` down | `serve()` reconnects; missed runs are not backfilled |

## Cutover

One PR. After merge:

1. `git pull --ff-only` on the host checkout.
2. `make provision-app app=prefect`.
3. `make s3-provision app=prefect bucket=obsidian` → keys into `.env`.
4. `kcadm`: create group `prefect` and client `prefect` in realm `infra`
   (as in `infra-realm.json`), add yourself to the group, copy the client
   secret into `PREFECT_OAUTH_CLIENT_SECRET`. Generate
   `PREFECT_AUTH_STRING` and `PREFECT_OAUTH_COOKIE_SECRET`.
5. `make vault-seed`, then `make up`.
6. In the Prefect UI: create `Secret` block `infra-ci-github-token`.
7. Acceptance checks below.
8. After one green nightly `pr-validation` run: `DROP DATABASE airflow;
   DROP ROLE airflow;` by hand (irreversible, so not in the PR), and remove
   `airflow` from `APP_DATABASES` if present.

## Acceptance

- `make up` succeeds; no `airflow-*` container remains.
- `https://prefect.infra.famillelallier.net`: a user outside group `prefect`
  is refused by oauth2-proxy; a member passes SSO and then the Prefect
  password prompt.
- From another container on `infra-net`,
  `curl http://prefect-server:4200/api/deployments/filter -X POST` without
  the auth string gets `401`.
- Both deployments (`pr-validation/nightly`, `organize-inbox/every-15m`)
  appear with their schedules.
- A manual `pr-validation` run against an open PR posts/updates its single
  comment; a deliberately broken PR shows as a failed mapped task.
- A test note dropped in `Inbox/` and left 10 minutes ends up in an existing
  folder with `tags`, `summary`, `organized_at`; the bucket holds a prior
  version of the deleted inbox object.
- `python prefect/flows/test_organize_inbox.py` passes.

## Out of scope

- Pipeline #2, and any generic pipeline framework.
- Moving secrets to `infra/apps/prefect` in OpenBao.
- Prometheus metrics / Grafana dashboard for Prefect.
- Work pools, remote workers, per-run containers.
- Any Obsidian-app integration (Local REST API, `192.168.1.142`).
- Changes to the PR-validation checks themselves.
