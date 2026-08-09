#!/usr/bin/env bash
# Creates/updates the DNS zones and records this stack owns inside the
# running Technitium `dns` container: a wildcard zone for
# *.infra.famillelallier.net (covers every app automatically) and leaf
# zones for pgadmin.famillelallier.net, keycloak.famillelallier.net, and
# jarvis.famillelallier.net.
# Safe to re-run — zone creation is ignored if the zone already exists,
# and records are added with overwrite=true.
#
# Deliberately does NOT touch famillelallier.net itself: beacon./dev.
# subdomains live outside this repo and must keep resolving elsewhere.
# Zone authority is absolute in DNS, so owning the whole parent zone
# here would break them.
#
# Usage: scripts/dns-provision.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "dns-provision.sh: .env not found (run 'make init' first)" >&2
  exit 1
fi

# shellcheck disable=SC1091
set -a; source .env; set +a

: "${LAN_IP:?dns-provision.sh: LAN_IP not set in .env}"
: "${DNS_ADMIN_PASSWORD:?dns-provision.sh: DNS_ADMIN_PASSWORD not set in .env}"

BASE="http://${LAN_IP}:5380"

login_response="$(curl -sf --data-urlencode "user=admin" --data-urlencode "pass=${DNS_ADMIN_PASSWORD}" "${BASE}/api/user/login")"
TOKEN="$(echo "$login_response" | grep -o '"token"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)"

if [ -z "$TOKEN" ]; then
  echo "dns-provision.sh: login to ${BASE} failed — is the dns container up ('make up') and DNS_ADMIN_PASSWORD correct?" >&2
  echo "  response: $login_response" >&2
  exit 1
fi

create_zone() {
  local zone="$1"
  local resp
  resp="$(curl -sf "${BASE}/api/zones/create?token=${TOKEN}&zone=${zone}&type=Primary")"
  if echo "$resp" | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"'; then
    echo "  zone ${zone}: created"
  else
    echo "  zone ${zone}: already exists (or unchanged)"
  fi
}

add_a_record() {
  local domain="$1" zone="$2"
  curl -sf "${BASE}/api/zones/records/add?token=${TOKEN}&zone=${zone}&domain=${domain}&type=A&ipAddress=${LAN_IP}&ttl=300&overwrite=true" >/dev/null
  echo "  record ${domain} -> A ${LAN_IP}"
}

echo "Provisioning DNS zones on ${BASE}..."

create_zone "infra.famillelallier.net"
add_a_record "infra.famillelallier.net" "infra.famillelallier.net"
add_a_record "*.infra.famillelallier.net" "infra.famillelallier.net"

create_zone "pgadmin.famillelallier.net"
add_a_record "pgadmin.famillelallier.net" "pgadmin.famillelallier.net"

create_zone "keycloak.famillelallier.net"
add_a_record "keycloak.famillelallier.net" "keycloak.famillelallier.net"

create_zone "jarvis.famillelallier.net"
add_a_record "jarvis.famillelallier.net" "jarvis.famillelallier.net"

create_zone "minio.famillelallier.net"
add_a_record "minio.famillelallier.net" "minio.famillelallier.net"

create_zone "minio-console.famillelallier.net"
add_a_record "minio-console.famillelallier.net" "minio-console.famillelallier.net"

echo "Done. Run 'make dns-check' to verify."
