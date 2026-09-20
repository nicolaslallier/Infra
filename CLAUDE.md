# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`Infra` is the shared "common group" backing stack for sibling application
repos (`Jarvis` and others): NGINX, PostgreSQL 18, pgAdmin, Keycloak, MinIO,
RabbitMQ, Neo4j, OpenBao, Portainer, a Technitium DNS server, and an LGTM
monitoring stack (Grafana, Prometheus, Loki, Tempo, Alloy + exporters), run via
Docker Compose.
Application repos are meant to stay in their own repositories and connect in
over a shared Docker network rather than being folded into this one.

## Commands

Run `make help` for the target list. Notable: `make up`/`down` deploy via Portainer, `make init` bootstraps `.env`/certs/`infra-net`/OpenBao's seal key, `make vault-*` drive the secrets vault, `make runner-*` the CI runner, `make clean CONFIRM=1` deletes the stack + volumes.

The `vault-*` targets deliberately do **not** run `check-env`: `make vault-env`
is how a `.env` that `check-env` rejects gets repaired, so requiring it first
would deadlock.

`up`, `pull`, `config`, `provision-app`, `dns-provision`, `dns-check`,
`keycloak-seed-users` and `obsidian-minio` run `check-env`
(`scripts/check-env.sh`) first — see "Preflight: `make check-env`" below for
what it asserts and why each check exists. `up`, `pull`, `config`,
and `portainer-up` also run `check-docker` (see "Runtime: Docker Desktop"
below).

`up` and `pull` — the two targets that deploy — run **`vault-render` before
`check-env`**, so what gets validated and deployed is a `.env` rendered from
the vault seconds earlier rather than whatever the checkout happened to hold.
That ordering is why the Makefile declares `.NOTPARALLEL:`: prerequisites are
only made left to right in a serial build. See "Rendering `.env` at deploy
time" under "Secrets (OpenBao)" below for when it skips and when it fails.

There is no build/lint/test step — this repo is Compose config, NGINX
config, and shell scripts, not an application. Validate changes by actually
running the stack (`make up`) and exercising it, per the checks below.

## Architecture

