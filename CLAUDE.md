# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`Infra` is the shared "common group" backing stack for sibling application
repos (`Jarvis` and others): NGINX, PostgreSQL 18, pgAdmin, Keycloak, MinIO,
RabbitMQ, Neo4j, Portainer, a Technitium DNS server, and an LGTM monitoring stack
(Grafana, Prometheus, Loki, Tempo, Alloy + exporters), run via Docker Compose.
Application repos are meant to stay in their own repositories and connect in
over a shared Docker network rather than being folded into this one.

## Commands

```bash
make / make help                 # list targets (default goal)
make init                        # create infra-net, generate dev certs, copy .env.example -> .env
make docker-start / make docker-stop  # launch / quit Docker Desktop (and wait for its daemon)
make up / make down              # deploy-or-redeploy / stop the stack via Portainer (Git main)
make restart                     # docker compose restart (optional: s=<service>)
make logs                        # tail logs (optional: s=<service>)
make ps / make status            # service status
make pull / make config          # redeploy re-pulling images / validate compose + .env
make portainer-up / -down        # Portainer itself (its own compose project)
make shell s=<service>           # shell into a running service
make psql                        # psql shell as the superuser (via docker compose exec)
make provision-app app=<name>    # add a new app DB/role to an already-running cluster
make provision-monitoring-role   # create/update postgres-exporter monitoring role
make certs                       # generate TLS certs (FORCE=1 to regenerate)
make hosts                       # print the /etc/hosts lines this stack needs
make dns-provision               # create/update the DNS zones & records the dns service serves
make dns-check                   # query the dns service to confirm it's answering correctly
make migrate-volumes             # copy the stack's volumes off the old Colima VM (DRY=1 previews)
make clean CONFIRM=1             # delete the Portainer stack + its volumes (keeps Portainer, infra-net, certs/)
```

`up`, `config`, `provision-app`, `dns-provision`, `dns-check`,
`keycloak-seed-users` and `obsidian-minio` run `check-env`
(`scripts/check-env.sh`) first — see "Preflight: `make check-env`" below for
what it asserts and why each check exists. `up`, `config`,
and `portainer-up` also run `check-docker` (see "Runtime: Docker Desktop"
below).

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
  `email` claim, so an `ea` user without an email address cannot log in.
  Vault data is synced into MinIO (bucket `obsidian`, versioned) by the
  in-app **Remotely Save** plugin against `http://minio:9000`, using a
  MinIO user `obsidian` scoped to that bucket
  (`make obsidian-minio` / `scripts/provision-obsidian-minio.sh`). The
  working copy stays on the `obsidian-config` volume: Obsidian watches the
  filesystem, so a FUSE/s3fs mount of the bucket as `/config` is not an
  option (it also needs `SYS_ADMIN`). MinIO is the durable copy and the one
  other devices sync from.
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

`scripts/check-env.sh` refuses to let anything deploy or provision against
a `.env` that cannot bring the stack up. Everything it finds goes to stderr
— warnings first, then the blockers — and it exits 1 if there was a blocker,
having reported all of them rather than the first. Every check is there
because the failure it prevents surfaces somewhere other than `.env`:

- **Settings `.env.example` defines that this `.env` never got.** `.env` is
  copied once, by `make init`, and then lives on (gitignored) while
  `.env.example` keeps growing — so a variable introduced with a new service
  is simply absent from a long-lived `.env`. Compose interpolates an absent
  variable as an **empty string and deploys anyway**, so the symptom is a
  container dying on its own config with nothing naming `.env`:
  `oauth2-proxy-ea`, handed an empty `EA_OBSIDIAN_OAUTH_COOKIE_SECRET`,
  logs `invalid configuration: missing setting: cookie-secret` and
  crash-loops. The check diffs the assigned keys of the two files and prints
  the missing lines ready to append. Keys assigned only inside a comment in
  `.env.example` (`PORTAINER_API_KEY`, which belongs in `.portainer.env`)
  are not keys and never trip it. To decline a setting that has a Compose
  `:-` default (`UPSTREAM_DNS`, `GRAFANA_ADMIN_USER`), keep its line and
  leave the value empty rather than deleting it.
