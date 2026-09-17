#!/usr/bin/env bash
# Run a `bao` command inside the openbao container, authenticated with the
# token from .openbao.env.
#
#   scripts/vault-cli.sh status
#   scripts/vault-cli.sh kv list infra/
#   scripts/vault-cli.sh kv get -field=POSTGRES_PASSWORD -mount=infra env
#
# The token is forwarded by name (-e BAO_TOKEN), never as an argument, so it
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

# `docker compose exec` allocates a TTY by default and complains when stdin
# is not one -- which is the case whenever this runs from a pipe or a
# non-interactive make invocation.
tty_flag=()
[ -t 0 ] || tty_flag=(-T)

exec docker compose exec "${tty_flag[@]}" ${BAO_TOKEN:+-e BAO_TOKEN} openbao bao "$@"
