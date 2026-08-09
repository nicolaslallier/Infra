# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`Infra` is the shared "common group" backing stack for sibling application
repos (`Jarvis` and others): NGINX, PostgreSQL 18, pgAdmin, Keycloak, MinIO,
RabbitMQ, a Technitium DNS server, and an LGTM monitoring stack (Grafana,
Prometheus, Loki, Tempo, Alloy + exporters), run via Docker Compose.
Application repos are meant to stay in their own repositories and connect in
over a shared Docker network rather than being folded into this one.

## Commands

```bash
make / make help                 # list targets (default goal)
make init                        # create infra-net, generate dev certs, copy .env.example -> .env
make up / make down / make restart
make logs                        # tail logs (optional: s=<service>)
make ps / make status            # service status
make pull / make config          # pull images / validate compose + .env
make shell s=<service>           # shell into a running service
make psql                        # psql shell as the superuser (via docker compose exec)
make provision-app app=<name>    # add a new app DB/role to an already-running cluster
make provision-monitoring-role   # create/update postgres-exporter monitoring role
make certs                       # generate TLS certs (FORCE=1 to regenerate)
make hosts                       # print the /etc/hosts lines this stack needs
make dns-provision               # create/update the DNS zones & records the dns service serves
make dns-check                   # query the dns service to confirm it's answering correctly
make clean CONFIRM=1             # docker compose down -v (keeps infra-net and certs/)
```

`up`, `config`, `provision-app`, `dns-provision`, and `dns-check` run
`check-env` first: `.env` must exist, and password-like values must not
still be the `change-me` placeholders from `.env.example`.

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
- **`minio`** — `minio/minio`. Publishes no host port. S3 API on `:9000`
  and browser console on `:9001`, both fronted by NGINX
  (`minio.famillelallier.net` / `minio-console.famillelallier.net`).
  Apps on `infra-net` reach the API at `http://minio:9000`.
- **`rabbitmq`** — `rabbitmq:4-management`. Publishes no host port. AMQP
  on `:5672` (NGINX stream passthrough at `127.0.0.1:5672`; apps on
  `infra-net` use `rabbitmq:5672` directly) and management UI on `:15672`
  (`rabbitmq.infra.famillelallier.net`). Prometheus metrics on `:15692`.
- **`nginx`** — `nginx:alpine`. Fronts every backend application service —
  the only one of those services with a `ports:` entry. Also listens on
  internal `:8080/stub_status` for `nginx-exporter` (not published on the
  host).
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

`postgres` has no LAN/browser-facing hostname — that's deliberate, not an
oversight. `pgadmin` (`pgadmin.famillelallier.net`), `keycloak`
(`keycloak.famillelallier.net`), Grafana
(`grafana.infra.famillelallier.net`), MinIO
(`minio.famillelallier.net` / `minio-console.famillelallier.net`),
RabbitMQ management (`rabbitmq.infra.famillelallier.net`),
and the Jarvis frontend (`jarvis.famillelallier.net`, also reachable at
`jarvis.infra.famillelallier.net`) do. When registering the Postgres server
inside pgAdmin's own UI, the host is the Compose service name `postgres`
(pgAdmin and `postgres` share `infra-net` directly), port `5432` — never a
`*.famillelallier.net` hostname. A hostname like
`postgresql.famillelallier.net` doesn't exist anywhere in this stack and
produces connection-refused, not a DNS or reachability problem.

### Single-ingress rule

This rule governs *backend application services* — anything NGINX fronts
(`postgres`, `pgadmin`, `keycloak`, `minio`, `rabbitmq`, `grafana`,
monitoring backends, and future apps) — not top-level infra processes that
own a protocol NGINX can't meaningfully front. `postgres`, `pgadmin`,
`keycloak`, `minio`, `rabbitmq`, `grafana`, and the rest of LGTM/exporters
deliberately have no `ports:` key. All host access to them — HTTP(S),
Postgres, and AMQP — goes through NGINX:

