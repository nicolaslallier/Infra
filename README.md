# Infra

Shared backing infrastructure — the "common group" — for sibling application
repos (`Jarvis` and others). A single Docker Compose stack provides NGINX,
PostgreSQL 18, and pgAdmin. Application repos stay independent: they don't
run their own database or proxy, they just join this stack's Docker network.

**NGINX is the only ingress.** It is the sole container that publishes ports
to the host — 80/443 for HTTP(S), and 5432 (TCP passthrough) for Postgres.
Postgres and pgAdmin publish nothing themselves; they're reachable only on
the shared `infra-net` Docker network or through NGINX.

## First run

```bash
make init      # creates infra-net, generates local dev certs, copies .env.example -> .env
```

Edit `.env` and set real passwords (`POSTGRES_PASSWORD`, `PGADMIN_PASSWORD`,
and one `<APPNAME>_DB_PASSWORD` per entry in `APP_DATABASES`).

```bash
make hosts     # prints /etc/hosts lines to add (not applied automatically)
make up
```

The cert script prints a `sudo security add-trusted-cert ...` command to
trust the local CA in macOS's keychain — run that yourself if you want
browsers to stop warning about the self-signed cert.

pgAdmin: `https://pgadmin.infra.famillelallier.net`
Postgres: `psql -h 127.0.0.1 -p 5432 -U postgres` (or `make psql`)

## Common commands

| Command | What it does |
|---|---|
| `make up` / `make down` | Start / stop the stack |
| `make logs` | Tail all container logs |
| `make ps` | Show service status |
| `make psql` | Open a psql shell as the superuser |
| `make provision-app app=<name>` | Add a new app's database/role to an **already-running** cluster |
| `make certs` | Regenerate certs (pass nothing; edit the script for `--force`) |

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
   `nginx/conf.d/<name>.conf`, point it at the app's service name, and add
   its hostname to `/etc/hosts` (see `make hosts`).

## Layout

```
docker-compose.yml       postgres, pgadmin, nginx — nginx is the only service with `ports:`
nginx/nginx.conf         http{} (web) + stream{} (Postgres TCP passthrough)
nginx/conf.d/            per-hostname HTTPS server blocks
nginx/stream.d/          the Postgres TCP proxy block
postgres/initdb/         first-run schema/extension/provisioning scripts
scripts/                 gen-certs.sh, provision-app.sh, print-hosts-entries.sh
```

See [CLAUDE.md](CLAUDE.md) for the architecture notes and gotchas that
matter when changing this stack.
