SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

.DEFAULT_GOAL := help

.PHONY: help init net certs seal-key up down restart logs ps status pull config \
	shell psql provision-app provision-monitoring-role hosts dns-provision \
	dns-check clean check-env check-docker docker-start docker-stop \
	migrate-volumes keycloak-seed-users obsidian-minio ea-minio \
	vault-init vault-seed vault-env vault-status vault-cli \
	portainer-up portainer-down portainer-restart portainer-logs

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

up: check-env check-docker net ## Deploy/redeploy the stack via Portainer (Git main)
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

pull: ## Redeploy via Portainer, re-pulling images
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
# round trip. None of them takes check-env: vault-env is how a .env that
# check-env rejects gets fixed, so requiring it first would deadlock.

vault-init: ## Initialise the vault (root token -> .openbao.env, mount KV v2)
	@./scripts/vault-init.sh

vault-seed: ## Copy .env into the vault (infra/env)
	@./scripts/vault-seed.sh

vault-env: ## Regenerate .env from the vault (keeps the old one as .env.bak)
	@./scripts/vault-env.sh

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
