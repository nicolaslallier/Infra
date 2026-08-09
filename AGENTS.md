# AGENTS.md

This repo is a Docker Compose infrastructure stack (NGINX, PostgreSQL 18
with pgvector, pgAdmin, Keycloak, Technitium DNS, and the LGTM monitoring
stack). There is no application code, build, lint, or unit-test step — the
"test" is bringing the stack up and exercising it. See `README.md` and
`CLAUDE.md` for the architecture and the full list of `make` targets.

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
  pass out of the box.

- **Bring the stack up / down:** `make up` (runs `check-env` first) and
  `make down`. `make ps` for status, `make logs s=<service>` to tail one
  service. First `make up` provisions the per-app databases listed in
  `APP_DATABASES` (`jarvis`, `nurse`, `keycloak`, `grafana`). To add a DB to
  the already-running cluster, add `<APP>_DB_PASSWORD` to `.env` then run
  `make provision-app app=<name>` (init scripts only run once on an empty
  volume).

- **Reaching the web UIs.** Everything is fronted by NGINX on `:443` by
  hostname (there are no per-service host ports). Add loopback entries so a
  browser resolves the hostnames — run `make hosts` and append its lines to
  `/etc/hosts` (already done in the snapshot). Then:
  `https://grafana.infra.famillelallier.net` (admin / `GRAFANA_ADMIN_PASSWORD`),
  `https://pgadmin.famillelallier.net`,
  `https://keycloak.famillelallier.net/admin/master/console/`.
  Certs are a self-signed local CA (`certs/infra-ca.crt`), so browsers/`curl`
  need `-k` / trust the CA. For scripted checks, use
  `curl -k --resolve <host>:443:127.0.0.1 https://<host>/...`.

- **Postgres is only reachable through NGINX's TCP passthrough** at
  `127.0.0.1:5432` (bound to loopback), or in-cluster by service name
  `postgres:5432`. `make psql` opens a superuser shell inside the container.
  Do not add a `ports:` entry to `postgres`/`pgadmin`/`keycloak`/`grafana`
  (see `CLAUDE.md` "Single-ingress rule").

- **DNS zones** are provisioned via the Technitium API, not env vars:
  `make dns-provision` (idempotent), then `make dns-check` to verify
  `*.infra.famillelallier.net`, `pgadmin.`, and `keycloak.` resolve to
  `LAN_IP`.