- Port 80/443 → NGINX's `http{}` block (`nginx/conf.d/*.conf`), reverse
  proxying to `pgadmin:80`, `keycloak:8080`, `grafana:3000`, `minio:9000`
  / `minio:9001`, `rabbitmq:15672`, and, per-app, to whatever apps register.
- Port 5432 → NGINX's `stream{}` block (`nginx/stream.d/postgres.conf`),
  a raw TCP passthrough proxy to `postgres:5432`, bound to
  `127.0.0.1:5432` at the Compose level so it never reaches the LAN.
- Port 5672 → NGINX's `stream{}` block (`nginx/stream.d/rabbitmq.conf`),
  a raw TCP passthrough proxy to `rabbitmq:5672`, bound to
  `127.0.0.1:5672` the same way.

**Do not add a `ports:` entry to `postgres`, `pgadmin`, `keycloak`,
`minio`, `rabbitmq`, `grafana`, or other monitoring backends.** If a backend
service needs to be reachable from the host, add an NGINX server block
instead (`nginx/conf.d/app.conf.example` is the template for HTTP; extend
`nginx/stream.d/` for raw TCP). This is a deliberate constraint, not an
oversight — keeping every backend-app host-facing port behind one process
is the point of this stack.

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

### Certificates

`scripts/gen-certs.sh` prefers `mkcert` and falls back to `openssl`
(mkcert isn't installed on the dev machine this was built on; openssl is).
Either path produces a wildcard cert for `*.infra.famillelallier.net` plus
`localhost`/`127.0.0.1`, so adding a new app subdomain never requires
regenerating certs. Trusting the local CA in the system keychain is a
`sudo`-gated step the script prints but does not run — that's for the
human running it, not automated here.

pgAdmin, Keycloak, Jarvis, MinIO API, and MinIO console are all deliberate
exceptions to the `.infra.` subdomain convention: they're served at
`pgadmin.famillelallier.net`, `keycloak.famillelallier.net`,
`jarvis.famillelallier.net`, `minio.famillelallier.net`, and
`minio-console.famillelallier.net` (no `.infra.`), so those exact hostnames
are added as extra SANs (the `EXTRA_SANS` array) alongside the wildcard in
`gen-certs.sh` rather than being covered by `*.infra.famillelallier.net`.
Regenerating certs (`./scripts/gen-certs.sh --force`) always mints a new
local CA too, so re-run the `sudo security add-trusted-cert` step it
prints for every browser/keychain that had the old one trusted — the
old CA's trust doesn't carry over.

### DNS (LAN resolver)

`dns` runs Technitium's official `technitium/dns-server` image. Its
environment variables (`DNS_SERVER_DOMAIN`, `DNS_SERVER_ADMIN_PASSWORD`,
`DNS_SERVER_FORWARDERS`, `DNS_SERVER_RECURSION`, ...) are only read on
first boot, when `/etc/dns` (the `dns-config` volume) is still empty — they
bootstrap server-level settings, not zone data.

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
zones, **never** a `Primary` zone for `famillelallier.net` itself:

- `infra.famillelallier.net` — apex + `*.infra.famillelallier.net`
  wildcard A records, both → `LAN_IP`. Covers every current/future app
  hostname automatically; no DNS config needed per new app. Jarvis is
  also reachable this way, at `jarvis.infra.famillelallier.net`, with no
  extra DNS/cert config.
- `pgadmin.famillelallier.net` — apex A record → `LAN_IP`, mirroring its
  exception status in `gen-certs.sh` above.
- `keycloak.famillelallier.net` — apex A record → `LAN_IP`, same
  exception pattern as pgAdmin's zone.
- `jarvis.famillelallier.net` — apex A record → `LAN_IP`, same exception
  pattern, requested in addition to the `.infra.` hostname above so
  Jarvis is reachable at both.
- `minio.famillelallier.net` / `minio-console.famillelallier.net` — apex
  A records → `LAN_IP`, same exception pattern (API + browser console).

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
