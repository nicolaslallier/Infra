#!/usr/bin/env bash
# Apply keycloak/realm-import/jarvis-realm.json's protocol mappers to the
# `jarvis` client in an ALREADY-EXISTING `jarvis` realm.
#
# Why this exists: docker-compose.yml runs Keycloak with `start --import-realm`,
# which uses the default IGNORE_EXISTING strategy — the realm JSON is read only
# when the realm does not exist yet. Any edit to that file after the realm's
# first boot (such as adding the jarvis-audience mapper) is therefore a silent
# no-op on every host that already ran `make up`. Switching the import to
# OVERWRITE_EXISTING is not an option: the realm's one login user and its
# password are created by hand (see README.md) and would be wiped.
#
# Same shape and the same manual-step precedent as keycloak-seed-users.sh.
# Safe to re-run — it deletes and recreates each mapper so the live config
# always matches the JSON. Requires the keycloak service to already be up.
#
# Usage: scripts/keycloak-sync-jarvis-client.sh
set -euo pipefail
cd "$(dirname "$0")/.."

REALM="jarvis"
CLIENT_ID="jarvis"
REALM_JSON="keycloak/realm-import/jarvis-realm.json"

if [ ! -f .env ]; then
  echo "keycloak-sync-jarvis-client.sh: .env not found (run 'make init' first)" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

: "${KEYCLOAK_ADMIN:?Set KEYCLOAK_ADMIN in .env}"
: "${KEYCLOAK_ADMIN_PASSWORD:?Set KEYCLOAK_ADMIN_PASSWORD in .env}"

kc() {
  docker compose exec -T keycloak /opt/keycloak/bin/kcadm.sh "$@"
}

# kcadm prints CRLF through `docker compose exec`; strip it or the ids below
# get pasted into URLs with a trailing carriage return.
clean() { tr -d '\r' | tr -d '\n'; }

kc config credentials --server http://localhost:8080 --realm master \
  --user "$KEYCLOAK_ADMIN" --password "$KEYCLOAK_ADMIN_PASSWORD"

client_uuid="$(kc get clients -r "$REALM" -q "clientId=$CLIENT_ID" \
  --fields id --format csv --noquotes | clean)"

if [ -z "$client_uuid" ]; then
  echo "keycloak-sync-jarvis-client.sh: client '$CLIENT_ID' not found in realm '$REALM'." >&2
  echo "  The realm import has not run yet — start the stack and let Keycloak" >&2
  echo "  finish booting, then re-run this." >&2
  exit 1
fi

# Read the mappers out of the realm JSON rather than restating them here, so
# this script and the import file cannot drift apart.
mapper_names="$(python3 -c '
import json, sys
realm = json.load(open(sys.argv[1]))
client = next(c for c in realm["clients"] if c["clientId"] == sys.argv[2])
print("\n".join(m["name"] for m in client.get("protocolMappers", [])))
' "$REALM_JSON" "$CLIENT_ID")"

if [ -z "$mapper_names" ]; then
  echo "keycloak-sync-jarvis-client.sh: no protocolMappers in $REALM_JSON, nothing to do."
  exit 0
fi

while IFS= read -r name; do
  [ -n "$name" ] || continue

  existing_id="$(kc get "clients/$client_uuid/protocol-mappers/models" -r "$REALM" \
    --fields id,name --format json 2>/dev/null \
    | python3 -c '
import json, sys
name = sys.argv[1]
try:
    mappers = json.load(sys.stdin)
except Exception:
    mappers = []
print(next((m["id"] for m in mappers if m.get("name") == name), ""))
' "$name" | clean)"

  if [ -n "$existing_id" ]; then
    echo "keycloak-sync-jarvis-client.sh: replacing existing mapper '$name'"
    kc delete "clients/$client_uuid/protocol-mappers/models/$existing_id" -r "$REALM"
  else
    echo "keycloak-sync-jarvis-client.sh: creating mapper '$name'"
  fi

  python3 -c '
import json, sys
realm = json.load(open(sys.argv[1]))
client = next(c for c in realm["clients"] if c["clientId"] == sys.argv[2])
mapper = next(m for m in client["protocolMappers"] if m["name"] == sys.argv[3])
json.dump(mapper, sys.stdout)
' "$REALM_JSON" "$CLIENT_ID" "$name" \
    | kc create "clients/$client_uuid/protocol-mappers/models" -r "$REALM" -f -
done <<< "$mapper_names"

echo "keycloak-sync-jarvis-client.sh: '$CLIENT_ID' protocol mappers now match $REALM_JSON."
