#!/usr/bin/env bash
# Ensure the external volumes shared with app stacks exist, through
# Portainer's API (see lib/portainer-api.sh). Compose does not create an
# external volume; a missing one fails the deploy of the whole stack.
# Usage: scripts/portainer-volumes.sh [volume...]   (default: darkangel-web infra-backups)
set -euo pipefail
. "$(dirname "$0")/lib/portainer-api.sh"

# infra-backups can live on an SMB share (see CLAUDE.md, `backup`). Only these
# three keys are read from .env, never the whole file: it holds every secret.
# Strip CR (CRLF .env from Windows), surrounding whitespace and quotes.
envf="$(dirname "$0")/../.env"
envkey() {
  [ -f "$envf" ] || return 0   # no .env yet (fresh checkout, worktree): not configured
  sed -n "s/^$1=//p" "$envf" | tail -1 | tr -d '\r' \
    | sed -E "s/^[[:space:]]+//; s/[[:space:]]+\$//; s/^(\"(.*)\"|'(.*)')\$/\2\3/"
}
smb_share="$(envkey BACKUPS_SMB_SHARE)"; smb_user="$(envkey BACKUPS_SMB_USER)"
SMB_PASSWORD="$(envkey BACKUPS_SMB_PASSWORD)"
# A comma separates mount options and cannot be escaped here.
case "$smb_user$SMB_PASSWORD" in *,*) die "BACKUPS_SMB_USER/BACKUPS_SMB_PASSWORD must not contain a comma" ;; esac
smb_host="${smb_share#//}"; smb_host="${smb_host%%/*}"
# uid 0: prefect-flows writes as root. gid 65534 + 0640/0750: node-exporter runs
# as nobody and must read metrics/backup.prom, but the postgres dump holds every
# app's data, so nothing is world-readable. vers=3.0: macOS SMB; no guessing.
# The password is passed to jq through the environment, and never printed.
smb_opts="addr=$smb_host,username=$smb_user,password=$SMB_PASSWORD,vers=3.0,uid=0,gid=65534,file_mode=0640,dir_mode=0750"
export SMB_PASSWORD smb_opts smb_share

[ $# -gt 0 ] || set -- darkangel-web infra-backups
for v in "$@"; do
  printf '\n\033[1mVolume %s\033[0m\n' "$v"
  want_smb=0
  [ "$v" = infra-backups ] && [ -n "$smb_share" ] && [ -n "$smb_user" ] && [ -n "$SMB_PASSWORD" ] && want_smb=1
  if vol="$(api GET "$d/volumes/$v" 2>/dev/null)"; then
    ok "exists"
    if [ "$want_smb" = 1 ] && ! jq -e \
      '.Options.type == "cifs" and .Options.device == $ENV.smb_share and .Options.o == $ENV.smb_opts' <<<"$vol" >/dev/null; then
      # A volume's driver options are immutable, so it has to be recreated.
      # Its options hold the password: never echo them.
      die "$v exists but is not the SMB volume for $smb_share (a local one, or other share/credentials).\nOne-time migration (at most a few nightly dumps live in the old volume):\n  DOCKER_HOST=... docker rm -f infra-prefect-flows-1 infra-node-exporter-1 && DOCKER_HOST=... docker volume rm $v && make up"
    fi
  else
    body="$(jq -nc --arg n "$v" '{Name: $n}')"
    [ "$want_smb" = 1 ] && body="$(jq -nc --arg n "$v" \
      '{Name: $n, Driver: "local", DriverOpts: {type: "cifs", device: $ENV.smb_share, o: $ENV.smb_opts}}')"
    api POST "$d/volumes/create" "$body" >/dev/null
    vol="$(api GET "$d/volumes/$v")"
    ok "was missing, created"
  fi
  kind="$(jq -r 'if .Options.type == "cifs" then "SMB \(.Options.device)" else "\(.Driver) volume" end' <<<"$vol")"
  ok "$kind, created $(jq -r '.CreatedAt // "?"' <<<"$vol")"
  users="$(api GET "$d/containers/json?all=1&filters=$(jq -rn --arg v "$v" '{volume: [$v]} | tojson | @uri')" \
    | jq -r '.[] | "\(.Names[0] | ltrimstr("/")) (\(.State))"' | sort)"
  if [ -n "$users" ]; then
    printf '  Used by:\n'; sed 's/^/    /' <<<"$users"
  else
    warn "no container mounts it yet"
  fi
done
