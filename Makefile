SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

.DEFAULT_GOAL := help

# Prerequisites are made left to right only in a serial build, and 'up'
# depends on that: vault-render writes the .env that check-env then reads.
.NOTPARALLEL:

.PHONY: help test init net certs seal-key app-images up down restart logs ps status pull config \
	shell psql provision-app provision-monitoring-role provision-litellm-rag hosts dns-provision \
	dns-check clean check-env check-docker docker-start docker-stop \
	migrate-volumes keycloak-seed-users s3-provision ntfy-provision rabbitmq-provision \
	vault-init vault-seed vault-oidc vault-seed-ea vault-env vault-render vault-status vault-cli vault-backup-token \
	portainer-up portainer-down portainer-restart portainer-logs \
	runners-up runners-down runners-restart runners-logs runners-status runners-pull \
	runners-env \
	dev-image dev-up dev-down dev-test

# Portainer's hostname, served by nginx/conf.d/portainer.conf. Covered by
# the wildcard cert and the wildcard DNS zone -- no per-host setup needed.
PORTAINER_HOST ?= portainer.infra.famillelallier.net

# The stack runs on Docker Desktop on the Windows laptop (laptop-dopbpc0j).
# From the Mac, every docker/compose call -- and so the Portainer API calls,
# which run in a curl container -- goes there over SSH (key auth required).
# 'make DOCKER_HOST=' targets the local daemon instead.
INFRA_HOST ?= 192.168.2.10
INFRA_SSH_USER ?= this
ifeq ($(shell uname -s),Darwin)
export DOCKER_HOST ?= ssh://$(INFRA_SSH_USER)@$(INFRA_HOST)
# The laptop's checkout (C:\Users\nicol\OpenCode\Infra) as its Docker
# Desktop VM sees it: Portainer bind-mounts from there, not from this Mac
# checkout, so 'make up'/'pull' first fast-forward it to origin/main
# (sync_host_checkout in scripts/portainer-stack.sh). Not under
# 'make DOCKER_HOST=': the local daemon mounts this checkout.
ifneq ($(DOCKER_HOST),)
export PORTAINER_INFRA_DIR ?= /run/desktop/mnt/host/c/Users/nicol/OpenCode/Infra
endif
endif

##@ Setup & host
help: ## Show available targets, grouped
	@awk 'BEGIN {FS = ":.*## "} \
		/^##@ / {printf "\n\033[1m%s\033[0m\n", substr($$0, 5)} \
		/^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-26s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

init: net app-volumes app-images certs seal-key ## Create network, volumes, certs, OpenBao's seal key, and .env
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		echo "Created .env — edit passwords, LAN_IP, and DNS_ADMIN_PASSWORD before 'make up'."; \
	else \
		echo ".env already exists, left untouched — 'make check-env' lists the settings .env.example has gained since."; \
	fi

net: ## Ensure infra-net exists and Portainer is on it (via Portainer's API)
	@INFRA_HOST=$(INFRA_HOST) ./scripts/portainer-net.sh

# Volumes an app stack writes and this stack reads, declared external in both
# so the name is the same on each side (the way infra-net is). Compose does not
# create an external volume: a missing one fails `make up` for the whole stack,
# not just the vhost that wants it -- hence a prerequisite, not a note.
app-volumes: ## Ensure the external volumes shared with app stacks exist (via Portainer's API)
	@INFRA_HOST=$(INFRA_HOST) ./scripts/portainer-volumes.sh

# Images compose references but cannot pull. ollama-proxy is built from a
# pinned commit of nicolaslallier/ollama-metrics, which publishes no image,
# and here rather than via `build:` because Portainer's
# Git stacks do not reliably build. Change the commit here and the tag in
# docker-compose.yml together; a tag already on the daemon is not rebuilt.
OLLAMA_PROXY_REF := 2762bfb3c5d5d044a1380d17e89fd303687b2c12
# litellm-pgvector (BerriAI/litellm-pgvector, no published image): the
# OpenAI-compatible vector store API LiteLLM's pg_vector provider talks to.
# Same rule: change the commit here and the tag in docker-compose.platform.yml together.
LITELLM_PGVECTOR_REF := 5bd8f3ab1fa9129e758a2c4b17ba1c6f3047ba24
app-images: ## Build the images the stack references but cannot pull (via Portainer's API)
	@INFRA_HOST=$(INFRA_HOST) OLLAMA_PROXY_REF=$(OLLAMA_PROXY_REF) LITELLM_PGVECTOR_REF=$(LITELLM_PGVECTOR_REF) ./scripts/portainer-images.sh

