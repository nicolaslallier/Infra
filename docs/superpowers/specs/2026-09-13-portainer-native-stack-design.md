# Stack `infra` deployed natively by Portainer (Git, CE)

Status: approved 2026-09-13

## Goal

Portainer CE (2.45 LTS) owns the `infra` stack as a Git-deployed stack
(full control, not "Limited"), instead of `docker compose up` from the
Makefile. Existing data (`infra_*` volumes) is kept.

## Constraints found

- Relative bind-mount paths in Git stacks ("relative path volumes") are
  Business Edition only. In CE, Portainer runs compose from
  `/data/compose/<id>` inside its own container, so `./nginx/...` would
  mount an empty directory. The compose file has 14 relative bind mounts.
- `certs/` and `.env` are gitignored, so a host checkout is required
  regardless: the compose comes from GitHub, mounted files from the host.
- Portainer cannot manage the stack that contains itself (a redeploy would
  stop it mid-deploy).
- The stack name is the compose project name, which prefixes volumes: it
  must be `infra`.
- CE supports polling GitOps; webhooks are BE only. Redeploys from `make`
  go through the REST API with an access token.
- A stack created outside Portainer cannot be adopted; it has to be
  recreated through Portainer.

## Design

### 1. Architecture

- `portainer` moves out of `docker-compose.yml` into
  `docker-compose.portainer.yml` (project `portainer`), started by
  `make portainer-up`. It keeps its data via
  `volumes: portainer-data: name: infra_portainer-data`, stays on
  `infra-net`, publishes no ports. NGINX still resolves it as `portainer`.
- The `infra` stack is a Portainer Git stack: repo
  `https://github.com/nicolaslallier/Infra` (public, no auth), ref
  `refs/heads/main`, file `docker-compose.yml`, name `infra`. GitOps
  polling is **off** — an auto-redeploy on push would run a new compose
  against a not-yet-pulled local checkout.
- `docker-compose.yml` changes:
  - top-level `name: infra` (pins the project name from any worktree);
  - every `./x` bind mount becomes `${INFRA_DIR:-.}/x`; CLI use is
    unchanged, Portainer is given `INFRA_DIR=/Users/nicolaslallier/Claude/Infra`;
  - `postgres` `env_file` lists `.env` and `stack.env`, both
    `required: false`, so the same file works under CLI and Portainer.

### 2. Control: `scripts/portainer-stack.sh` + Makefile

- `.env` stays the source of truth. The script sends its variables plus
  `INFRA_DIR` as the stack's env on every create/redeploy.
- New `.env` key `PORTAINER_API_KEY` (access token created by the user in
  the Portainer UI). `PORTAINER_ENDPOINT_ID` defaults to the local
  environment id.
- API calls run from a throwaway `curlimages/curl` container on
  `infra-net` against `https://portainer:9443` (`-k`): no new host port,
  no dependency on NGINX or DNS, which belong to the stack being deployed.
- Subcommands / targets:
  - `make up` → `up`: create the stack if absent, else Git pull & redeploy.
  - `make down` → `down`: stop the stack.
  - `make pull` → `pull`: redeploy with image pull.
  - `make clean CONFIRM=1` → delete the stack, then remove the project's
    volumes.
- Drift guard: `up`/`pull` refuse unless `INFRA_DIR` is on `main` at the
  same commit as `origin/main` (after `git fetch`).
- `logs`, `ps`, `shell`, `psql`, `restart s=`, `provision-*`, `dns-*`
  stay on `docker compose` (they act on containers, not definitions).
- Errors: any non-2xx API response fails the target and prints Portainer's
  message; Portainer unreachable → hint to run `make portainer-up`.

### 3. Migration (once; short outage; volumes kept)

1. Remove `portainer` from project `infra`; `make portainer-up` with the
   new file.
2. User creates the API token, adds it to `.env`.
3. The compose/script changes are merged to `main` and the main checkout
   (`INFRA_DIR`) is pulled — Portainer deploys what is on GitHub `main`.
4. `docker compose -p infra down` (no `-v`).
5. `make up` → Portainer creates stack `infra`.
6. Verify: all services up/healthy; stack shows full control in Portainer;
   data present (Keycloak realms, `make psql` databases, Grafana, MinIO).

Rollback: delete the stack in Portainer (without volumes), check out the
previous commit, `docker compose up -d`.

### 4. Docs & verification

- Update `CLAUDE.md`, `README.md`, `AGENTS.md`, `.env.example`.
- `make config`, `bash -n scripts/portainer-stack.sh`, then the real
  migration. Step 4 needs explicit user confirmation first (it stops the
  live stack).
- API request bodies are checked against the live Portainer 2.45 before
  any mutating call.
