# Infra

Shared backing infrastructure — the "common group" — for sibling application
repos (`Jarvis` and others). A single Docker Compose stack provides NGINX,
PostgreSQL 18 with pgvector, pgAdmin, Keycloak, MinIO, RabbitMQ, Neo4j, Portainer,
Technitium DNS, and an LGTM monitoring stack (Grafana, Prometheus, Loki,
Tempo, Alloy).
Application repos stay independent: they don't run their own database or
proxy, they just join this stack's Docker network.

**NGINX is the only ingress for application traffic.** It is the sole
container fronting backend services — 80/443 for HTTP(S), 5432 (TCP
passthrough) for Postgres, 5672 (TCP passthrough) for RabbitMQ AMQP, and
7687 (TCP passthrough) for Neo4j Bolt.
Postgres, pgAdmin, Keycloak, MinIO, RabbitMQ, Neo4j, Grafana, and
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
make init      # creates infra-net, generates local dev certs, copies .env.example -> .env
```

Edit `.env` and set real passwords (`POSTGRES_PASSWORD`, `PGADMIN_PASSWORD`,
`KEYCLOAK_ADMIN_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`, `MINIO_ROOT_PASSWORD`,
`RABBITMQ_DEFAULT_PASS`, `MONITORING_DB_PASSWORD`, and one
`<APPNAME>_DB_PASSWORD` per entry in `APP_DATABASES`, including
`KEYCLOAK_DB_PASSWORD` and `GRAFANA_DB_PASSWORD`).

```bash
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
rand -base64 32`) — unlike the client secret, oauth2-proxy needs this at
startup, not after.

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
   (`openssl rand -base64 32`) — oauth2-proxy needs it at startup.
2. In the Keycloak admin console, `ea` realm → **Clients** → `ea-obsidian`
   → **Credentials**, copy the client secret into
   `EA_OBSIDIAN_OAUTH_CLIENT_SECRET` in `.env`, then
   `docker compose up -d oauth2-proxy-ea`.
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
| `make provision-app app=<name>` | Add/update an app's database/role (and `vector` extension) on an **already-running** cluster |
| `make provision-monitoring-role` | Create/update the postgres-exporter `monitoring` role |
| `make certs` / `make certs FORCE=1` | Generate certs (or regenerate with `FORCE=1`) |
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
  MinIO, RabbitMQ (`:15692/metrics`), Alloy, and sibling apps that expose
  `/metrics` (Jarvis API at `jarvis-api:8000`, scraped as job `jarvis`)
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
**Application logs**, and **Jarvis** (`uid: jarvis-overview`) covering
API HTTP metrics, containers, the `jarvis` Postgres DB, Loki logs, and
Tempo traces.

On an **already-running** Postgres volume (init scripts won't re-run):

```bash
# After adding grafana to APP_DATABASES + GRAFANA_DB_PASSWORD in .env:
make provision-app app=grafana
make provision-monitoring-role   # postgres-exporter role (idempotent)
```

**macOS / Docker Desktop:** node-exporter and cAdvisor see Docker Desktop's
Linux VM, not the Mac host hardware — CPU/RAM/disk panels are best-effort and
describe the VM's 6 vCPU / 12 GB / 100 GB, not the Mac's. Container metrics
and logs still work. cAdvisor is the service most likely to need attention
after the move off Colima; see the note on its mounts in
`docker-compose.yml`.

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
docker-compose.yml       postgres, pgadmin, keycloak, minio, rabbitmq, neo4j, nginx, dns, LGTM + exporters
docker-compose.portainer.yml  portainer (deploys the stack above)
nginx/nginx.conf         http{} (web) + stream{} (Postgres + AMQP + Bolt TCP passthrough)
nginx/conf.d/            per-hostname HTTPS server blocks
nginx/stream.d/          Postgres + RabbitMQ + Neo4j TCP proxy blocks
postgres/initdb/         first-run schema/extension/provisioning scripts
rabbitmq/                enabled_plugins (management + prometheus)
monitoring/              prometheus, loki, tempo, alloy, grafana provisioning
scripts/                 check-docker.sh, migrate-volumes.sh, gen-certs.sh, provision-app.sh, print-hosts-entries.sh, dns-provision.sh, dns-check.sh
scripts/portainer-stack.sh    make up/down/pull/clean via Portainer's API
```

See [CLAUDE.md](CLAUDE.md) for the architecture notes and gotchas that
matter when changing this stack.
