#!/usr/bin/env bash
# Confirms the dns service is actually answering LAN DNS queries:
# - infra.famillelallier.net / pgadmin.famillelallier.net /
#   keycloak.famillelallier.net resolve to LAN_IP (proves the zones
#   from dns-provision.sh are live)
# - example.com still resolves to a real public IP (proves forwarding
#   to the upstream servers works too, not just the local answers)
#
# Queries LAN_IP from .env by default. Pass an IP as $1 to query a
# different resolver instead — e.g. to check reachability from another
# machine's terminal once the router's DHCP DNS points at it:
#   ./scripts/dns-check.sh 192.168.1.50
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v dig >/dev/null 2>&1; then
  echo "dns-check.sh: 'dig' not found. Install it (e.g. 'brew install bind' on macOS, 'apt install dnsutils' on Debian/Ubuntu) or query manually with nslookup." >&2
  exit 1
fi

if [ -f .env ]; then
  # shellcheck disable=SC1091
  set -a; source .env; set +a
fi

RESOLVER="${1:-${LAN_IP:?dns-check.sh: LAN_IP not set in .env and no resolver given}}"

echo "Querying dns server at ${RESOLVER}:53..."
echo

for host in infra.famillelallier.net pgadmin.famillelallier.net keycloak.famillelallier.net; do
  answer="$(dig @"$RESOLVER" "$host" +short)"
  echo "$host -> ${answer:-<no answer>}"
done

echo
echo "Forwarding check (should return a real public IP, not LAN_IP):"
dig @"$RESOLVER" example.com +short
