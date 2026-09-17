# Infra

Shared backing infrastructure — the "common group" — for sibling application
repos (`Jarvis` and others). A single Docker Compose stack provides NGINX,
PostgreSQL 18 with pgvector, pgAdmin, Keycloak, MinIO, RabbitMQ, Neo4j, OpenBao,
Portainer, Technitium DNS, and an LGTM monitoring stack (Grafana, Prometheus,
Loki, Tempo, Alloy).
Application repos stay independent: they don't run their own database or
proxy, they just join this stack's Docker network.

**NGINX is the only ingress for application traffic.** It is the sole
container fronting backend services — 80/443 for HTTP(S), 5432 (TCP
passthrough) for Postgres, 5672 (TCP passthrough) for RabbitMQ AMQP, and
7687 (TCP passthrough) for Neo4j Bolt.
Postgres, pgAdmin, Keycloak, MinIO, RabbitMQ, Neo4j, OpenBao, Grafana, and
the rest of the monitoring backends publish nothing themselves; they're
reachable only on the shared `infra-net` Docker network or through NGINX.
A separate `dns` container publishes its own ports too — it's a top-level
infra service in its own right, not something NGINX can front. See "DNS"
below.

## Runtime

This stack runs on **Docker Desktop for Mac**, sized 6 CPU / 12 GB / 100 GB
under Settings → Resources, with its disk image on the external
`/Volumes/Docker` volume (Settings → Resources → Advanced → "Disk image
location").

```bash
make docker-start   # launch Docker Desktop and wait for its daemon
make docker-stop    # quit it (takes the whole stack down with it)
```

`make check-docker` runs before `make up` and `make config`. It verifies more
than "is Docker running": that the daemon is actually Docker Desktop and not
a leftover `colima` context, that the external volume holding the disk image
is mounted, that this repo sits under a directory Docker Desktop shares, and
that the VM is sized for the stack. See "Runtime: Docker Desktop" in
`CLAUDE.md` for what each of those failures looks like when it isn't caught.

Enable Settings → General → "Start Docker Desktop when you sign in" to bring
the stack up at login — but **don't let it start with `/Volumes/Docker`
unmounted**: Docker Desktop builds a fresh empty VM in the default location
instead of refusing, which loses every volume until you point it back.

### Migrating from Colima

This stack previously ran on a bridged Colima VM. Named volumes live inside
the daemon's VM, so switching to Docker Desktop does not bring Postgres,
Keycloak, MinIO, Grafana or RabbitMQ data with it. With the stack stopped on
both daemons:

```bash
make migrate-volumes DRY=1   # list what would be copied
make migrate-volumes         # colima -> desktop-linux
```

Nothing on the Colima side is modified, and volumes that already hold data on
Docker Desktop are skipped (`OVERWRITE=1` to replace them). Two settings also
change meaning:

- **`LAN_IP` in `.env` is now this Mac's LAN IP**, not the VM's — Docker
  Desktop publishes ports on the host. Move the router's static DHCP
  reservation to the Mac, and find the address with `ipconfig getifaddr en1`.
- **`docker context`** must point at `desktop-linux`; `make check-docker`
  fails loudly if it still points at `colima`, because the stack would
  otherwise come up healthy-looking on the old VM's volumes.

## First run

```bash
make init      # creates infra-net, local dev certs, OpenBao's seal key, copies .env.example -> .env
```

Edit `.env` and set real passwords (`POSTGRES_PASSWORD`, `PGADMIN_PASSWORD`,
`KEYCLOAK_ADMIN_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`, `MINIO_ROOT_PASSWORD`,
`RABBITMQ_DEFAULT_PASS`, `MONITORING_DB_PASSWORD`, and one
`<APPNAME>_DB_PASSWORD` per entry in `APP_DATABASES`, including
`KEYCLOAK_DB_PASSWORD` and `GRAFANA_DB_PASSWORD`), plus the two
oauth2-proxy cookie keys (`JARVIS_OAUTH_COOKIE_SECRET`,
`EA_OBSIDIAN_OAUTH_COOKIE_SECRET` — `openssl rand -base64 32 | tr -- '+/'
'-_'` each; the `tr` matters, see below).
`make check-env` lists whatever is still missing, so you don't have to work
that list out by hand:

```bash
make check-env    # run by up / config / provision-* / dns-* anyway
make hosts        # prints /etc/hosts lines to add (not applied automatically)
```

`make up` deploys this stack through Portainer's API (see "Portainer" below
and CLAUDE.md "Portainer-managed stack"), so Portainer needs to exist and
hold an API key before `make up` can run. On a machine where this stack has
never run before, bootstrap that with a one-time plain-compose bring-up —
it's what gets NGINX (and so the Portainer UI) reachable in the first
place:

```bash
docker compose up -d   # one-time bootstrap only, so nginx/dns exist
make portainer-up      # start Portainer itself (its own compose project)
```

Within a few minutes of that first start, create the admin account at
`https://portainer.infra.famillelallier.net` (it locks the signup form
after that window; `make portainer-restart` reopens it), then create an
access token (My account → Access tokens) and put it in `.portainer.env`
(gitignored, not `.env` — see "Portainer" below):

```
PORTAINER_API_KEY=<the token>
```

Now stop the bootstrap containers — Portainer won't create a stack whose
name matches a compose project it already knows about, even a stopped one
— and let Portainer deploy for real:

```bash
docker compose down   # no -v: keeps the volumes/data step 2 initialised
make up               # Portainer creates stack `infra` from GitHub main
```