dev-image: ## Build the dev images (session, proxy, gateway) on the Mac Studio from main (DEV_IMAGE_REF=<ref>; FORCE=1 rebuilds existing tags)
	@INFRA_HOST=$(INFRA_HOST) PORTAINER_ENDPOINT_ID=$(DEV_ENDPOINT) FORCE=$(FORCE) ./scripts/portainer-images.sh dev

certs: ## Generate TLS certs (FORCE=1 to regenerate)
	@./scripts/gen-certs.sh $(if $(filter 1,$(FORCE)),--force,)

# openbao/seal.key is what lets the vault unseal itself after a restart, and
# the only thing that can decrypt the openbao-data volume. Never regenerate it
# for a vault that holds anything (FORCE=1 says so before it does).
seal-key: ## Generate OpenBao's auto-unseal key (FORCE=1 to replace)
	@./scripts/gen-seal-key.sh $(if $(filter 1,$(FORCE)),--force,)

hosts: ## Print /etc/hosts lines for this stack
	@./scripts/print-hosts-entries.sh

test: ## Run the flow tests, the pr-validation checks and check-env's rejection cases (TEST_ONLY=unit: flow tests only)
	@./scripts/test.sh

# Asserts .env is complete and usable before anything deploys against it:
# every setting .env.example defines is present (a variable added with a new
# service and never copied over interpolates as an empty string and takes a
# container down on its own config), no placeholders are left, the
# oauth2-proxy cookie keys are a length oauth2-proxy accepts, and LAN_IP is
# an address the Docker host owns.
check-env:
	@INFRA_HOST="$(INFRA_HOST)" ./scripts/check-env.sh

docker-start: ## Start Docker Desktop and wait for its daemon
	@if [ -n "$${DOCKER_HOST:-}" ]; then \
		echo "make docker-start: the daemon is remote ($$DOCKER_HOST); start Docker Desktop on that host." >&2; \
		exit 1; \
	fi
	@./scripts/check-docker.sh "$(CURDIR)" && state=0 || state=$$?; \
	case $$state in \
	  0) echo "make docker-start: Docker Desktop is already running and correctly configured."; \
	     exit 0 ;; \
	  5) echo; \
	     echo "make docker-start: Docker Desktop is running; the warnings above are not fatal."; \
	     exit 0 ;; \
	  1) echo "  Mount that volume BEFORE launching Docker Desktop, then retry." >&2; \
	     exit 1 ;; \
	  3|4) echo "  Docker Desktop is running but not usable for this stack; fix the above." >&2; \
	     exit 1 ;; \
	esac; \
	open -a Docker || { \
	  echo "make docker-start: could not launch Docker.app -- is Docker Desktop installed?" >&2; \
	  exit 1; \
	}; \
	printf 'make docker-start: waiting for the daemon '; \
	for _ in $$(seq 1 90); do \
	  if docker info >/dev/null 2>&1; then break; fi; \
	  printf '.'; sleep 2; \
	done; \
	echo; \
	docker info >/dev/null 2>&1 || { \
	  echo "make docker-start: the daemon did not come up within 3 minutes." >&2; \
	  exit 1; \
	}; \
	./scripts/check-docker.sh "$(CURDIR)" && exit 0 || state=$$?; \
	if [ $$state -eq 5 ]; then exit 0; fi; \
	exit 1

docker-stop: ## Quit Docker Desktop (takes the whole stack down with it)
	@if [ -n "$${DOCKER_HOST:-}" ]; then \
		echo "make docker-stop: the daemon is remote ($$DOCKER_HOST); quit Docker Desktop on that host." >&2; \
		exit 1; \
	fi
	osascript -e 'quit app "Docker"'

