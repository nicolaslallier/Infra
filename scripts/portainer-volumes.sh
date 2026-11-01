#!/usr/bin/env bash
# Ensure the external volumes shared with app stacks exist, through
# Portainer's API (see lib/portainer-api.sh). Compose does not create an
# external volume; a missing one fails the deploy of the whole stack.
# Usage: scripts/portainer-volumes.sh [volume...]   (default: darkangel-web infra-backups)
set -euo pipefail
. "$(dirname "$0")/lib/portainer-api.sh"

# infra-backups can live on the NAS (see CLAUDE.md, `backup`). Only these two
# keys are read from .env, never the whole file: it holds every secret.
envf="$(dirname "$0")/../.env"
envkey() { sed -n "s/^$1=//p" "$envf" 2>/dev/null | tail -1 | tr -d "\"'"; }
nfs_addr="$(envkey BACKUPS_NFS_ADDR)"; nfs_export="$(envkey BACKUPS_NFS_EXPORT)"
# soft: a down NAS must fail reads and writes, not hang prefect-flows or
# node-exporter (the backup alerts cover the failure).
nfs_opts="addr=$nfs_addr,rw,nfsvers=4.1,soft,timeo=100,retrans=3"
nfs_dev=":$nfs_export"

[ $# -gt 0 ] || set -- darkangel-web infra-backups
for v in "$@"; do
  printf '\n\033[1mVolume %s\033[0m\n' "$v"
  want_nfs=0
  [ "$v" = infra-backups ] && [ -n "$nfs_addr" ] && [ -n "$nfs_export" ] && want_nfs=1
  if vol="$(api GET "$d/volumes/$v" 2>/dev/null)"; then
    ok "exists"
    if [ "$want_nfs" = 1 ] && ! jq -e --arg o "$nfs_opts" --arg dv "$nfs_dev" \
      '.Options.type == "nfs" and .Options.o == $o and .Options.device == $dv' <<<"$vol" >/dev/null; then
      # A volume's driver options are immutable, so it has to be recreated.
      die "$v exists but is not the NFS volume $nfs_addr$nfs_dev (it is: $(jq -c '{Driver, Options}' <<<"$vol")).\n" \
        "One-time migration (at most a few nightly dumps live in the old volume):\n" \
        "  DOCKER_HOST=... docker rm -f infra-prefect-flows-1 infra-node-exporter-1 && DOCKER_HOST=... docker volume rm $v && make up"
    fi
  else
    body="$(jq -nc --arg n "$v" '{Name: $n}')"
    [ "$want_nfs" = 1 ] && body="$(jq -nc --arg n "$v" --arg o "$nfs_opts" --arg dv "$nfs_dev" \
      '{Name: $n, Driver: "local", DriverOpts: {type: "nfs", o: $o, device: $dv}}')"
    api POST "$d/volumes/create" "$body" >/dev/null
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
