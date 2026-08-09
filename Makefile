SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c

.DEFAULT_GOAL := help

.PHONY: help init net certs up down restart logs ps status pull config \
	shell psql provision-app provision-monitoring-role hosts dns-provision \
	dns-check clean check-env keycloak-seed-users

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
	if [ "$${LAN_IP:-}" = "192.168.1.50" ]; then \
		echo "make check-env: warning: LAN_IP is still the example value 192.168.1.50" >&2; \
	fi

up: check-env net ## Start the stack
	docker compose up -d

down: ## Stop the stack (keeps volumes)
	docker compose down

restart: ## Restart services (optional: s=<service>)
	docker compose restart $(if $(s),"$(s)",)

logs: ## Tail logs (optional: s=<service>)
	docker compose logs -f $(if $(s),"$(s)",)

ps: status

status: ## Show service status (alias: ps)
	docker compose ps

pull: ## Pull latest images
	docker compose pull

config: check-env ## Validate docker-compose.yml + .env
	docker compose config

shell: ## Open a shell in a service (s=<service>)
	@test -n "$(s)" || { echo "usage: make shell s=<service>" >&2; exit 1; }
	docker compose exec "$(s)" sh

psql: ## Open a psql shell as the superuser
	docker compose exec postgres sh -c 'psql -U "$$POSTGRES_USER"'

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

clean: ## Remove containers + volumes (CONFIRM=1 required)
	@test "$(CONFIRM)" = "1" || { echo "usage: make clean CONFIRM=1" >&2; exit 1; }
	docker compose down -v
