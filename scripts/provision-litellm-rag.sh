#!/usr/bin/env bash
# Create/update litellm_rag in the jarvis database: the read-only role and the
# views litellm-pgvector serves Jarvis's RAG chunks from (litellm/rag.sql).
# Needs Jarvis's migrations applied first (file_chunks, files). Idempotent.
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

docker compose -f docker-compose.postgres.yml exec -T postgres \
  psql -X -q -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d jarvis \
  -v ragpass="$LITELLM_RAG_DB_PASSWORD" < litellm/rag.sql

echo "provision-litellm-rag.sh: role litellm_rag and views litellm_rag.{vector_stores,embeddings} are ready in 'jarvis'"