- **Placeholders, empties, and absences** in the password-like values with
  no source other than `.env` — the `change-me` check — plus a
  `<APP>_DB_PASSWORD` for every entry in `APP_DATABASES` (an app added to
  that list by hand has no `.env.example` line to diff against, hence the
  separate loop). The three states are reported separately because they are
  three different mistakes.
- **oauth2-proxy cookie keys of the wrong length.** oauth2-proxy accepts
  only a 16, 24 or 32 byte `cookie-secret` (raw, or base64/base64url of
  that many bytes) and dies at startup otherwise, so
  `JARVIS_OAUTH_COOKIE_SECRET` / `EA_OBSIDIAN_OAUTH_COOKIE_SECRET` are
  length-checked rather than just checked for being filled in.
- **`LAN_IP` the host does not own.** `dns` publishes its ports on that
  address; a stale one (an old VM's, a changed DHCP lease) fails the bind
  and leaves every later service stuck in `Created`. Against a remote daemon
  (`DOCKER_HOST=ssh://…`, the normal Mac → Windows-laptop case) the
  addresses of *this* machine say nothing, so `LAN_IP` is compared to the
  Makefile's `INFRA_HOST` instead; standalone, that host is derived from
  `DOCKER_HOST`. Where neither `ifconfig` nor `ip` exists to enumerate
  addresses, the check passes rather than guessing.

The **two oauth2-proxy client secrets are warnings, never errors**:
Keycloak generates them when it imports a realm, so they cannot exist
before the first deploy — erroring on them would make the documented
bootstrap order (deploy, then copy the secret out of the admin console)
impossible. The warning names the realm and client to copy it from, and
which container crash-loops until then. For the same reason
`docker-compose.yml` guards the *cookie* secrets with
`${...:?Set ... in .env}` (like `LAN_IP` and `DNS_ADMIN_PASSWORD`) but
leaves the *client* secrets unguarded: the cookie key is required before
first boot and choosable offline, so failing the compose parse is right,
while a `:?` on the client secret would block the very deploy that creates
it. Non-Mac environments that run `docker compose up -d` directly
(CI, the cloud VM in `AGENTS.md`) never call `check-env`, so those `:?`
guards are the only thing standing between them and a silently empty value.

### Runtime: Docker Desktop

The stack runs on **Docker Desktop for Mac**, sized **6 CPU / 12 GB / 100 GB**
under Settings → Resources — the defaults cannot hold Keycloak's JVM,
Postgres, the whole LGTM stack, MinIO and RabbitMQ at once. Sibling app repos
(Jarvis and others) share this same daemon and context automatically; there is
no per-repo VM.

This replaced a **Colima** VM. Notes mentioning `colima start`,
`~/.colima/_lima`, `socket_vmnet`, bridged networking or `make vm-start`
describe that old runtime and no longer apply. Two things changed that are
not cosmetic — what `LAN_IP` means, and what the `dns` container sees as a
client address. Both are below.

**The one thing the migration can silently get wrong** is the daemon the
`docker` CLI talks to. A leftover `docker context use colima`, `DOCKER_HOST`,
or `DOCKER_CONTEXT` still resolves, so `make up` would bring the whole stack
back up on the old VM, against the old volumes, and look entirely healthy.
`scripts/check-docker.sh` asserts `docker info` reports Docker Desktop and
fails the build otherwise; that check is the reason it exists.

#### The disk image must live on the external volume

Point **Settings → Resources → Advanced → "Disk image location"** at
`/Volumes/Docker`. The Mac's internal SSD has under 90 GB free, and Docker
Desktop's sparse disk image grows toward the VM's full 100 GB. (Docker
Desktop used a `~/Library/Containers/com.docker.docker/Data` symlink to
`/Volumes/Docker` on this machine historically; the built-in setting is the
supported way and `check-docker.sh` accepts either.)

**Do not start Docker Desktop while that volume is unmounted.** Unlike
Colima, which refused, Docker Desktop builds a *fresh empty VM* in the
default location and comes up looking fine — a new Postgres cluster, no app
databases, no Keycloak realms, an empty MinIO. `scripts/check-docker.sh`
therefore checks the disk image location *first*, before it even asks
whether a daemon is reachable, so `make docker-start` can refuse to launch
the app rather than discovering the problem afterwards.

#### `LAN_IP` is the Mac's address now, not a VM's

Colima ran bridged, with the VM holding its own DHCP lease, and `LAN_IP` was
*the VM's* address. Docker Desktop has no bridged mode: it publishes
container ports on the Mac itself. So `LAN_IP` is now **this Mac's** LAN IP
(`ipconfig getifaddr en1`), and `ports: ["${LAN_IP}:53:53/udp", ...]` on the
`dns` service binds the Mac's LAN interface directly. Move the router's
static DHCP reservation from the VM's MAC to the Mac's.

What this buys and costs:

- **UDP/53 works.** Bridged mode existed because Colima's default `ssh`
  port-forwarder does not forward UDP at all. Docker Desktop's forwarder
  does, so Technitium answers LAN clients through ordinary port publishing
  and none of that machinery is needed.
- **The `dns` container no longer sees real client addresses.** Docker
  Desktop's forwarder rewrites the source IP to its internal gateway, so
  every query arrives from one address. `DNS_SERVER_RECURSION` is still
  satisfied (that gateway is a private address, and the policy is
  `AllowOnlyForPrivateNetworks`), but Technitium's per-client ACLs,
  stats and query logs now describe the forwarder, not the phone that
  asked. Do not build anything on them.
- macOS prompts once to allow incoming connections, and nothing else may
  already hold `:53` on that address.

`127.0.0.1:5432` and `127.0.0.1:5672` on the `nginx` service now bind the
Mac's loopback directly, with no Lima forwarder in the path — simpler than
before. Keep them on `127.0.0.1` rather than `${LAN_IP}`: binding them to the
LAN address would expose Postgres and AMQP to every device on the network and
defeat the single-ingress rule.

#### Bind mounts and file sharing

Docker Desktop shares `/Users`, `/Volumes`, `/private` and `/tmp` by default
(Settings → Resources → File sharing). A repo outside those resolves to an
empty auto-created directory *inside the VM*, and the stack then fails the
same split way it did under a mountless Colima VM:

- services mounting a single file (`loki`, `tempo`, `prometheus`, `alloy`,
  `nginx`, `oauth2-proxy`, `rabbitmq`) die with
  `error mounting ".../monitoring/loki/config.yml": ... not a directory`
- services mounting a directory (`grafana` provisioning, `postgres` initdb,
  `keycloak` realm-import) start **successfully against empty config**

`scripts/check-docker.sh` checks the repo path against the shared roots so
this surfaces as one clear error instead of half a stack behaving oddly.

#### Preflight: `make check-docker` / `make docker-start`

`scripts/check-docker.sh` reports state as an exit code, the same pattern the
old `check-vm.sh` used:

| code | meaning |
|---|---|
| 0 | running, Docker Desktop, repo bind-mountable, sized right |
| 1 | the disk image location does not resolve (external volume unmounted) |
| 2 | no docker CLI, or no reachable daemon (Docker Desktop is not running) |
| 3 | a daemon answers, but it is not Docker Desktop |
| 4 | the repo is outside Docker Desktop's shared directories |
| 5 | usable, but under-sized or storing its disk image on the internal SSD |

Setting `SKIP_DOCKER_CHECK=1` short-circuits the whole script to 0. Every
check in it is macOS/Docker-Desktop specific, so that is the escape hatch for
the non-Mac environments this stack is also brought up in (CI, a cloud dev
VM, a plain Linux `dockerd` — see `AGENTS.md`); the compose stack itself is
portable.

`make check-docker` (a prerequisite of `up`, `config` and `portainer-up`)
fails the build on 1–4 and only warns on 5, since a small VM or a misplaced
disk image degrades the stack rather than breaking it. `make docker-start`
reads the same code: it no-ops when the daemon is already correct, refuses on
1 (mount the volume first), launches Docker.app and waits up to three minutes
on 2, and re-checks afterwards.

#### Autostart

Settings → General → **"Start Docker Desktop when you sign in"** brings the
daemon up at login, and the containers' `restart: unless-stopped` follows.
Turn off "put hard disks to sleep when possible" in Energy settings: a
spin-down under a live disk image stalls every container.

The autostart caveat is the mirror of Colima's. Colima's flagless
`brew services` start silently rebuilt a small, mountless VM; Docker Desktop
keeps its Settings across restarts, so the sizing and file-sharing config
persist — but it will happily start with `/Volumes/Docker` absent and build
an empty VM there and then. That is why `check-docker.sh`'s disk-image check
runs before anything else, and why `make up` runs it every time.

#### Migrating the volumes off the old Colima VM

Named volumes live inside the daemon's own VM: switching contexts does not
bring them along. With both daemons installed and the stack stopped on both:

```bash
make migrate-volumes DRY=1   # list what would be copied
make migrate-volumes         # colima -> desktop-linux, streamed through tar
```

`scripts/migrate-volumes.sh` enumerates the volumes by their
`com.docker.compose.project` label (falling back to the `<project>_` name
prefix), refuses to run while any of the project's containers are up on
either daemon — copying a live Postgres data directory yields a corrupt
cluster — and skips volumes that already hold data on the target unless
`OVERWRITE=1`. It never modifies the source. Data that is *not* in a volume
(`certs/`, `.env`, everything bind-mounted from the repo) needs nothing: it
lives in the working tree.

After migrating, re-run `make provision-app app=<name>` for each app — it is
idempotent, and it is what re-asserts the `vector` extension and the
`CONNECT` revocation if anything was missed.

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

### Single-ingress rule

This rule governs *backend application services* — anything NGINX fronts
(`postgres`, `pgadmin`, `keycloak`, `minio`, `rabbitmq`, `portainer`,
`grafana`, monitoring backends, and future apps) — not top-level infra
processes that own a protocol NGINX can't meaningfully front. `postgres`,
`pgadmin`, `keycloak`, `minio`, `rabbitmq`, `grafana`, and the
rest of LGTM/exporters deliberately have no `ports:` key. All host access
to them — HTTP(S), Postgres, and AMQP — goes through NGINX:

- Port 80/443 → NGINX's `http{}` block (`nginx/conf.d/*.conf`), reverse
  proxying to `pgadmin:80`, `keycloak:8080`, `grafana:3000`, `minio:9000`
  / `minio:9001`, `rabbitmq:15672`, `portainer:9443` (https upstream), and,
  per-app, to whatever apps register.
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
`minio`, `rabbitmq`, `neo4j`, `obsidian`, `grafana`, or other monitoring backends.** If a backend service needs to be reachable from the host, add
an NGINX server block instead (`nginx/conf.d/app.conf.example` is the
template for HTTP; extend `nginx/stream.d/` for raw TCP). This is a
deliberate constraint, not an oversight — keeping every backend-app
host-facing port behind one process is the point of this stack.

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

### Jarvis: Keycloak login gate (oauth2-proxy)

`jarvis.famillelallier.net` (and its `.infra.` alias) is one of the two
application vhosts in this repo that require a login — the other is
Obsidian, which runs the same recipe against a different realm through its
own `oauth2-proxy-ea` container (see the `obsidian` service above). Every
other backend app listed in "Single-ingress rule" above is reachable by
anyone who can resolve its hostname. The gate is the standard
`oauth2-proxy` + NGINX `auth_request` recipe:

- **`keycloak/realm-import/jarvis-realm.json`** — a dedicated realm
  (`jarvis`), separate from `nurse-realm.json`, holding one confidential
  client (`clientId: jarvis`) with a single redirect URI
  (`https://jarvis.famillelallier.net/oauth2/callback`, owned by
  oauth2-proxy, not the Jarvis app itself). It deliberately omits both a
  client `secret` (Keycloak auto-generates one for a confidential client
  on import, so no secret value — even a placeholder — ever lands in git)
  and a `users` array (a real login password shouldn't live in a
  committed JSON file either). Both are manual admin-console steps after
  the first `make up` — see the `JARVIS_OAUTH_CLIENT_SECRET` comment in
  `.env.example`. This mirrors `nurse-realm.json`'s own seed-user
  precedent: `NURSE_SEED_PASSWORD`/`EXAMINER_SEED_PASSWORD` are likewise
  applied after boot via `make keycloak-seed-users`, not baked into the
  realm JSON.
- **`oauth2-proxy` service** (`docker-compose.yml`) — publishes no host
  port; reached only by `nginx` over `infra-net` at
  `oauth2-proxy:4180`. Its own `OAUTH2_PROXY_UPSTREAMS` is a dummy
  (`static://202`) because it's never used as an actual reverse proxy
  here, only as the `auth_request` subrequest target and the handler for
  `/oauth2/*` (sign-in, callback, logout). Points at Keycloak via the
  internal `http://keycloak:8080/realms/jarvis` issuer URL, not the
  external `https://keycloak.famillelallier.net` one, for the same
  same-network reason the `minio` service avoids `MINIO_SERVER_URL`
  (hairpinning back out through NGINX from inside `infra-net`). This
  internal-URL/external-issuer split hits a real Keycloak hostname-v2
  quirk — `KC_HOSTNAME` is set to the full external URL
  (`https://keycloak.famillelallier.net`, not a bare hostname) so the
  discovery document's `issuer` is stable regardless of which request
  triggers it, but that issuer then never matches the internal
  `OIDC_ISSUER_URL` used to fetch it, so strict verification always
  fails. `OAUTH2_PROXY_INSECURE_OIDC_SKIP_ISSUER_VERIFICATION=true` is
  therefore enabled — this is the documented escape hatch, deliberately
  on here rather than the exceptional case. oauth2-proxy's own
  server-to-server calls (token exchange, jwks) hit the endpoints named
  in that discovery doc, i.e. the external `https://keycloak.famillelallier.net`
  hostname — which otherwise has no route from inside `infra-net` — so
  the `nginx` service carries a `keycloak.famillelallier.net` network
  alias pointing that hostname back at itself (it already TLS-terminates
  and proxies it via `nginx/conf.d/keycloak.conf`). Those calls then hit
  the local dev CA (`certs/infra-ca.crt`), which isn't in oauth2-proxy's
  default trust store and whose distroless image has no shell for a
  `--provider-ca-file`-at-build-time trick; instead
  `scripts/gen-certs.sh`'s `gen_oauth2proxy_bundle` bakes a
  `certs/oauth2proxy-ca-bundle.crt` (the image's own CA bundle plus our
  CA) that's bind-mounted over `/etc/ssl/certs/ca-certificates.crt`, so
  every Go `http.Client` in the process picks it up via the system pool.
  The `keycloak` service also carries a `healthcheck` (`/health/ready` on
  its management port, probed with a `/dev/tcp` one-liner since the image
  ships no curl/wget) so `oauth2-proxy` can `depends_on: condition:
  service_healthy` instead of `service_started` — without it, oauth2-proxy
  starts as soon as Keycloak's container process launches, long before its
  HTTP listener is actually up, and its one-shot OIDC discovery call fails
  with a DNS/connection error that only clears on a lucky restart.
- **`nginx/conf.d/jarvis.conf`** — adds `location = /oauth2/auth`
  (internal-only `auth_request` target), `location /oauth2/` (proxies
  sign-in/callback/logout to oauth2-proxy), and gates the existing
  `location /` with `auth_request` + `error_page 401 = /oauth2/sign_in`.
  This only protects the frontend's static-file location — **it does
  not cover the Jarvis backend API or its `GET /ws/ingest-status`
  WebSocket.** Per the Jarvis repo's `frontend/src/useFiles.ts` and
  `frontend/Dockerfile`, `VITE_API_URL` is a browser-facing build-time
  value baked into the static bundle and pointed at the backend's own
  published host port (e.g. `http://localhost:8000`) — the browser calls
  `fetch()`/`new WebSocket()` against that URL directly, never through
  this NGINX vhost. So the usual "`auth_request` breaks WebSocket
  upgrades" failure mode doesn't apply here (there's no `auth_request` on
  a WS route in this file), but it also means logging into the frontend
  page does **not** by itself put the backend API/WebSocket behind
  Keycloak. Verify manually post-deploy: confirm what `VITE_API_URL` the
  deployed frontend was actually built with, and whether that backend
  port is reachable unauthenticated from outside the LAN.

