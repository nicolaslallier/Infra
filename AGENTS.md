# AGENTS.md

This repo is a Docker Compose infrastructure stack (NGINX, PostgreSQL 18
with pgvector, pgAdmin, Keycloak, MinIO, RabbitMQ, Neo4j, OpenBao, Portainer,
Technitium DNS, and the LGTM monitoring stack). There is no application code, build,
lint, or unit-test step — the "test" is bringing the stack up and exercising
it.
See `README.md` and `CLAUDE.md` for the architecture and the full list of
`make` targets.

## Cursor Cloud specific instructions

The dependency-refresh update script keeps this environment minimal — it only
ensures the `infra-net` network, dev TLS certs, and `.env` exist (equivalent
to `make init`, which is idempotent). Docker itself is baked into the VM
snapshot, not reinstalled per run. The notes below cover the non-obvious
startup caveats that the update script deliberately does NOT handle.

- **Docker daemon must be started manually each session.** Docker is
  installed in the snapshot, but `dockerd` is not running on boot (a process
  can't survive a snapshot restore). It also needs Docker-in-Docker
  workarounds baked into `/etc/docker/daemon.json` (`fuse-overlayfs` storage
  driver) and `iptables-legacy`. Start it and grant socket access with:
  ```bash
  sudo nohup dockerd >/tmp/dockerd.log 2>&1 &
  sleep 8
  sudo chmod 666 /var/run/docker.sock   # so `docker`/`make` work without sudo this session
  ```
  If `docker ps` errors with a fuse/overlay or iptables message, confirm
  `/etc/docker/daemon.json` sets `"storage-driver": "fuse-overlayfs"` and that
  `update-alternatives --set iptables /usr/sbin/iptables-legacy` (and
  `ip6tables`) has been applied, then restart `dockerd`.

- **`LAN_IP` is set to `127.0.0.1` in `.env` for this VM.** The `dns` service
  publishes ports `53` and `5380` on `${LAN_IP}` and there is no real LAN
  here, so it binds to loopback. Do not set it to the `.env.example`
  placeholder `192.168.1.50` — the container would fail to publish its ports.
  `.env` is gitignored and persists in the snapshot with real dev passwords
  already filled in (no `change-me` values), so `make check-env` / `make up`
  pass out of the box. If `check-env` reports settings that `.env.example`
  defines and `.env` does not, that snapshot predates a service added since:
  append those lines from `.env.example` and fill them in (see "Preflight:
  `make check-env`" in CLAUDE.md) — an absent variable is interpolated into
  the stack as an empty string, which is how a container ends up dying on
  its own config instead of anything naming `.env`.

- **`make config` needs `SKIP_DOCKER_CHECK=1` here.** The stack's normal
  runtime is Docker Desktop on a Mac, and `make config` / `make
  portainer-up` run `scripts/check-docker.sh` first (it asserts the daemon is
  Docker Desktop, its disk image volume is mounted, and the repo is under a
  shared directory). None of that applies to this VM's plain `dockerd`, so
  export `SKIP_DOCKER_CHECK=1` for the session — the compose stack itself is
  portable and needs no other change.

- **Bring the stack up / down here with plain compose:** on the Mac `make up`
  deploys through Portainer's API, which this VM doesn't run — use
  `docker compose up -d` / `docker compose down` instead (`make ps`,
  `make logs s=<service>` still work). First bringing the stack up
  provisions the per-app databases listed in `APP_DATABASES` (`jarvis`,
  `nurse`, `keycloak`, `grafana`). To add a DB to the already-running
  cluster, add `<APP>_DB_PASSWORD` to `.env` then run
  `make provision-app app=<name>` (init scripts only run once on an empty
  volume).

- **Reaching the web UIs.** Everything is fronted by NGINX on `:443` by
  hostname (there are no per-service host ports). Add loopback entries so a
  browser resolves the hostnames — run `make hosts` and append its lines to
  `/etc/hosts` (already done in the snapshot). Then:
  `https://grafana.infra.famillelallier.net` (admin / `GRAFANA_ADMIN_PASSWORD`),
  `https://pgadmin.famillelallier.net`,
  `https://keycloak.famillelallier.net/admin/master/console/`,
  `https://portainer.infra.famillelallier.net`.
  Certs are a self-signed local CA (`certs/infra-ca.crt`), so browsers/`curl`
  need `-k` / trust the CA. For scripted checks, use
  `curl -k --resolve <host>:443:127.0.0.1 https://<host>/...`.

- **Postgres is only reachable through NGINX's TCP passthrough** at
  `127.0.0.1:5432` (bound to loopback), or in-cluster by service name
  `postgres:5432`. AMQP is the same pattern at `127.0.0.1:5672` →
  `rabbitmq:5672`, and Bolt at `127.0.0.1:7687` → `neo4j:7687`. `make psql` opens a superuser shell inside the container.
  Do not add a `ports:` entry to `postgres`/`pgadmin`/`keycloak`/`grafana`
  /`minio`/`rabbitmq`/`neo4j`/`airflow-*`/`openbao`/`portainer` (see `CLAUDE.md` "Single-ingress rule").

- **The vault needs two files this snapshot may not have.** `openbao` reads
  `openbao/seal.key` as a bind-mounted file, and Docker turns a *missing*
  bind-mount source into an empty directory, so the container dies on "is a
  directory" rather than on anything naming the file. `make seal-key`
  generates it (gitignored, so it never arrives with a `git pull`);
  `make check-env` fails the deploy when it is absent. After the stack is up,
  `make vault-init` initialises the vault and writes the root token to
  `.openbao.env`, and `make vault-seed` copies `.env` into it. See
  `CLAUDE.md` "Secrets (OpenBao)" for what the auto-unseal key trades away.
  On the Mac, `make up` renders `.env` from the vault before deploying;
  here the stack comes up with plain compose, so nothing renders and `.env`
  stays hand-edited. `VAULT_RENDER=0` is the opt-out if a `make up` is ever
  run in an environment with no vault.

- **The CD runner is not part of this stack and does not belong on this VM.**
  `docker-compose.runner.yml` (`make runner-up`) registers a self-hosted
  GitHub Actions runner that redeploys the stack through Portainer on a push
  to `main` — it only makes sense on the machine that runs Portainer. Here
  there is no Portainer and nothing to deploy to, so leave it down;
  `.runner.env` is absent and every `runner-*` target refuses without it.
  `scripts/ci-deploy.sh` is that workflow's entry point and is likewise
  meant for the deploy host, not for this VM. See `CLAUDE.md`
  ("CI: deploying on a push to main").

- **DNS zones** are provisioned via the Technitium API, not env vars:
  `make dns-provision` (idempotent), then `make dns-check` to verify
  `*.infra.famillelallier.net`, `pgadmin.`, and `keycloak.` resolve to
  `LAN_IP`.
