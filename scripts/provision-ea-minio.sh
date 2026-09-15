#!/usr/bin/env bash
# Create/update the MinIO bucket and the dedicated user the EA API stores
# its files in (EA docs/adr/0036). Idempotent: safe to re-run, e.g. to
# rotate EA_MINIO_SECRET_KEY. Access key = ea-api.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ ! -f .env ]; then
  echo "provision-ea-minio.sh: .env not found (run 'make init' first)" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

: "${MINIO_ROOT_USER:?Set MINIO_ROOT_USER in .env}"
: "${MINIO_ROOT_PASSWORD:?Set MINIO_ROOT_PASSWORD in .env}"
: "${EA_MINIO_SECRET_KEY:?Set EA_MINIO_SECRET_KEY in .env}"

docker compose exec -T \
  -e MINIO_ROOT_USER="$MINIO_ROOT_USER" \
  -e MINIO_ROOT_PASSWORD="$MINIO_ROOT_PASSWORD" \
  -e EA_MINIO_SECRET_KEY="$EA_MINIO_SECRET_KEY" \
  minio bash -euo pipefail -s <<'EOF'
export MC_CONFIG_DIR="$(mktemp -d)"
trap 'rm -rf "$MC_CONFIG_DIR"' EXIT

mc alias set local http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null

# The API refuses to boot on a missing bucket and has no right to create it.
mc mb --ignore-existing local/ea-catalogue

cat >"$MC_CONFIG_DIR/policy.json" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": ["arn:aws:s3:::ea-catalogue"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": ["arn:aws:s3:::ea-catalogue/*"]
    }
  ]
}
JSON
mc admin policy create local ea-catalogue-rw "$MC_CONFIG_DIR/policy.json"

# Creates the user, or resets its secret if it already exists.
mc admin user add local ea-api "$EA_MINIO_SECRET_KEY"

if ! out="$(mc admin policy attach local ea-catalogue-rw --user ea-api 2>&1)"; then
  case "$out" in
    *"already in effect"*) ;;
    *) echo "$out" >&2; exit 1 ;;
  esac
fi

echo "bucket 'ea-catalogue' + user 'ea-api' (policy ea-catalogue-rw) ready"
EOF