### EA: token verification, no gateway

`keycloak/realm-import/ea-realm.json` seeds a dedicated realm (`ea`),
separate from `jarvis`/`nurse`, for the EA application in the `EA` repo.
It holds three clients — `ea-spa` (public, PKCE, the SPA's browser
sessions), `ea-mcp` (public, PKCE, an agent talking to `/mcp` via the same
authorization-code flow but with a loopback redirect since there is no
browser origin to restrict it to) and `ea-pipelines` (confidential, service
account only — no human ever logs in as it) — plus one realm role,
`ea-editor`, that gates writes (reading the catalogue needs no role). All
three clients carry an `oidc-audience-mapper` stamping `ea-api` into the
access token, because the EA API validates that audience rather than
trusting whichever client requested the token.

Every `redirectUris` entry is an **exact** callback, never a trailing
`*`: Keycloak's match for a trailing `*` is a plain string prefix, so
`http://localhost:*` also matches
`http://localhost:1234@evil.example/callback` (a browser reads `1234` as
userinfo and goes to `evil.example`) — a wildcard redirect is an open
redirect. `ea-spa` lists `https://ea.infra.famillelallier.net/auth/callback`
plus the two Vite-dev loopback forms, all at the SPA's one callback path;
its `post.logout.redirect.uris` attribute holds the matching bare origins,
`##`-joined (Keycloak's multi-value separator for that attribute, not a
JSON array); `webOrigins` stays `["+"]`, which derives allowed CORS origins
from those exact redirect URIs rather than naming its own wildcard. A LAN
origin for the Vite dev server is **not** a missing redirect URI: on plain
http (`http://192.168.x.y:5173`) the SPA cannot even start the login,
because PKCE needs `crypto.subtle` and browsers only expose it in a secure
context — so reach Vite as `http://localhost:5173` (from another machine,
`ssh -L 5173:127.0.0.1:5173 -L 8000:127.0.0.1:8000 <host>`) or through the
https vhost, never by adding the LAN origin in the console (EA
`docs/adr/0032`). `ea-mcp` lists exactly one redirect URI,
`http://localhost:33418/callback` — Claude Code (2.1.270) opens a loopback
callback on the port its own `.mcp.json` pins as `callbackPort` for
`clientId: ea-mcp`; the two numbers must always agree, so changing EA's
`.mcp.json` means changing this realm file (and the live realm) to match,
never the other way only.

