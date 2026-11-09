# shellcheck shell=bash
# Sourced by the Postgres provisioning scripts (provision-app.sh,
# provision-monitoring-role.sh, provision-litellm-rag.sh) and `make psql`.
#
# Postgres runs on the Mac mini (docker-compose.postgres.yml), not on this
# host's daemon, so `docker compose exec postgres` no longer reaches it.
# pg_run starts a one-shot container from the same image on this host's
# infra-net instead, and psql connects over TCP to postgres:5432 (the nginx
# alias, relayed to the mini; or the container itself when run on the mini).
# Works wherever the cluster lives, as long as `postgres` answers on infra-net.
#
# Needs POSTGRES_USER and POSTGRES_PASSWORD (from .env). The password reaches
# the container as PGPASSWORD, never an argv.
#
#   pg_run [docker-run options...] -- <command> [args...]
pg_image() {
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  awk '$1 == "image:" && $2 ~ /^pgvector\/pgvector:/ { print $2; exit }' \
    "$root/docker-compose.postgres.yml"
}

pg_run() {
  local image opts=()
  image="$(pg_image)"
  [ -n "$image" ] || { echo "pg.sh: no pgvector image in docker-compose.postgres.yml" >&2; return 1; }
  : "${POSTGRES_PASSWORD:?pg.sh: POSTGRES_PASSWORD is not set (source .env)}"
  while [ $# -gt 0 ] && [ "$1" != -- ]; do opts+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  [ $# -gt 0 ] || { echo "pg.sh: pg_run needs a command after --" >&2; return 1; }
  # -t only at a terminal: provisioning pipes SQL on stdin.
  [ -t 0 ] && [ -t 1 ] && opts+=(-t)
  PGPASSWORD="$POSTGRES_PASSWORD" docker run --rm -i \
    --network infra-net \
    -e PGHOST="${PG_HOST:-postgres}" -e PGPORT=5432 \
    -e PGUSER="${POSTGRES_USER:-postgres}" -e POSTGRES_USER="${POSTGRES_USER:-postgres}" \
    -e PGPASSWORD \
    ${opts[@]+"${opts[@]}"} "$image" "$@"
}

# pg_run_script <file> [docker-run options...] -- [args...]
# Runs one of postgres/initdb/*.sh in that container (as sh -c, so the file
# needs no exec bit and stdin stays free).
pg_run_script() {
  local file="$1"; shift
  local opts=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do opts+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  pg_run ${opts[@]+"${opts[@]}"} -- sh -c "$(cat "$file")" "$(basename "$file")" "$@"
}
