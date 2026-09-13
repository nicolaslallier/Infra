# Portainer-native `infra` stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Portainer CE deploys and owns the `infra` stack from GitHub `main`; `make up/down/pull/clean` drive it through Portainer's API.

**Architecture:** Portainer moves to its own compose project (it cannot redeploy the stack that contains it). `docker-compose.yml` becomes deployable from Portainer's Git clone by pinning `name: infra` and prefixing bind mounts with `${INFRA_DIR:-.}` (CE has no relative-path volumes). `scripts/portainer-stack.sh` calls the API from a throwaway curl container on `infra-net`, sending `.env` as the stack env.

**Tech Stack:** Docker Compose v5, Portainer CE 2.45 LTS REST API, bash, jq (host), `curlimages/curl:8.5.0`.

**Spec:** `docs/superpowers/specs/2026-09-13-portainer-native-stack-design.md`

## Global Constraints

- Stack name / compose project: `infra` (reuses `infra_*` volumes).
- Git: `https://github.com/nicolaslallier/Infra`, ref `refs/heads/main`, file `docker-compose.yml`, no auth, GitOps polling off.
- Portainer: `portainer/portainer-ce:lts`, volume `infra_portainer-data`, on `infra-net`, **no `ports:`** (single-ingress rule).
- API from `https://portainer:9443/api` with header `X-API-Key`, never via NGINX.
- `.env` is the source of truth; `PORTAINER_*` keys are never sent to the stack.
- `make clean` must never delete `infra_portainer-data`.
- No push, PR, merge, or stopping the live stack without explicit user confirmation.

API facts (Portainer 2.45 source, `api/http/handler/stacks/`):
- `GET /stacks` → `[{Id, Name, Status (1 active, 2 inactive), ...}]`
- `GET /endpoints` → `[{Id, Type (1 = local Docker), ...}]`
- `POST /stacks/create/standalone/repository?endpointId=N` body `{Name, RepositoryURL, RepositoryReferenceName, ComposeFile, RepositoryAuthentication, Env:[{name,value}]}`. Name must be unique **including running compose projects** — the CLI-run `infra` containers must be down first.
- `PUT /stacks/{id}/git/redeploy?endpointId=N` body `{RepositoryReferenceName, RepositoryAuthentication, Env, Prune, RepullImageAndRedeploy}`
- `POST /stacks/{id}/start|stop?endpointId=N`, `DELETE /stacks/{id}?endpointId=N`

---

### Task 1: Move Portainer into its own compose project

**Files:**
- Create: `docker-compose.portainer.yml`
- Modify: `docker-compose.yml:435-452` (remove `portainer` service), `docker-compose.yml:469` (remove `portainer-data` volume)
- Modify: `Makefile` (`portainer-*` targets)

**Interfaces:**
- Produces: `make portainer-up|down|restart|logs` operating on project `portainer`; container reachable as `portainer` on `infra-net`.

- [ ] **Step 1: Check the failing condition**

Run: `docker compose --env-file .env.example config --services | grep -x portainer`
Expected: prints `portainer` (still in the main stack — this is what we remove).

- [ ] **Step 2: Create `docker-compose.portainer.yml`**

```yaml
# Portainer runs as its own compose project, outside the "infra" stack it
# deploys: a stack redeploy must never stop the thing running it. See
# CLAUDE.md "Portainer-managed stack".
name: portainer

services:
  portainer:
    # 'lts' is Portainer's own long-term-support channel tag -- same
    # moving-tag tradeoff as minio/dns in docker-compose.yml, and the tag
    # Portainer documents for anything that isn't a throwaway test.
    image: portainer/portainer-ce:lts
    restart: unless-stopped
    # Read-write on purpose: Portainer *is* a Docker control plane, so it
    # needs to start/stop/exec containers, not just read their state. That
    # makes the UI equivalent to root on this host's Docker daemon -- it is
    # reachable only through NGINX (no 'ports:' here, per the single-ingress
    # rule) and behind Portainer's own admin account.
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer-data:/data
    networks:
      - infra-net

networks:
  infra-net:
    external: true

volumes:
  portainer-data:
    # Named for the infra project it used to live in; holds the admin
    # account and the infra stack's definition. 'make portainer-up' creates
    # it if missing.
    name: infra_portainer-data
    external: true
```