Unlike Jarvis, there is **no oauth2-proxy and no `auth_request`** on the
EA vhost itself: the EA API and its `/mcp` transport verify the JWT
themselves (EA `docs/adr/0032`), so `nginx/conf.d/ea.conf` needs no change
and this realm adds no NGINX location *there*. Keycloak is still reached
the normal way, at `https://keycloak.famillelallier.net`.

The realm does have a fourth client that *is* an oauth2-proxy gate,
`ea-obsidian` — but it fronts Obsidian, not EA (see the `obsidian` service
above). It is the one client here with no `ea-api` audience mapper, because
nothing behind that gate calls the EA API; the token is only ever proof
that the person is an `ea` realm user. Its single redirect URI is
`https://obsidian.infra.famillelallier.net/oauth2/callback` — the same
exact-callback rule as every other client in this file, no trailing `*`.

`ea-realm.json` carries a **`users` array**, deliberately, where
`jarvis-realm.json` deliberately has none: `ea-pipelines`'s service
account is not a human who logs in with a password, it is how the worker
itself authenticates, so the only way to hand it the `ea-editor` role at
import time is a `users` entry named `service-account-<clientId>` with
`serviceAccountClientId` set and no `credentials` — Keycloak creates that
user automatically for any client with `serviceAccountsEnabled: true`, and
the import is just attaching a role to the user it will create anyway.
Nothing sensitive lands in the file: no password, and the confidential
client's secret is still Keycloak-generated on import, copied out of the
console afterwards exactly like `jarvis`'s.

`--import-realm` only seeds a realm that does not exist yet — editing this
file after the first `make up` does not touch the live `ea` realm; repeat
the change in the admin console too.

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

pgAdmin, Keycloak, Jarvis, LibreChat, MinIO API, and MinIO console are all
deliberate exceptions to the `.infra.` subdomain convention: they're served at
`pgadmin.famillelallier.net`, `keycloak.famillelallier.net`,
`jarvis.famillelallier.net`, `chat.famillelallier.net`,
`minio.famillelallier.net`, and
`minio-console.famillelallier.net` (no `.infra.`), so those exact hostnames
are added as extra SANs (the `EXTRA_SANS` array) alongside the wildcard in
`gen-certs.sh` rather than being covered by `*.infra.famillelallier.net`.
Regenerating certs (`./scripts/gen-certs.sh --force`) re-issues the leaf
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
that one address — see "`LAN_IP` is the Mac's address now" above.

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
- `chat.famillelallier.net` — apex A record → `LAN_IP`, same exception
  pattern (LibreChat; its admin panel rides the `.infra.` wildcard).

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
