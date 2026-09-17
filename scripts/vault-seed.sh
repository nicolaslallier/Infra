#!/usr/bin/env bash
# Copy this checkout's .env into the vault, at the KV v2 path infra/env --
# one field per variable, named exactly as the variable is.
#
# Flat and 1:1 on purpose. .env is a flat namespace that Compose interpolates
# by name, so mirroring it exactly is what lets `make vault-env` regenerate a
# .env that `make check-env` still passes, and leaves nothing that can drift
# between the two. (Splitting secrets per app, with a policy and a token each,
# is a later step that sits *beside* this one, at infra/apps/<name>; it cannot
# replace it, because Compose has no way to read a vault.)
#
# Values are stored as the literal text to the right of the '=', which is what
# Compose itself hands the container. Re-running is safe: KV v2 keeps every
# version, and a seed that would change nothing is skipped rather than
# creating an identical version.
#
# Usage: scripts/vault-seed.sh
set -euo pipefail
cd "$(dirname "$0")/.."

MOUNT="infra"
SECRET="env"

die() { echo "vault-seed.sh: $*" >&2; exit 1; }

[ -f .env ] || die ".env not found (run 'make init' first)."
[ -f .openbao.env ] || die ".openbao.env not found -- run 'make vault-init' first."

# shellcheck disable=SC1091
. ./.openbao.env
: "${BAO_TOKEN:?vault-seed.sh: BAO_TOKEN not set in .openbao.env}"
export BAO_TOKEN

# -e BAO_TOKEN forwards the exported value; it never enters the argv of the
# host `docker` process, so it cannot be read from another user's `ps`.
bao() { docker compose exec -T -e BAO_TOKEN openbao bao "$@"; }

# KEY<TAB>VALUE for every assignment in .env, same notion of "an assignment"
# that scripts/check-env.sh uses. A key assigned twice keeps the last value,
# which is how dotenv resolves it too.
json="$(
  sed -nE 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$/\1\t\2/p' .env \
    | jq -R -s '
        split("\n")
        | map(select(length > 0))
        | map(split("\t") | {(.[0]): (.[1:] | join("\t"))})
        | add // {}
      '
)"

count="$(jq -r 'length' <<<"$json")"
[ "$count" -gt 0 ] || die "no assignments found in .env -- nothing to seed."

current="$(bao kv get -format=json -mount="$MOUNT" "$SECRET" 2>/dev/null | jq -c '.data.data' || true)"
if [ -n "$current" ] && [ "$current" != "null" ] \
  && jq -e -n --argjson a "$current" --argjson b "$json" '$a == $b' >/dev/null; then
  echo "vault-seed.sh: $MOUNT/$SECRET already matches .env ($count settings); nothing written."
  exit 0
fi

# Over stdin, not as key=value arguments: the whole point is to keep every
# password out of the process list.
printf '%s' "$json" | bao kv put -mount="$MOUNT" "$SECRET" - >/dev/null

version="$(bao kv get -format=json -mount="$MOUNT" "$SECRET" | jq -r '.data.metadata.version')"
echo "vault-seed.sh: wrote $count settings to $MOUNT/$SECRET (now version $version)."
echo
echo "  The vault is the record now. Edit secrets there (or with"
echo "  'bao kv patch'), then run 'make vault-env' to regenerate .env and"
echo "  'make up' to deploy it."
