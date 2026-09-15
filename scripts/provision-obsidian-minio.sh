#!/usr/bin/env bash
# Create/update the MinIO bucket and the dedicated user the obsidian
# service's Remotely Save plugin syncs vaults into. Idempotent: safe to
# re-run, e.g. to rotate OBSIDIAN_MINIO_SECRET_KEY.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ ! -f .env ]; then
  echo "provision-obsidian-minio.sh: .env not found (run 'make init' first)" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

: "${MINIO_ROOT_USER:?Set MINIO_ROOT_USER in .env}"
: "${MINIO_ROOT_PASSWORD:?Set MINIO_ROOT_PASSWORD in .env}"
: "${OBSIDIAN_MINIO_SECRET_KEY:?Set OBSIDIAN_MINIO_SECRET_KEY in .env}"

# mc ships in the minio image. Its alias (root credentials) goes to a
# throwaway config dir, not ~/.mc, so nothing outlives this run.
docker compose exec -T \
  -e MINIO_ROOT_USER="$MINIO_ROOT_USER" \
  -e MINIO_ROOT_PASSWORD="$MINIO_ROOT_PASSWORD" \
  -e OBSIDIAN_MINIO_SECRET_KEY="$OBSIDIAN_MINIO_SECRET_KEY" \
  minio bash -euo pipefail -s <<'EOF'
export MC_CONFIG_DIR="$(mktemp -d)"
trap 'rm -rf "$MC_CONFIG_DIR"' EXIT

mc alias set local http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null

mc mb --ignore-existing local/obsidian
# A sync conflict or a wiped local vault propagates deletes/overwrites to
# the bucket; versioning keeps every previous copy of every note.
mc version enable local/obsidian

cat >"$MC_CONFIG_DIR/policy.json" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"],
      "Resource": ["arn:aws:s3:::obsidian"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
      "Resource": ["arn:aws:s3:::obsidian/*"]
    }
  ]
}
JSON
mc admin policy create local obsidian-rw "$MC_CONFIG_DIR/policy.json"

# Creates the user, or resets its secret if it already exists.
mc admin user add local obsidian "$OBSIDIAN_MINIO_SECRET_KEY"

if ! out="$(mc admin policy attach local obsidian-rw --user obsidian 2>&1)"; then
  case "$out" in
    *"already in effect"*) ;;
    *) echo "$out" >&2; exit 1 ;;
  esac
fi

echo "bucket 'obsidian' + user 'obsidian' (policy obsidian-rw) ready"
EOF
