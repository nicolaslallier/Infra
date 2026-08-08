#!/usr/bin/env bash
# Add (or update) a per-app database + role on an ALREADY-RUNNING cluster,
# without touching the rest of the data. Safe to re-run.
#
# Usage: scripts/provision-app.sh <appname>
#
# Looks up <APPNAME>_DB_PASSWORD (uppercased) in .env, then drives the
# same provisioning logic used at initdb time
# (postgres/initdb/10-provision-apps.sh) inside the running container,
# so the two paths can never diverge.
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:?usage: scripts/provision-app.sh <appname>}"

if [ ! -f .env ]; then
  echo "provision-app.sh: .env not found (run 'make init' first)" >&2
  exit 1
fi

var_name="$(echo "${app}_DB_PASSWORD" | tr '[:lower:]' '[:upper:]')"
pass="$(grep -E "^${var_name}=" .env | tail -n1 | cut -d= -f2-)"

if [ -z "$pass" ]; then
  echo "provision-app.sh: ${var_name} not set in .env" >&2
  echo "  Add a line like: ${var_name}=some-strong-password" >&2
  exit 1
fi

docker compose exec -T \
  -e APP_NAME="$app" \
  -e APP_PASSWORD="$pass" \
  postgres /docker-entrypoint-initdb.d/10-provision-apps.sh --single

echo "provision-app.sh: '$app' is ready. Add it to APP_DATABASES in .env"
echo "  too, so a future 'docker compose down -v' + 'up' recreates it."