check-docker:
	@./scripts/check-docker.sh "$(CURDIR)" && exit 0 || state=$$?; \
	if [ $$state -eq 5 ]; then \
		echo "make check-docker: warning: starting anyway; see above." >&2; \
		exit 0; \
	fi; \
	if [ $$state -eq 2 ] && [ -z "$${DOCKER_HOST:-}" ]; then \
		echo "make check-docker: start it with 'make docker-start'." >&2; \
	fi; \
	exit 1

migrate-volumes: ## Copy the stack's volumes from Colima to Docker Desktop (DRY=1 previews)
	@./scripts/migrate-volumes.sh $(if $(filter 1,$(DRY)),--dry-run,) $(if $(filter 1,$(OVERWRITE)),--force,)

# The stacks a deploy walks, in stacks.conf order; `stack=<name>` picks one.
STACKS = $(or $(stack),$(shell awk '!/^\#/ && NF { print $$1 }' stacks.conf))

# Deploy + health gate, one stack after the other, so a stack only starts once
# the ones above it in stacks.conf are healthy. Portainer's API returns before
# containers are recreated, so record each stack's container IDs first and let
# wait-healthy.sh wait until none of them is left (and everything is up).
# WAIT_HEALTHY=0 skips. Exit 3 from portainer-stack.sh is a stack
# ONLY_IF_CHANGED=1 left alone: nothing to wait for.
define deploy_and_wait
for s in $(STACKS); do \
  before=$$(docker ps -a -q --no-trunc --filter label=com.docker.compose.project=$$s) \
    || { echo "deploy aborted: cannot list $$s containers (docker ps failed); an empty BEFORE_IDS would let the gate pass on the old stack" >&2; exit 1; }; \
  before=$$(echo $$before); \
  rc=0; STACK=$$s ./scripts/portainer-stack.sh $(1) || rc=$$?; \
  [ $$rc != 3 ] || continue; [ $$rc = 0 ] || exit $$rc; \
  if [ "$$(awk -v s=$$s '!/^\#/ && $$1 == s { print $$3 }' stacks.conf)" != - ]; then echo "$$s: remote environment, health gate skipped (check it in Portainer)"; continue; fi; \
  [ "$(WAIT_HEALTHY)" = 0 ] || BEFORE_IDS="$$before" WAIT_PROJECT=$$s WAIT_COMPOSE_FILE="$$(awk -v s=$$s '!/^\#/ && $$1 == s { print $$2 }' stacks.conf)" ./scripts/wait-healthy.sh $(or $(WAIT_HEALTHY_TIMEOUT),600); \
done
endef

##@ Stack (deploy via Portainer)
up: check-docker vault-render check-env net app-volumes app-images ## Deploy/redeploy the stacks via Portainer (Git main; stack=<name> for one)
	$(call deploy_and_wait,up)

down: ## Stop the stacks via Portainer (keeps volumes; stack=<name> for one)
	for s in $(STACKS); do STACK=$$s ./scripts/portainer-stack.sh down; done

stack-status: ## List Portainer's stacks and the commit each is deployed at
	./scripts/portainer-stack.sh status

restart: ## Restart services (optional: s=<service>)
	docker compose restart $(if $(s),"$(s)",)

logs: ## Tail logs (optional: s=<service>)
	docker compose logs -f $(if $(s),"$(s)",)

ps: status

status: ## Show service status (alias: ps)
	docker compose ps

pull: check-docker vault-render check-env net app-volumes app-images ## Redeploy via Portainer, re-pulling images (stack=<name> for one)
	$(call deploy_and_wait,pull)

config: check-env check-docker ## Validate docker-compose.yml + .env
	docker compose config

shell: ## Open a shell in a service (s=<service>)
	@test -n "$(s)" || { echo "usage: make shell s=<service>" >&2; exit 1; }
	docker compose exec "$(s)" sh

psql: check-env ## Open a psql shell as the superuser (one-shot container; Postgres is on the Mac mini)
	@set -a && . ./.env && set +a && . scripts/lib/pg.sh && pg_run -- psql

