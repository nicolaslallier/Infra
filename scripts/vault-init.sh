#!/usr/bin/env bash
# One-time bootstrap of the OpenBao vault: initialise it, record the root
# token and recovery key in .openbao.env, mount the KV v2 engine the rest of
# this repo writes to, and activate the declared audit device.
#
# Idempotent -- every step checks first, so re-running it after a redeploy or
# a partial failure is safe and does nothing it has already done.
#
# The credentials go to .openbao.env, NOT .env, for the same reason
# PORTAINER_API_KEY does: .env is handed to containers wholesale (postgres
# env_files it) and shipped to Portainer as the stack env, and a root token
# for the secret store has no business in either. Only these scripts read it.
#
# Usage: scripts/vault-init.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CRED_FILE=".openbao.env"
MOUNT="infra"
# Every KV v2 engine this vault has: infra/ (this stack's .env) plus one per
# app that keeps its own secrets. Add a name here and re-run to mount it.
MOUNTS=(infra ea)

die() { echo "vault-init.sh: $*" >&2; exit 1; }

# `bao` inside the container. The token goes in as the first line of stdin,
# never as an argument, so it cannot be read out of another user's `ps`.
# Not `-e BAO_TOKEN`: on this host neither `docker compose exec` nor
# `docker exec` forwards a bare `-e VAR`, and the container gets it unset.
bao() {
  printf '%s\n' "$BAO_TOKEN" \
    | docker compose exec -T openbao sh -c 'read -r BAO_TOKEN; export BAO_TOKEN; exec bao "$@"' bao "$@"
}

[ -f openbao/seal.key ] || die "openbao/seal.key is missing -- run 'make seal-key' first, then redeploy."

# --- 1. initialise, or pick up where a previous run left off ----------------
export BAO_TOKEN="${BAO_TOKEN:-}"
if [ -f "$CRED_FILE" ]; then
  # shellcheck disable=SC1090
  . "./$CRED_FILE"
fi

status="$(bao status -format=json || true)"
[ -n "$status" ] || die "could not reach the vault. Is the openbao container up?
  'make ps' lists it, 'make logs s=openbao' says why it is not."

initialized="$(jq -r '.initialized' <<<"$status")"

if [ "$initialized" != "true" ]; then
  if [ -f "$CRED_FILE" ]; then
    backup="$CRED_FILE.$(date +%Y%m%d%H%M%S).bak"
    mv "$CRED_FILE" "$backup"
    echo "vault-init.sh: this vault is uninitialised but $CRED_FILE existed;"
    echo "  it described a different vault (a wiped openbao-data volume, say)."
    echo "  Kept it as $backup rather than overwriting it."
    export BAO_TOKEN=""
  fi

  echo "vault-init.sh: initialising the vault..."
  # One recovery share, threshold one: this is a single-operator homelab, and
  # splitting a key across shareholders who are all the same person buys
  # nothing. The *seal* is openbao/seal.key (auto-unseal), so this key is not
  # needed on a normal restart -- it is the break-glass credential for
  # regenerating a root token, and belongs in a password manager.
  init_json="$(bao operator init -recovery-shares=1 -recovery-threshold=1 -format=json)"

  token="$(jq -r '.root_token' <<<"$init_json")"
  # recovery_keys_b64 with an auto-unseal seal; unseal_keys_b64 is the Shamir
  # spelling, accepted here so a config without the seal stanza still works.
  recovery="$(jq -r '(.recovery_keys_b64 // .unseal_keys_b64 // [])[0] // ""' <<<"$init_json")"

  [ -n "$token" ] && [ "$token" != "null" ] || die "initialisation returned no root token: $init_json"

  umask 077
  cat > "$CRED_FILE" <<EOF
# Written by scripts/vault-init.sh on $(date -u '+%Y-%m-%dT%H:%M:%SZ').
# Gitignored, like .portainer.env, and for the same reason: these are
# vault-root credentials and must never reach a container or Portainer.
#
# BAO_TOKEN is the initial root token. Once a real auth method is set up
# (Keycloak OIDC, userpass, ...), revoke it with 'bao token revoke <token>'
# and regenerate one on demand with 'bao operator generate-root' using the
# recovery key below.
BAO_TOKEN=$token

# Break-glass. NOT needed to unseal -- openbao/seal.key does that
# automatically -- but it is what 'bao operator generate-root' asks for.
# Copy it into a password manager and consider deleting the line here.
OPENBAO_RECOVERY_KEY=$recovery
EOF
  chmod 600 "$CRED_FILE"
  export BAO_TOKEN="$token"
  echo "vault-init.sh: initialised. Root token and recovery key written to $CRED_FILE (mode 600)."
else
  echo "vault-init.sh: already initialised."
  [ -n "$BAO_TOKEN" ] || die "the vault is initialised but $CRED_FILE has no BAO_TOKEN.
  Without a token nothing here can configure it. Recover one with
  'bao operator generate-root' (needs OPENBAO_RECOVERY_KEY), or wipe the
  vault and start over with: make down && docker volume rm infra_openbao-data"
fi

sealed="$(bao status -format=json | jq -r '.sealed')"
[ "$sealed" = "false" ] || die "the vault is still sealed after initialisation.
  With seal \"static\" it should unseal itself from openbao/seal.key -- check
  'make logs s=openbao' for a seal error (a key of the wrong length, or the
  bind mount having become a directory)."

# --- 2. the KV v2 engines everything else reads and writes -----------------
mounted="$(bao secrets list -format=json)"
for m in "${MOUNTS[@]}"; do
  if jq -e --arg m "$m/" 'has($m)' >/dev/null <<<"$mounted"; then
    echo "vault-init.sh: secrets engine '$m/' already mounted."
  else
    # -version=2 is not the default: a bare 'secrets enable kv' gives KV v1,
    # which has no versioning, so an overwritten secret is simply gone.
    bao secrets enable -path="$m" -version=2 kv
    echo "vault-init.sh: mounted KV v2 at '$m/'."
  fi
done

# --- 3. the audit device declared in openbao/config.hcl ---------------------
# Declared audit devices are applied when the active node starts and on
# SIGHUP. This process became active during initialisation above, i.e. after
# it had already read its config, so the first run needs the HUP.
if ! bao audit list -format=json 2>/dev/null | jq -e 'length > 0' >/dev/null; then
  docker compose kill -s HUP openbao >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do
    sleep 1
    if bao audit list -format=json 2>/dev/null | jq -e 'length > 0' >/dev/null; then break; fi
  done
fi

if bao audit list -format=json 2>/dev/null | jq -e 'length > 0' >/dev/null; then
  echo "vault-init.sh: audit device active (to stdout -> alloy -> Loki)."
else
  echo "vault-init.sh: warning: no audit device is active. It is declared in" >&2
  echo "  openbao/config.hcl, so 'make restart s=openbao' should enable it." >&2
fi

echo
echo "Vault ready at https://vault.infra.famillelallier.net (KV v2 at ${MOUNTS[*]/%//})."
echo "Next: 'make vault-seed' copies this checkout's .env into $MOUNT/env."
