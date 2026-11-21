#!/usr/bin/env bash
# Index the Obsidian vault (arg 1, a directory on this machine) into LiteLLM's
# `second-brain` vector store: read what is indexed, embed new/changed notes
# through LiteLLM (scripts/index_vault.py), apply in one psql transaction.
# Incremental and idempotent; make index-vault.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VAULT="${1:?usage: index-vault.sh <vault dir>}"
[ -d "$VAULT" ] || { echo "index-vault.sh: $VAULT is not a directory" >&2; exit 1; }

if [ ! -f .env ]; then
  echo "index-vault.sh: .env not found (run 'make init' first)" >&2
  exit 1
fi
set -a
# shellcheck source=/dev/null  # .env is generated, not lintable source
. ./.env
set +a
: "${LITELLM_MASTER_KEY:?Set LITELLM_MASTER_KEY in .env}"
export LITELLM_URL="${LITELLM_URL:-https://litellm.infra.famillelallier.net}"

# shellcheck source=lib/pg.sh
. scripts/lib/pg.sh

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

pg_run -- psql -X -At -F $'\t' -v ON_ERROR_STOP=1 -d litellm_rag -c \
  "select distinct metadata->>'path', metadata->>'sha256' from embeddings where vector_store_id='second-brain' and metadata->>'source'='obsidian-maison'" \
  </dev/null >"$tmp/state"

python3 scripts/index_vault.py --vault "$VAULT" --state "$tmp/state" ${FORCE:+--force} >"$tmp/apply.sql"
pg_run -- psql -X -q -v ON_ERROR_STOP=1 -1 -d litellm_rag -f - <"$tmp/apply.sql"
echo "index-vault.sh: second-brain is up to date"