Services on one external Docker network (`infra-net`, created by
`make net` / `make init`, not by Compose itself — `external: true` in
`docker-compose.yml` so the network outlives `docker compose down` and
never orphans another app that's still attached to it):

- **`postgres`** — `pgvector/pgvector:pg18` (Postgres 18 + pgvector;
  Debian bookworm — no alpine tag for pg18). Publishes no host port.
  Per-app provisioning also runs `CREATE EXTENSION IF NOT EXISTS vector`
  as the superuser in each app database, so app roles (e.g. Jarvis RAG
  migrations) can use the `vector` type without needing CREATE EXTENSION
  privilege themselves.
- **`pgadmin`** — `dpage/pgadmin4:9`. Publishes no host port.
- **`keycloak`** — `quay.io/keycloak/keycloak`. Publishes no host port;
  uses the shared `postgres` cluster (database/role `keycloak`, via the
  same generic per-app provisioning as any other app — see "Per-app
  database provisioning" below), not a bundled DB of its own. Metrics
  enabled on the management interface (`:9000/metrics`).
- **`minio`** — `quay.io/minio/minio` (pinned; gone from Docker Hub). Publishes no host port. S3 API on `:9000`
  and browser console on `:9001`, both fronted by NGINX
  (`minio.famillelallier.net` / `minio-console.famillelallier.net`).
  Apps on `infra-net` reach the API at `http://minio:9000`.
- **`rabbitmq`** — `rabbitmq:4-management`. Publishes no host port. AMQP
  on `:5672` (NGINX stream passthrough at `127.0.0.1:5672`; apps on
  `infra-net` use `rabbitmq:5672` directly) and management UI on `:15672`
  (`rabbitmq.infra.famillelallier.net`). Prometheus metrics on `:15692`.
- **`neo4j`** — `neo4j:<version>-community`, pinned by tag *and* digest
  because a store-format upgrade must not ride along with a redeploy. The
  EA repo's architecture graph (its `docs/adr/0030`). Publishes no host
  port: Bolt goes through NGINX's stream passthrough at `127.0.0.1:7687`;
  apps on `infra-net` use `neo4j:7687`. The browser (`:7474`) is not
  exposed. `NEO4J_PASSWORD` is read once, on first boot against an empty
  `neo4j-data` volume — and `make clean` deletes that volume like the rest.
- **`openbao`** — `openbao/openbao:2.6.2`, the secret store, at
  `vault.infra.famillelallier.net` (NGINX → `openbao:8200`). OpenBao is the
  MPL-licensed fork of HashiCorp Vault, which went BUSL at 1.15; same KV v2
  API and the same `bao`/`vault` CLI, so Vault's docs and client libraries
  apply. Publishes no host port; apps on `infra-net` use
  `http://openbao:8200`. Raft (integrated) storage on the `openbao-data`
  volume, KV v2 mounted at `infra/`. **Auto-unseals** from
  `openbao/seal.key` — a gitignored 32-byte file, not a `.env` value — which
  is the only reason it survives `make up` at all (every deploy
  force-recreates every container, and a Shamir-sealed vault would come back
  sealed each time). `make vault-init` initialises it and writes the root
  token to `.openbao.env`; `make vault-seed` / `make vault-env` are the two
  directions of the `.env` round trip. See "Secrets (OpenBao)" below — the
  seal key and the trade it makes are the part worth reading before touching
  anything here.
- **`portainer`** — `portainer/portainer-ce:lts`, the Docker management
  UI, at `portainer.infra.famillelallier.net` and directly at
  `https://${LAN_IP}:9443`. The one backend that **publishes its own
  ports** (9443/9000/8000, bound to `${LAN_IP}`) — see "Single-ingress
  rule" for why. The vhost's NGINX proxies to `https://portainer:9443` rather than
  `http://portainer:9000`, because Portainer's self-signed TLS listener is
  present on every release while the plain-HTTP one is version-dependent
  and can be off by default (`proxy_ssl_verify off` — that certificate is
  container-generated and the hop never leaves `infra-net`). It mounts
  `/var/run/docker.sock` **read-write** on purpose: managing containers is
  what it is for. That makes the UI equivalent to root on the daemon,
  gated only by Portainer's own admin account — this vhost is not behind
  oauth2-proxy. Its admin account must be created within a few minutes of
  the container's first start or Portainer disables the form;
  `make portainer-restart` reopens that window. It is **not** part of
  `docker-compose.yml`: it lives in `docker-compose.portainer.yml` (project
  `portainer`, volume `infra_portainer-data`) because it deploys the
  `infra` stack and a redeploy must never stop it. `make portainer-up` /
  `-down` / `-restart` / `-logs` drive it.
- **`nginx`** — `nginx:alpine-otel`. Fronts every backend application service —
  the only one of those services with a `ports:` entry. Also listens on
  internal `:8080/stub_status` for `nginx-exporter` (not published on the
  host). The `-otel` variant is load-bearing: `nginx.conf` loads
  `ngx_otel_module` and starts a trace for every request (span exported to
  `alloy:4317`, W3C `traceparent` forwarded upstream, id returned as the
  `X-Trace-Id` response header and logged as `trace_id=`). Plain
  `nginx:alpine` fails on `load_module`. Keycloak continues that trace
  (`KC_TRACING_ENABLED`), so one id shows nginx → keycloak → its SQL
  queries in Tempo. A vhost that sets its own `add_header` loses the
  inherited `X-Trace-Id` and must repeat it.
- **`obsidian`** — `lscr.io/linuxserver/obsidian`, the Obsidian desktop
  app streamed to a browser at `obsidian.infra.famillelallier.net`
  (port `3000`, one long-lived WebSocket; vaults in the `obsidian-config`
  volume). Publishes no host port. It has no auth of its own and is a whole
  desktop session, so `nginx/conf.d/obsidian.conf` gates it with an
  `oauth2-proxy`/`auth_request` recipe — but against the **`ea`** realm,
  via a **second** proxy container, `oauth2-proxy-ea`, and its own
  confidential client `ea-obsidian`. The second container is not
  duplication to be tidied away: an oauth2-proxy process is bound to one
  issuer, so "who may open Obsidian" (the `ea` realm) and "who may open
  Jarvis" (the `jarvis` realm) cannot share one. Everything happens on the
  Obsidian hostname — `REDIRECT_URL` is
  `https://obsidian.infra.famillelallier.net/oauth2/callback` — so unlike
  the Jarvis gate it needs no `COOKIE_DOMAINS` and no
  `WHITELIST_DOMAINS`, and its cookie is host-scoped. It still carries a
  distinct `OAUTH2_PROXY_COOKIE_NAME` (`_oauth2_proxy_ea`), because the
  Jarvis proxy's `_oauth2_proxy` cookie *is* scoped to
  `.famillelallier.net` and would otherwise be clobbered on every Obsidian
  login. Consequence: any `ea` realm user gets Obsidian, and an Obsidian
  session is not a Jarvis session (different realm, different cookie, no
  SSO). `ea-obsidian` enforces PKCE like every other client in that realm,
  hence `OAUTH2_PROXY_CODE_CHALLENGE_METHOD: S256`. oauth2-proxy reads the
  `email` claim, so an `ea` user without an email address cannot log in,
  and one whose **Email verified** is off gets a bare 500 on
  `/oauth2/callback` (logged as `email in id_token (...) isn't verified`).
  Vault data is synced into MinIO (bucket `obsidian`, versioned) by the
  in-app **Remotely Save** plugin against `http://minio:9000`, using a
  MinIO user `obsidian` scoped to that bucket
  (`make obsidian-minio` / `scripts/provision-obsidian-minio.sh`). The
  working copy stays on the `obsidian-config` volume: Obsidian watches the
  filesystem, so a FUSE/s3fs mount of the bucket as `/config` is not an
  option (it also needs `SYS_ADMIN`). MinIO is the durable copy and the one
  other devices sync from.
- **`airflow-*`** — `apache/airflow:3.3.1`, at
  `airflow.infra.famillelallier.net` (NGINX → `airflow-apiserver:8080`).
  Publishes no host port. `LocalExecutor`, so tasks run inside
  `airflow-scheduler` and there is no Celery/Redis; `airflow-dag-processor`
  is a required component in Airflow 3, not optional. Its metadata DB is the
  provisioned Postgres database/role `airflow` — on an existing cluster run
  `make provision-app app=airflow` before the first deploy, or `airflow-init`
  fails and the rest never start. `airflow-init` is a one-shot (migrate +
  create admin) that re-runs harmlessly on every `make up`. All components
  must share `AIRFLOW_JWT_SECRET` (execution-API tokens) and
  `AIRFLOW_FERNET_KEY` (connection encryption; changing it orphans stored
  secrets), hence their `:?` guards. DAGs are bind-mounted read-only from
  `airflow/dags/` — they must be committed, since the drift guard refuses
  untracked files. No triggerer: add an `airflow-triggerer` service
  (`command: triggerer`) the day a DAG uses deferrable operators.
  `airflow-scheduler` alone carries the Docker socket and the
  `/tmp/infra-ci` workspace — see "Airflow: nightly PR validation" below for
  what they are for and what the socket costs.
- **`dns`** — `technitium/dns-server`. A top-level infra service, not a
  backend app — publishes its own ports (53 and 5380). See "Single-ingress
  rule" and "DNS (LAN resolver)" below for why that's not a violation of
  the same rule that keeps `postgres`/`pgadmin`/`keycloak` unpublished.
- **LGTM + exporters** — `grafana`, `prometheus`, `loki`, `tempo`,
  `alloy`, `cadvisor`, `node-exporter`, `postgres-exporter`, `nginx-exporter`.
  Only Grafana is fronted by NGINX (`grafana.infra.famillelallier.net`);
  everything else stays on `infra-net` with no host `ports:`. Config lives
  under `monitoring/`. Grafana stores its own state in the provisioned
  Postgres database/role `grafana`. Alloy mounts the Docker socket to
  collect container logs (all Compose projects on the host) and accepts
  OTLP (`alloy:4317` / `alloy:4318`) for traces forwarded to Tempo.
- **Windows machines** — no service of this stack at all: `windows_exporter`
  runs *on* each Windows host and Prometheus scrapes it over the LAN as job
  `windows`. See "Windows machines (`windows_exporter`)" below.
- **Macs** — likewise no service of this stack: node_exporter's *darwin*
  build runs on each Mac and Prometheus scrapes it over the LAN as job
  `macos`, distinct from the `node` job (the node-exporter container, which
  describes Docker Desktop's Linux VM). See "macOS machines
  (`node_exporter` on darwin)" below.

`postgres` has no LAN/browser-facing hostname — that's deliberate, not an
oversight. `pgadmin` (`pgadmin.famillelallier.net`), `keycloak`
(`keycloak.famillelallier.net`), Grafana
(`grafana.infra.famillelallier.net`), MinIO
(`minio.famillelallier.net` / `minio-console.famillelallier.net`),
RabbitMQ management (`rabbitmq.infra.famillelallier.net`),
the Jarvis frontend (`jarvis.famillelallier.net`, also reachable at
`jarvis.infra.famillelallier.net`), and LibreChat (`chat.famillelallier.net`,
admin panel at `chat-admin.infra.famillelallier.net`) do. LibreChat is a
Portainer stack of its own (compose in `~/OpenCode/LibreChat`), not a service
of this repo: its `api` and `admin-panel` join `infra-net` under the aliases
`librechat` / `librechat-admin` (`nginx/conf.d/librechat.conf`), and nothing
else of it publishes a port. When registering the Postgres server
inside pgAdmin's own UI, the host is the Compose service name `postgres`
(pgAdmin and `postgres` share `infra-net` directly), port `5432` — never a
`*.famillelallier.net` hostname. A hostname like
`postgresql.famillelallier.net` doesn't exist anywhere in this stack and
produces connection-refused, not a DNS or reachability problem.

### Preflight: `make check-env`

`scripts/check-env.sh` blocks deploys against a `.env` that can't bring the
stack up (keys missing vs `.env.example`, `change-me`/empty passwords,
bad oauth2-proxy cookie keys, a missing/wrong-sized `openbao/seal.key`, a
`LAN_IP` the host doesn't own). Rules that apply outside `scripts/`: every
cookie-secret recipe must end in `| tr -- '+/' '-_'` (oauth2-proxy decodes
URL-safe base64 only), and the oauth2-proxy *client* secrets must never get
a `:?` guard in `docker-compose.yml` — Keycloak creates them on first realm
import. Full rationale per check in `scripts/CLAUDE.md`.

### Runtime: Docker Desktop

Docker Desktop for Mac (6 CPU / 12 GB / 100 GB, disk image on `/Volumes/Docker`). Details — `check-docker.sh` exit codes, `LAN_IP` semantics, Colima migration — live in `scripts/CLAUDE.md`.

### Portainer-managed stack

The `infra` stack is a **Portainer CE Git stack**: Portainer clones
`https://github.com/nicolaslallier/Infra` at `main` and runs
`docker-compose.yml` itself. `make up` / `down` / `pull` / `clean` call
Portainer's API through `scripts/portainer-stack.sh`; nobody runs
`docker compose up` for this stack any more. GitOps polling is off on
purpose.

Things that look odd and are load-bearing:

- **`${INFRA_DIR:-.}` on every repo bind mount.** Portainer runs compose
  from its clone in `/data/compose/<id>` *inside its container*, so a bare
  `./nginx` would be mounted from a path that doesn't exist on the Mac and
  arrive empty. Relative-path volumes are Business Edition only. The script
  passes `INFRA_DIR=<the checkout make ran from>`, so **the compose comes
  from GitHub and the mounted files from that checkout**. `certs/` and
  `.env` are gitignored and could not come from Git anyway. That path must
  be the one the *daemon* sees: from the Mac the Makefile sets
  `PORTAINER_INFRA_DIR`, and from WSL `daemon_dir` rewrites `/mnt/c/...` to
  `/run/desktop/mnt/host/c/...`. A raw `/mnt/c` path gets auto-created empty
  in Docker Desktop's VM and `nginx` dies with `mounting ".../nginx.conf"
  ... not a directory`.
- **The drift guard.** Because of that split, `make up` / `pull` refuse
  unless the checkout is on `main`, clean, and at `origin/main`. Merge,
  `git pull --ff-only`, then `make up`. It is also why polling stays off:
  a push would redeploy against configs that haven't been pulled yet.
- **No `name:` pin in `docker-compose.yml`.** The CLI project name comes
  from the checkout directory instead — the main checkout is `Infra`, so
  the CLI project is `infra` there, and it must not be renamed. Portainer
  names its stack `infra` itself, independent of any directory name. A
  worktree checkout gets its *own* compose project (a different name), by
  design: `scripts/portainer-stack.sh` also refuses outright to run
  `up`/`pull`/`down`/`delete` from a linked worktree (`check_main_checkout`),
  since it would otherwise mount files from a directory that can later be
  deleted and address the one live stack from any number of worktrees.
- **The drift guard checks for untracked files too.** `check_synced` uses
  `git status --porcelain`, not `git diff --quiet HEAD` — a stray untracked
  file (e.g. a new `nginx/conf.d/*.conf` not yet `git add`ed) would
  otherwise be silently mounted into the deploy without tripping the guard.
  `.env`, `.portainer.env`, and `certs/` are gitignored, so they never
  trip it.
- **Every `up`/`pull` force-recreates every container.** Portainer's
  git-redeploy always sets `forceCreate=true`; there's no "only what
  changed" mode here like plain `docker compose up -d` had. Expect a brief
  outage on every `make up`, including a momentary LAN DNS drop from
  `dns` — this is a real behavior change from the pre-Portainer stack, not
  a bug.
- **`.env` stays the source of truth for the stack itself.** Every `up` /
  `pull` sends it as the stack env (Portainer writes it to `stack.env`,
  hence the two optional `env_file` entries on `postgres`). Edits made in
  Portainer's env editor are overwritten on the next `make up`.
- **`PORTAINER_API_KEY` / `PORTAINER_ENDPOINT_ID` live in `.portainer.env`,
  not `.env`.** `.env` is handed to containers via `env_file` (`postgres`),
  and the API key is a Docker-daemon-root token that must never reach one
  — `scripts/portainer-stack.sh` sources `.portainer.env` on its own and
  dies if it's missing. `env_json`'s `PORTAINER_*` filter on `.env` stays
  in place as defence in depth.
- **API calls go through a throwaway `curlimages/curl` container on
  `infra-net`** to `https://portainer:9443`, not through NGINX or a hostname:
  both nginx and dns are *in* the stack being deployed. The API key
  reaches curl via a `-K` config file written inside that container from
  the first line of stdin (the JSON body follows), never on a command
  line, so it doesn't show up in any process list. Not `-e
  PORTAINER_API_KEY`: from WSL a Windows `docker.exe` doesn't inherit the
  shell's env, the key arrives empty, and Portainer only says "A valid
  authorization token is missing".
- **Portainer refuses to create a stack whose name matches a compose
  project it already knows about, stopped or not** — it lists containers
  regardless of state, so `docker compose stop` isn't enough; containers
  started by the CLI as project `infra` must be `docker compose down`
  first (volumes untouched).
- **`make clean`** deletes the Portainer stack, then `docker compose down
  -v`, which only removes volumes `docker-compose.yml` declares.
  `infra_portainer-data` still carries the `infra` project label from
  before the split, so never clean up by label.
- **Non-Mac environments** (CI, the cloud VM in `AGENTS.md`) have no
  Portainer stack: run `docker compose up -d` directly there.

### CI: deploying on a push to main

`.github/workflows/deploy.yml` redeploys the stack when main moves, running
`scripts/ci-deploy.sh` on a self-hosted runner
(`docker-compose.runner.yml`, `make runner-up`). `workflow_dispatch` runs the
same thing by hand, with a `pull_images` input that switches `make up` for
`make pull`.

**A GitHub-hosted runner cannot deploy this stack**, which is the constraint
the whole design follows from. Portainer publishes its API on
`${LAN_IP}:9443` and is otherwise only on `infra-net`, and there is no public
ingress to either — the same reason `airflow/dags/` exists rather than a
GitHub Actions job. The runner has to be on this LAN.

Five things here are load-bearing.

- **The runner is its own compose project**, like Portainer and for the same
  reason: every `up` force-recreates every container in `infra`, and a runner
  recreated mid-job is a job that never reports. `make runner-up` drives it;
  `--env-file .runner.env` on that target is not cosmetic, since without it
  compose would interpolate the runner's one setting out of the stack's
  entire secret set.
- **The deploy acts on the *host* checkout, not the runner's.** Portainer
  takes `docker-compose.yml` from GitHub main but every bind mount from the
  checkout at `INFRA_CHECKOUT` (see "Portainer-managed stack"), so that
  directory is what `ci-deploy.sh` brings to `origin/main`. The tree
  `actions/checkout` writes under the runner's `_work` only supplies the
  script. Confusing the two deploys main's compose against yesterday's
  configs — exactly what `portainer-stack.sh`'s drift guard exists to refuse.
- **The deploy runs in a throwaway `docker:*-cli` container**, the way
  `portainer-stack.sh` runs curl in one, and it is mounted at *the same path*
  inside as outside. Two things fall out of that. The runner image carries no
  part of the deploy, so updating or replacing it cannot change what gets
  deployed (`bash`, `make`, `jq`, `git` and the compose plugin are installed
  into the throwaway container, never assumed). And `$PWD` is a path the
  daemon can resolve too, so `portainer-stack.sh`'s
  `${PORTAINER_INFRA_DIR:-$PWD}` is already the right bind-mount source with
  nothing to translate — the identical-paths idiom, for the usual reason: a
  nested bind mount is resolved by the daemon, not by the container asking
  for it.
- **`INFRA_CHECKOUT` must end in `/Infra`,** and `ci-deploy.sh` refuses
  otherwise. The compose project name is the working directory's basename,
  and `make up` reaches the vault with `docker compose exec openbao`
  (`scripts/vault-env.sh`), which finds nothing under any other project name.
  This is the same "the main checkout must not be renamed" rule as above,
  arrived at from the other side.
- **`DOCKER_HOST` is set to the socket rather than left unset.**
  `check-env.sh` verifies `LAN_IP` against the addresses of the machine it
  runs on *unless* a `DOCKER_HOST` says the daemon is elsewhere — and the
  addresses of a throwaway container are not the deploy host's, so the check
  would reject a perfectly good `LAN_IP`. With it set, the comparison is
  against `INFRA_HOST` instead, which is the question actually worth asking.
  `SKIP_DOCKER_CHECK=1` is set for the reason `AGENTS.md` already documents:
  `check-docker.sh` asserts macOS/Docker-Desktop facts that mean nothing in
  here.

The `runner-*` targets are the whole management surface, and two of their
behaviours are load-bearing rather than polish. **`runner-status` reports
both sides** — the container on this daemon *and* `GET
/repos/<repo>/actions/runners` — because the runner is `EPHEMERAL` and the
two routinely disagree: it de-registers after every job, so a healthy
container is no evidence GitHub has a runner for the next deploy, and
GitHub never surfaces the gap (a job matching no labels queues silently
instead of failing). It reads the same PAT from `.runner.env`, so there is
nothing extra to provision, and it degrades to a warning — not an error —
when jq, the token or the network is missing, since an operator who cannot
reach GitHub must still be able to stop the runner. It does, however,
**separate a PAT GitHub refuses from a GitHub it cannot reach**, and reports
the first by name rather than as "unknown": that is the same credential the
runner's entrypoint exchanges for a registration token on every start, so a
401 here is the `Obtaining the token of the runner` → `curl: (22) ... 401` →
`Invalid configuration provided for token` loop in `make runner-logs`, seen
from the side that can explain it. Nothing else in the repo does — the
container restarts forever, `make runner-up` reported success, and the next
push to main queues its deploy silently. The fix is a new PAT
(`make runner-env FORCE=1 && make runner-restart`); `gen-runner-env.sh`
validates tokens when it writes them, but PATs expire afterwards.
**`runner-down`,
`-restart` and `-pull` refuse while a job is running** (`--busy`, exit 3;
`FORCE=1` overrides), scoped to the `infra` label because that label is the
contract with `deploy.yml`: recreating the container mid-job kills it and
the workflow run never reports a result. `runner-pull` exists because the
image tag moves on purpose — GitHub retires old runner versions server-side
— so it is the fix for a runner the service has stopped accepting, not
routine housekeeping.

`INFRA_CHECKOUT` and `INFRA_HOST` come from repository variables
(Settings → Secrets and variables → Actions → Variables) and fall back to the
two values the Makefile already hard-codes for the Mac. `GH_RUNNER_TOKEN` —
a PAT allowed to register runners — lives in `.runner.env`, gitignored, for
the reason `PORTAINER_API_KEY` lives in `.portainer.env`. `make runner-env`
(`scripts/gen-runner-env.sh`) writes that file, and the check it makes first
is the point of it: it asks GitHub for `/repos/<repo>/actions/runners` with
the token, and refuses to write one that gets a 401/403/404. A token with
the wrong scope otherwise registers nothing while `make runner-up` reports
success — the failure surfaces only as a 403 in the runner's own logs, from
a container that then restarts forever, and `deploy.yml` meanwhile queues
against a label no runner holds. The file is written where `make` runs, not
on the Docker host: compose reads `--env-file` locally and only the
interpolated result crosses `DOCKER_HOST`.

Docs-only pushes do not deploy (`paths-ignore` covers `**/*.md`, `docs/**`
and `.github/**`): a deploy force-recreates `dns` among everything else, so
it costs a brief LAN DNS outage, and a change that cannot reach a container
is not worth one. Deploys are serialised by a `concurrency` group and never
cancelled in flight, since a cancelled job leaves Portainer mid-redeploy.

**The security note, which is the part to read before changing any of this.**
This repo is public and the runner holds `/var/run/docker.sock` — root on the
Docker daemon, the same power Portainer's UI has. Two consequences:

- **Never add a `pull_request` or `pull_request_target` trigger to a workflow
  that runs on the `infra` label.** A fork's PR brings its own workflow file,
  so that combination is arbitrary code execution as root on the deploy host.
  The deploy workflow triggers on `push` to main and `workflow_dispatch`
  only. Set Settings → Actions → General → "Fork pull request workflows from
  outside collaborators" to **Require approval for all outside
  collaborators**; the default only gates first-time contributors.
- **Merging to main is now enough to run code on the host.** That was already
  true for whoever ran `make up`; it is now true for whoever can push to
  main. Branch protection on main is what keeps those two sets the same size.

### Single-ingress rule

This rule governs *backend application services* — anything NGINX fronts
(`postgres`, `pgadmin`, `keycloak`, `minio`, `rabbitmq`, `openbao`,
`portainer`, `grafana`, monitoring backends, and future apps) — not top-level infra
processes that own a protocol NGINX can't meaningfully front. `postgres`,
`pgadmin`, `keycloak`, `minio`, `rabbitmq`, `grafana`, and the
rest of LGTM/exporters deliberately have no `ports:` key. All host access
to them — HTTP(S), Postgres, and AMQP — goes through NGINX:

- Port 80/443 → NGINX's `http{}` block (`nginx/conf.d/*.conf`), reverse
  proxying to `pgadmin:80`, `keycloak:8080`, `grafana:3000`, `minio:9000`
  / `minio:9001`, `rabbitmq:15672`, `openbao:8200`, `portainer:9443` (https
  upstream), and, per-app, to whatever apps register.
- Port 5432 → NGINX's `stream{}` block (`nginx/stream.d/postgres.conf`),
  a raw TCP passthrough proxy to `postgres:5432`, bound to
  `127.0.0.1:5432` at the Compose level so it never reaches the LAN.
- Port 5672 → NGINX's `stream{}` block (`nginx/stream.d/rabbitmq.conf`),
  a raw TCP passthrough proxy to `rabbitmq:5672`, bound to
  `127.0.0.1:5672` the same way.
- Port 7687 → NGINX's `stream{}` block (`nginx/stream.d/neo4j.conf`),
  a raw TCP passthrough proxy to `neo4j:7687` (Bolt), bound to
  `127.0.0.1:7687` the same way.
**`portainer` is the one deliberate exception.** It publishes 9443 (UI,
TLS), 9000 (UI, plain HTTP) and 8000 (Edge-agent tunnel) itself, from
`docker-compose.portainer.yml`, bound to `${LAN_IP}` — never `0.0.0.0`,
since that UI is root on the Docker daemon. Routing them through NGINX
(as an earlier `nginx/stream.d/portainer.conf` did) made the tool you use
to fix a broken stack depend on that stack: any `make up` recreates
`nginx`, and a failed deploy leaves it down. Don't reintroduce that
passthrough, and don't add the same ports back to `nginx` — the two would
fight over the bind. The `portainer.infra.famillelallier.net` vhost stays
as a convenience.

**Do not add a `ports:` entry to `postgres`, `pgadmin`, `keycloak`,
`minio`, `rabbitmq`, `neo4j`, `obsidian`, `airflow-*`, `openbao`, `grafana`, or other monitoring backends.** If a backend service needs to be reachable from the host, add
an NGINX server block instead (`nginx/conf.d/app.conf.example` is the
template for HTTP; extend `nginx/stream.d/` for raw TCP). This is a
deliberate constraint, not an oversight — keeping every backend-app
host-facing port behind one process is the point of this stack.

The `windows` and `macos` scrape jobs are outside this rule rather than an
exception to it: `windows_exporter` and node_exporter's darwin build are not
containers and not services this repo deploys, they run on LAN machines.
There is nothing to put behind NGINX and nothing to publish — Prometheus
reaches out to `<host>:9182` / `<host>:9100`.

`nginx` (HTTP/S + Postgres/AMQP TCP) and `dns` (LAN DNS) are peers at a
different, top tier: each is the sole host-facing process for its own
protocol, not a backend NGINX fronts. `dns` publishing `ports:` for 53
and 5380 is not a violation of the rule above and should not be "fixed" by
routing DNS through NGINX or removing its `ports:` entry — see "DNS (LAN
resolver)" below for why both of `dns`'s ports are deliberately direct.

The stock `nginx:alpine` image's shipped `nginx.conf` only includes
`conf.d/*.conf` inside `http{}`, so it can't host a stream proxy as-is.
This repo supplies its own `nginx/nginx.conf` with both an `http{}` and a
`stream{}` context — don't replace it with the image's default.

Both the HTTP and stream server blocks resolve their upstream via
`resolver 127.0.0.11` + a `set $upstream ...` variable rather than a bare
`proxy_pass http://pgadmin:80;`. NGINX refuses to start if a `proxy_pass`
hostname doesn't resolve at boot, so resolving lazily at request time means
one stopped container can't take down the whole proxy. Keep this pattern
for any new app block.

The stream block also sets `proxy_timeout 1h` explicitly — the NGINX
default is 10 minutes, which silently drops idle Postgres connections
(pooled connections, an idle `psql` session) and shows up as confusing
"connection reset" errors far from the actual cause.

### DarkAngel: NGINX serves the SPA itself

DarkAngel (github.com/nicolaslallier/DarkAngel) is the one app this NGINX
serves files for rather than proxies to. Every other app ships its own web
server and registers a `proxy_pass` upstream; DarkAngel deliberately ships
none, so `nginx/conf.d/darkangel.conf` carries a `root` and a `try_files` for
the SPA and proxies only `/api/`, to `darkangel-api:8000` on infra-net.

The files arrive through a volume, not an image. DarkAngel's stack runs a
one-shot `web-assets` container that copies its built SPA into `darkangel-web`
and exits -- `Exited (0)` is that container's healthy state -- and `nginx`
mounts the volume read-only at `/srv/darkangel`. The publisher renames a
finished directory into `current/`, so this `root` never points at a
half-written copy, and a DarkAngel redeploy needs no `make up` here: new files
simply appear under the path nginx already serves.

Three things to know before changing any of it:

- `darkangel-web` is `external: true` on both sides, exactly as `infra-net`
  is, so compose will not create it. A missing external volume fails the
  deploy of *this whole stack*, not just that one vhost -- `make app-volumes`,
  a prerequisite of `make up`, `make pull` and `make init`, is what guarantees
  it exists.
- `/api/` has no `rewrite`, unlike `ea.conf` and `jarvis.conf`: DarkAngel's
  FastAPI router is mounted at `/api` itself, so the prefix is passed through.
  Stripping it here would 404 every API call.
- The vhost is versioned in DarkAngel's repo too, as
  `deploy/nginx/darkangel.conf`. Changes here belong there as well.

### Jarvis / EA Keycloak gates

oauth2-proxy gates (Jarvis, Obsidian) and the EA token-verification realm are documented in `keycloak/CLAUDE.md`.

### Airflow: nightly PR validation

`airflow/dags/infra_pr_validation.py` is this repo's first DAG. At 03:00 it
lists the open, non-draft PRs on GitHub, and for each one clones the head,
renders a throwaway `.env` into it, runs the file-level checks, and posts (or
updates) a single comment on the PR. A failing check fails the mapped task,
so the UI shows which PR is red without opening GitHub.

Why here and not in GitHub Actions: a GitHub-hosted runner cannot reach
`infra-net`, this daemon, or anything on the LAN. The checks below do not
need any of that — but the smoke test this DAG is scaffolding for (actually
bringing the stack up and exercising it) can only ever run on this machine,
and that is what the workspace and socket plumbing is for.

Four things here are load-bearing.

- **`WORKSPACE_ROOT` is mounted at the same path inside and outside the
  container** (`/tmp/infra-ci:/tmp/infra-ci` on `airflow-scheduler`). The
  checks run as *sibling* containers, so their `-v <path>:/repo` is resolved
  by the **daemon**, against the host filesystem — not against the
  scheduler's. A clone written to an ordinary temp dir inside the scheduler
  would be invisible to them, and Docker would auto-create an empty directory
  in its place: the same trap `${INFRA_DIR:-.}` exists for (see
  "Portainer-managed stack"), with the same silent symptom. Identical paths on
  both sides is what makes the nested bind mount agree with no translation.
  The cost is that this DAG assumes Airflow and the daemon share a
  filesystem — it does not work against a remote `DOCKER_HOST`.
- **Only `airflow-scheduler` gets the Docker socket.** LocalExecutor runs
  every task inside it, so the api-server and the dag-processor have no reason
  to hold it. Understand what it buys: the socket is root on the daemon, so
  any DAG can do anything to any container on this host, and
  `airflow.infra.famillelallier.net` sits behind Airflow's own FAB login and
  nothing else — no oauth2-proxy. That is a weaker gate than Portainer's
  equivalent power has, and Portainer's is at least not proxied. If the DAG
  goes away, remove the mount with it.
- **Each check runs in the image the real service uses**, mounted the way the
  real service mounts the repo — `nginx -t` inside `nginx:alpine-otel` with
  `nginx/` and `certs/` at their deployed paths, `promtool check config` with
  `monitoring/prometheus/` at `/etc/prometheus` (it resolves the `file_sd`
  target files by their in-container absolute path, so mounting the repo at
  `/repo` would make it report them missing). A generic linter image would
  validate a configuration nothing deploys.
- **`scripts/ci-fake-env.sh` comes from the PR's own checkout**, not from
  `main`, so a PR that breaks it fails on its own change. It renders a
  throwaway `.env`, a 32-byte `openbao/seal.key` and a self-signed `certs/`
  pair into a clone that has none of them (all three are gitignored). Values
  are shaped the way `check-env.sh` demands rather than merely non-empty —
  url-safe cookie keys, a padded Fernet key, a url-safe `AIRFLOW_DB_PASSWORD`,
  `LAN_IP=127.0.0.1` — which is why running the repo's own preflight against
  it is a meaningful check and not a tautology. It refuses to overwrite an
  existing `.env` unless `CI_FAKE_ENV_FORCE=1`: in the real checkout that file
  is the deployed secret set, gitignored, with no copy to restore from.

Setup, once:

```bash
# in the airflow-scheduler container, or through the UI (Admin -> Variables)
airflow variables set infra_ci_github_token <a PAT with pull_requests:write>
airflow variables set infra_ci_repo nicolaslallier/Infra   # optional
```

The token is an Airflow Variable, not a `.env` key, for the reason
`PORTAINER_API_KEY` lives in `.portainer.env`: `.env` is handed to containers
wholesale and shipped to Portainer as the stack env, and this one can write to
GitHub. Airflow encrypts Variables with `AIRFLOW__CORE__FERNET_KEY`. The
obvious next move is `infra/apps/airflow` in OpenBao — it would be the vault's
first real consumer (see "Secrets (OpenBao)").

The DAG arrives **paused** (`AIRFLOW__CORE__DAGS_ARE_PAUSED_AT_CREATION` is
`"true"`); unpause it once in the UI. And a nightly schedule on a Mac that
sleeps does not fire — either `sudo pmset repeat wakeorpoweron MTWRFSU
02:55:00`, or move the schedule to an hour the machine is awake.

### Windows machines (`windows_exporter`)

Job `windows` in `monitoring/prometheus/prometheus.yml`, dashboard
`monitoring/grafana/provisioning/dashboards/json/windows.json`
(`uid: windows-hosts`). Four things here are deliberate:

- **`file_sd_configs`, not `static_configs`.** These are the only targets
  that aren't containers on `infra-net`, so they can't be named by service
  name and the list churns as machines come and go. `file_sd` re-reads
  `monitoring/prometheus/targets/windows.yml` every 30s, so adding a machine
  doesn't need a Prometheus restart. The file is still bind-mounted from the
  checkout (`${INFRA_DIR:-.}/monitoring/prometheus/targets`), so it must be
  committed — the drift guard refuses untracked files, and Portainer mounts
  the checkout, not Git.
- **The `hostname` → `instance` relabel.** A target may carry a `hostname`
  label; `relabel_configs` copies it over `instance` and drops it. Without
  that, every legend, `up{}` series and the dashboard's Machine picker reads
  `192.168.2.20:9182`. Set it for new machines.
- **Every memory/uptime expression is `A or B`.** windows_exporter folded
  the `cs` and `os` collectors into `memory`/`system` around v0.30 and
  renamed the metrics with them (`windows_cs_physical_memory_bytes` →
  `windows_memory_physical_total_bytes`, `windows_system_system_up_time` →
  `windows_system_boot_time_timestamp_seconds`). `or` is per-series, so a
  fleet on mixed versions charts whole. Don't "simplify" one side away until
  every machine is upgraded.
- **`(?i)` in the NIC filter, `_Total` out of the volume filter.** PromQL
  regexes are case-sensitive and fully anchored, and the adapter is spelled
  `Microsoft_ISATAP_Adapter` — a lowercase `.*isatap.*` silently matches
  nothing and the tunnel adapters show up in every network panel. Likewise
  `windows_logical_disk_*{volume="_Total"}` is the exporter's own rollup and
  would double-count in any fleet-wide `max()`.

### macOS machines (`node_exporter` on darwin)

Job `macos` in `monitoring/prometheus/prometheus.yml`, targets in
`monitoring/prometheus/targets/macos.yml`, dashboard
`monitoring/grafana/provisioning/dashboards/json/macos.json`
(`uid: macos-hosts`), GPU sampler `scripts/macos-gpu-textfile.sh` +
`scripts/install-macos-gpu-exporter.sh`. The `file_sd` + `hostname` →
`instance` relabel is the same machinery as the `windows` job above and is
load-bearing for the same reasons. What is specific to darwin:

- **`macos` and `node` are two jobs over one metric namespace.** Both emit
  `node_*`: `node` is the node-exporter *container*, which sees Docker
  Desktop's Linux VM (6 vCPU / 12 GB / 100 GB), `macos` is a node_exporter
  running on the Mac itself. Every panel in the dashboard pins
  `job="macos"`; a query that forgets it averages the VM into the hardware.
  The two never collide on the wire — the container is `node-exporter:9100`
  on `infra-net`, a Mac is `<its LAN address>:9100`.
- **Never target a Mac as `host.docker.internal:9100`.** That name means
  *the Docker host*, and the daemon this stack runs on is not necessarily a
  Mac — it has been the Windows laptop, in which case the job quietly scrapes
  whatever holds `:9100` over there (`426 Upgrade Required`) and
  `up{job="macos"}` reads 0 forever while every panel says "No data". Macs
  are LAN machines like the Windows ones: address them by IP, with a DHCP
  reservation, and not by a `.local` name (mDNS does not resolve from inside
  a Linux container).
- **darwin's network counters are not Linux's.** The netdev collector on
  darwin keys them `receive_errors` / `receive_dropped`, so the metrics are
  `node_network_receive_errors_total` and
  `node_network_receive_dropped_total` — Linux's `_errs_` and `_drop_` names
  do not exist here, and there is no transmit-dropped counter at all. The
  *Errors and drops / s* panel selects by `__name__` regex over both
  spellings, the same "chart on whichever exists" idiom the Windows
  dashboard uses for its `or`-ed expressions.
- **Memory used is `wired + active + compressed`,** over
  `node_memory_total_bytes` (darwin's meminfo collector exposes
  `hw.memsize` directly; there is no `node_memory_MemTotal_bytes` here).
  `inactive` and `purgeable` are reclaimable — counting them as used makes
  every Mac read ~95% full, which is exactly why Activity Monitor doesn't.
  The same holds on disk: `node_filesystem_purgeable_bytes` is APFS space
  Finder already reports as free but `avail_bytes` does not.
- **NIC and disk filters are include-lists, not exclude-lists.** macOS
  invents a lot of virtual interfaces (`utun*` for VPNs, `awdl0`/`llw0` for
  AirDrop, `anpi*`/`ap1` on Apple Silicon, `gif0`, `stf0`), and the set
  grows with each release, so the panels match `en[0-9]+|bridge[0-9]+` and
  `disk[0-9]+` rather than trying to enumerate the noise. PromQL regexes
  are fully anchored, so those match exactly `en0`, `bridge0`, `disk0` —
  slices like `disk0s1` are excluded on purpose, IOKit's stats are
  whole-disk.
- **`/` and `/System/Volumes/Data` are one APFS container** and report
  identical numbers; `/` is the read-only system snapshot. Both are charted
  — dropping one would be wrong on a non-APFS or pre-Catalina volume. The
  helper volumes (`Preboot`, `VM`, `Update`, `xarts`, `iSCPreboot`,
  `Hardware`) are filtered out; `/Volumes/Docker` is not, since that is the
  external disk the Docker Desktop disk image lives on (see "The disk image
  must live on the external volume" above) and its free space is worth
  watching.
- **Battery panels are empty on a desktop Mac.** `powersupplyclass` has no
  power source to enumerate there. Don't "fix" it. On a laptop,
  `node_power_supply_time_to_empty_seconds` is `-1` while charging or still
  estimating, hence the `> 0` filter on that panel.
- **The GPU row is not node_exporter's.** The darwin build has no GPU
  collector — absent, not disabled, and no flag produces one — so
  `scripts/macos-gpu-textfile.sh` reads IOKit via `ioreg` (no root, unlike
  `powermetrics`) and writes `macos_gpu_*` into node_exporter's **textfile
  collector** directory. Riding the existing `job="macos"` scrape rather than
  standing up a second exporter on a second port is what keeps the `instance`
  label, the **Mac** picker and the targets file working unchanged; a separate
  job would have needed all three duplicated. `scripts/install-macos-gpu-exporter.sh`
  installs the sampler's launchd agent **and** one for node_exporter itself,
  replacing `brew services start node_exporter`: the textfile directory is a
  command-line flag only, and `brew services` runs the binary bare and
  rewrites its plist on every restart, so an edited Homebrew plist does not
  survive. The installer stops the brew service so the two never contend for
  `:9100`; `--uninstall` reverses both halves.
- **`macos_gpu_*` are point samples, not rates.** Every other panel here
  averages a counter over the scrape window; IOKit reports an instantaneous
  gauge, so the resolution is the sampler's `SAMPLE_INTERVAL` (15s). A stopped
  sampler and an idle GPU both read as "no recent data" — the query that tells
  them apart is `time() - node_textfile_mtime_seconds{job="macos"}`.
- **Both IOKit spellings are matched, case-insensitively.** The same counter
  is `"Device Utilization %"` on some macOS/GPU combinations and
  `"device utilization"` on others, and the tiler counter does not exist at
  all outside Apple silicon. That is the same chart-on-whichever-exists idiom
  as the `or`-ed Windows expressions and the network-counter regex above —
  don't collapse it to one spelling.

### PostgreSQL 18's data directory moved

The official image (and `pgvector/pgvector:pg18`, which is based on it)
sets `PGDATA=/var/lib/postgresql/18/docker` (verified against both the
`bookworm` and `alpine` variants) and declares `VOLUME /var/lib/postgresql`
— **not** `/var/lib/postgresql/data` as in PG ≤17. `docker-compose.yml`
mounts the named volume at `/var/lib/postgresql` accordingly. Mounting the
pre-18 path here doesn't error — it just silently creates a database that
doesn't persist across restarts, since data actually lands under `PGDATA`.

### Per-app database provisioning

Each application gets its own database and a role that owns it (not a
shared database/schema). The logic lives in one place,
`postgres/initdb/10-provision-apps.sh`, and is used two ways so the two
code paths can't drift apart:

1. **First boot** — Compose's `docker-entrypoint-initdb.d` runs it with no
   args; it loops over `APP_DATABASES` (comma-separated in `.env`) and
   reads each app's password from `<APPNAME>_DB_PASSWORD`.
2. **Adding an app later** — `scripts/provision-app.sh <name>` runs the
   same script inside the already-running container via
   `docker compose exec ... 10-provision-apps.sh --single`, passing
   `APP_NAME`/`APP_PASSWORD` explicitly. This exists because
   `docker-entrypoint-initdb.d` scripts only run once, against an empty
   volume — there's no other built-in way to add a database to a live
   cluster without wiping it.

Provisioning revokes `CONNECT` from `PUBLIC` on each app's database, so
apps can't see each other's data over the shared network. It also creates
the `vector` (pgvector) extension in each app database as the superuser —
needed so apps like Jarvis can run RAG migrations without CREATE EXTENSION
privilege. After swapping an existing cluster onto the pgvector image,
re-run `make provision-app app=<name>` for each app (idempotent) so the
extension is installed into already-existing databases.

### Secrets (OpenBao)

`openbao` is the stack's secret store, at `vault.infra.famillelallier.net`
(UI + API through NGINX) and at `http://openbao:8200` for anything on
`infra-net`. Config is `openbao/config.hcl`; the scripts are
`scripts/vault-*.sh`, driven by `make vault-init` / `vault-seed` /
`vault-env` / `vault-render` / `vault-status` / `vault-cli`.

**Bootstrap order**, once per vault:

```bash
make seal-key     # only if this checkout predates OpenBao; make init does it
make up           # openbao comes up initialised=false, and that is fine
make vault-init   # initialise, write .openbao.env, mount KV v2 at infra/
make vault-seed   # copy the current .env into infra/env
```

Four things here are load-bearing.

- **Auto-unseal, via a `static` seal reading a bind-mounted key file.**
  This is not a convenience. OpenBao's default Shamir seal comes up *sealed*
  after every restart and refuses every request until an operator types
  unseal keys in — and every `make up` force-recreates every container
  (Portainer's git-redeploy always sets `forceCreate=true`; see
  "Portainer-managed stack"). A Shamir vault here would be sealed after every
  deploy of the whole stack, which is to say most of the time. The `static`
  seal encrypts the root key with the 32 bytes in `openbao/seal.key`.
  Understand the trade before defending it: **whoever holds that file and the
  `openbao-data` volume can decrypt the vault offline.** That is the
  documented use of this seal type — chaining the vault to an existing source
  of trust — and here that source is the machine's own disk. Back the key up
  somewhere the volume is not; lose it and the vault is unrecoverable, since
  no recovery key unseals an auto-sealed vault (the recovery key in
  `.openbao.env` only regenerates a *root token*).
- **The seal key is a file, not a `.env` value.** `.env` is handed to
  containers wholesale (`postgres` `env_file`s it) and shipped to Portainer as
  the stack env. A key that decrypts the secret store belongs in neither —
  the same reasoning that keeps `PORTAINER_API_KEY` in `.portainer.env`. Same
  for the root token, which `make vault-init` writes to `.openbao.env`; only
  the `vault-*` scripts read it, and they forward it to the container by name
  (`docker compose exec -e BAO_TOKEN`) so it never enters the host's process
  list.
- **`.env` does not go away, and cannot.** Compose has no way to read a
  vault: it interpolates `${FOO}` from the environment it is handed, full
  stop. So the vault is the *record* and `.env` is a rendered artifact of it.
  `make vault-seed` pushes `.env` → `infra/env` (one KV field per variable,
  named exactly as the variable is); `make vault-env` renders it back, using
  **`.env.example` as the template** so the regenerated file keeps every
  explanatory comment and, by construction, passes the one thing `check-env`
  diffs — that every key `.env.example` assigns is present. A key the vault
  lacks keeps `.env.example`'s value and is reported rather than silently
  blanked; keys the vault has and the template lacks (a hand-added
  `<APP>_DB_PASSWORD`) are appended. The old `.env` is kept as `.env.bak`,
  which is gitignored **because it has to be** — an untracked file in the
  checkout trips the Portainer drift guard and blocks the next `make up`.
  The flat 1:1 mapping is deliberate: it is what makes the round trip
  lossless and leaves nothing that can drift. What keeps it from drifting in
  practice is that `make up` renders the file itself — see "Rendering `.env`
  at deploy time" below. Per-app secrets with a policy
  and a token each belong at `infra/apps/<name>`, *beside* `infra/env` and
  read by the app itself at runtime — they cannot replace it.
- **The audit device is declared in `config.hcl`, not enabled over the API.**
  OpenBao refuses API-created audit devices unless
  `unsafe_allow_api_audit_creation` is on, and reasonably so: a device the
  API can create, the API can also remove. Declared devices are applied when
  the active node starts and on `SIGHUP`, and a vault becomes active during
  `sys/init` — i.e. after it has already read its config — so
  `vault-init.sh` HUPs the container once and then checks `bao audit list`
  rather than assuming. It writes to **stdout**, so Alloy collects the audit
  trail into Loki with every other container log and it needs no volume.
  Values are HMAC'd before they are written: this records who asked for what,
  never the secrets.

#### Rendering `.env` at deploy time

`make up` and `make pull` run `vault-render` (`make vault-render` on its own
does the same thing) **before** `check-env`, and `check-env` before the
deploy. The deployer authenticates against the vault with the token in
`.openbao.env`, pulls `infra/env`, writes `.env`, and only then hands it to
Portainer. Nothing inside any container knows the vault exists: the secrets
still arrive as the same flat Compose env they always did, rendered a moment
earlier from the record instead of edited by hand months ago. A `.env` that
has quietly drifted from the vault cannot be deployed by accident any more,
and `make vault-env && make check-env && make up` is now just `make up`.

Ordering is load-bearing and the reason the Makefile declares
`.NOTPARALLEL:`: `vault-render` writes the file `check-env` then reads, and
make only guarantees prerequisites are made left to right in a serial build.

**It skips rather than blocks when there is no vault to read**, because the
vault is a service of the very stack being deployed and so cannot be a
precondition for deploying it. No `.openbao.env` (the vault has never been
initialised) or no running `openbao` container (the stack is down — which is
exactly when `make up` is most needed) both deploy the `.env` already in the
checkout, saying so on stderr; `check-env` still has to accept it. That is
what keeps the bootstrap order above working: the first `make up` happens
before there is anything to render from.

A vault that *is* up but refuses to be read — sealed, or an expired
`BAO_TOKEN` — is an **error**, not a skip. Silently deploying last week's
secrets is the failure this whole arrangement exists to prevent, so
`vault-env.sh`'s exit status is passed straight through and the deploy never
starts.

`VAULT_RENDER=0 make up` turns the render off entirely, for an environment
that has no vault at all (CI, the cloud VM in `AGENTS.md`).

The running container is found by its compose label
(`docker ps --filter label=com.docker.compose.service=openbao`) rather than
with `docker compose ps`, which would have to interpolate
`docker-compose.yml` first and so would die on the very `${VAR:?}` guards a
stale `.env` is there to fix.

Not done here, and worth knowing before assuming otherwise: the vault's only
login is the root token in `.openbao.env`. There is no Keycloak OIDC auth
method, no per-app policy, and no app in this stack or any sibling repo reads
its secrets from the vault yet — they all still get them from `.env` via
Compose. Prometheus does scrape it (job `openbao`, unauthenticated because
the listener sets `unauthenticated_metrics_access`, the same posture as
MinIO's public metrics), but there is no Grafana dashboard for it.

`vault.infra.famillelallier.net` needs no cert or DNS work: it rides the
`*.infra.famillelallier.net` wildcard in both `gen-certs.sh` and the
`infra.famillelallier.net` zone, which is exactly what that wildcard is for.

### Certificates

`scripts/gen-certs.sh` prefers `mkcert` and falls back to `openssl`
(mkcert isn't installed on the dev machine this was built on; openssl is).
Either path produces a wildcard cert for `*.infra.famillelallier.net` plus
`localhost`/`127.0.0.1`, so adding a new app subdomain never requires
regenerating certs. Trusting the local CA in the system keychain is a
`sudo`-gated step the script prints but does not run — that's for the
human running it, not automated here.

Hostnames outside `.infra.` (the exceptions listed under "Architecture")
are extra SANs in `EXTRA_SANS` (`gen-certs.sh`), and each also needs an
apex zone in `dns-provision.sh`. Regenerating certs (`./scripts/gen-certs.sh --force`) re-issues the leaf
and **keeps the local CA** when `certs/infra-ca.key` and `infra-ca.crt`
exist, so adding a SAN needs no re-trust on any device. To mint a new CA,
delete `certs/infra-ca.*` first — then re-run the `sudo security
add-trusted-cert` step it prints for every browser/keychain that had the
old one trusted, since the old CA's trust doesn't carry over. (The mkcert
path always signs with mkcert's own CA.)

### DNS (LAN resolver)

`dns` runs Technitium's official `technitium/dns-server` image. Its
environment variables (`DNS_SERVER_DOMAIN`, `DNS_SERVER_ADMIN_PASSWORD`,
`DNS_SERVER_FORWARDERS`, `DNS_SERVER_RECURSION`, ...) are only read on
first boot, when `/etc/dns` (the `dns-config` volume) is still empty — they
bootstrap server-level settings, not zone data.

Under Docker Desktop every query reaches the container from the port
forwarder's gateway address rather than from the device that asked, so
Technitium's per-client views (ACLs, stats, query logs) all collapse onto
that one address — see "`LAN_IP` is the Mac's address now" in
`scripts/CLAUDE.md`.

`DNS_SERVER_RECURSION` is set explicitly to `AllowOnlyForPrivateNetworks`
rather than left at its default. This is what makes "forward everything
else upstream" actually work *for other LAN devices* — Technitium's
fallback recursion policy denies recursion for networks that don't match
any configured ACL, which would silently break resolution for every LAN
client (phones, laptops) the moment they queried a non-local name, while
still appearing to work fine from the Docker host itself.

`LAN_IP` is never used to configure a listen/bind address *inside* the
container — Technitium's web/DNS services stay on their default
all-interfaces bind. Docker's `ports: ["${LAN_IP}:...", ...]` mapping is
what restricts host-side exposure to `LAN_IP`, the same pattern
`postgres`'s `127.0.0.1:5432` already uses. Setting an in-container
bind address to `LAN_IP` would fail — the container only has Docker's
bridge IP on its own interfaces, never the host's LAN IP.

Zone/record data (which hostnames resolve to `LAN_IP`) is managed through
Technitium's HTTP API by `scripts/dns-provision.sh`, not through env vars
or a mounted config file — safe to re-run any time zones/records need to
be recreated (e.g. after a `dns-config` volume wipe). It creates scoped
zones, **never** a `Primary` zone for `famillelallier.net` itself — an
`infra.famillelallier.net` apex + wildcard (covers every `.infra.` app, no
per-app DNS config), plus one apex zone per non-`.infra.` hostname. The
list lives in `scripts/dns-provision.sh`.

DNS zone authority is absolute — owning a `Primary` zone for the whole
`famillelallier.net` parent would make Technitium authoritative for every
name under it, including `beacon.famillelallier.net` /
`dev.famillelallier.net`, which exist outside this repo and must keep
resolving wherever they already do. **Never collapse the scoped zones
above into one wildcard covering all of `famillelallier.net`.**

The Technitium web console (port 5380) is published directly rather than
fronted through NGINX like pgAdmin. This is deliberate: fronting it
through NGINX would need a hostname (e.g. `dns.famillelallier.net`) to
already resolve, but that can only happen *after* this DNS server exists
and is provisioned — a bootstrap chicken-and-egg problem. `dns-provision.sh`
drives the API directly by IP, so this is a one-time cost paid by the repo,
not by whoever runs `make up`.
