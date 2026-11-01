#!/usr/bin/env bash
# Ensure the external volumes shared with app stacks exist, through
# Portainer's API (see lib/portainer-api.sh). Compose does not create an
# external volume; a missing one fails the deploy of the whole stack.
# Usage: scripts/portainer-volumes.sh [volume...]   (default: darkangel-web infra-backups)
set -euo pipefail
. "$(dirname "$0")/lib/portainer-api.sh"

[ $# -gt 0 ] || set -- darkangel-web infra-backups
for v in "$@"; do
  printf '\n\033[1mVolume %s\033[0m\n' "$v"
  if vol="$(api GET "$d/volumes/$v" 2>/dev/null)"; then
    ok "exists"
  else
    api POST "$d/volumes/create" "$(jq -nc --arg n "$v" '{Name: $n}')" >/dev/null
    vol="$(api GET "$d/volumes/$v")"
    ok "was missing, created"
  fi
  ok "$(jq -r .Driver <<<"$vol") volume, created $(jq -r '.CreatedAt // "?"' <<<"$vol")"
  users="$(api GET "$d/containers/json?all=1&filters=$(jq -rn --arg v "$v" '{volume: [$v]} | tojson | @uri')" \
    | jq -r '.[] | "\(.Names[0] | ltrimstr("/")) (\(.State))"' | sort)"
  if [ -n "$users" ]; then
    printf '  Used by:\n'; sed 's/^/    /' <<<"$users"
  else
    warn "no container mounts it yet"
  fi
done
