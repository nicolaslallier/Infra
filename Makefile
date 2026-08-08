.PHONY: init net certs up down restart logs ps psql provision-app hosts

init: net certs
	@if [ ! -f .env ]; then cp .env.example .env; echo "Created .env — edit passwords before 'make up'."; fi

net:
	@docker network create infra-net >/dev/null 2>&1 || true

certs:
	@./scripts/gen-certs.sh

hosts:
	@./scripts/print-hosts-entries.sh

up: net
	docker compose up -d

down:
	docker compose down

restart:
	docker compose restart

logs:
	docker compose logs -f

ps:
	docker compose ps

psql:
	docker compose exec postgres psql -U $${POSTGRES_USER:-postgres}

provision-app:
	@./scripts/provision-app.sh $(app)
