#!/usr/bin/env bash
# Create/update LiteLLM's vector database: database + role `litellm_rag`
# (the generic per-app provisioning, password LITELLM_RAG_DB_PASSWORD, with
# the vector extension), then the tables litellm-pgvector uses
# (litellm/rag.sql). Idempotent; run it before the first deploy of
# litellm-pgvector, which cannot start without them.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ ! -f .env ]; then
  echo "provision-litellm-rag.sh: .env not found (run 'make init' first)" >&2
  exit 1
fi

set -a
# shellcheck source=/dev/null  # .env is generated, not lintable source
. ./.env
set +a

: "${LITELLM_RAG_DB_PASSWORD:?Set LITELLM_RAG_DB_PASSWORD in .env}"

./scripts/provision-app.sh litellm_rag </dev/null

docker compose -f docker-compose.postgres.yml exec -T postgres \
  psql -X -q -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d litellm_rag \
  < litellm/rag.sql

echo "provision-litellm-rag.sh: database 'litellm_rag' is ready (store 'second-brain')"
