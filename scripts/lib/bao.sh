# shellcheck shell=bash
# Sourced by scripts/vault-*.sh: runs `bao` inside the live openbao container.
# Defines openbao_container, bao and bao_in. Needs $BAO_TOKEN set (may be empty
# for commands that take none, e.g. `status`, `operator init`).
#
# The container is found by its compose labels and reached with `docker exec`,
# never `docker compose exec`: compose interpolates docker-compose.yml with
# the checkout's .env first, so a stale .env (a new `${VAR:?}` guard it lacks)
# aborts compose before it reaches the vault -- and vault-render exists to
# repair exactly that .env. Project `infra` is pinned: it is the one live
# stack, and a worktree's own compose project must never be picked.
openbao_container() {
  local ids n
  ids="$(docker ps -q \
    --filter label=com.docker.compose.project=infra \
    --filter label=com.docker.compose.service=openbao)"
  n="$(printf '%s' "$ids" | grep -c .)" || n=0
  if [ "$n" -ne 1 ]; then
    echo "bao.sh: expected exactly one running container with labels com.docker.compose.project=infra and com.docker.compose.service=openbao, found $n (is the stack up?)" >&2
    exit 1
  fi
  printf '%s\n' "$ids"
}

# The token goes in as the first line of stdin, never as an argument, so it
# stays out of every process list. Not `-e BAO_TOKEN`: on this host neither
# `docker compose exec` nor `docker exec` forwards a bare `-e VAR`.
_bao_exec() {
  local id
  id="$(openbao_container)" || exit 1
  docker exec -i "$id" sh -c 'read -r BAO_TOKEN; export BAO_TOKEN; exec bao "$@"' bao "$@"
}

# bao sends only the token; bao_in sends it followed by the caller's stdin.
bao() { printf '%s\n' "$BAO_TOKEN" | _bao_exec "$@"; }
bao_in() { { printf '%s\n' "$BAO_TOKEN"; cat; } | _bao_exec "$@"; }
