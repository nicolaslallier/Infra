# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`Infra` is the shared "common group" backing stack for sibling application
repos (`Jarvis` and others): NGINX, PostgreSQL 18, pgAdmin, Keycloak,
SeaweedFS (S3), RabbitMQ, OpenBao, Portainer, a Technitium DNS server, and an LGTM
monitoring stack (Grafana, Prometheus, Loki, Tempo, Alloy + exporters), run via
Docker Compose.
Application repos are meant to stay in their own repositories and connect in
over a shared Docker network rather than being folded into this one.

## Commands

Run `make help` for the target list. Notable: `make up`/`down` deploy via Portainer, `make init` bootstraps `.env`/certs/`infra-net`/OpenBao's seal key, `make vault-*` drive the secrets vault, `make runners-*` the five CI runners, `make dev-*` the dev-session plumbing (see "Dev sessions"), `make clean CONFIRM=1` deletes the stack + volumes.

The `vault-*` targets deliberately do **not** run `check-env`: `make vault-env`
is how a `.env` that `check-env` rejects gets repaired, so requiring it first
would deadlock.

`up`, `pull`, `config`, `provision-app`, `dns-provision`, `dns-check`,
`keycloak-seed-users` and `s3-provision` run `check-env`
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

There is no build or lint step — this repo is Compose config, NGINX
config, and shell scripts, not an application. `make test`
(`scripts/test.sh`) runs everything that can be checked without
deploying: the flows' plain-assert tests; the `pr-validation` flow's checks,
through `_run_all()` in `pr_validation.py` — the same function the nightly
`run_checks` calls, so keep any new check in there; and cases asserting
`check-env.sh` *rejects* broken `.env` files (after first asserting the
unmutated one passes). It works on a throwaway copy of exactly the files git
lists (`tar --no-recursion`, so a nested worktree's real `.env` never comes
along) under `~/.cache/infra-test`, with a `ci-fake-env.sh` `.env`. It pins
`DOCKER_HOST` to the *local* daemon and drops `DOCKER_CONTEXT`, because only
the local daemon can bind-mount that copy — so Docker Desktop must be running
on the machine `make test` runs on. The `prefect` and `fastapi` versions it
tests against are read from the pinned `prefecthq/prefect` image (tag, and
`pip show` cached per image digest), so a Renovate bump moves them too; a
floating fastapi breaks prefect's import. Beyond
that, validate changes by actually running the stack (`make up`) and
exercising it, per the checks below.

## Architecture

Every image is pinned `tag@sha256` (the index digest). Renovate (`renovate.json`) proposes bumps on
Saturdays before 6am, never automerges, blocks majors for pgvector/openbao/seaweedfs, and
ignores the runner image and `infra-ollama-proxy`; merging a Renovate PR redeploys the whole stack.