`make up` also refuses to run unless this checkout is on `main`, clean,
and at `origin/main`, since Portainer deploys from GitHub rather than your
working tree, and only from the main checkout (not a worktree). Every
`make up` recreates every container, so expect a brief outage (including a
momentary LAN DNS drop) on each redeploy, not just the first one.

The cert script prints a `sudo security add-trusted-cert ...` command to
trust the local CA in macOS's keychain — run that yourself if you want
browsers to stop warning about the self-signed cert.

pgAdmin: `https://pgadmin.famillelallier.net`
Keycloak: `https://keycloak.famillelallier.net` (admin console at
`/admin/master/console/`)
Grafana: `https://grafana.infra.famillelallier.net`
MinIO console: `https://minio-console.famillelallier.net` (API at
`https://minio.famillelallier.net`; apps on `infra-net` can also use
`http://minio:9000`)
Airflow: `https://airflow.infra.famillelallier.net` (admin / `AIRFLOW_ADMIN_PASSWORD`;
DAGs go in `airflow/dags/`)
RabbitMQ management: `https://rabbitmq.infra.famillelallier.net` (AMQP at
`127.0.0.1:5672` from the host, or `rabbitmq:5672` on `infra-net`)
Portainer: `https://portainer.infra.famillelallier.net` (admin account and
access token already created above — see "Portainer" below)
Postgres: `psql -h 127.0.0.1 -p 5432 -U postgres` (or `make psql`)
Neo4j (the EA graph): Bolt at `bolt://127.0.0.1:7687` from the host, or
`neo4j:7687` on `infra-net`; no browser is exposed
Obsidian (desktop app in the browser): `https://obsidian.infra.famillelallier.net`
(Keycloak login against the `ea` realm; vaults live in the `obsidian-config`
volume)
OpenBao (the vault): `https://vault.infra.famillelallier.net` (log in with
the root token from `.openbao.env` after `make vault-init` — see "Secrets"
below; apps on `infra-net` use `http://openbao:8200`)

### Keeping an existing `.env` in step with `.env.example`

`.env` is copied from `.env.example` once and is gitignored, so a `.env`
created months ago is missing every setting added since — a new service's
variables are simply absent from it. Compose interpolates an absent
variable as an **empty string and deploys anyway**, so the symptom is a
container dying on its own config with nothing pointing back at `.env`:

```
[main.go:52] invalid configuration:
  missing setting: cookie-secret
  missing setting: client-secret or client-secret-file
```

That is `oauth2-proxy` (or `oauth2-proxy-ea`) handed empty secrets.
`make check-env` diffs the two files and prints the lines to append:

```
check-env: .env is missing settings that .env.example defines: EA_OBSIDIAN_OAUTH_COOKIE_SECRET
...
    EA_OBSIDIAN_OAUTH_COOKIE_SECRET=change-me
```

Append them, fill each in (`grep -B4 -n <VAR> .env.example` says what it is
for), and re-run. Do this after every `git pull` that adds a service. The
one value `check-env` only warns about is an oauth2-proxy **client** secret:
Keycloak generates it during realm import, so it cannot exist until after
the first deploy — see the Jarvis and Obsidian login sections below.

### Registering the Postgres server inside pgAdmin

`postgres` has no LAN hostname of its own — only pgAdmin does
(`pgadmin.famillelallier.net`). Don't guess a hostname like
`postgresql.famillelallier.net` in the "Register Server" dialog; it doesn't
exist and the connection will be refused. pgAdmin and `postgres` are both
containers on `infra-net`, so pgAdmin reaches Postgres directly by Compose
service name:

- **Host**: `postgres`
- **Port**: `5432`
- **Username / Password**: your `POSTGRES_USER` / `POSTGRES_PASSWORD`

