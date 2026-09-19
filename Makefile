SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

.DEFAULT_GOAL := help

# Prerequisites are made left to right only in a serial build, and 'up'
# depends on that: vault-render writes the .env that check-env then reads.
.NOTPARALLEL:

.PHONY: help init net certs seal-key up down restart logs ps status pull config \
	shell psql provision-app provision-monitoring-role hosts dns-provision \
	dns-check clean check-env check-docker docker-start docker-stop \
	migrate-volumes keycloak-seed-users obsidian-minio ea-minio \
	vault-init vault-seed vault-seed-ea vault-env vault-render vault-status vault-cli \
	portainer-up portainer-down portainer-restart portainer-logs \
	runner-up runner-down runner-restart runner-logs runner-status runner-pull \
	runner-shell check-runner-env

# Portainer's hostname, served by nginx/conf.d/portainer.conf. Covered by
# the wildcard cert and the wildcard DNS zone -- no per-host setup needed.
PORTAINER_HOST ?= portainer.infra.famillelallier.net

# The stack runs on Docker Desktop on the Windows laptop (laptop-dopbpc0j).
# From the Mac, every docker/compose call -- and so the Portainer API calls,
# which run in a curl container -- goes there over SSH (key auth required).
# 'make DOCKER_HOST=' targets the local daemon instead.
INFRA_HOST ?= 192.168.2.10
INFRA_SSH_USER ?= nicol
ifeq ($(shell uname -s),Darwin)
export DOCKER_HOST ?= ssh://$(INFRA_SSH_USER)@$(INFRA_HOST)
# This checkout (C:\Users\nicol\OpenCode\Infra, SMB-mounted on the Mac) as
# the laptop's Docker Desktop VM sees it: Portainer bind-mounts from here.
export PORTAINER_INFRA_DIR ?= /run/desktop/mnt/host/c/Users/nicol/OpenCode/Infra
endif

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "}; /^[a-zA-Z0-9_-]+:.*## / {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

init: net certs seal-key ## Create network, certs, OpenBao's seal key, and .env
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		echo "Created .env — edit passwords, LAN_IP, and DNS_ADMIN_PASSWORD before 'make up'."; \
	else \
		echo ".env already exists, left untouched — 'make check-env' lists the settings .env.example has gained since."; \
	fi

net: ## Ensure the external infra-net Docker network exists
	@docker network create infra-net >/dev/null 2>&1 \
		&& echo "created network infra-net" \
		|| echo "network infra-net already exists"

certs: ## Generate TLS certs (FORCE=1 to regenerate)
	@./scripts/gen-certs.sh $(if $(filter 1,$(FORCE)),--force,)

# openbao/seal.key is what lets the vault unseal itself after a restart, and
# the only thing that can decrypt the openbao-data volume. Never regenerate it
# for a vault that holds anything (FORCE=1 says so before it does).
seal-key: ## Generate OpenBao's auto-unseal key (FORCE=1 to replace)
	@./scripts/gen-seal-key.sh $(if $(filter 1,$(FORCE)),--force,)

hosts: ## Print /etc/hosts lines for this stack
	@./scripts/print-hosts-entries.sh

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

up: check-docker vault-render check-env net ## Deploy/redeploy the stack via Portainer (Git main)
	./scripts/portainer-stack.sh up

down: ## Stop the stack via Portainer (keeps volumes)
	./scripts/portainer-stack.sh down

restart: ## Restart services (optional: s=<service>)
	docker compose restart $(if $(s),"$(s)",)

logs: ## Tail logs (optional: s=<service>)
	docker compose logs -f $(if $(s),"$(s)",)

ps: status

status: ## Show service status (alias: ps)
	docker compose ps

pull: check-docker vault-render check-env net ## Redeploy via Portainer, re-pulling images
	./scripts/portainer-stack.sh pull

config: check-env check-docker ## Validate docker-compose.yml + .env
	docker compose config

shell: ## Open a shell in a service (s=<service>)
	@test -n "$(s)" || { echo "usage: make shell s=<service>" >&2; exit 1; }
	docker compose exec "$(s)" sh

psql: ## Open a psql shell as the superuser
	docker compose exec postgres sh -c 'psql -U "$$POSTGRES_USER"'

PORTAINER_COMPOSE := docker compose -f docker-compose.portainer.yml

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

