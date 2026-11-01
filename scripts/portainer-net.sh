#!/usr/bin/env bash
# Ensure infra-net exists, through Portainer's API (see lib/portainer-api.sh) instead of the docker CLI, so it works from a
# Mac with no daemon access. Reports whether the portainer container is on it.
set -euo pipefail
# shellcheck source=lib/portainer-api.sh
. "$(dirname "$0")/lib/portainer-api.sh"

printf '\n\033[1mNetwork infra-net\033[0m\n'
if net="$(api GET "$d/networks/infra-net" 2>/dev/null)"; then
  ok "exists"
else
  api POST "$d/networks/create" '{"Name":"infra-net","Driver":"bridge"}' >/dev/null
  net="$(api GET "$d/networks/infra-net")"
  ok "was missing, created"
fi
ok "$(jq -r .Driver <<<"$net") network, subnet $(jq -r '.IPAM.Config[0].Subnet // "?"' <<<"$net")"

if jq -e '[.Containers[].Name | select(startswith("portainer"))] | length > 0' <<<"$net" >/dev/null; then
  ok "Portainer is attached"
else
  warn "Portainer is NOT attached ('make portainer-up' attaches it)"
fi

printf '\n\033[1mAttached containers\033[0m (%s)\n' "$(jq '.Containers | length' <<<"$net")"
# column is cosmetic and util-linux, not busybox: the Alpine container
# scripts/ci-deploy.sh runs make in has none, so fall back to one per line.
if command -v column >/dev/null 2>&1; then fmt() { column -c "${COLUMNS:-100}"; }; else fmt() { cat; }; fi
jq -r '[.Containers[].Name] | sort[]' <<<"$net" | fmt | sed 's/^/  /'