(The `127.0.0.1:5432` address above is for connecting from your host
machine via `psql` — it's a different path than pgAdmin uses.)

### Jarvis login (Keycloak + oauth2-proxy)

`https://jarvis.famillelallier.net` requires a Keycloak login (see
"Obsidian login" below for the other gated vhost; every other app listed
above is unauthenticated at the NGINX layer). After `make up`:

1. In the Keycloak admin console, open the `jarvis` realm → **Clients** →
   `jarvis` → **Credentials** tab, copy the client secret into
   `JARVIS_OAUTH_CLIENT_SECRET` in `.env`, then
   `docker compose up -d oauth2-proxy` to pick it up.
2. Still in the `jarvis` realm, **Users** → **Add user**, and set a
   password on that user's **Credentials** tab. This is the one homelab
   account that can log in — nothing in this repo creates it for you (see
   `keycloak/realm-import/jarvis-realm.json` / CLAUDE.md for why).

Set `JARVIS_OAUTH_COOKIE_SECRET` in `.env` before first boot (`openssl
rand -base64 32 | tr -- '+/' '-_'`) — unlike the client secret,
oauth2-proxy needs this at startup, not after, and `docker-compose.yml`
fails the compose parse outright if it is unset. It must be 16, 24 or 32
bytes, raw or **base64url**; anything else and oauth2-proxy exits on
`invalid configuration`, which is why `make check-env` checks it.

That `tr` is the whole reason the recipe is not just `openssl rand -base64
32`. oauth2-proxy decodes the key with the URL-safe base64 alphabet only
and quietly keeps the raw string when the decode fails, so a standard-base64
key — one containing a `+` or a `/`, which is roughly three out of four —
is read as a 44-byte key and the container dies on:

```
cookie_secret must be 16, 24, or 32 bytes to create an AES cipher, but is 44 bytes
```

An existing key hit by this keeps its entropy; only its spelling is wrong.
Convert it in place rather than generating a new one (which would log
everyone out): `printf '%s\n' "$JARVIS_OAUTH_COOKIE_SECRET" | tr -- '+/' '-_'`. Until step 1 is done,
`oauth2-proxy` crash-loops on `missing setting: client-secret` — expected
on a first deploy, and `make check-env` warns about it rather than
blocking.

Note this only gates the frontend page itself; the Jarvis backend
API/WebSocket are reached by the browser directly at their own published
port, not through this vhost — see the "Jarvis: Keycloak login gate"
section in [CLAUDE.md](CLAUDE.md) for the full explanation and what to
verify manually.

### Obsidian login (Keycloak + oauth2-proxy, realm `ea`)

`https://obsidian.infra.famillelallier.net` is gated too, but by the **`ea`
realm**, not `jarvis`: anyone who can log in to EA can open Obsidian. An
oauth2-proxy process talks to exactly one issuer, so this is a second
container — `oauth2-proxy-ea` — with its own client, `ea-obsidian`, seeded
by `keycloak/realm-import/ea-realm.json`. It is a separate session from a
Jarvis login: different realm, different cookie, no SSO between the two.

After `make up`:

1. Set `EA_OBSIDIAN_OAUTH_COOKIE_SECRET` in `.env` **before first boot**
   (`openssl rand -base64 32 | tr -- '+/' '-_'` — base64url, same as the
   Jarvis key above and for the same reason) — oauth2-proxy needs it at
   startup.
2. In the Keycloak admin console, `ea` realm → **Clients** → `ea-obsidian`
   → **Credentials**, copy the client secret into
   `EA_OBSIDIAN_OAUTH_CLIENT_SECRET` in `.env`, then
   `docker compose up -d oauth2-proxy-ea`.
   Until then `oauth2-proxy-ea` crash-loops on `missing setting:
   client-secret`, exactly as the Jarvis proxy does before its own step 1.
3. Give each `ea` realm user who should reach Obsidian an **email address**
   — oauth2-proxy reads the `email` claim and rejects a login without one.
   No realm role is required; to narrow access to EA editors, add
   `OAUTH2_PROXY_ALLOWED_ROLES: ea-editor` to the service.

`--import-realm` only seeds a realm that does not exist yet, so on an
already-running Keycloak the `ea-obsidian` client has to be created by hand
in the console: confidential client, standard flow only, PKCE method `S256`,
one exact redirect URI
`https://obsidian.infra.famillelallier.net/oauth2/callback`.

The desktop inside that container has no login of its own, which is the
whole reason for the gate — never give the `obsidian` service a `ports:`
entry.

### Obsidian vaults in MinIO

The browser Obsidian keeps its working copy on the `obsidian-config`
volume and syncs it into the MinIO bucket `obsidian` with the Remotely Save
plugin. One-time setup, after `make up`:

1. Set `OBSIDIAN_MINIO_SECRET_KEY` in `.env`, then `make obsidian-minio`
   (creates the versioned bucket, a policy limited to it, and the MinIO
   user `obsidian`; safe to re-run).
2. In `https://obsidian.infra.famillelallier.net`, create or open a vault,
   then **Settings → Community plugins → Browse → Remotely Save → Install →
   Enable**.
3. Remotely Save settings → **S3 or compatible**:
   - Endpoint: `http://minio:9000`
   - Region: `us-east-1`
   - Access Key ID: `obsidian`
   - Secret Access Key: your `OBSIDIAN_MINIO_SECRET_KEY`
   - Bucket: `obsidian`
   - S3 URL style: **Path Style**
   - Bypass CORS: on
   - Then **Check** the connection, and set a schedule (e.g. every 5 min).

Other devices (phone, laptop) can sync the same vault with the same
settings, using `https://minio.famillelallier.net` as the endpoint.

### EA login

Unlike Jarvis, `https://ea.infra.famillelallier.net` has no oauth2-proxy
gate: the EA API and its `/mcp` verify the token themselves, so
`nginx/conf.d/ea.conf` is unchanged. After `make up` with
`keycloak/realm-import/ea-realm.json` in place:

1. In the `ea` realm, **Users** → **Add user** for each human, then give
   editors the realm role `ea-editor` on that user's **Role mapping** tab
   (reading the catalogue needs no role).
2. **Clients** → `ea-pipelines` → **Credentials**, copy the client secret
   into EA's `pipelines/.env` as `PIPELINES_EA_CLIENT_SECRET`.
3. **Do not add LAN origins to `ea-spa`.** A plain-http LAN origin such as
   `http://192.168.x.y:5173` cannot log in whatever its redirect URIs say:
   the SPA builds PKCE with `crypto.subtle`, which browsers only expose in a
   secure context. Open the Vite dev server as `http://localhost:5173` —
   from another machine through
   `ssh -L 5173:127.0.0.1:5173 -L 8000:127.0.0.1:8000 <host>` — or use the
   https vhost; both are already among `ea-spa`'s exact redirect URIs (EA
   `docs/adr/0032`).

`ea-mcp`'s one redirect URI (`http://localhost:33418/callback`) follows
EA's `.mcp.json` `callbackPort` for the Claude Code MCP OAuth flow — change
one and the other stops working.

`--import-realm` only seeds a realm that doesn't exist yet (see "Keycloak
admin bootstrap" below); changing `ea-realm.json` later means repeating the
edit in the live realm through the console.

### Keycloak admin bootstrap

`KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD` in `.env` only take effect on
Keycloak's very first boot against an empty `keycloak` database (same
caveat as `PGADMIN_EMAIL`/`PGADMIN_PASSWORD` above) — changing them later
in `.env` does nothing to an already-provisioned admin user. Change the
password from inside the admin console instead.

## Secrets (OpenBao)