PORTAINER_COMPOSE := docker compose -f docker-compose.portainer.yml

##@ Portainer itself
portainer-up: check-env check-docker net ## Start Portainer (its own compose project)
	@docker volume create infra_portainer-data >/dev/null
	$(PORTAINER_COMPOSE) up -d
	@echo
	@. ./.env; echo "Portainer -> https://$$LAN_IP:9443 (direct, no nginx)"
	@echo "           https://$(PORTAINER_HOST) (via nginx)"
	@echo
	@echo "On a first start, create the admin account within a few minutes --"
	@echo "Portainer locks itself out otherwise, and 'make portainer-restart'"
	@echo "reopens that window."

portainer-down: ## Stop Portainer (keeps its volume)
	$(PORTAINER_COMPOSE) down

portainer-restart: ## Restart Portainer
	$(PORTAINER_COMPOSE) restart

# Not `compose logs`: that interpolates the file, so it needs .env (LAN_IP).
portainer-logs: ## Tail Portainer's logs
	@id=$$(docker ps -aq --filter label=com.docker.compose.project=portainer --filter label=com.docker.compose.service=portainer); \
	if [ -z "$$id" ]; then echo "make portainer-logs: no Portainer container on this daemon (make portainer-up)." >&2; exit 1; fi; \
	docker logs -f --tail 100 $$id

##@ CI runners
# --- Six repo runners (docker-compose.runners.yml) -------------------------
# Their own Portainer stack ("runners"), outside "infra": a `make up`
# force-recreates every container in infra, and a runner recreated mid-job
# never reports. Portainer reads the compose from GitHub main (merge first).
# See CLAUDE.md "CI: deploying on a push to main".
#
# --env-file .runner.env is not a convenience: without it compose would
# interpolate from this repo's .env, the stack's whole secret set.
RUNNERS_COMPOSE := docker compose -f docker-compose.runners.yml --env-file .runner.env

# GitHub mints PATs in its web UI only. This takes the six (one per repo)
# from there and checks each can administer runners on its repo before writing.
runners-env: ## Write .runner.env from six per-repo GitHub PATs (FORCE=1 replaces it)
	@./scripts/gen-runner-env.sh $(if $(filter 1,$(FORCE)),--force,)

# up/down/pull/restart are redeploys of all six runners through Portainer;
# scripts/runners-stack.sh refuses while any job runs (exit 3), FORCE=1 means it.
runners-up: ## Create/redeploy the runners stack via Portainer (refuses mid-job; FORCE=1)
	@INFRA_HOST=$(INFRA_HOST) ./scripts/runners-stack.sh up

runners-down: ## Stop the runners stack (refuses mid-job; FORCE=1)
	@INFRA_HOST=$(INFRA_HOST) ./scripts/runners-stack.sh down

# The image tag moves on purpose (GitHub retires old runner versions), so this
# is the fix for a runner the service stopped accepting, not housekeeping.
runners-pull: ## Re-pull the runner image and redeploy (refuses mid-job; FORCE=1)
	@INFRA_HOST=$(INFRA_HOST) ./scripts/runners-stack.sh pull

runners-restart: ## Redeploy the runners stack (same as runners-up)
	@INFRA_HOST=$(INFRA_HOST) ./scripts/runners-stack.sh up

runners-logs: ## Tail the six runners' logs (on the Docker host, DOCKER_HOST)
	@test -f .runner.env || { echo "make: .runner.env not found -- run 'make runners-env'" >&2; exit 1; }
	$(RUNNERS_COMPOSE) logs -f

runners-status: ## Per repo: the container here, and what GitHub has registered
	@./scripts/runner-status.sh

# Dev-session plumbing (docker-compose.dev.yml): egress proxy + SSH gateway,
# Portainer stack `dev` on the Mac Studio (stacks.conf). The sessions
# themselves are Portainer stacks made by the devbox CLI on the same
# environment. See CLAUDE.md "Dev sessions".
DEV_ENDPOINT := 6

