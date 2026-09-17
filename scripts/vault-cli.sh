#!/usr/bin/env bash
# Run a `bao` command inside the openbao container, authenticated with the
# token from .openbao.env.
#
#   scripts/vault-cli.sh status
#   scripts/vault-cli.sh kv list infra/
#   scripts/vault-cli.sh kv get -field=POSTGRES_PASSWORD -mount=infra env
#
# The token goes in as the first line of stdin, never as an argument, so it
# stays out of the host's process list. Commands that need no token (status,
# operator init) work without .openbao.env.
set -euo pipefail
cd "$(dirname "$0")/.."

[ $# -gt 0 ] || { echo "usage: scripts/vault-cli.sh <bao args...>" >&2; exit 1; }

if [ -f .openbao.env ]; then
  # shellcheck disable=SC1091
  . ./.openbao.env
fi
export BAO_TOKEN="${BAO_TOKEN:-}"

# The token goes in as the first line of stdin, never as an argument. Not
# `-e BAO_TOKEN`: on this host neither `docker compose exec` nor `docker exec`
# forwards a bare `-e VAR`. When stdin is a pipe it follows the token, so
# `... | make vault-cli args="kv put -mount=infra x -"` still works. No TTY:
# stdin is the token pipe, so interactive prompts (bao login) will not work.
{ printf '%s\n' "$BAO_TOKEN"; [ -t 0 ] || cat; } \
  | docker compose exec -T openbao sh -c 'read -r BAO_TOKEN; export BAO_TOKEN; exec bao "$@"' bao "$@"
