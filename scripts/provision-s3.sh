#!/usr/bin/env bash
# Create/update an app's bucket and its bucket-scoped S3 identity on the
# SeaweedFS `s3` service -- the object-store twin of provision-app.sh.
# Idempotent: re-run it to rotate <APP>_S3_SECRET_KEY. The access key stays
# the app name, so the new secret replaces the old one in place.
#
# Usage: scripts/provision-s3.sh <app> [bucket] [versioned]
#   bucket    defaults to <app>
#   versioned 1 enables bucket versioning (default 0)
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:?usage: scripts/provision-s3.sh <app> [bucket] [versioned]}"
bucket="${2:-$app}"
versioned="${3:-0}"

# Every value below ends up inside a `weed shell` command line, which splits
# on whitespace and runs `;`-separated commands -- so validate, don't quote.
name_re='^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$'
[[ "$app" =~ $name_re ]] || { echo "provision-s3.sh: app '$app' must be 3-63 chars of a-z, 0-9, '-'" >&2; exit 1; }
[[ "$bucket" =~ $name_re ]] || { echo "provision-s3.sh: bucket '$bucket' must be 3-63 chars of a-z, 0-9, '-'" >&2; exit 1; }
case "$versioned" in 0 | 1) ;; *) echo "provision-s3.sh: versioned must be 0 or 1" >&2; exit 1 ;; esac

if [ ! -f .env ]; then
  echo "provision-s3.sh: .env not found (run 'make init' first)" >&2
  exit 1
fi

var_name="$(printf '%s' "${app}_S3_SECRET_KEY" | tr 'a-z-' 'A-Z_')"
secret="$(grep -E "^${var_name}=" .env | tail -n1 | cut -d= -f2-)"
if [ -z "$secret" ] || [ "$secret" = change-me ]; then
  echo "provision-s3.sh: ${var_name} not set in .env" >&2
  echo "  Add a line like: ${var_name}=\$(openssl rand -hex 24)" >&2
  exit 1
fi
[[ "$secret" =~ ^[A-Za-z0-9+/=_-]{16,}$ ]] || {
  echo "provision-s3.sh: ${var_name} must be >= 16 chars of A-Z a-z 0-9 + / = _ -" >&2
  exit 1
}

# `-e NAME` with no value: docker takes it from this process's environment,
# so the secret never appears in an argv (ps).
export S3P_APP="$app" S3P_BUCKET="$bucket" S3P_SECRET="$secret" S3P_VERSIONED="$versioned"
docker compose exec -T -e S3P_APP -e S3P_BUCKET -e S3P_SECRET -e S3P_VERSIONED \
  s3 sh -eu -s <<'EOF'
ws() { printf '%s\n' "$1" | weed shell -master=s3:9333; }

# s3.bucket.create on an existing bucket silently replaces its entry --
# versioning flag included -- so only create what is not there yet.
if ! ws "s3.bucket.list" | awk '{print $1}' | grep -qxF "$S3P_BUCKET"; then
  ws "s3.bucket.create -name $S3P_BUCKET"
fi

ws "s3.configure -user $S3P_APP -access_key $S3P_APP -secret_key $S3P_SECRET -buckets $S3P_BUCKET -actions Read,Write,List,Tagging -apply" >/dev/null

if [ "$S3P_VERSIONED" = 1 ]; then
  ws "s3.bucket.versioning -name $S3P_BUCKET -enable"
fi
echo "bucket '$S3P_BUCKET' + identity '$S3P_APP' ready"
EOF
