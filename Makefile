SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

.DEFAULT_GOAL := help

.PHONY: help init net certs up down restart logs ps status pull config \
	shell psql provision-app provision-monitoring-role hosts dns-provision \
	dns-check clean check-env check-docker docker-start docker-stop \
	migrate-volumes keycloak-seed-users \
	portainer-up portainer-down portainer-restart portainer-logs

# Portainer's hostname, served by nginx/conf.d/portainer.conf. Covered by
# the wildcard cert and the wildcard DNS zone -- no per-host setup needed.
PORTAINER_HOST ?= portainer.infra.famillelallier.net

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "}; /^[a-zA-Z0-9_-]+:.*## / {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

init: net certs ## Create network, certs, and .env from .env.example
	@if [ ! -f .env ]; then \
		cp .env.example .env; \
		echo "Created .env — edit passwords, LAN_IP, and DNS_ADMIN_PASSWORD before 'make up'."; \
	fi

net: ## Ensure the external infra-net Docker network exists
	@docker network create infra-net >/dev/null 2>&1 || true

certs: ## Generate TLS certs (FORCE=1 to regenerate)
	@./scripts/gen-certs.sh $(if $(filter 1,$(FORCE)),--force,)

hosts: ## Print /etc/hosts lines for this stack
	@./scripts/print-hosts-entries.sh

# LAN_IP must be an address this host owns: dns publishes its ports on it, and
# a stale one (an old VM's, a changed DHCP lease) fails that bind and leaves
# every later service stuck in "Created".
check-env:
	@if [ ! -f .env ]; then \
		echo "make check-env: .env not found (run 'make init' first)" >&2; \
		exit 1; \
	fi
	@set -a; . ./.env; set +a; \
	bad=""; \
	for var in POSTGRES_PASSWORD PGADMIN_PASSWORD KEYCLOAK_ADMIN_PASSWORD KEYCLOAK_DB_PASSWORD DNS_ADMIN_PASSWORD GRAFANA_ADMIN_PASSWORD MONITORING_DB_PASSWORD MINIO_ROOT_PASSWORD RABBITMQ_DEFAULT_PASS; do \
		if [ -z "$${!var:-}" ] || [ "$${!var}" = "change-me" ]; then \
			bad="$$bad $$var"; \
		fi; \
	done; \
	old_ifs="$$IFS"; \
	IFS=','; for app in $${APP_DATABASES:-}; do \
		app="$${app//[[:space:]]/}"; \
		[ -z "$$app" ] && continue; \
		var="$$(printf '%s' "$$app" | tr '[:lower:]' '[:upper:]')_DB_PASSWORD"; \
		if [ -z "$${!var:-}" ] || [ "$${!var}" = "change-me" ]; then \
			bad="$$bad $$var"; \
		fi; \
	done; \
	IFS="$$old_ifs"; \
	if [ -n "$$bad" ]; then \
		bad="$$(printf '%s\n' $$bad | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$$//')"; \
		echo "make check-env: replace placeholder values in .env for: $$bad" >&2; \
		exit 1; \
	fi; \
	addrs="$$( { ifconfig 2>/dev/null || ip -4 -o addr show 2>/dev/null; } \
		| grep -oE 'inet (addr:)?[0-9.]+' | grep -oE '[0-9.]+$$')"; \
	if [ -z "$${LAN_IP:-}" ]; then \
		echo "make check-env: LAN_IP is not set in .env" >&2; \
		exit 1; \
	elif [ -n "$$addrs" ] && ! printf '%s\n' "$$addrs" | grep -qxF "$$LAN_IP"; then \
		echo "make check-env: LAN_IP=$$LAN_IP is not an address on this host (have: $$(echo $$addrs))" >&2; \
		exit 1; \
	fi

docker-start: ## Start Docker Desktop and wait for its daemon
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
	osascript -e 'quit app "Docker"'

check-docker:
	@./scripts/check-docker.sh "$(CURDIR)" && exit 0 || state=$$?; \
	if [ $$state -eq 5 ]; then \
		echo "make check-docker: warning: starting anyway; see above." >&2; \
		exit 0; \
	fi; \
	if [ $$state -eq 2 ]; then \
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

# Deleting the Portainer stack only removes its containers; 'down -v' then
# drops the volumes docker-compose.yml declares -- infra_portainer-data is
# no longer one of them, so Portainer keeps its data.
clean: ## Delete the stack and its volumes (CONFIRM=1 required)
	@test "$(CONFIRM)" = "1" || { echo "usage: make clean CONFIRM=1" >&2; exit 1; }
	./scripts/portainer-stack.sh delete
	docker compose down -v