# The key file is baked into the gateway image: refuse a private key anywhere
# in it, and any non-comment line that is not a public key (ssh-/ecdsa-/sk-).
# The images are built from GitHub main: merge a key change first.
dev-up: check-env ## Rebuild the dev proxy and gateway images from main and (re)deploy the dev stack
	@rc=0; awk '/PRIVATE KEY/ { priv = 1 } /^[[:space:]]*(#|$$)/ { next } \
		{ n++; if ($$0 !~ /^(ssh-|ecdsa-|sk-)/) bad = 1 } \
		END { exit priv ? 2 : (n > 0 && !bad) ? 0 : 1 }' dev/gateway/authorized_keys || rc=$$?; \
	[ "$$rc" != 2 ] || { echo "make dev-up: dev/gateway/authorized_keys holds a PRIVATE key -- only the .pub line goes there" >&2; exit 1; }; \
	[ "$$rc" = 0 ] || { echo "make dev-up: dev/gateway/authorized_keys has no key, or a line that is not one -- add your ~/.ssh/id_*.pub line(s)" >&2; exit 1; }
	@INFRA_HOST=$(INFRA_HOST) PORTAINER_ENDPOINT_ID=$(DEV_ENDPOINT) FORCE=1 ./scripts/portainer-images.sh dev-plumbing
	STACK=dev ./scripts/portainer-stack.sh up

dev-down: ## Stop the dev stack (sessions lose SSH and egress; keeps volumes)
	STACK=dev ./scripts/portainer-stack.sh down

# Builds the image and runs the session/image checks on THIS machine's
# daemon (they need to bind-mount nothing, but must not touch the live one),
# plus the CLI's unit tests.
dev-test: ## Dev sessions: CLI unit tests, then image and state checks on the local daemon
	cargo test --manifest-path dev/cli/Cargo.toml
	DOCKER_HOST= docker build -q -t devbox-session:1 dev/image
	DOCKER_HOST= ./scripts/dev-image-check.sh
	DOCKER_HOST= ./scripts/dev-session-check.sh


##@ App provisioning
provision-app: check-env ## Add an app DB/role (app=<name>)
	@test -n "$(app)" || { echo "usage: make provision-app app=<name>" >&2; exit 1; }
	@./scripts/provision-app.sh "$(app)"

provision-monitoring-role: check-env ## Create/update postgres-exporter monitoring role
	@./scripts/provision-monitoring-role.sh

provision-litellm-rag: check-env ## Create/update LiteLLM's read-only view of Jarvis's pgvector chunks
	@./scripts/provision-litellm-rag.sh

dns-provision: check-env ## Create/update DNS zones & records
	@./scripts/dns-provision.sh

dns-check: check-env ## Query the dns service to verify answers
	@./scripts/dns-check.sh

keycloak-seed-users: check-env ## Set nurse.demo / examiner.demo login passwords
	@./scripts/keycloak-seed-users.sh

s3-provision: check-env ## Create/update an app's S3 bucket + identity (app=<name> [bucket=] [versioned=1])
	@test -n "$(app)" || { echo "usage: make s3-provision app=<name> [bucket=<bucket>] [versioned=1]" >&2; exit 1; }
	@./scripts/provision-s3.sh "$(app)" "$(or $(bucket),$(app))" "$(or $(versioned),0)"

ntfy-provision: check-env ## Create an app's ntfy user + write-only token (app=<name> [topic=<prefix>])
	@test -n "$(app)" || { echo "usage: make ntfy-provision app=<name> [topic=<topic-prefix>]" >&2; exit 1; }
	@./scripts/provision-ntfy.sh "$(app)" "$(or $(topic),$(app))"

rabbitmq-provision: check-env ## Create/update an app's RabbitMQ vhost + user (app=<name>; password <APP>_AMQP_PASSWORD)
	@test -n "$(app)" || { echo "usage: make rabbitmq-provision app=<name>" >&2; exit 1; }
	@./scripts/provision-rabbitmq.sh "$(app)"