`openbao` is the stack's vault — OpenBao, the MPL-licensed fork of
HashiCorp Vault (BUSL since Vault 1.15). Same KV v2 API, same `bao`/`vault`
CLI, so Vault's documentation and client libraries apply. It publishes no
host port: `https://vault.infra.famillelallier.net` through NGINX for the
UI, `http://openbao:8200` on `infra-net` for anything in the stack.

Bootstrap it once, after the stack is up:

```bash
make vault-init   # initialise; writes the root token to .openbao.env, mounts KV v2 at infra/
make vault-seed   # copy this checkout's .env into infra/env
```

`make vault-init` is idempotent, so re-running it after a redeploy is
harmless. Log in to the UI with the root token from `.openbao.env`, or use
the CLI without pasting it anywhere:

```bash
make vault-status                            # seal/init state
make vault-cli args="kv list infra/"
make vault-cli args="kv get -mount=infra env"
make vault-cli args="kv patch -mount=infra env MINIO_ROOT_PASSWORD=new-value"
```

### Two files, and why they aren't in `.env`

| File | What it is |
|---|---|
| `openbao/seal.key` | 32 random bytes. Lets the vault unseal itself on restart, and is the only thing that can decrypt the `openbao-data` volume. Generated by `make seal-key` (which `make init` runs), gitignored, bind-mounted into the container. |
| `.openbao.env` | The root token and a break-glass recovery key, written by `make vault-init`. Gitignored; only the `vault-*` scripts read it. |

Neither belongs in `.env`, for the reason `PORTAINER_API_KEY` doesn't
either: `.env` is handed to containers wholesale (`postgres` `env_file`s
it) and shipped to Portainer as the stack env.

**Back `openbao/seal.key` up somewhere that is not this machine's disk.**
It never arrives with a `git pull`, and there is no recovering the vault
without it — the recovery key in `.openbao.env` regenerates a *root token*,
it does not unseal an auto-sealed vault. And be clear-eyed about what the
auto-unseal buys and costs: without it the vault would come back **sealed
after every `make up`** (every deploy force-recreates every container), and
with it, anyone holding that file plus the volume can decrypt the vault
offline.

### The `.env` round trip

Compose cannot read a vault — it interpolates `${FOO}` from the environment
it is handed, and that is `.env`. So `.env` does not go away; it becomes a
rendered artifact, and the vault becomes the record:

```bash
make vault-seed   # .env  -> infra/env   (after editing .env by hand)
make vault-env    # infra/env -> .env    (after editing in the vault)
make check-env && make up
```

`make vault-env` renders through `.env.example` as a template, so the
regenerated `.env` keeps every comment explaining what each setting is for
and passes `make check-env` by construction. A setting the vault doesn't
have keeps `.env.example`'s value and is reported rather than silently
blanked. The previous `.env` is kept as `.env.bak`.

Each variable is one field of the KV v2 secret `infra/env`, named exactly
as the variable is, so `kv get -field=POSTGRES_PASSWORD -mount=infra env`
does what it looks like. KV v2 keeps every version, so
`kv rollback -mount=infra -version=3 env` undoes a bad edit.

### What this does not do yet

The vault's only login is that root token: there's no Keycloak OIDC auth
method and no per-app policies. No app in this stack or in a sibling repo
reads its secrets from the vault — they all still get them from `.env` via
Compose. Prometheus scrapes it (job `openbao`), but there's no Grafana
dashboard for it. The audit trail goes to the container's stdout, so it
lands in Loki with everything else; query it in Grafana with
`{compose_service="openbao"}` (Alloy sets that label from the Compose
service name, which — unlike the container name — doesn't change with the
project name).

## DNS

`make hosts` (loopback `/etc/hosts` entries, one device at a time) still
works and is the simplest option if you only need this on the machine
running Docker, or don't want to touch router settings.

