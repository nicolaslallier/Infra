#!/usr/bin/env bash
# Set/reset login passwords for the demo users defined in
# keycloak/realm-import/nurse-realm.json (nurse.demo, examiner.demo).
# Safe to re-run. Requires the keycloak service to already be up.
#
# Usage: scripts/keycloak-seed-users.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "keycloak-seed-users.sh: .env not found (run 'make init' first)" >&2
  exit 1
fi

set -a
# shellcheck source=/dev/null  # .env is generated, not lintable source
source .env
set +a

: "${KEYCLOAK_ADMIN:?Set KEYCLOAK_ADMIN in .env}"
: "${KEYCLOAK_ADMIN_PASSWORD:?Set KEYCLOAK_ADMIN_PASSWORD in .env}"
: "${NURSE_SEED_PASSWORD:?Set NURSE_SEED_PASSWORD in .env}"
: "${EXAMINER_SEED_PASSWORD:?Set EXAMINER_SEED_PASSWORD in .env}"

# Keycloak runs on the Mac mini: run this on the mini, or with DOCKER_HOST /
# DOCKER_CONTEXT pointed at its Colima daemon.
kc() {
  docker exec -i auth-keycloak-1 /opt/keycloak/bin/kcadm.sh "$@"
}

kc config credentials --server http://localhost:8080 --realm master \
   --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD"

kc set-password -r nurse --username nurse.demo --new-password "$NURSE_SEED_PASSWORD"
kc set-password -r nurse --username examiner.demo --new-password "$EXAMINER_SEED_PASSWORD"

echo "keycloak-seed-users.sh: nurse.demo / examiner.demo passwords set."