- [ ] **Step 3: Remove `portainer` from `docker-compose.yml`**

Delete lines 435-452 (the `# --- Docker management UI ...` comment through the `portainer:` service's `networks:` block) and the `  portainer-data:` line under top-level `volumes:`.

- [ ] **Step 4: Point the Makefile's `portainer-*` targets at the new file**

Replace the four targets (Makefile lines ~152-172) with:

```make
PORTAINER_COMPOSE := docker compose -f docker-compose.portainer.yml

portainer-up: check-docker net ## Start Portainer (its own compose project)
	@docker volume create infra_portainer-data >/dev/null
	$(PORTAINER_COMPOSE) up -d
	@echo
	@echo "Portainer -> https://$(PORTAINER_HOST)"
	@echo
	@echo "It publishes no host port (single-ingress rule), so nginx has to be"
	@echo "running to reach it in a browser; 'make up' itself talks to it"
	@echo "directly over infra-net and does not need nginx."
	@echo "On a first start, create the admin account within a few minutes --"
	@echo "Portainer locks itself out otherwise, and 'make portainer-restart'"
	@echo "reopens that window."

portainer-down: ## Stop Portainer (keeps its volume)
	$(PORTAINER_COMPOSE) down

portainer-restart: ## Restart Portainer
	$(PORTAINER_COMPOSE) restart

portainer-logs: ## Tail Portainer's logs
	$(PORTAINER_COMPOSE) logs -f
```

(`check-env` is dropped from `portainer-up`: the file interpolates no `.env` value.)

- [ ] **Step 5: Verify**

Run:
```bash
docker compose --env-file .env.example config --services | grep -x portainer || echo "not in infra: ok"
docker compose -f docker-compose.portainer.yml config --quiet && echo "portainer file: ok"
make -n portainer-up portainer-down
```
Expected: `not in infra: ok`, `portainer file: ok`, dry-run shows `docker compose -f docker-compose.portainer.yml up -d` / `down`.

- [ ] **Step 6: Commit**

```bash
git add docker-compose.portainer.yml docker-compose.yml Makefile
git commit -m "Run Portainer as its own compose project

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Make `docker-compose.yml` deployable from Portainer's Git clone

**Files:**
- Modify: `docker-compose.yml` (top: `name:`; lines 16-20, 80, 167, 187-191, 243, 253, 263, 277, 303, 425)

**Interfaces:**
- Produces: compose honours `INFRA_DIR` (absolute checkout path) for every repo bind mount; project name fixed to `infra`; `postgres` reads `.env` or `stack.env`, whichever exists.

- [ ] **Step 1: Check the failing condition**

Run: `INFRA_DIR=/probe docker compose --env-file .env.example config | grep -c '/probe/'`
Expected: `0` (INFRA_DIR is not honoured yet).

- [ ] **Step 2: Pin the project name**

Insert at the very top of `docker-compose.yml`:

```yaml
# Pinned so the CLI (from any checkout or worktree) and Portainer's stack
# "infra" address the same project -- and the same infra_* volumes.
name: infra

```

- [ ] **Step 3: Prefix every repo bind mount with `${INFRA_DIR:-.}`**

Run:
```bash
sed -i '' -E 's#^(      - )\./#\1${INFRA_DIR:-.}/#' docker-compose.yml
```
Then add, directly above `services:`, after the `name:` block:

```yaml
# Repo bind mounts are ${INFRA_DIR:-.}/...: Portainer CE runs compose from
# its own Git clone inside its container, where ./ is not on the host
# (relative-path volumes are Business Edition only). make up passes
# INFRA_DIR=<this checkout>; plain CLI use falls back to ./.
```

- [ ] **Step 4: Make `postgres`'s env file work under both CLI and Portainer**

Replace:
```yaml
    env_file:
      - .env
```
with:
```yaml
    # .env under the CLI, stack.env (written by Portainer from the stack's
    # env) under Portainer -- the per-app <APP>_DB_PASSWORD names are
    # dynamic, so they can't be listed under environment:.
    env_file:
      - path: .env
        required: false
      - path: stack.env
        required: false
```

- [ ] **Step 5: Verify**

Run:
```bash
grep -nE '^\s+- \./' docker-compose.yml || echo "no ./ mounts left: ok"
INFRA_DIR=/probe docker compose --env-file .env.example config | grep -c '/probe/'
docker compose --env-file .env.example config | grep -m1 'source: .*/nginx/nginx.conf'
docker compose --env-file .env.example config | grep -m1 '^name:'
```
Expected: `no ./ mounts left: ok`; count `14`; nginx.conf source is this worktree's absolute path; `name: infra`.

- [ ] **Step 6: Commit**

```bash
git add docker-compose.yml
git commit -m "Make docker-compose.yml deployable from Portainer's Git clone

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: `scripts/portainer-stack.sh`

**Files:**
- Create: `scripts/portainer-stack.sh`

**Interfaces:**
- Consumes: `.env` with `PORTAINER_API_KEY` (and optional `PORTAINER_ENDPOINT_ID`); compose from Task 2 (`INFRA_DIR`).
- Produces: `scripts/portainer-stack.sh up|pull|down|delete|selftest`. Exit 0 on success, 1 with a `portainer-stack.sh: ...` message on stderr otherwise.

- [ ] **Step 1: Write the self-check first, with a stub**

Create `scripts/portainer-stack.sh`:

```bash
#!/usr/bin/env bash
# Drive the "infra" stack through Portainer's API. Portainer CE deploys
# docker-compose.yml from GitHub main; the files that compose bind-mounts
# come from this checkout (INFRA_DIR). See CLAUDE.md "Portainer-managed
# stack".
#
# Usage: scripts/portainer-stack.sh up|pull|down|delete|selftest
#   up      create the stack, or pull main and redeploy it
#   pull    redeploy, re-pulling every image
#   down    stop the stack (volumes kept)
#   delete  remove the stack from Portainer (volumes kept)
set -euo pipefail
cd "$(dirname "$0")/.."

STACK=infra
REPO_URL=https://github.com/nicolaslallier/Infra
REF=refs/heads/main
CURL_IMAGE=curlimages/curl:8.5.0

die() { printf 'portainer-stack.sh: %b\n' "$*" >&2; exit 1; }

env_json() { # <env-file> <infra-dir>
  echo '[]'
}

selftest() {
  local tmp got want
  tmp="$(mktemp -d)"
  printf '%s\n' '# comment' '' 'A=1' 'URL=postgres://u:p@h/db?x=y' 'EMPTY=' \
    'PORTAINER_API_KEY=secret' 'INFRA_DIR=/stale' '  INDENTED=no' >"$tmp/env"
  got="$(env_json "$tmp/env" /repo | jq -c .)"
  rm -rf "$tmp"
  want='[{"name":"A","value":"1"},{"name":"URL","value":"postgres://u:p@h/db?x=y"},{"name":"EMPTY","value":""},{"name":"INFRA_DIR","value":"/repo"}]'
  [ "$got" = "$want" ] || die "selftest: env_json\n  got:  $got\n  want: $want"
  echo "portainer-stack.sh: selftest ok"
}

case "${1:-}" in
  selftest) selftest; exit 0 ;;
esac
```

- [ ] **Step 2: Run it to see it fail**

Run: `chmod +x scripts/portainer-stack.sh && scripts/portainer-stack.sh selftest`
Expected: exit 1, `selftest: env_json` with `got:  []`.

- [ ] **Step 3: Implement `env_json`**

Replace the stub with:

```bash
# .env -> Portainer's [{name,value}] stack env: KEY=VALUE lines only, minus
# this script's own PORTAINER_* settings (never handed to containers) and
# any stale INFRA_DIR, plus INFRA_DIR pointing at this checkout.
env_json() { # <env-file> <infra-dir>
  jq -Rn --arg dir "$2" '
    [inputs
     | select(test("^[A-Za-z_][A-Za-z0-9_]*="))
     | capture("^(?<name>[^=]+)=(?<value>.*)$")
     | select(((.name | startswith("PORTAINER_")) or .name == "INFRA_DIR") | not)]
    + [{name: "INFRA_DIR", value: $dir}]' <"$1"
}
```

- [ ] **Step 4: Run it to see it pass**

Run: `scripts/portainer-stack.sh selftest`
Expected: `portainer-stack.sh: selftest ok`

- [ ] **Step 5: Add the API client, drift guard and commands**

Replace the trailing `case` block with:

```bash
# Runs curl in a throwaway container on infra-net, so deploying never
# depends on nginx or dns -- both are part of the stack being deployed.
# The key travels as an env var, not a command-line argument.
api() { # <method> <path> [json-body]
  printf '%s' "${3:-}" | docker run --rm -i --network infra-net \
    -e PORTAINER_API_KEY --entrypoint sh "$CURL_IMAGE" -c '
      out="$(curl -sSk --fail-with-body -X "$1" \
        -H "X-API-Key: $PORTAINER_API_KEY" -H "Content-Type: application/json" \
        --data-binary @- "https://portainer:9443/api$2" 2>&1)" \
        || { printf "%s\n" "$out" >&2; exit 1; }
      printf "%s" "$out"' sh "$1" "$2" \
    || die "$1 $2 failed (is Portainer up? 'make portainer-up')"
}

# Portainer deploys GitHub main while the mounted configs come from this
# checkout: refuse to deploy whenever the two could differ.
check_synced() {
  local branch
  branch="$(git rev-parse --abbrev-ref HEAD)"
  [ "$branch" = main ] || die "this checkout is on '$branch'; Portainer deploys main"
  git diff --quiet HEAD || die "uncommitted changes here would not match what Portainer deploys"
  git fetch -q origin main
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
    || die "this checkout is not at origin/main -- 'git pull --ff-only' (or push) first"
}

cmd="${1:-}"
case "$cmd" in
  selftest) selftest; exit 0 ;;
  up|pull|down|delete) ;;
  *) die "usage: scripts/portainer-stack.sh up|pull|down|delete|selftest" ;;
esac

[ -f .env ] || die ".env not found (run 'make init' first)"
set -a; . ./.env; set +a
if [ -z "${PORTAINER_API_KEY:-}" ] || [ "$PORTAINER_API_KEY" = change-me ]; then
  die "set PORTAINER_API_KEY in .env (Portainer -> My account -> Access tokens)"
fi

eid="${PORTAINER_ENDPOINT_ID:-$(api GET /endpoints | jq -r '[.[] | select(.Type == 1)][0].Id // empty')}"
[ -n "$eid" ] || die "no local Docker environment found in Portainer"
stack="$(api GET /stacks | jq -c --arg n "$STACK" 'first(.[] | select(.Name == $n)) // empty')"
sid=""
[ -z "$stack" ] || sid="$(jq -r .Id <<<"$stack")"

case "$cmd" in
  up|pull)
    check_synced
    env="$(env_json .env "$PWD")"
    if [ -z "$sid" ]; then
      [ "$cmd" = up ] || die "stack '$STACK' does not exist yet -- 'make up' first"
      body="$(jq -n --arg name "$STACK" --arg url "$REPO_URL" --arg ref "$REF" --argjson env "$env" \
        '{Name: $name, RepositoryURL: $url, RepositoryReferenceName: $ref,
          ComposeFile: "docker-compose.yml", RepositoryAuthentication: false, Env: $env}')"
      api POST "/stacks/create/standalone/repository?endpointId=$eid" "$body" >/dev/null
      echo "portainer-stack.sh: created stack '$STACK' from $REPO_URL ($REF)"
    else
      if [ "$(jq -r .Status <<<"$stack")" = 2 ]; then
        api POST "/stacks/$sid/start?endpointId=$eid" >/dev/null
      fi
      body="$(jq -n --arg ref "$REF" --argjson env "$env" --argjson pull "$([ "$cmd" = pull ] && echo true || echo false)" \
        '{RepositoryReferenceName: $ref, RepositoryAuthentication: false, Env: $env,
          Prune: false, RepullImageAndRedeploy: $pull}')"
      api PUT "/stacks/$sid/git/redeploy?endpointId=$eid" "$body" >/dev/null
      echo "portainer-stack.sh: redeployed stack '$STACK' at $(git rev-parse --short HEAD)"
    fi
    ;;
  down)
    [ -n "$sid" ] || die "stack '$STACK' does not exist in Portainer"
    api POST "/stacks/$sid/stop?endpointId=$eid" >/dev/null
    echo "portainer-stack.sh: stopped stack '$STACK'"
    ;;
  delete)
    [ -n "$sid" ] || { echo "portainer-stack.sh: no stack '$STACK' in Portainer"; exit 0; }
    api DELETE "/stacks/$sid?endpointId=$eid" >/dev/null
    echo "portainer-stack.sh: deleted stack '$STACK' from Portainer"
    ;;
esac
```

- [ ] **Step 6: Verify offline**

Run:
```bash
bash -n scripts/portainer-stack.sh && echo "syntax ok"
scripts/portainer-stack.sh selftest
scripts/portainer-stack.sh bogus; echo "exit=$?"
command -v shellcheck >/dev/null && shellcheck scripts/portainer-stack.sh
```
Expected: `syntax ok`; `selftest ok`; usage message with `exit=1`; shellcheck clean (if installed).

- [ ] **Step 7: Verify read-only against live Portainer (no mutation)**

Only once a token exists (Task 6 Step 2). From the main checkout:
```bash
set -a; . ./.env; set +a
docker run --rm --network infra-net -e PORTAINER_API_KEY --entrypoint sh curlimages/curl:8.5.0 \
  -c 'curl -sSk -H "X-API-Key: $PORTAINER_API_KEY" https://portainer:9443/api/endpoints' | jq '[.[] | {Id, Name, Type}]'
```
Expected: one entry with `Type: 1`. If field names differ from the "API facts" above, fix the script before Task 6 Step 5.

- [ ] **Step 8: Commit**

```bash
git add scripts/portainer-stack.sh
git commit -m "Add portainer-stack.sh to drive the infra stack via Portainer's API

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Route `make up/down/pull/clean` through Portainer

**Files:**
- Modify: `Makefile` (`up`, `down`, `pull`, `clean` targets and `.PHONY`)
- Modify: `.env.example` (append Portainer API block)

**Interfaces:**
- Consumes: `scripts/portainer-stack.sh up|pull|down|delete` (Task 3).

- [ ] **Step 1: Replace the lifecycle targets**

```make
up: check-env check-docker net ## Deploy/redeploy the stack via Portainer (Git main)
	./scripts/portainer-stack.sh up

down: ## Stop the stack via Portainer (keeps volumes)
	./scripts/portainer-stack.sh down

pull: ## Redeploy via Portainer, re-pulling images
	./scripts/portainer-stack.sh pull
```

```make
# Deleting the Portainer stack only removes its containers; 'down -v' then
# drops the volumes docker-compose.yml declares -- infra_portainer-data is
# no longer one of them, so Portainer keeps its data.
clean: ## Delete the stack and its volumes (CONFIRM=1 required)
	@test "$(CONFIRM)" = "1" || { echo "usage: make clean CONFIRM=1" >&2; exit 1; }
	./scripts/portainer-stack.sh delete
	docker compose down -v
```

`restart`, `logs`, `ps`, `status`, `config`, `shell`, `psql`, `provision-*`, `dns-*` stay unchanged (`name: infra` makes them hit the right project).

- [ ] **Step 2: Append to `.env.example`**

```bash
# --- Portainer API (make up / down / pull / clean) ---
# Portainer deploys this stack from GitHub main (CLAUDE.md "Portainer-managed
# stack"). After 'make portainer-up' and creating the admin account, create a
# token under Portainer -> My account -> Access tokens and paste it here.
# PORTAINER_* values are never passed to the stack's containers.
PORTAINER_API_KEY=change-me
# Optional: Portainer environment id; defaults to the local Docker one.
# PORTAINER_ENDPOINT_ID=1
```

- [ ] **Step 3: Verify**

Run:
```bash
make -n up | tail -1
make -n down pull
make clean; echo "exit=$?"
make -n clean CONFIRM=1
```
Expected: `./scripts/portainer-stack.sh up`; down/pull lines; `usage: make clean CONFIRM=1` with `exit=2`; clean dry-run shows `delete` then `docker compose down -v`.

- [ ] **Step 4: Commit**

```bash
git add Makefile .env.example
git commit -m "Route make up/down/pull/clean through Portainer

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Documentation

**Files:**
- Modify: `CLAUDE.md` (Commands block lines 17-34, `portainer` bullet lines 76-90, `check-docker` mention line 227, new section after "Runtime: Docker Desktop")
- Modify: `README.md` (table lines 195-211, Portainer section 254-290, layout line 327)
- Modify: `AGENTS.md` (lines 39-56)

- [ ] **Step 1: CLAUDE.md commands block**

Replace the `make up / make down / make restart` and `make pull` and `make clean` lines with:
```
make up / make down              # deploy-or-redeploy / stop the stack via Portainer (Git main)
make restart                     # docker compose restart (optional: s=<service>)
make pull / make config          # redeploy re-pulling images / validate compose + .env
make portainer-up / -down        # Portainer itself (its own compose project)
make clean CONFIRM=1             # delete the Portainer stack + its volumes (keeps Portainer, infra-net, certs/)
```

- [ ] **Step 2: CLAUDE.md `portainer` bullet**

Replace its last sentence (`make portainer-up` / `-down` / ...) with:
"It is **not** part of `docker-compose.yml`: it lives in
`docker-compose.portainer.yml` (project `portainer`, volume
`infra_portainer-data`) because it deploys the `infra` stack and a redeploy
must never stop it. `make portainer-up` / `-down` / `-restart` / `-logs`
drive it."

- [ ] **Step 3: CLAUDE.md new section `### Portainer-managed stack`** (after "Runtime: Docker Desktop", before "Single-ingress rule")

```markdown
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
  `.env` are gitignored and could not come from Git anyway.
- **The drift guard.** Because of that split, `make up` / `pull` refuse
  unless the checkout is on `main`, clean, and at `origin/main`. Merge,
  `git pull --ff-only`, then `make up`. It is also why polling stays off:
  a push would redeploy against configs that haven't been pulled yet.
- **`name: infra`** pins the project, so the stack name, the CLI targets
  that still use `docker compose` (`logs`, `ps`, `shell`, `psql`,
  `restart`, `provision-*`) and the `infra_*` volume names all agree from
  any worktree. Renaming the stack means starting from empty volumes.
- **`.env` stays the source of truth.** Every `up` / `pull` sends it as the
  stack env (Portainer writes it to `stack.env`, hence the two optional
  `env_file` entries on `postgres`). Edits made in Portainer's env editor
  are overwritten on the next `make up`. `PORTAINER_*` keys are filtered
  out.
- **API calls go through a throwaway `curlimages/curl` container on
  `infra-net`** to `https://portainer:9443`, not through NGINX or a hostname:
  both nginx and dns are *in* the stack being deployed.
- **Portainer refuses to create a stack whose name matches a running
  compose project**, so containers started by the CLI as project `infra`
  must be `docker compose down` first (volumes untouched).
- **`make clean`** deletes the Portainer stack, then `docker compose down
  -v`, which only removes volumes `docker-compose.yml` declares.
  `infra_portainer-data` still carries the `infra` project label from
  before the split, so never clean up by label.
- **Non-Mac environments** (CI, the cloud VM in `AGENTS.md`) have no
  Portainer stack: run `docker compose up -d` directly there.
```

- [ ] **Step 4: CLAUDE.md line 227**

`(a prerequisite of \`up\`, \`config\` and \`portainer-up\`)` is still true — leave it.

- [ ] **Step 5: README.md**

Table rows become:
```
| `make up` / `make down` | Deploy-or-redeploy / stop the stack **via Portainer** (Git `main`; `up` checks `.env`, Docker Desktop and that this checkout is at `origin/main`) |
| `make pull` | Redeploy via Portainer, re-pulling images |
| `make clean CONFIRM=1` | Delete the Portainer stack and its volumes (destructive; keeps Portainer, `infra-net` and `certs/`) |
| `make portainer-up` / `make portainer-down` | Start / stop Portainer (its own compose project, `docker-compose.portainer.yml`) |
```
In "## Portainer", replace "`make up` starts it along with everything else; the targets above exist for when you only want this one service." with:
"Portainer is not part of `docker-compose.yml`: it *deploys* that stack.
Start it first, create the admin account, then create an access token
(My account → Access tokens) and set `PORTAINER_API_KEY` in `.env` —
`make up` needs it. See CLAUDE.md \"Portainer-managed stack\" for why bind
mounts use `${INFRA_DIR}` and why `make up` insists on `origin/main`."
In the layout block (line 327) remove `portainer` from the docker-compose.yml line and add:
`docker-compose.portainer.yml  portainer (deploys the stack above)` and
`scripts/portainer-stack.sh    make up/down/pull/clean via Portainer's API`.

- [ ] **Step 6: AGENTS.md**

Replace the "**Bring the stack up / down:**" bullet's first sentence with:
"**Bring the stack up / down here with plain compose:** on the Mac `make up`
deploys through Portainer's API, which this VM doesn't run — use
`docker compose up -d` / `docker compose down` instead (`make ps`,
`make logs s=<service>` still work)."
And in the `SKIP_DOCKER_CHECK` bullet change "`make up` / `make config` / `make portainer-up`" to "`make config` / `make portainer-up`".

- [ ] **Step 7: Verify & commit**

```bash
grep -rn "make up.*starts it along" README.md || echo "stale sentence gone"
git add CLAUDE.md README.md AGENTS.md
git commit -m "Document the Portainer-managed stack

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Live migration (gated — ask the user before Steps 1, 4 and 5)

**Files:** none (operations).

- [ ] **Step 1: Ship the branch** — with user approval: push, open PR, user merges. Then in the main checkout:
```bash
git -C /Users/nicolaslallier/Claude/Infra pull --ff-only
```

- [ ] **Step 2: Move Portainer** (short Portainer-only outage) — from `/Users/nicolaslallier/Claude/Infra`:
```bash
docker rm -f infra-portainer-1
make portainer-up
docker ps --filter name=portainer-portainer-1 --format '{{.Names}} {{.Status}}'
```
Expected: `portainer-portainer-1 Up`. User logs in at `https://portainer.infra.famillelallier.net` with the existing admin account (same volume), creates an access token, adds `PORTAINER_API_KEY=...` to `.portainer.env`. Then run Task 3 Step 7.

- [ ] **Step 3: Snapshot pre-migration state**
```bash
docker ps --format '{{.Names}}' | grep '^infra-' | sort > /tmp/infra-before.txt; wc -l /tmp/infra-before.txt
docker exec -i infra-postgres-1 sh -c 'psql -U "$POSTGRES_USER" -lqt' | cut -d'|' -f1 | grep -wE 'jarvis|nurse|keycloak|grafana'
```
Expected: 17 containers (Portainer already moved out); 4 databases.

- [ ] **Step 4: Stop the CLI-run stack** (full outage incl. LAN DNS — **ask first**)
```bash
docker compose down
docker ps --format '{{.Names}}' | grep '^infra-' || echo "infra down"
```

- [ ] **Step 5: Create the stack in Portainer**
```bash
make up
```
Expected: `created stack 'infra' from https://github.com/nicolaslallier/Infra (refs/heads/main)`.

- [ ] **Step 6: Verify**
```bash
sleep 90
docker ps --format '{{.Names}}' | grep '^infra-' | sort | diff /tmp/infra-before.txt - && echo "same containers"
docker ps --format '{{.Names}} {{.Status}}' | grep '^infra-' | grep -vE 'Up' || echo "all up"
docker inspect infra-nginx-1 --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' | grep conf.d
docker exec infra-nginx-1 ls /etc/nginx/conf.d | head -3
docker exec -i infra-postgres-1 sh -c 'psql -U "$POSTGRES_USER" -lqt' | cut -d'|' -f1 | grep -wE 'jarvis|nurse|keycloak|grafana'
curl -sk -o /dev/null -w '%{http_code}\n' --resolve keycloak.famillelallier.net:443:127.0.0.1 https://keycloak.famillelallier.net/realms/jarvis/.well-known/openid-configuration
curl -sk --resolve grafana.infra.famillelallier.net:443:127.0.0.1 https://grafana.infra.famillelallier.net/api/health
make dns-check
```
Expected: same containers; all up; mount source `/Users/nicolaslallier/Claude/Infra/nginx/conf.d`; conf files listed; 4 databases; `200`; Grafana `"database": "ok"`; dns-check passes. In the Portainer UI, stack `infra` shows Git source and full control.

- [ ] **Step 7: Redeploy idempotence**
```bash
make up
```
Expected: `redeployed stack 'infra' at <sha>`; every container is recreated
(Portainer's git-redeploy always forces this — expect a brief outage
including a momentary LAN DNS drop), so verify they all come back up
rather than expecting them to stay up.

**Rollback** (if Step 5/6 fails): `scripts/portainer-stack.sh delete` (volumes kept), then `docker compose up -d` from the main checkout, and `git revert` the merge if needed.
