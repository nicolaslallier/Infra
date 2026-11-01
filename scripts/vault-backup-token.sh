#!/usr/bin/env bash
# Write policy `backup` and mint the periodic token the nightly backup flow
# uses to take raft snapshots. Prints ONLY the token on stdout; paste it into
# Prefect UI -> Blocks -> Secret `openbao-backup-token`.
#
# Re-running mints a NEW token; older ones stay valid until revoked.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .openbao.env ] || { echo "vault-backup-token: no .openbao.env (run make vault-init)" >&2; exit 1; }
# shellcheck disable=SC1091
. ./.openbao.env
export BAO_TOKEN="${BAO_TOKEN:-}"

# shellcheck source=lib/bao.sh
. scripts/lib/bao.sh

# Policy goes in as stdin content: openbao/ is not mounted into the container.
bao_in policy write backup - < openbao/policies/backup.hcl >&2

out="$(bao token create -policy=backup -period=768h -orphan \
  -display-name=prefect-backup -format=json)"
token="$(printf '%s' "$out" | sed -n 's/.*"client_token": *"\([^"]*\)".*/\1/p')"
[ -n "$token" ] || { echo "vault-backup-token: no token in bao output" >&2; exit 1; }

echo "Paste the token below into Prefect UI -> Blocks -> Secret 'openbao-backup-token'." >&2
echo "It is periodic (768h) and renewed by every backup run; it is shown only once." >&2
printf '%s\n' "$token"
