# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`Infra` is the shared "common group" backing stack for sibling application
repos (`Jarvis` and others): NGINX, PostgreSQL 18, and pgAdmin, run via
Docker Compose. Application repos are meant to stay in their own
repositories and connect in over a shared Docker network rather than being
folded into this one.

## Commands

```bash
make init                        # create infra-net, generate dev certs, copy .env.example -> .env
make up / make down / make restart
make logs                        # tail all container logs
make ps                          # service status
make psql                        # psql shell as the superuser (via docker compose exec)
make provision-app app=<name>    # add a new app DB/role to an already-running cluster
make certs                       # regenerate TLS certs
make hosts                       # print the /etc/hosts lines this stack needs
```

There is no build/lint/test step — this repo is Compose config, NGINX
config, and shell scripts, not an application. Validate changes by actually
running the stack (`make up`) and exercising it, per the checks below.

## Architecture

Three services on one external Docker network (`infra-net`, created by
`make net` / `make init`, not by Compose itself — `external: true` in
`docker-compose.yml` so the network outlives `docker compose down` and
never orphans another app that's still attached to it):

- **`postgres`** — `postgres:18-alpine`. Publishes no host port.
- **`pgadmin`** — `dpage/pgadmin4:9`. Publishes no host port.
- **`nginx`** — `nginx:alpine`. **The only service with a `ports:` entry.**

### Single-ingress rule

`postgres` and `nginx`'s `pgadmin` services deliberately have no `ports:`
key. All host access — HTTP(S) *and* Postgres — goes through NGINX:

- Port 80/443 → NGINX's `http{}` block (`nginx/conf.d/*.conf`), reverse
  proxying to `pgadmin:80` and, per-app, to whatever apps register.
- Port 5432 → NGINX's `stream{}` block (`nginx/stream.d/postgres.conf`),
  a raw TCP passthrough proxy to `postgres:5432`, bound to
  `127.0.0.1:5432` at the Compose level so it never reaches the LAN.

**Do not add a `ports:` entry to `postgres` or `pgadmin`.** If a service
needs to be reachable from the host, add an NGINX server block instead
(`nginx/conf.d/app.conf.example` is the template for HTTP; extend
`nginx/stream.d/` for raw TCP). This is a deliberate constraint, not an
oversight — keeping every host-facing port behind one process is the point
of this stack.

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

The official image sets `PGDATA=/var/lib/postgresql/18/docker` (verified
against both the `bookworm` and `alpine` variants) and declares
`VOLUME /var/lib/postgresql` — **not** `/var/lib/postgresql/data` as in
PG ≤17. `docker-compose.yml` mounts the named volume at
`/var/lib/postgresql` accordingly. Mounting the pre-18 path here doesn't
error — it just silently creates a database that doesn't persist across
restarts, since data actually lands under `PGDATA`.

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
apps can't see each other's data over the shared network.

### Certificates

`scripts/gen-certs.sh` prefers `mkcert` and falls back to `openssl`
(mkcert isn't installed on the dev machine this was built on; openssl is).
Either path produces a wildcard cert for `*.infra.famillelallier.net` plus
`localhost`/`127.0.0.1`, so adding a new app subdomain never requires
regenerating certs. Trusting the local CA in the system keychain is a
`sudo`-gated step the script prints but does not run — that's for the
human running it, not automated here.

pgAdmin is a deliberate exception to the `.infra.` subdomain convention:
it's served at `pgadmin.famillelallier.net` (no `.infra.`), so that exact
hostname is added as an extra SAN alongside the wildcard in
`gen-certs.sh` rather than being covered by `*.infra.famillelallier.net`.
Regenerate certs (`./scripts/gen-certs.sh --force`) after pulling this
change if your local `certs/` predates it.