portainer-logs: ## Tail Portainer's logs
	$(PORTAINER_COMPOSE) logs -f

# --- CI runner (deploy on a push to main) ----------------------------------
# The self-hosted GitHub Actions runner lives in its own compose project,
# outside the stack it deploys, for the reason Portainer does: a redeploy
# force-recreates every container in "infra", and a runner recreated mid-job
# never reports. See CLAUDE.md "CI: deploying on a push to main".
#
# --env-file .runner.env is not a convenience: without it compose would
# interpolate from this repo's .env, which is the stack's whole secret set.
# The runner needs one value and has no business seeing the rest.
RUNNER_COMPOSE := docker compose -f docker-compose.runner.yml --env-file .runner.env

check-runner-env:
	@test -f .runner.env || { \
		echo "make: .runner.env not found -- create it with GH_RUNNER_TOKEN (a PAT that may register runners on this repo); see .env.example" >&2; \
		exit 1; \
	}

# Stopping or recreating the runner mid-job kills that job, and GitHub gets
# no result for it -- the workflow run simply stops reporting. Every target
# that does so asks scripts/runner-status.sh first; FORCE=1 means it.
RUNNER_NOT_BUSY = test -n "$(FORCE)" || ./scripts/runner-status.sh --busy

runner-up: check-runner-env ## Start the self-hosted CI runner (its own compose project)
	$(RUNNER_COMPOSE) up -d
	@echo
	@echo "Runner -> https://github.com/nicolaslallier/Infra/settings/actions/runners"
	@echo "It must show up there with the label 'infra' before a push to main can deploy."
	@echo "Confirm with 'make runner-status'; 'make runner-logs' until \"Listening for Jobs\"."

runner-down: check-runner-env ## Stop the CI runner (FORCE=1 even mid-job)
	@$(RUNNER_NOT_BUSY)
	$(RUNNER_COMPOSE) down

runner-restart: check-runner-env ## Restart the CI runner (FORCE=1 even mid-job)
	@$(RUNNER_NOT_BUSY)
	$(RUNNER_COMPOSE) restart

runner-logs: check-runner-env ## Tail the CI runner's logs
	$(RUNNER_COMPOSE) logs -f

runner-status: check-runner-env ## Runner state: the container here, and what GitHub has registered
	@./scripts/runner-status.sh

# The image tag moves on purpose (GitHub retires old runner versions
# server-side, and then refuses to talk to them), so this is the fix for a
# runner the service has stopped accepting -- not routine housekeeping.
runner-pull: check-runner-env ## Re-pull the runner image and recreate it (FORCE=1 even mid-job)
	@$(RUNNER_NOT_BUSY)
	$(RUNNER_COMPOSE) pull
	$(RUNNER_COMPOSE) up -d

runner-shell: check-runner-env ## Open a shell in the running CI runner
	$(RUNNER_COMPOSE) exec runner bash

provision-app: check-env ## Add an app DB/role (app=<name>)
	@test -n "$(app)" || { echo "usage: make provision-app app=<name>" >&2; exit 1; }
	@./scripts/provision-app.sh "$(app)"

provision-monitoring-role: check-env ## Create/update postgres-exporter monitoring role
	@./scripts/provision-monitoring-role.sh

dns-provision: check-env ## Create/update DNS zones & records
	@./scripts/dns-provision.sh

dns-check: check-env ## Query the dns service to verify answers
	@./scripts/dns-check.sh

keycloak-seed-users: check-env ## Set nurse.demo / examiner.demo login passwords
	@./scripts/keycloak-seed-users.sh

obsidian-minio: check-env ## Create/update the MinIO bucket + user Obsidian syncs into
	@./scripts/provision-obsidian-minio.sh

ea-minio: check-env ## Create/update the MinIO bucket + user the EA API stores files in
	@./scripts/provision-ea-minio.sh

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

# Deleting the Portainer stack only removes its containers; 'down -v' then
# drops the volumes docker-compose.yml declares -- infra_portainer-data is
# no longer one of them, so Portainer keeps its data.
clean: ## Delete the stack and its volumes (CONFIRM=1 required)
	@test "$(CONFIRM)" = "1" || { echo "usage: make clean CONFIRM=1" >&2; exit 1; }
	./scripts/portainer-stack.sh delete
	docker compose down -v