Services on one external Docker network (`infra-net`, created by
`make net` / `make init`, not by Compose itself — `external: true` in
`docker-compose.yml` so the network outlives `docker compose down` and
never orphans another app that's still attached to it):

- **`postgres`** (own stack, `docker-compose.postgres.yml`, with `pgadmin` and
  `postgres-exporter`) — `pgvector/pgvector:0.8.6-pg18-bookworm` (Postgres 18 + pgvector;
  Debian bookworm — no alpine tag for pg18). Publishes no host port.
  Per-app provisioning also runs `CREATE EXTENSION IF NOT EXISTS vector`
  as the superuser in each app database, so app roles (e.g. Jarvis RAG
  migrations) can use the `vector` type without needing CREATE EXTENSION
  privilege themselves. Logs connections/disconnections (`command:` flags).
- **`pgadmin`** — `dpage/pgadmin4:9`. Publishes no host port.
- **`keycloak`** — `quay.io/keycloak/keycloak`. Publishes no host port;
  uses the shared `postgres` cluster (database/role `keycloak`, via the
  same generic per-app provisioning as any other app — see "Per-app
  database provisioning" below), not a bundled DB of its own. Metrics
  enabled on the management interface (`:9000/metrics`).
- **`s3`** — `chrislusf/seaweedfs:4.47`, pinned by tag *and* digest (a
  store-format change must not ride along with a redeploy). One `weed server -s3` container; publishes no host
  port. S3 (and STS) on `:8333`, fronted by NGINX at
  `s3.infra.famillelallier.net`; apps on `infra-net` use `http://s3:8333`.
  Auth is on from first boot via the `S3_ADMIN_*` env identity — SeaweedFS
  serves **anonymously** when no identity exists, so never remove it.
  Per-app bucket-scoped identities come from `make s3-provision
  app=<name> [bucket=] [versioned=1]` (`scripts/provision-s3.sh`); the IAM
  config (Keycloak OIDC provider, STS roles) is the `seaweedfs-iam` config
  inlined in `docker-compose.data.yml`,
  rendered into the container's `/tmp` at start. The filer (`:8888`) and
  master (`:9333`) UIs are unauthenticated and must never get a host path.
  Metrics on `:9324`. Break glass: `docker compose exec s3 weed shell
  -master=s3:9333`.
- **`s3-admin`** — `weed admin` (same image), at
  `s3-admin.infra.famillelallier.net`. It has no login of its own (OSS
  SeaweedFS's OIDC is Enterprise-only) and runs `-allowInsecureBind` on
  `infra-net`; `nginx/conf.d/s3-admin.conf` gates it through a **third**
  oauth2-proxy, `oauth2-proxy-infra` (realm `infra`, client `s3-admin`,
  `OAUTH2_PROXY_ALLOWED_GROUPS: s3-admin`). Only `s3-admin` members get in,
  as full admins; there is no read-only UI role.
- **`rabbitmq`** — `rabbitmq:4.3.5-management`. Publishes no host port. AMQP
  on `:5672` (NGINX stream passthrough at `127.0.0.1:5672`; apps on
  `infra-net` use `rabbitmq:5672` directly) and management UI on `:15672`
  (`rabbitmq.infra.famillelallier.net`). Prometheus metrics on `:15692`.
  `hostname: rabbitmq` is load-bearing: the database is keyed by node name
  (`rabbit@<hostname>`), and an unpinned hostname changes on every deploy,
  which silently resets every provisioned vhost and user.
  Per-app accounts: `make rabbitmq-provision app=<name>`
  (`scripts/provision-rabbitmq.sh`) makes vhost + user `<name>` (no tags,
  permissions on that vhost only) from `<APP>_AMQP_PASSWORD` (alphanumeric:
  it goes in an amqp:// URL; `check-env` enforces it for
  `MORIA_AMQP_PASSWORD`). Idempotent; re-run to rotate the password.
  A wiped/fresh `rabbitmq-data` volume loses these accounts (only
  `RABBITMQ_DEFAULT_*` is recreated): re-run `make rabbitmq-provision
  app=moria`. `make up`/`pull`/`config` fail until `MORIA_AMQP_PASSWORD` is
  in the vault (patch it, `make vault-env`, `make up`); the Moria stack's
  Portainer `MORIA_AMQP_PASSWORD` must equal it, set before deploying Moria.
- **`ntfy`** — `binwiederhier/ntfy`, pinned by tag *and* digest.
  Push notifications, at `ntfy.infra.famillelallier.net` (NGINX → `ntfy:80`);
  apps use `http://ntfy`. Publishes no host port. Its config (`ntfy-server`, inlined in `docker-compose.data.yml`) sets
  `auth-default-access: deny-all`: never loosen it, the API is reachable
  from every container on `infra-net`. `make ntfy-provision app=<name>
  [topic=<prefix>]` (`scripts/provision-ntfy.sh`) creates a user with
  write-only access to `<prefix>-*` and prints a token; **every run mints a
  new token**, older ones stay valid until `ntfy token remove`. The vhost is
  deliberately **not** behind oauth2-proxy: phones and apps use tokens/Basic
  auth, which an SSO redirect would break. It does not include
  `snippets/proxy.conf`: that snippet appends to a client-sent
  `X-Forwarded-For`, which ntfy rate-limits on, so the vhost overwrites it
  with `$remote_addr` and adds a `limit_req`. Long-lived streams, hence
  `proxy_read_timeout 12h` and `proxy_buffering off`. Users, ACLs, tokens and
  the message cache live in the `ntfy-data` volume. `upstream-base-url`
  is `https://ntfy.sh` (iOS push is delayed without it; only a topic hash, never
  content, goes to ntfy.sh). Prometheus job `ntfy` scrapes the separate metrics listener
  `ntfy:9090` (on `:80` `/metrics` needs credentials under deny-all); the
  vhost 404s `/metrics`.
  There is no `NTFY_*` key in `.env`; the `NTFY_*` application
  variables are documented in the README ("Notifications").
- **`litellm`** — `ghcr.io/berriai/litellm-database`, the LLM gateway, at
  `litellm.infra.famillelallier.net` (NGINX → `litellm:4000`; admin UI at
  `/ui`). OpenAI- and Anthropic-format API in front of exo on the Macs
  (`EXO_API_BASE`, by LAN address) and `ollama-proxy`. Config is
  `litellm/config.yaml`; secrets (`LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`,
  `LITELLM_UI_PASSWORD`) come from `.env`. Database/role `litellm`, provisioned
  like any other app; without it the UI login fails with "Not connected to DB".
  Publishes no host port. Not behind oauth2-proxy: API clients use bearer
  keys. Never rotate `LITELLM_SALT_KEY` once models are stored in the DB.
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
- **`portainer`** — `portainer/portainer-ce:2.45.0` (pinned by digest; move to the next LTS
  by hand, forward only), the Docker management
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
- **`nginx`** — `nginx:1.31.5-alpine-otel`. Fronts every backend application service —
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
- **`prefect-*`** — `prefecthq/prefect:3.8.7-python3.12`, at
  `prefect.infra.famillelallier.net` (NGINX → `prefect-server:4200`, gated
  by a **fourth** oauth2-proxy, `oauth2-proxy-prefect`: realm `infra`, client
  and group `prefect`). Publishes no host port. Two containers:
  `prefect-server` (API + UI; metadata in the provisioned Postgres
  database/role `prefect` — on an existing cluster run
  `make provision-app app=prefect` before the first deploy) and
  `prefect-flows`, which runs `prefect/flows/serve.py`: `serve()` registers
  every deployment with its schedule and executes runs as subprocesses, so
  there is no work pool, no worker and no deploy step. Flows are
  bind-mounted read-only from `prefect/flows/` and must be committed (the
  drift guard refuses untracked files); a changed flow takes effect on the
  next `make up`, which recreates `prefect-flows` anyway. `prefect-flows`
  alone carries the Docker socket and the `/tmp/infra-ci` workspace — see
  "Prefect: pipelines" below for what they are for, and why
  `PREFECT_AUTH_STRING` is not optional.
- **`ollama-proxy`** — the only way this stack reaches Ollama, which runs
  on a Mac outside it (`OLLAMA_UPSTREAM_URL`, default
  `http://192.168.2.35:11434`). Ollama has no `/metrics` (upstream PRs
  #16998/#18508 still open), so every client on `infra-net` — LibreChat,
  `prefect-flows` — calls `http://ollama-proxy:11434` instead, and the proxy
  counts tokens, latency and loaded models per model (job `ollama`,
  dashboard `ollama.json`, `uid: ollama`). Traffic that goes to Ollama
  directly is simply not counted. Ollama runs on three machines, and a
  proxy watches exactly one, so there are three: on the two Macs,
  mac-infra (`.35`) and mac-02 (`.41`), ollama-metrics runs on the Mac
  itself (below); the laptop (`.10`) has the `ollama-proxy-laptop`
  container, which shares `ollama-proxy`'s definition by YAML anchor. Their scrape targets
  carry a `host` label spelled like that machine's `instance` in the
  `macos`/`windows` jobs, which is what lets the dashboard's one **Host**
  picker filter the Ollama panels and the machine/GPU panels together.
  Loaded models and their memory are polled, so they show for all three;
  tokens and latency only for requests sent through that host's proxy.
  The Macs are the exception: their clients (Claude Code on mac-02, `ollama
  run` on the Mac itself) call `<mac>:11434` directly, so
  `scripts/install-macos-ollama-proxy.sh` runs ollama-metrics *on each
  Mac*, on `:11434`, with Ollama moved to `127.0.0.1:11435` and the app's
  "Expose to network" setting off. Prometheus scrapes `<mac>:11434` for
  `host=mac-infra` / `host=mac-02`, and on mac-infra
  the `ollama-proxy` container becomes an unscraped relay to it (scraping
  both would count container traffic twice). LAN machines that are not containers
  (Claude Code on another Mac) use `https://ollama.infra.famillelallier.net`
  (`nginx/conf.d/ollama.conf`, ungated like Ollama's own `:11434`). It is
  `nicolaslallier/ollama-metrics`, our fork of `datahub-local/ollama-metrics`
  (itself a fork of `NorskHelsenett/ollama-metrics`, which counts only
  `/api/*`): datahub-local added `/v1/chat/completions`, LibreChat's dialect,
  and ours adds `/v1/messages`, the Anthropic dialect Claude Code speaks.
  Changes to the proxy go there, as a PR, then a repin here. It publishes no image and Portainer's Git stacks do not build
  reliably, so `make app-images` builds it from a pinned commit on the
  daemon before `up`/`pull`, and compose has `pull_policy: never`: bump
  `OLLAMA_PROXY_REF` in the Makefile and the tag in `docker-compose.yml`
  together. Its two response rewrites (UTF-8 repair, reasoning→content) are
  switched off so clients see exactly what Ollama sent. Its `time_per_token`
  buckets start at 0.01 s, above what the Mac decodes at, which is why the
  dashboard charts averages (`rate(_sum)/rate(_count)`) and not quantiles.
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
  Retention is bounded: Loki 31d (compactor), Prometheus 90d or 20GB.
  Alert rules are provisioned from `monitoring/grafana/provisioning/alerting/`
  (folder `Infra`, group `infra`, 60s): add a rule to `rules.yml`. The single
  contact point `ntfy` posts to topic `alerts-infra` using `GRAFANA_NTFY_TOKEN`
  (`make ntfy-provision app=grafana topic=alerts`; `check-env` only warns when
  empty). Provisioned rules are read-only in the UI.
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
(`grafana.infra.famillelallier.net`), SeaweedFS
(`s3.infra.famillelallier.net`, admin UI `s3-admin.infra.famillelallier.net`),
RabbitMQ management (`rabbitmq.infra.famillelallier.net`),
the Jarvis frontend (`jarvis.famillelallier.net`, also reachable at
`jarvis.infra.famillelallier.net`), and LibreChat (`chat.famillelallier.net`,
admin panel at `chat-admin.infra.famillelallier.net`) do. LibreChat is a
Portainer stack of its own (compose in `~/OpenCode/LibreChat`), not a service
of this repo: its `api` and `admin-panel` join `infra-net` under the aliases
`librechat` / `librechat-admin` (`nginx/conf.d/librechat.conf`), and nothing
else of it publishes a port. Heaven, the backup appliance
(`heaven.infra.famillelallier.net`), is another such outside stack
(github.com/nicolaslallier/Heaven): its `heaven-web` container serves the
interface and relays `/api/` to `heaven:8000` on its own, so
`nginx/conf.d/heaven.conf` is a plain pass-through to one upstream.
Moria, the game server (github.com/nicolaslallier/Moria), joins `infra-net`:
`server` under the alias `moria-server`, plus `dwarf-ai` and `inventory`, which
talk over RabbitMQ (vhost/user `moria`). Its Internet-facing `:7777` goes
through NGINX's `stream{}` block (`nginx/stream.d/moria.conf`, `limit_conn` 4
per IP). Prometheus scrapes `moria-server:9464` (job `moria`) and the `moria`
vhost's per-queue depth and consumers from RabbitMQ's `/metrics/detailed`
(job `rabbitmq-moria`); dashboard `moria.json` (`uid: moria-overview`).
When registering the Postgres server inside pgAdmin's own UI, the host is
the Compose service name `postgres` (pgAdmin and `postgres` share
`infra-net` directly), port `5432` — never a
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

Docker Desktop on the deploy host, the Windows laptop (12 CPU / ~7.7 GiB VM; the old Mac setup was 6 CPU / 12 GB / 100 GB, disk image on `/Volumes/Docker`). `keycloak`, `litellm`, `prometheus` and `loki` carry `mem_limit:` ceilings sized ~1.5× each service's measured 14-day peak, deliberately not budgeted to sum under the VM; the Grafana rule `Container OOM-killed` fires if one is hit. Details — `check-docker.sh` exit codes, `LAN_IP` semantics, Colima migration — live in `scripts/CLAUDE.md`.

### Portainer-managed stack

The `infra` stack is a **Portainer CE Git stack**: Portainer clones
`https://github.com/nicolaslallier/Infra` at `main` and runs
`docker-compose.yml` itself. `make up` / `down` / `pull` / `clean` call
Portainer's API through `scripts/portainer-stack.sh`; nobody runs
`docker compose up` for this stack any more. GitOps polling is off on
purpose.

`stacks.conf` lists the stacks the script deploys, in order (one row per
stack: name, compose file, Portainer environment, owned paths): `dns`
(`docker-compose.dns.yml`: Technitium, so a merge no longer cuts the LAN's
DNS), `openbao` (`docker-compose.openbao.yml`: the vault every `make up`
reads first), `postgres` (`docker-compose.postgres.yml`: postgres, pgadmin,
postgres-exporter), `data` (`docker-compose.data.yml`: s3, s3-admin,
rabbitmq, ntfy, on the Mac mini, environment 7: it publishes S3 :8333, AMQP
:5672, the RabbitMQ UI :15672, ntfy :8090 and the metrics ports on
192.168.2.67, never s3-admin, the filer or the master; its config files are
inlined as compose `configs:`; on this host nginx carries the aliases `s3`,
`rabbitmq` and `ntfy` on infra-net and relays them, so apps keep their
URLs; the provisioning scripts run with `DOCKER_HOST` on the mini's daemon), `monitoring` (`docker-compose.monitoring.yml`: the LGTM
stack, cadvisor, node-exporter), `keycloak` (`docker-compose.keycloak.yml`:
Keycloak alone, on the Mac mini, environment 7: nginx relays
keycloak.famillelallier.net to 192.168.2.67:8080, Prometheus scrapes :9000,
and it reaches Postgres through nginx on `LAN_IP:5432`), `auth`
(`docker-compose.auth.yml`: the oauth2-proxies, also on the Mac mini; nginx
auth_requests them on 192.168.2.67:4180-4182), `platform` (`docker-compose.platform.yml`:
litellm, the ollama-proxies, prefect) and `infra` (`docker-compose.yml`:
nginx and nginx-exporter, deployed before auth so the
keycloak.famillelallier.net alias the oauth2-proxies use is up). More stacks follow, each
meant to be able to run on another Portainer-managed machine.
`make up` / `pull` / `down` walk the list top to bottom, deploying a stack and
waiting for it to be healthy (`WAIT_PROJECT=<stack>` for `wait-healthy.sh`)
before the next; `stack=<name>` restricts them to one. A stack on another
machine names its Portainer environment id instead of `-`; it must not
bind-mount anything from the checkout (no `INFRA_DIR`: only the local
host's checkout is synced), and its health gate is skipped (wait-healthy.sh
only sees the local daemon).

- **CI redeploys only what a push touched.** `ci-deploy.sh up` sets
  `ONLY_IF_CHANGED=1`: a stack is skipped when nothing in its paths column
  changed between the commit Portainer last deployed it at
  (`GitConfig.ConfigHash`) and HEAD; `*` means everything the other stacks
  don't claim. A vault-only change (no commit) therefore redeploys nothing:
  run `make up stack=<name>`. `make up` by hand still deploys every stack.
- **No `depends_on` across stacks.** The deploy order and each stack's health
  gate replace it; services still find each other by name on `infra-net`.
- **Taking a service over.** The first deploy of a stack stops (`-t 120`)
  and removes any `infra` container of the same service names before
  creating it (`take_over_services`): Portainer never removes containers a
  redeploy no longer defines, and two postgres on one data volume corrupt it.
- **Volumes keep their `infra_` names.** A split-out stack declares them
  `external: true, name: infra_<volume>`, so it reuses the data without a
  copy, a missing volume fails the deploy instead of starting empty, and
  `make clean` (infra only) no longer deletes them.

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
- **`up`/`pull` end with a health gate (`scripts/wait-healthy.sh`).**
  Portainer's API returns before containers are recreated, and a compose run
  that aborts half way (a dependency going unhealthy, e.g. keycloak) leaves
  the rest — `nginx` included — in `Created` while the deploy reports
  success. So the Makefile records the infra container IDs just before the
  call (`BEFORE_IDS`) and the gate then polls (read-only: `docker ps -a` /
  `inspect` on the `com.docker.compose.project=infra` label, never starts
  anything) until no listed container still has a pre-deploy ID, none is
  `created`/`restarting`/`exited`, and none is health `starting`/`unhealthy`;
  timeout 600s, exit 1 with each offender, its last health log line and a
  `docker start <names>` hint. It is ID-based because "everything is healthy"
  is also true of the old stack before Portainer has touched it.
  `WAIT_HEALTHY=0 make up` skips it; `WAIT_HEALTHY_TIMEOUT=<seconds>`
  changes the 600s. A one-shot/init service added to the infra project would
  sit in `exited` and fail every deploy unless the gate is taught to skip it.
  Services with a `healthcheck:` are
  nginx, grafana, prometheus, loki, litellm, prefect-server (`/api/health`
  is exempt from the auth string), dns, plus the older ones; the
  oauth2-proxies have none (their image has no shell or probe binary).
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
`scripts/ci-deploy.sh` on the self-hosted runner labelled `infra` — one of
five (`darkangel`, `ea`, `heaven`, `infra`, `moria`, one per repo) in
`docker-compose.runners.yml`, `make runners-up`. `workflow_dispatch` runs the
same thing by hand, with a `pull_images` input that switches `make up` for
`make pull`.

**A GitHub-hosted runner cannot deploy this stack**, which is the constraint
the whole design follows from. Portainer publishes its API on
`${LAN_IP}:9443` and is otherwise only on `infra-net`, and there is no public
ingress to either — the same reason `prefect/flows/pr_validation.py` exists rather than a
GitHub Actions job. The runner has to be on this LAN.

Several things here are load-bearing.

- **The runners are their own Portainer stack (`runners`)**, like Portainer
  itself and for the same reason: every `make up` force-recreates every
  container in `infra`, and a runner recreated mid-job is a job that never
  reports. `make runners-up` drives it through `scripts/runners-stack.sh`
  (needs `PORTAINER_API_KEY` and `PORTAINER_PINNEDPUBKEY` in `.portainer.env`;
  `INFRA_HOST` comes from the Makefile, `PORTAINER_URL` optionally overrides). **Portainer reads the compose from
  GitHub main**, so merge before `make runners-up`. The env it sends is
  `.runner.env` (five PATs) plus `INFRA_DIR`, never `.env`: that file is the
  stack's whole secret set.
- **One fine-grained PAT per repo** (`GH_RUNNER_TOKEN_<NAME>`, Administration:
  read and write on that repo only). This limits the damage only as long as no
  socket-holding runner is compromised: any job on `darkangel`, `heaven` or
  `infra` holds `/var/run/docker.sock`, so it can `docker inspect`/`exec` into
  the other runners and read all five tokens (admin on all five repos, on top
  of root on the daemon) and tamper with the `ea` and `moria` runners. That is
  the accepted ceiling. Follow-ups: darkangel could use its own
  `PORTAINER_DIRECT` mode and drop the socket; heaven's `scripts/ci-deploy.sh`
  uses `docker run`, so it needs a rewrite or keeps the socket.
  A missing one fails `runners-up` by name rather than starting four of five.
- **Privileges differ per runner.** The Docker socket (root on the daemon) is
  mounted only on `darkangel`, `heaven` and `infra`, whose deploys need it;
  `ea` and `moria` get none (`ea` keeps its CA mount and `extra_hosts`).
  A runner is scoped to one repo, so a workflow elsewhere cannot use it.
- **Self-hosted labels are never for PRs.** No workflow running on one of the
  five labels may trigger on `pull_request`/`pull_request_target`; PR checks
  (`test.yml`) run GitHub-hosted. `main` in each repo is meant to be guarded
  by a PR-required ruleset (`main-protection`, no bypass actors), applied
  repo by repo with the owner's go-ahead, Infra last: apply infra only after
  `test` has run green on a real PR (`github-harden.sh --apply` refuses while a
  required check has no successful run on the default branch). Escape hatch if
  `test` goes red and blocks every Infra PR: repo Settings → Rules → Rulesets →
  disable `main-protection`.
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

The `runners-*` targets are the whole management surface, and two behaviours
are load-bearing. **`runners-status` reports both sides, per repo** — the
container on the Docker host (`DOCKER_HOST`) *and* `GET /repos/<repo>/actions/runners` — because
the runners are `EPHEMERAL` and the two routinely disagree: they de-register
after every job, so a healthy container is no evidence GitHub has a runner for
the next deploy, and a job matching no labels queues silently instead of
failing. It separates a PAT GitHub refuses (named, per repo: the 401 loop in
`make runners-logs`) from a GitHub it cannot reach (a warning). The fix for a
bad PAT is `make runners-env FORCE=1 && make runners-up`; `gen-runner-env.sh`
validates all five when it writes them, but PATs expire afterwards.
**`runners-up`, `-down`, `-pull` and `-restart` are stack redeploys** that
recreate all five runners, and refuse while *any* runner has a job (exit 3;
`FORCE=1` overrides): recreating mid-job kills it and the run never reports.
`runners-restart` is `runners-up`. `runners-pull` re-pulls the image, whose
tag moves on purpose (GitHub retires old runner versions server-side). Only
`runners-logs` is not a Portainer call: compose against the Docker host
(`DOCKER_HOST`; from the Mac that is the deploy host over ssh, not a local
daemon), as is the container half of `runners-status`.

`INFRA_CHECKOUT` and `INFRA_HOST` come from repository variables
(Settings → Secrets and variables → Actions → Variables) and fall back to the
two values the Makefile already hard-codes for the Mac. The five PATs live in
`.runner.env`, gitignored, for the reason `PORTAINER_API_KEY` lives in
`.portainer.env`. `make runners-env` (`scripts/gen-runner-env.sh`) writes that
file after asking GitHub for each repo's `/actions/runners` with its token,
and refuses any that gets a 401/403/404, naming the repo: a wrongly scoped
token otherwise registers nothing while `make runners-up` reports success.
The file is written where `make` runs, not on the Docker host.

Docs-only pushes do not deploy (`paths-ignore` covers `**/*.md`, `docs/**`
and `.github/**`): a deploy force-recreates `dns` among everything else, so
it costs a brief LAN DNS outage, and a change that cannot reach a container
is not worth one. Deploys are serialised by a `concurrency` group and never
cancelled in flight, since a cancelled job leaves Portainer mid-redeploy.

**The security note, which is the part to read before changing any of this.**
This repo is public and the `darkangel`, `heaven` and `infra` runners hold `/var/run/docker.sock` — root on the
Docker daemon, the same power Portainer's UI has. Two consequences:

- **Never add a `pull_request` or `pull_request_target` trigger to a workflow
  that runs on a self-hosted label (`darkangel`, `ea`, `heaven`, `infra`, `moria`).** A fork's PR brings its own workflow file,
  so that combination is arbitrary code execution as root on the deploy host.
  The deploy workflow triggers on `push` to main and `workflow_dispatch`
  only. Set Settings → Actions → General → "Fork pull request workflows from
  outside collaborators" to **Require approval for all outside
  collaborators**; the default only gates first-time contributors.
- **Merging to main is now enough to run code on the host.** That was already
  true for whoever ran `make up`; it is now true for whoever can push to
  main. What keeps those two sets the same size is the `main-protection`
  ruleset (PR required, no bypass) — only where it has actually been applied;
  until then nothing but the owner's discipline does.

### Single-ingress rule

This rule governs *backend application services* — anything NGINX fronts
(`postgres`, `pgadmin`, `keycloak`, `s3`, `s3-admin`, `rabbitmq`, `openbao`,
`portainer`, `grafana`, monitoring backends, and future apps) — not top-level infra
processes that own a protocol NGINX can't meaningfully front. `postgres`,
`pgadmin`, `keycloak`, `s3`, `s3-admin`, `rabbitmq`, `ntfy`, `grafana`, and the
rest of LGTM/exporters deliberately have no `ports:` key. All host access
to them — HTTP(S), Postgres, and AMQP — goes through NGINX:

- Port 80/443 → NGINX's `http{}` block (`nginx/conf.d/*.conf`), reverse
  proxying to `pgadmin:80`, `keycloak:8080`, `grafana:3000`, `s3:8333`,
  `s3-admin:23646` (behind `oauth2-proxy-infra`), `prefect-server:4200` (behind `oauth2-proxy-prefect`), `rabbitmq:15672`,
  `openbao:8200`, `portainer:9443` (https
  upstream), and, per-app, to whatever apps register.
- Port 5432 → NGINX's `stream{}` block (`nginx/stream.d/postgres.conf`),
  a raw TCP passthrough proxy to `postgres:5432`, bound to
  `127.0.0.1:5432` at the Compose level so it never reaches the LAN.
- Port 5672 → NGINX's `stream{}` block (`nginx/stream.d/rabbitmq.conf`),
  a raw TCP passthrough proxy to `rabbitmq:5672`, bound to
  `127.0.0.1:5672` the same way.
- Port 2222 → NGINX's `stream{}` block (`nginx/stream.d/devssh.conf`), to
  the dev gateway on the Mac Studio (`192.168.2.66:2222`), bound to `${LAN_IP}` (never `0.0.0.0`): dev-session SSH
  has to reach other LAN machines (see "Dev sessions").
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
`s3`, `s3-admin`, `oauth2-proxy`, `oauth2-proxy-infra`,
`oauth2-proxy-prefect`, `ollama-proxy*`, `litellm`, `rabbitmq`, `ntfy`, `prefect-*`, `openbao`, `grafana`, other
monitoring backends, `dev-egress`, `dev-gateway`, or a `dev-*` session.** If a backend service needs to be reachable from the host, add
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
  it exists (it also ensures `infra-backups`, the backup flow's volume).
- `/api/` has no `rewrite`, unlike `ea.conf` and `jarvis.conf`: DarkAngel's
  FastAPI router is mounted at `/api` itself, so the prefix is passed through.
  Stripping it here would 404 every API call.
- The vhost is versioned in DarkAngel's repo too, as
  `deploy/nginx/darkangel.conf`. Changes here belong there as well.

### Jarvis / EA Keycloak gates

oauth2-proxy gates (Jarvis, Prefect, s3-admin) and the EA token-verification realm are documented in `keycloak/CLAUDE.md`.

### Prefect: pipelines

`prefect-flows` serves three deployments from `prefect/flows/`:
`pr-validation/nightly` (03:00 America/Toronto),
`organize-inbox/every-15m` and `sort-mail/every-15m`. They are live as soon
as `serve()` registers them — nothing arrives paused.

**Two gates, and neither replaces the other.** `prefect-flows` holds the
Docker socket, and a deployment's `pull` steps can run shell commands — so
whoever can write to Prefect's API is root on the daemon. Prefect OSS's API
is open by default, and it is reachable at `prefect-server:4200` from every
container on `infra-net` (LibreChat, Jarvis, EA, …), a path NGINX is not on.
`PREFECT_AUTH_STRING` (`PREFECT_SERVER_API_AUTH_STRING` on the server,
`PREFECT_API_AUTH_STRING` on `prefect-flows`) closes it and has a `:?`
guard; `check-env` also asserts its `user:password` shape, since without a
colon every call gets a bare 401. `oauth2-proxy-prefect` gates the browser
vhost on top: SSO first, then Prefect's own password prompt.

**Models are called directly — the convention for every pipeline.** Flows
`POST` Ollama's `/api/chat` (`OLLAMA_URL`, default
`http://ollama-proxy:11434`, the same Ollama LibreChat uses) with a JSON-schema
`format`, and validate the reply before acting on it. Not LibreChat's Agents
API, not an MCP agent loop: the flow owns the control flow, the model owns
only judgement.

Flow settings in `prefect-flows`' environment are `ORGANIZER_*` / `OLLAMA_*`,
never `PREFECT_*` — Prefect reads that namespace as its own settings.

#### `pr-validation`

At 03:00 it lists the open, non-draft PRs on GitHub, and for each one clones
the head, renders a throwaway `.env` into it, runs the file-level checks, and
posts (or updates) a single comment on the PR. A failing check fails that
PR's mapped task, so the UI shows which PR is red without opening GitHub.

Why here and not in GitHub Actions: a GitHub-hosted runner cannot reach
`infra-net`, this daemon, or anything on the LAN. The checks do not need any
of that — but the smoke test this flow is scaffolding for can only ever run
on this machine, and that is what the workspace and socket plumbing is for.

Four things here are load-bearing.

- **`WORKSPACE_ROOT` is mounted at the same path inside and outside the
  container** (`/tmp/infra-ci:/tmp/infra-ci` on `prefect-flows`). The checks
  run as *sibling* containers, so their `-v <path>:/repo` is resolved by the
  **daemon**, against the host filesystem. A clone written anywhere else would
  be invisible to them, and Docker would auto-create an empty directory in its
  place: the same trap `${INFRA_DIR:-.}` exists for. The cost is that this
  flow does not work against a remote `DOCKER_HOST`.
- **Only `prefect-flows` gets the Docker socket.** `prefect-server` has no
  reason to hold it. If the flow goes away, remove the mount with it.
- **Each check runs in the image the real service uses**, mounted the way the
  real service mounts the repo — `nginx -t` inside the pinned nginx image (the same ref as docker-compose.yml),
  `promtool check config` with `monitoring/prometheus/` at `/etc/prometheus`.
- **`scripts/ci-fake-env.sh` comes from the PR's own checkout**, so a PR that
  breaks it fails on its own change. It renders values shaped the way
  `check-env.sh` demands, which is why running the preflight against it is a
  meaningful check. It refuses to overwrite an existing `.env` unless
  `CI_FAKE_ENV_FORCE=1`.

Setup, once: in the Prefect UI, **Blocks → Secret**, name
`infra-ci-github-token`, value a PAT with `pull_requests:write`. The repo is
the flow parameter `repo` (default `nicolaslallier/Infra`). The PAT is a
Secret block, not a `.env` key, for the reason `PORTAINER_API_KEY` lives in
`.portainer.env`: `.env` is handed to containers wholesale and shipped to
Portainer, and this token can write to GitHub. The obvious next move is
`infra/apps/prefect` in OpenBao — it would be the vault's first real
consumer. A nightly schedule on a Mac that sleeps does not fire — either
`sudo pmset repeat wakeorpoweron MTWRFSU 02:55:00`, or move the schedule.

#### `organize-inbox`

Every 15 minutes it takes the notes under `Inbox/` in the `obsidian` bucket
that nobody has touched for `ORGANIZER_QUIET_MINUTES` (10), at most
`ORGANIZER_MAX_NOTES` (20), oldest first; asks Ollama for tags, a summary and
one of the vault's existing top-level folders (a JSON-schema `enum` built per
run, so it cannot invent one); merges `tags`/`summary`/`organized_at` into
the frontmatter; and moves the note there. It talks to S3 only, as identity `prefect` (`make s3-provision app=prefect
bucket=obsidian`, secret `PREFECT_S3_SECRET_KEY`), separate from Remotely
Save's `obsidian` identity.

- **The move is the only state.** A note that has left `Inbox/` is never
  seen again; there is no table of processed notes.
- **It never overwrites.** A note whose file name already exists in *any*
  top-level folder fails before the model is called, and leaves both objects
  alone (two notes with one basename would make `[[links]]` ambiguous). The inbox object is deleted only after the
  destination `PUT` succeeded; if that `DELETE` fails, the next run fails
  loudly on "already exists" instead of losing anything. The bucket is
  versioned, so every write is undoable.
- **The quiet window is the Remotely Save race mitigation**, not a lock: a
  conflict copy needs both sides to edit one object between two syncs. Raise
  `ORGANIZER_QUIET_MINUTES` if one ever appears.
- **Notes are processed one at a time, and runs never overlap** — parallel
  calls to one 27B model only queue inside Ollama until they hit the request
  timeout. Both deployments carry a concurrency limit of 1 with
  `CANCEL_NEW`, since a slow run can outlast the 15-minute interval.
- **Only its three keys are rewritten.** The rest of the frontmatter stays
  byte-for-byte: a YAML load/dump round trip would turn `12:30` into `750`
  and `NO` into `false`. A failure that can only repeat (bad frontmatter, a
  bad reply, a taken name) is not retried; an unreachable Ollama or S3 is.
- `ORGANIZER_VAULT_PREFIX` is the remote prefix Remotely Save syncs under,
  if it was given one; empty means the bucket root.

#### `sort-mail`

Every 15 minutes it takes up to `SORTER_MAX_THREADS` (20) Gmail inbox
threads, newest first; gives the latest non-draft message of each (a few
headers, attachment names, the text body) to Ollama; and lets it pick one of
the Gmail labels under `SORTER_LABEL_PREFIX` (`Tri/`) — a JSON-schema `enum`
built per run — or `garder`. It talks to the Gmail REST API with `urllib`
only, as the mailbox owner, over OAuth.

- **Threads, not messages.** The inbox is shown by conversation, and a
  thread stays visible while any of its messages carries `INBOX`, so labels
  and archiving apply to the whole thread.
- **One `threads.modify` per decision.** A sorted thread gets its label and
  loses `INBOX` in the same call; there is no half-applied state. Nothing is
  deleted: a wrong label is fixed from Gmail (`label:tri-<name>`).
- **`Tri/_garder` is the only other state.** A kept thread gets that marker
  and stays in the inbox; the inbox query excludes it, so a kept thread is
  not re-sorted (not even on a new reply). Remove the marker by hand to have
  it sorted again. Labels whose name after the prefix starts with `_` never
  enter the enum.
- **The label name is the category's only description.** Gmail has no label
  descriptions: `Tri/Factures et reçus` sorts better than `Tri/Fin`.
- **The credentials are the Secret block `gmail-sorter-oauth`** — JSON
  `{client_id, client_secret, refresh_token}` — not `.env`, for the reason
  `infra-ci-github-token` is not: this one reads all of the owner's mail.
  Scope `gmail.modify`: read and relabel, no permanent delete.
- **Subjects land in the logs.** Every decision is printed as
  `"<subject>" -> <label> (<reason>)`, in Prefect's run logs and in Loki.
- **Errors:** an unreachable Ollama or Gmail, a 429 or a 5xx is retried; a
  bad model reply or another 4xx fails that thread only, which stays in the
  inbox for the next run. A refused refresh token fails the run with
  `TokenRevoked`, naming the script below.
- `dry_run=true` (flow parameter, from the UI) logs the decisions and changes
  nothing.

Setup, once:

1. Google Cloud Console, in the Workspace organisation: a project, the Gmail
   API enabled, an OAuth consent screen of type **Internal** (an External app
   in Testing mode has its refresh tokens revoked after 7 days, and the flow
   then fails every run), and an OAuth client of type **Desktop app**;
   download its JSON.
2. `python3 scripts/gmail-oauth.py <client_secret.json>` on the Mac (stdlib;
   it opens the browser) and paste the JSON line it prints into Prefect UI →
   **Blocks → Secret** `gmail-sorter-oauth`. Delete the downloaded client
   JSON afterwards.
3. Create the `Tri/...` labels in Gmail. The flow creates `Tri/_garder`.

The flows have plain-assert tests (`prefect/flows/test_*.py`); `make test`
runs them (`TEST_ONLY=unit make test` runs only them), against the prefect
and fastapi versions of the pinned `prefecthq/prefect` image.

#### `backup`

At 01:30 America/Toronto it dumps postgres (`pg_dumpall` as `postgres`,
gzipped), OpenBao (raft snapshot, below) and
ntfy (tar of its volume) into the external volume `infra-backups`
(`/backups`), as `<target>/<target>-<UTC stamp>.<ext>`. The newest
`BACKUP_KEEP` (3) of each are kept. Heaven is to snapshot that volume (not wired
yet); this flow only leaves consistent files there.

The volume can live on an SMB share on mac-infra (192.168.2.35, external
disk `/Volumes/Data`). Set `BACKUPS_SMB_SHARE` (`//192.168.2.35/infra-backups`),
`BACKUPS_SMB_USER` and `BACKUPS_SMB_PASSWORD` (a secret) **in the vault**
(`infra/env`), not in `.env`: every `make up` re-renders `.env` from the vault
and blanks hand edits. E.g. `make vault-cli args="kv patch -mount=infra env
BACKUPS_SMB_SHARE=... BACKUPS_SMB_USER=..."`, and the password via stdin, prompted
silently (bash and zsh) -- at a terminal a bare `BACKUPS_SMB_PASSWORD=-` stores
an empty value, and `printf '%s'` keeps a trailing newline out of it:
`read -rs P && printf '%s' "$P" | make vault-cli args="kv patch -mount=infra env BACKUPS_SMB_PASSWORD=-"; unset P`. All three or none (`check-env` rejects a partial
set); none means a plain local volume, so the backups then share the data's
disk. `scripts/portainer-volumes.sh` (reads only those keys from `.env`)
creates it with the `local` driver, `type=cifs`, `vers=3.0`, `uid=0`,
`gid=65534`, `file_mode=0640`, `dir_mode=0750`: `prefect-flows` writes as
root, node-exporter runs as nobody and must read `metrics/backup.prom`, and a
postgres dump holds every app's data, so nothing is world-readable.

- **It mounts lazily.** Volume creation succeeds even with the Mac
  unreachable; the failure surfaces when `prefect-flows` / node-exporter
  start, and the deploy health gate names them. The Mac must be awake at
  01:30 (Energy settings, or `sudo pmset -c sleep 0`).
- **Mac setup (owner):** System Settings -> General -> Sharing -> File Sharing
  -> add `/Volumes/Data/infra-backups`, accessible to a dedicated macOS user
  with read & write.
- **Trade-off:** Docker keeps the mount options, password included, in the
  volume's metadata on the laptop; anyone who can read it has daemon access,
  which is root anyway.
- **Migration:** driver options are immutable, so an existing local
  `infra-backups` (or one with other credentials) makes `make app-volumes`
  fail with the one-time steps (remove `infra-prefect-flows-1` and
  `infra-node-exporter-1`, `docker volume rm infra-backups`, `make up`); at
  most a few nightly dumps are lost. It never deletes anything itself.

- **One-shot containers carry no `com.docker.compose.*` label.** The deploy
  health gate counts every container labelled project `infra` and fails on
  exited ones; the ntfy tar runs detached with a
  `BACKUP_STEP_TIMEOUT` wait, always force-removed, and no
  labels, and image and volume names are read from the running container.
- **A dump is `.part` until it succeeds.** A non-zero `pg_dumpall` exit
  removes the file. Targets run independently; the run goes red if any failed.
- **OpenBao** is snapshotted over HTTP (`GET /v1/sys/storage/raft/snapshot`
  at `BACKUP_BAO_ADDR`, default `http://openbao:8200`) into
  `openbao/openbao-<stamp>.snap`, after a `renew-self` of the token (periodic,
  768h, so the nightly renewal keeps it alive). The token is the Secret block
  `openbao-backup-token`, never `.env`. Owner steps, once: `make
  vault-backup-token` (writes policy `backup` from `openbao/policies/backup.hcl`,
  prints a new token once; re-running mints another), then paste it into
  Prefect UI -> Blocks -> Secret `openbao-backup-token`, then trigger
  `backup/nightly` once from the Prefect UI so the backup alerts clear. The snapshot is
  encrypted with the seal key, so back up `openbao/seal.key` separately.
- **Metric:** `backup.prom` under `metrics/` carries
  `infra_backup_last_success_timestamp_seconds{target=...}` for node-exporter's
  textfile collector (`prefect-flows` creates `metrics/` at start); a failed
  target keeps its old time. Grafana rules `Backup stale` (over 26 h) and
  `Backup metric missing` (absent for 30 m).

### Dev sessions

Claude Code in containers, one per GitHub repo, reached over SSH from the
LAN. Usage is in the README ("Dev sessions"). Pieces: the `devbox` CLI
(`dev/cli`, Rust, runs on the owner's Mac/PC), one Portainer stack per
session (`dev/session.compose.yml`, stack `dev-<name>`, image
`devbox-session:1` from `dev/image`, built on the daemon by `make dev-image`),
and the plumbing in `docker-compose.dev.yml` (Portainer stack `dev`,
`make dev-up`): `dev-egress` (squid) and `dev-gateway` (sshd). All of it runs
on the Mac Studio (Portainer environment 6, Colima VM `192.168.2.66`, arm64),
off `infra-net`: nginx on 192.168.2.10 passes `${LAN_IP}:2222` to
`DEV_SSH_IP:2222`, and the proxy reaches s3 at `S3_LAN_IP:8333` (`s3` is an
`extra_hosts` entry). The CLI runs `weed shell` on `s3_endpoint_id`. Neither project is part of the
`infra` stack, so `make up` never recreates a session -- but it does recreate
nginx, which drops every session's SSH (see tmux below). `make dev-test` runs
the CLI tests and the image/state checks on the local daemon.

- **SSH is a `ProxyJump`.** nginx (`stream.d/devssh.conf`) passes
  `${LAN_IP}:2222` to the gateway on the Mac Studio, user `jump`, which forwards only to
  port 2222 and has no shell; each session runs its own unprivileged sshd on
  2222, with every forwarding off (a forwarded agent would push past the
  one-repo token). `PermitOpen *:2222` cannot name sessions (no patterns),
  so the jump user can reach port 2222 on any host the gateway sees: accepted,
  owner keys only. The gateway's keys are `dev/gateway/authorized_keys`,
  baked into its image (edit, then `make dev-up`); a session's are
  `pubkey_path` + `extra_pubkeys` from the CLI config, so every machine of
  the owner can log in. The CLI keeps the `Host dev-<name>` blocks in
  `~/.ssh/devbox.conf`, included at the *top* of `~/.ssh/config` (ssh keeps
  the first value it reads, so a `Host *` must not come first).
- **Interactive logins land in tmux** (session `main`): a dropped link (Wi-Fi,
  sleep, nginx recreated) leaves `claude` running; ssh again re-attaches.
- **The only way out is the proxy.** Sessions are on `dev-net`
  (`internal: true`: no route anywhere, no DNS) and get
  `HTTP(S)_PROXY=dev-egress:3128`. squid's rule order is load-bearing:
  `s3:8333` first, then **names** (`deny !allowed`) before **addresses**
  (`deny private`) -- a `dst` check resolves the name, so checking it for a
  name about to be refused would leak that name over DNS
  (`<secret>.attacker.tld`). Only s3 and the allow-list (Anthropic, GitHub,
  crates.io, npm, PyPI) are ever resolved, through Docker's DNS and on to the
  host's resolver. The `-n` on `dstdomain` is load-bearing too: without it
  squid reverse-resolves an IP literal, and an attacker's own PTR record
  (`x.github.com`) would pass the list. `scripts/dev-isolation-check.sh <name>`
  asserts all of it against a running session, DNS leak included (it reads
  squid's ipcache through the cache manager, allowed from localhost only).
- **Sessions share `dev-net`**, so one session can reach ports another
  listens on (a dev server, a debugger). Not an anti-goal; per-session
  networks would need the CLI to attach the proxy and gateway to each.
- **No bind mounts in `docker-compose.dev.yml`**: configs are `COPY`'d into
  the images, which `make dev-image` / `dev-up` build on the Mac Studio from
  GitHub main through Portainer's API (Git stacks do not reliably build), so
  the stack deploys to a remote environment. Merge a `dev/` change, then
  rebuild: CI does not.
- **One S3 identity per session**: `devbox-<name>`, actions
  `Read/Write/List:devbox/<name>/*` (SeaweedFS action scopes; the `/*` is
  what makes them work, and `devbox/ab` is not `devbox/a`). `devbox create`
  mints it with a fresh secret by running `weed shell` in the infra `s3`
  container through Portainer's Docker API (the secret travels in the exec's
  env, never an argv), creating the versioned bucket `devbox` on first use;
  `devbox delete` removes it. No `.env` key, nothing in `check-env`.
- **State**: `/work` (volume `dev-<name>-work`) and the state volume
  `dev-<name>-state` (Claude's config and subscription credentials via
  `CLAUDE_CONFIG_DIR`, the SSH host key, the `ready` marker) survive a stop,
  a resume and a recreate. Both are pushed to `devbox/<name>/{work,claude}`
  every 60 s and on stop (`stop_grace_period: 120s`), with modes and
  symlinks (`-M --links`); `target/`, `node_modules/`, `.venv/` are not. The
  `ready` marker is written once a restore or clone has completed, and no push
  happens without it: a push is an `rclone sync`, and pushing a half-restored
  `/work` would delete the saved copy. A start without it restores again, so
  `devbox delete x` then `devbox create x` (same repo) gets the work and the
  Claude login back -- with a new host key, which `delete` forgets from
  `known_hosts`. Reusing a name for another repo is refused at start.
- **The GitHub token is the real guard rail**, not the container: Claude may
  merge to the default branch, which on a repo with a self-hosted runner runs
  code on the host. `devbox create`/`token` require a fine-grained token
  (`github_pat_`; one set to "All repositories" cannot be detected), a
  protected default branch, and a token *without* the Administration
  permission (probed by reading the branch's protection, fail-closed: only
  GitHub's 403 passes; a 404 "Branch not protected" -- rulesets only -- means
  the token could read it, and any other answer refuses), since that
  permission would let it lift the protection. The token sits in the stack env: Portainer,
  `docker inspect`, and Portainer's volume on disk hold it; the CLI never
  prints it. `devbox token <name>` replaces it (redeploys the stack).
- **The Portainer API key stays on the owner's machine**, in the CLI's
  `config.toml` (warned about unless mode 600); nothing in a session can reach
  Portainer or the socket. Point `portainer_url` at the nginx vhost with
  `ca_cert` = the stack's `certs/infra-ca.crt`: `insecure_tls` hands the key
  to anyone on the LAN who can answer for Portainer's address.
- **Budget**: `max_active` (4) x `mem_limit` (1536m) is 6 GiB on the Mac
  Studio's 8 GiB Colima VM, which also carries DarkAngel, so sessions have
  `oom_score_adj: 1000` (the OOM killer takes them first), `cpus` (2) and
  `pids_limit: 1024`. The owner's config sets `max_active = 2` (the VM stays
  at 8 GiB).
- **The image**: Claude Code is pinned (`CLAUDE_CODE_VERSION`) with its
  auto-updater off; `npm i -g` goes to `~/.npm-global`; Debian's pip is
  PEP 668-managed (use a venv). The dev/ Dockerfiles' base digests are
  Renovate's (`dockerfile` manager); the three local images are ignored.
  Changes under `dev/` do not trigger the infra deploy.

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
  somewhere the volume is not (a copy is kept in the owner's password manager,
  with its base64 and sha256 noted beside it; never in the repo, `.env` or the
  vault); lose it and the vault is unrecoverable, since
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
The `vault-*` scripts reach the container the same way (`scripts/lib/bao.sh`:
labels, then `docker exec`), never through `docker compose exec`, for the same
reason.

Not done here, and worth knowing before assuming otherwise: the vault's only
login is the root token in `.openbao.env`. There is no Keycloak OIDC auth
method, and the only consumer is the nightly backup flow (below), which holds
a scoped periodic token (policy `backup`: raft snapshot read plus
`renew-self`, nothing else), renewed on each run; no app reads its secrets
from the vault yet — they all still get them from `.env` via Compose. Prometheus does scrape it (job `openbao`, unauthenticated because
the listener sets `unauthenticated_metrics_access`, the same posture as
SeaweedFS's /metrics), but there is no Grafana dashboard for it.

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
per-app DNS config), plus one apex zone per non-`.infra.` hostname, plus a
**`Forwarder`** zone for `famillelallier.net` holding only
`*.famillelallier.net -> LAN_IP` (any new name resolves on the LAN without a
new zone; everything else in the parent is forwarded to `UPSTREAM_DNS`). The
list lives in `scripts/dns-provision.sh`.

DNS zone authority is absolute — owning a `Primary` zone for the whole
`famillelallier.net` parent would make Technitium authoritative for every
name under it, including `beacon.famillelallier.net` /
`dev.famillelallier.net`, which exist outside this repo and must keep
resolving wherever they already do, plus the Google Workspace MX and
SPF/DKIM TXT records. **The parent zone stays a `Forwarder` zone, never a
`Primary` one**: names and types it doesn't hold go to the public DNS.

The Technitium web console (port 5380) is published directly rather than
fronted through NGINX like pgAdmin. This is deliberate: fronting it
through NGINX would need a hostname (e.g. `dns.famillelallier.net`) to
already resolve, but that can only happen *after* this DNS server exists
and is provisioned — a bootstrap chicken-and-egg problem. `dns-provision.sh`
drives the API directly by IP, so this is a one-time cost paid by the repo,
not by whoever runs `make up`.
