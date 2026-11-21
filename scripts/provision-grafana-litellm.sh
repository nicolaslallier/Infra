#!/usr/bin/env bash
# Create/update Grafana's read-only role on LiteLLM's spend log (datasource
# litellm-db). Re-run after a LiteLLM upgrade recreates "LiteLLM_SpendLogs".
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ ! -f .env ]; then
  echo "provision-grafana-litellm.sh: .env not found (run 'make init' first)" >&2
  exit 1
fi

set -a
# shellcheck source=/dev/null  # .env is generated, not lintable source
. ./.env
set +a

: "${GRAFANA_LITELLM_DB_PASSWORD:?Set GRAFANA_LITELLM_DB_PASSWORD in .env}"

# Over the network from a one-shot container: Postgres is on the Mac mini.
# shellcheck source=lib/pg.sh
. scripts/lib/pg.sh
pg_run_script postgres/initdb/30-grafana-litellm-role.sh -e GRAFANA_LITELLM_DB_PASSWORD --