For LAN-wide resolution — so other devices (phones, laptops) also resolve
`*.infra.famillelallier.net`, `pgadmin.famillelallier.net`, and
`keycloak.famillelallier.net` without per-device `/etc/hosts` edits — this
stack also runs a `dns` service ([Technitium DNS
Server](https://technitium.com/dns/)). It answers authoritatively for
those names (the wildcard covers every `*.infra.famillelallier.net` app
automatically) and forwards every other query upstream to
`UPSTREAM_DNS`/`UPSTREAM_DNS_2` (Cloudflare by default), so it's safe to
use as your LAN's only DNS resolver.

To use it LAN-wide:

1. Set `LAN_IP` and `DNS_ADMIN_PASSWORD` in `.env` (a DHCP reservation for
   `LAN_IP` is strongly recommended, so it doesn't change on reboot).
2. `make up` — starts `dns` alongside the rest of the stack, listening on
   `${LAN_IP}:53` and its web console on `${LAN_IP}:5380`.
3. `make dns-provision` — creates the `infra.famillelallier.net`,
   `pgadmin.famillelallier.net`, and `keycloak.famillelallier.net`
   zones/records via Technitium's API. Safe to re-run.
4. Point your router's DHCP DNS server setting at `LAN_IP` (a manual,
   router-specific step this repo can't automate — same treatment as
   trusting the local CA in `gen-certs.sh`). Devices may need to reconnect
   or renew their DHCP lease to pick it up.
5. `make dns-check` (or `./scripts/dns-check.sh <LAN_IP>` from another
   machine) to confirm it's answering.

The admin console lives at `http://<LAN_IP>:5380` — it's plain HTTP on the
LAN by default (password-protected via `DNS_ADMIN_PASSWORD`). Set
`DNS_SERVER_WEB_SERVICE_ENABLE_HTTPS=true` in the `dns` service's
environment if you want to encrypt that session too.

## Common commands

Run `make` / `make help` for the full list. Notable targets:

| Command | What it does |
|---|---|
| `make docker-start` / `make docker-stop` | Launch / quit Docker Desktop (see "Runtime" above) |
| `make up` / `make down` | Deploy-or-redeploy / stop the stack **via Portainer** (Git `main`; `up` checks `.env`, Docker Desktop and that this checkout is at `origin/main`; every `up` recreates every container — brief outage expected) |
| `make logs` / `make logs s=nginx` | Tail logs (all services, or one via `s=`) |
| `make ps` / `make status` | Show service status |
| `make restart` / `make restart s=keycloak` | Restart services (all, or one via `s=`) |
| `make shell s=postgres` | Open a shell in a service |
| `make psql` | Open a psql shell as the superuser |
| `make portainer-up` / `make portainer-down` | Start / stop Portainer (its own compose project, `docker-compose.portainer.yml`) |
| `make portainer-restart` / `make portainer-logs` | Restart Portainer / tail its logs |
| `make pull` | Redeploy via Portainer, re-pulling images |
| `make config` | Validate `docker-compose.yml` + `.env` |
| `make check-env` | Check `.env` on its own: settings missing since `.env.example` grew, placeholders, unusable oauth2-proxy cookie keys, a `LAN_IP` the Docker host doesn't own, a missing `openbao/seal.key` |
| `make provision-app app=<name>` | Add/update an app's database/role (and `vector` extension) on an **already-running** cluster |
| `make provision-monitoring-role` | Create/update the postgres-exporter `monitoring` role |
| `make certs` / `make certs FORCE=1` | Generate certs (or regenerate with `FORCE=1`) |
| `make seal-key` | Generate OpenBao's auto-unseal key (`FORCE=1` replaces it — destroys an existing vault) |
| `make vault-init` | Initialise the vault: root token → `.openbao.env`, KV v2 at `infra/` (idempotent) |
| `make vault-seed` / `make vault-env` | Copy `.env` into the vault / regenerate `.env` from it (old one → `.env.bak`) |
| `make vault-status` / `make vault-cli args="..."` | Seal/init state / run any `bao` command against the vault |
| `make dns-provision` | Create/update the DNS zones & records the `dns` service serves |
| `make dns-check` | Query the `dns` service to confirm it's answering correctly |
| `make migrate-volumes` / `make migrate-volumes DRY=1` | Copy the stack's volumes off the old Colima VM (`DRY=1` previews) |
| `make clean CONFIRM=1` | Delete the Portainer stack and its volumes (destructive; keeps Portainer, `infra-net` and `certs/`) |

## Monitoring

The LGTM stack (Grafana + Prometheus + Loki + Tempo + Alloy) plus
exporters (cAdvisor, node-exporter, postgres-exporter, nginx-exporter) runs
on `infra-net`. Only Grafana is browser-facing, at
`https://grafana.infra.famillelallier.net` (admin password =
`GRAFANA_ADMIN_PASSWORD`). Prometheus, Loki, Tempo, Alloy, and exporters
have no host `ports:`.

What you get:

- **Metrics** — host (node-exporter), containers (cAdvisor), Postgres,
  NGINX (`stub_status` on an internal `:8080`), Keycloak (`:9000/metrics`),
  MinIO, RabbitMQ (`:15692/metrics`), Alloy, Windows machines
  (windows_exporter, job `windows` — see below), Macs (node_exporter's darwin
  build plus a GPU sampler, job `macos` — see below), and sibling apps that
  expose `/metrics`
  (Jarvis API at `jarvis-api:8000`, scraped as job `jarvis`)
- **Logs** — Alloy reads every container's stdout/stderr via the Docker
  socket (this stack and sibling Compose projects on the same host) and
  ships them to Loki
- **Traces** — NGINX starts a trace for every request and returns its id
  in the `X-Trace-Id` response header; Keycloak continues it. To follow one
  request: `curl -skI https://<host>/... | grep -i x-trace-id`, then
  Grafana → Explore → Tempo → paste the id (the span's "Logs for this
  span" shows every container's log lines carrying it). Alloy accepts OTLP
  on `alloy:4317` (gRPC) / `alloy:4318` (HTTP); sibling apps on `infra-net`
  should export there and honour the incoming `traceparent` header to join
  the same trace

Provisioned dashboards (Grafana → Dashboards): **Infra overview**,
**Application logs**, **Jarvis** (`uid: jarvis-overview`) covering
API HTTP metrics, containers, the `jarvis` Postgres DB, Loki logs and
Tempo traces, **Windows machines** (`uid: windows-hosts`), and **macOS
machines** (`uid: macos-hosts`).

### Windows machines

**Windows machines** (`uid: windows-hosts`) charts the LAN's Windows hosts —
CPU, memory and commit charge, volumes, disk and network I/O, uptime, and
auto-start services that are not running. The **Machine** picker at the top
filters every panel; leave it on *All* for the fleet.

It is fed by [windows_exporter][we] running **on each Windows machine**, not
by anything in this stack. That is the one place the single-ingress rule does
not reach: the exporter lives on a host we don't deploy to, so it is scraped
over the LAN rather than fronted by NGINX.

[we]: https://github.com/prometheus-community/windows_exporter/releases

Per machine, in an **Administrator** PowerShell — take the current
`windows_exporter-<version>-amd64.msi` from the releases page above:

```powershell
msiexec /i windows_exporter-<version>-amd64.msi /qn `
  ENABLED_COLLECTORS="cpu,logical_disk,memory,net,os,service,system" `
  LISTEN_PORT=9182

# Only if the installer did not add its own inbound rule (check first with
# `Get-NetFirewallRule -DisplayName 'windows_exporter*'`) -- New-NetFirewallRule
# happily creates a duplicate.
New-NetFirewallRule -DisplayName "windows_exporter" -Direction Inbound `
  -Protocol TCP -LocalPort 9182 -Action Allow

Invoke-RestMethod http://localhost:9182/metrics | Select-Object -First 5
```

On a windows_exporter older than v0.30, add `cs` to `ENABLED_COLLECTORS`:
total physical memory lived there before the `memory` collector gained it.
The dashboard reads whichever of the two exists, so a fleet running mixed
versions charts whole.

Then list the machine in
[`monitoring/prometheus/targets/windows.yml`](monitoring/prometheus/targets/windows.yml)
— one entry per host, `hostname` optional and cosmetic (it becomes the
`instance` label, so panels name the machine instead of an IP):

```yaml
- targets: ["192.168.2.20:9182"]
  labels:
    hostname: desk-nicolas
```

Prometheus re-reads that file every 30s, so a new machine appears without a
restart — but it is bind-mounted from this checkout, so commit and push
before the next `make up` (the drift guard refuses untracked files anyway).
Confirm with Prometheus → Status → Targets, or the dashboard's *Machines*
tile.

Two things to know about the machine **this stack runs on**: it is scraped at
`host.docker.internal:9182` (Docker Desktop's route from a container back to
its own host — from inside `infra-net` the laptop is not a container), and
its firewall rule has to cover the Docker/WSL virtual adapter, not just the
LAN one. It is also the one machine node-exporter and cAdvisor already
report on — but they see Docker Desktop's Linux VM, so windows_exporter is
what actually describes the hardware.

The `service` collector enumerates every service on the box, which is a few
hundred series per machine. If that is more than you want to store, narrow it
with `EXTRA_FLAGS="--collector.service.include=..."`; the *Auto-start services
that are not running* panel then only covers the services you named.

### macOS machines

**macOS machines** (`uid: macos-hosts`) charts the LAN's Macs — CPU and load,
memory the way Activity Monitor counts it, swap and paging, volumes, disk and
network I/O, GPU, uptime, and battery. The **Mac** picker at the top filters
every panel; leave it on *All* for the fleet.

It is fed by [node_exporter][ne]'s **darwin build, running on each Mac** — not
by the `node-exporter` container in this stack, which sees Docker Desktop's
Linux VM. Same exception to the single-ingress rule as the Windows job: the
exporter lives on a host we don't deploy to, so it is scraped over the LAN
rather than fronted by NGINX.

[ne]: https://github.com/prometheus/node_exporter

Per Mac:

```bash
brew install node_exporter
brew services start node_exporter     # listens on :9100, comes back at login

curl -s localhost:9100/metrics | head -5
```

macOS prompts once to allow incoming connections the first time a LAN machine
scrapes it; accept, or the target flaps between `up` and `down`. The default
collector set on darwin already covers everything this dashboard reads —
`cpu`, `meminfo`, `filesystem`, `diskstats`, `netdev`, `loadavg`, `boottime`,
`uname` and `powersupplyclass` — so there is nothing to enable.

Then list the Mac in
[`monitoring/prometheus/targets/macos.yml`](monitoring/prometheus/targets/macos.yml),
same shape as the Windows list (`hostname` optional, cosmetic, becomes the
`instance` label):

```yaml
- targets: ["192.168.2.30:9100"]
  labels:
    hostname: macbook-nicolas
```

The Mac **this stack runs on** is scraped at `host.docker.internal:9100`, the
same route the Windows job uses for its own host. It is the one machine the
`node` job also reports on — but that job is the container, describing the
Linux VM, so this is the dashboard that describes the actual hardware.

Three things about the queries, all of which bite anyone adapting a
Linux-shaped dashboard:

- **The `node` and `macos` jobs share the `node_*` metric namespace.** Every
  panel here pins `job="macos"`; drop that and the Docker Desktop VM is
  averaged into the Mac's numbers.
- **darwin spells the network counters differently.** It exports
  `node_network_receive_errors_total` and `node_network_receive_dropped_total`
  where Linux says `_errs_` and `_drop_`, and has no transmit-dropped counter
  at all. The *Errors and drops / s* panel matches both spellings by
  `__name__` regex so it charts on either.
- **Memory used is wired + app + compressed**, over `hw.memsize` —
  `node_memory_inactive_bytes` and `node_memory_purgeable_bytes` are
  reclaimable, and counting them as used makes every Mac look permanently
  full. Likewise on disk: `node_filesystem_purgeable_bytes` is space Finder
  already counts as free, which is why a volume can read 95% used and not
  actually be out of room.

On an APFS Mac, `/` and `/System/Volumes/Data` share one container and report
identical numbers (`/` being the read-only system snapshot), so both appear in
*Volume used %*. The helper volumes (`Preboot`, `VM`, `Update`, `xarts`,
`iSCPreboot`, `Hardware`) are filtered out. `/Volumes/Docker` — the external
disk Docker Desktop's disk image lives on, per *The disk image must live on
the external volume* in CLAUDE.md — does show up, which makes this dashboard
the place that notices it filling before the daemon does.

Battery panels are empty on a desktop Mac: IOKit has no power source to
report. That is the expected reading, not a broken scrape.

#### GPU panels

The **GPU** row — busy %, GPU memory, renderer/tiler split, and a table of the
accelerators found — needs one extra step per Mac, because **node_exporter's
darwin build has no GPU collector**. Not disabled: absent. There is no
`node_*` GPU metric on macOS and no flag that produces one, so the numbers
have to come from somewhere else.

They come from IOKit, read with `ioreg` — which needs no root, unlike
`powermetrics` — by [`scripts/macos-gpu-textfile.sh`](scripts/macos-gpu-textfile.sh),
and are handed to node_exporter's **textfile collector** rather than to a
second exporter on a second port. That keeps them on the same `job="macos"`
scrape as everything else on the dashboard, so they carry the same `instance`
label, answer to the same **Mac** picker, and need no new Prometheus job, no
new targets file and no second firewall prompt.

Per Mac, from a checkout of this repo:

```bash
./scripts/install-macos-gpu-exporter.sh

curl -s http://localhost:9100/metrics | grep '^macos_gpu'
```

That installs two launchd agents under `~/Library/LaunchAgents` (no sudo): one
runs the sampler every 15s, the other runs node_exporter itself with
`--collector.textfile.directory`. The second one **replaces
`brew services start node_exporter`**, and the installer stops the brew
service so the two cannot fight over `:9100`. It has to: node_exporter takes
that directory only as a command-line flag, and `brew services` runs the
binary with no arguments and regenerates its plist on every restart, so an
edited Homebrew plist does not survive. Same binary, same port, same default
collectors, one added flag. To go back:

```bash
./scripts/install-macos-gpu-exporter.sh --uninstall
brew services start node_exporter     # GPU panels go empty, everything else stays
```

What the panels read:

| metric | |
|---|---|
| `macos_gpu_utilization_ratio` | IOKit *Device Utilization*, 0–1 — the headline busy figure |
| `macos_gpu_renderer_utilization_ratio` / `macos_gpu_tiler_utilization_ratio` | the two engines behind it; **tiler is Apple silicon only** |
| `macos_gpu_memory_in_use_bytes` / `macos_gpu_memory_allocated_bytes` | on Apple silicon this is unified memory, already counted in the Memory panels — not extra RAM |
| `macos_gpu_info` | registry name, IOKit class, and model (empty on Intel, where the property is raw hex and is left undecoded) |
| `macos_gpu_accelerators` | how many GPUs `ioreg` found; `0` means the sampler ran and saw nothing |

Three things worth knowing:

- **These are point samples, not rates.** Every other panel on this dashboard
  averages a counter over the scrape window; `ioreg` reports an instantaneous
  gauge, so the GPU panels have the sampler's 15s resolution and a burst
  shorter than that can fall between two samples. Raise the cadence with
  `SAMPLE_INTERVAL=5 ./scripts/install-macos-gpu-exporter.sh` if that matters.
- **The launchd agent points at the script's path in your checkout**, so a
  `git pull` updates it in place — but moving or deleting the checkout breaks
  the agent. Re-run the installer after moving it.
- **A silent sampler looks exactly like an idle GPU**, since both are "no
  recent data". `time() - node_textfile_mtime_seconds{job="macos"}` is the
  distinguishing query: if it climbs past a minute, the agent has stopped
  (`launchctl list | grep famillelallier`, and
  `$(brew --prefix)/var/log/macos-gpu-textfile.err.log`).

The IOKit key spelling is not stable across macOS releases and GPU families —
the same counter appears as `"Device Utilization %"` and as
`"device utilization"` — so the sampler matches both, case-insensitively.
Don't "simplify" that to one spelling; it is the same
chart-on-whichever-exists idiom as the network-counter regex above.

On an **already-running** Postgres volume (init scripts won't re-run):

```bash
# After adding grafana to APP_DATABASES + GRAFANA_DB_PASSWORD in .env:
make provision-app app=grafana
make provision-monitoring-role   # postgres-exporter role (idempotent)
```

**macOS / Docker Desktop:** node-exporter and cAdvisor see Docker Desktop's
Linux VM, not the Mac host hardware — CPU/RAM/disk panels on **Infra
overview** are best-effort and describe the VM's 6 vCPU / 12 GB / 100 GB, not
the Mac's. That is what the **macOS machines** dashboard above is for: it
reads a node_exporter running on the Mac itself. Container metrics and logs
still work. cAdvisor is the service most likely to need attention after the
move off Colima; see the note on its mounts in `docker-compose.yml`.

## Portainer

Web UI for this host's Docker daemon — containers, images, volumes,
networks, logs, and an exec console — at
`https://portainer.infra.famillelallier.net`.

```bash
make portainer-up        # start it on its own (nginx must be running too)
make portainer-logs
make portainer-down      # stop + remove the container, keep portainer-data
```

Portainer is not part of `docker-compose.yml`: it *deploys* that stack.
Start it first, create the admin account, then create an access token
(My account → Access tokens) and put it in `.portainer.env` (gitignored,
`PORTAINER_API_KEY=...`, next to `.env` but never sent to a container) —
`make up` needs it. See CLAUDE.md "Portainer-managed stack" for why bind
mounts use `${INFRA_DIR}`, why `make up` insists on `origin/main`, and why
it also insists on the main checkout rather than a worktree.

It is the one exception to the single-ingress rule: it publishes 9443 (UI,
TLS), 9000 (UI, HTTP) and 8000 (Edge agent) on `LAN_IP` itself, so
`https://<LAN_IP>:9443` works even while the infra stack — nginx included —
is down. It is also reachable through NGINX at
`portainer.infra.famillelallier.net` (`nginx/conf.d/portainer.conf`). That
hostname is covered by the existing
`*.infra.famillelallier.net` cert and DNS wildcard, so no `gen-certs.sh` SAN
or `dns-provision.sh` zone is needed.

Two things worth knowing:

- **First visit creates the admin account, and the window is short.** If you
  don't set the password within a few minutes of the container's first
  start, Portainer disables that form as a security measure and the UI says
  so; `make portainer-restart` reopens it.
- **The UI is root on the Docker daemon.** Portainer mounts
  `/var/run/docker.sock` read-write because managing containers is the whole
  point of it, so anyone who reaches the page and gets past its login can
  start a privileged container. Its own admin account is the only gate —
   unlike `jarvis.famillelallier.net`, this vhost is not behind
   oauth2-proxy/Keycloak.

### Watching Portainer itself

Portainer CE exposes no `/metrics` endpoint, so to scrape Portainer from the
LGTM stack you run `scripts/portainer-metrics.py` — a host-side exporter that
polls the Portainer REST API and re-exports it in Prometheus text format. It
lives on the **host, not in a container**: its only credential is a
full-admin `PORTAINER_API_KEY`, which is a Docker-daemon-root secret that
CLAUDE.md "Portainer-managed stack" forbids reaching any container (`.env` is
handed to containers via postgres's `env_file`). It reads that same token out
of `.portainer.env` (the file `scripts/portainer-stack.sh` already uses), so
the token never lands in a container's filesystem, env, or process list.

```bash
python3 scripts/portainer-metrics.py --config .portainer.env   # serve on :9999
python3 scripts/portainer-metrics.py --once --selftest         # parse/render checks, no network
```

It is stdlib-only, so it runs under the Mac's system `python3` with no install
step. Defaults: bind `0.0.0.0:9999`, poll the API every 30s. The base URL falls
back through `--base-url` → `PORTAINER_BASE_URL` (in `.portainer.env`) →
`https://127.0.0.1:9443`; TLS verification is off, exactly like the `-k`
`api()` helper in `portainer-stack.sh` (the API sits behind Portainer's 9443
self-signed cert). A failed poll keeps the last good reading and bumps
`portainer_exporter_scrape_errors_total` instead of dropping the target.

To feed it to Prometheus, Prometheus (in the stack) reaches the host over
`host.docker.internal`. Add a job to `monitoring/prometheus/prometheus.yml`:

```yaml
   - job_name: portainer
     static_configs:
       - targets: ["host.docker.internal:9999"]
```

What it exports: `portainer_controlplane_up` (1 when the API answered the last
poll), `portainer_exporter_scrape_total` / `_scrape_errors_total`,
`portainer_api_last_success_timestamp_seconds`, `portainer_version`,
`portainer_ram_total_bytes`, `portainer_endpoint_count{type=}`,
`portainer_stack_count{status=}` (1=stopped 2=running), and per-stack
`portainer_stack_running` / `portainer_stack_status` / `portainer_stack_repository`
/ `portainer_stack_last_deploy_timestamp_seconds` (a git stack's last
successful snapshot update).

## Connecting an application repo

1. Add a database + role for the app: put its name in `APP_DATABASES` in
   `.env` (comma-separated) and set `<APPNAME>_DB_PASSWORD` before the
   *first* `make up` — `docker-entrypoint-initdb.d` scripts only run once,
   against an empty volume. If the stack is already running, use
   `make provision-app app=<name>` instead (and still add it to `.env` so a
   future full recreate stays in sync).
2. In the app's own `docker-compose.yml`, join the external network and
   connect to Postgres by service name:

   ```yaml
   services:
     myapp:
       # ...
       networks:
         - infra-net
       environment:
         DATABASE_URL: postgres://myapp:${MYAPP_DB_PASSWORD}@postgres:5432/myapp

   networks:
     infra-net:
       external: true
   ```

3. To route HTTP traffic through NGINX, copy
   [`nginx/conf.d/app.conf.example`](nginx/conf.d/app.conf.example) to
   `nginx/conf.d/<name>.conf` and point it at the app's service name. If
   you've set up the `dns` service (see "DNS" above), the hostname resolves
   automatically — the wildcard covers every `*.infra.famillelallier.net`
   name. Otherwise, add it manually (see `make hosts`).
4. Optional: send OpenTelemetry traces to Alloy on `infra-net`
   (`OTEL_EXPORTER_OTLP_ENDPOINT=http://alloy:4318`). Container logs are
   collected automatically via the Docker socket — no app changes needed
   for Loki.

## Layout

```
docker-compose.yml       postgres, pgadmin, keycloak, minio, rabbitmq, neo4j, openbao, nginx, dns, LGTM + exporters
docker-compose.portainer.yml  portainer (deploys the stack above)
nginx/nginx.conf         http{} (web) + stream{} (Postgres + AMQP + Bolt TCP passthrough)
nginx/conf.d/            per-hostname HTTPS server blocks
nginx/stream.d/          Postgres + RabbitMQ + Neo4j TCP proxy blocks
openbao/config.hcl       OpenBao server config (raft storage, static seal, declarative audit)
postgres/initdb/         first-run schema/extension/provisioning scripts
rabbitmq/                enabled_plugins (management + prometheus)
monitoring/              prometheus, loki, tempo, alloy, grafana provisioning
monitoring/prometheus/targets/  file_sd target lists (Windows machines, Macs)
scripts/                 check-docker.sh, migrate-volumes.sh, gen-certs.sh, provision-app.sh, print-hosts-entries.sh, dns-provision.sh, dns-check.sh
scripts/gen-seal-key.sh       OpenBao's auto-unseal key (openbao/seal.key)
scripts/vault-init.sh         initialise the vault; vault-seed/-env/-cli.sh drive it afterwards
scripts/portainer-stack.sh    make up/down/pull/clean via Portainer's API
scripts/portainer-metrics.py  host-side exporter: Portainer API -> Prometheus (:9999)
```

See [CLAUDE.md](CLAUDE.md) for the architecture notes and gotchas that
matter when changing this stack.
