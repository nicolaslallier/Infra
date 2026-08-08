# Infra

Shared backing infrastructure — the "common group" — for sibling application
repos (`Jarvis` and others). A single Docker Compose stack provides NGINX,
PostgreSQL 18, pgAdmin, and Keycloak. Application repos stay independent:
they don't run their own database or proxy, they just join this stack's
Docker network.

**NGINX is the only ingress for application traffic.** It is the sole
container fronting backend services — 80/443 for HTTP(S), and 5432 (TCP
passthrough) for Postgres. Postgres, pgAdmin, and Keycloak publish nothing
themselves; they're reachable only on the shared `infra-net` Docker network
or through NGINX. A separate `dns` container publishes its own ports too —
it's a top-level infra service in its own right, not something NGINX can
front. See "DNS" below.

## First run

```bash
make init      # creates infra-net, generates local dev certs, copies .env.example -> .env
```

Edit `.env` and set real passwords (`POSTGRES_PASSWORD`, `PGADMIN_PASSWORD`,
`KEYCLOAK_ADMIN_PASSWORD`, and one `<APPNAME>_DB_PASSWORD` per entry in
`APP_DATABASES`, including `KEYCLOAK_DB_PASSWORD`).

```bash
make hosts     # prints /etc/hosts lines to add (not applied automatically)
make up
```

The cert script prints a `sudo security add-trusted-cert ...` command to
trust the local CA in macOS's keychain — run that yourself if you want
browsers to stop warning about the self-signed cert.

pgAdmin: `https://pgadmin.famillelallier.net`
Keycloak: `https://keycloak.famillelallier.net` (admin console at
`/admin/master/console/`)
Postgres: `psql -h 127.0.0.1 -p 5432 -U postgres` (or `make psql`)

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

| Command | What it does |
|---|---|
| `make up` / `make down` | Start / stop the stack |
| `make logs` | Tail all container logs |
| `make ps` | Show service status |
| `make psql` | Open a psql shell as the superuser |
| `make provision-app app=<name>` | Add a new app's database/role to an **already-running** cluster |
| `make certs` | Regenerate certs (pass nothing; edit the script for `--force`) |
| `make dns-provision` | Create/update the DNS zones & records the `dns` service serves |
| `make dns-check` | Query the `dns` service to confirm it's answering correctly |

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

## Layout

```
docker-compose.yml       postgres, pgadmin, keycloak, nginx, dns — nginx and dns are the services with `ports:`
nginx/nginx.conf         http{} (web) + stream{} (Postgres TCP passthrough)
nginx/conf.d/            per-hostname HTTPS server blocks
nginx/stream.d/          the Postgres TCP proxy block
postgres/initdb/         first-run schema/extension/provisioning scripts
scripts/                 gen-certs.sh, provision-app.sh, print-hosts-entries.sh, dns-provision.sh, dns-check.sh
```

See [CLAUDE.md](CLAUDE.md) for the architecture notes and gotchas that
matter when changing this stack.
