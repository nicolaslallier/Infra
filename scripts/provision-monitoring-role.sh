#!/usr/bin/env bash
# Create/update the postgres-exporter "monitoring" role on an already-
# running cluster (initdb's 20-monitoring-role.sh only runs on first boot).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ ! -f .env ]; then
  echo "provision-monitoring-role.sh: .env not found (run 'make init' first)" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

: "${MONITORING_DB_PASSWORD:?Set MONITORING_DB_PASSWORD in .env}"

docker compose exec -T \
  -e MONITORING_DB_PASSWORD="$MONITORING_DB_PASSWORD" \
  postgres \
  sh /docker-entrypoint-initdb.d/20-monitoring-role.sh