##@ Secrets (OpenBao)
# --- OpenBao (the secret store) --------------------------------------------
# vault-init runs once per vault; seed/env are the two directions of the .env
# round trip, and vault-render is the deploy-time half of it that 'make up'
# runs for you. None of them takes check-env: vault-env is how a .env that
# check-env rejects gets fixed, so requiring it first would deadlock.

# The EA checkout sits beside this one; override for another layout.
EA_ENV ?= ../EA/deploy/ea.env

vault-init: ## Initialise the vault (root token -> .openbao.env, mount KV v2)
	@./scripts/vault-init.sh

vault-seed: ## Copy .env into the vault (infra/env)
	@./scripts/vault-seed.sh

vault-oidc: ## Enable Keycloak (OIDC) login for OpenBao; group openbao-admin = admin
	@./scripts/vault-oidc.sh

vault-seed-ea: ## Copy EA's deploy/ea.env into the vault (ea/env)
	@./scripts/vault-seed.sh $(EA_ENV) ea

vault-env: ## Regenerate .env from the vault (keeps the old one as .env.bak)
	@./scripts/vault-env.sh

# What "render at deploy time" means here: 'make up' / 'make pull'
# authenticate against the vault with the token in .openbao.env, pull
# infra/env, write .env, and only then deploy. No container is ever told the
# vault exists -- Compose gets the same flat file it always got, rendered a
# moment earlier from the record instead of edited by hand and left to drift.
#
# It skips rather than blocks when there is no vault to read, because the
# vault is a service of the very stack being deployed and cannot be a
# precondition for deploying it: before 'make vault-init' there is no
# .openbao.env, and while the stack is down there is no openbao container to
# exec into. Both cases deploy the .env already in the checkout -- which
# check-env still has to accept -- and say so. A vault that *is* up but
# refuses to be read (sealed, expired token) is an error, not a skip:
# deploying last week's secrets silently is the failure worth preventing.
#
# VAULT_RENDER=0 turns it off outright, for an environment that has no vault
# at all (CI, the cloud VM in AGENTS.md).
#
# The container is found by compose label rather than 'docker compose ps',
# which would have to interpolate docker-compose.yml first and so would die
# on the very `${VAR:?}` guards a stale .env is here to fix.
vault-render: ## Render .env from the vault, as 'make up' does (VAULT_RENDER=0 skips)
	@if [ "$(VAULT_RENDER)" = "0" ]; then \
		echo "make vault-render: VAULT_RENDER=0 -- deploying the .env in this checkout as-is."; \
		exit 0; \
	fi; \
	if [ ! -f .openbao.env ]; then \
		echo "make vault-render: no .openbao.env, so this vault has not been initialised yet." >&2; \
		echo "  Deploying the .env in this checkout as-is; 'make vault-init && make vault-seed' once it is up." >&2; \
		exit 0; \
	fi; \
	if ! docker ps --filter label=com.docker.compose.service=openbao \
		--format '{{.State}}' 2>/dev/null | grep -q '^running$$'; then \
		echo "make vault-render: the openbao container is not running -- nothing to read the secrets from." >&2; \
		echo "  Deploying the .env in this checkout as-is; re-run once the vault is back up." >&2; \
		exit 0; \
	fi; \
	./scripts/vault-env.sh

vault-status: ## Show the vault's seal/init state
	@./scripts/vault-cli.sh status

vault-cli: ## Run a bao command (args="kv list infra/")
	@test -n "$(args)" || { echo 'usage: make vault-cli args="kv list infra/"' >&2; exit 1; }
	@./scripts/vault-cli.sh $(args)

vault-backup-token: ## Mint the scoped token for the backup flow (prints it once)
	@./scripts/vault-backup-token.sh

# Deleting the Portainer stack only removes its containers; 'down -v' then
# drops the volumes docker-compose.yml declares -- infra_portainer-data is
# no longer one of them, so Portainer keeps its data.
##@ Danger zone
clean: ## Delete the stack and its volumes (CONFIRM=1 required)
	@test "$(CONFIRM)" = "1" || { echo "usage: make clean CONFIRM=1" >&2; exit 1; }
	./scripts/portainer-stack.sh delete
	docker compose down -v
