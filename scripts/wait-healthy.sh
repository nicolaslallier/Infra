#!/usr/bin/env bash
# Post-deploy gate: wait until every container of the `infra` compose project
# has been recreated and is up. Read-only -- never starts, stops or restarts
# anything.
#
#   BEFORE_IDS="<id> <id> ..." ./scripts/wait-healthy.sh [timeout_seconds=600]
#
# Why this exists: Portainer's redeploy API returns before the containers are
# recreated, and a compose run that aborts half way (a dependency going
# unhealthy) leaves the rest in `Created` while the deploy "succeeded".
# BEFORE_IDS is what the project held *before* the deploy; a container whose
# ID is still in it has not been recreated yet, so a stale healthy stack
# cannot satisfy the gate. Empty BEFORE_IDS (first deploy) skips that check.
#
# Runs under busybox + bash (CI container) and over DOCKER_HOST=ssh://...
set -uo pipefail

timeout=${1:-600}
before=" ${BEFORE_IDS:-} "
label=com.docker.compose.project=infra

# ID|name|state|health, one line per container; offenders land in $bad.
check() {
  total=0 healthy=0 bad=""
  local ids id line name state health
  ids=$(docker ps -a -q --no-trunc --filter "label=$label") || return 2
  [ -n "$ids" ] || { bad="  (no containers found for project infra)"; return 1; }
  for id in $ids; do
    line=$(docker inspect --format '{{.Name}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id") || continue
    name=${line%%|*}; name=${name#/}; line=${line#*|}
    state=${line%%|*}; health=${line#*|}
    total=$((total + 1))
    if [[ "$before" == *" $id "* ]]; then
      bad+="  $name: not recreated yet ($state)"$'\n'; continue
    fi
    case "$state/$health" in
      created/*|restarting/*|exited/*|dead/*|paused/*|*/starting|*/unhealthy)
        bad+="  $name: $state${health:+ / health=$health}"
        if [ "$health" = unhealthy ] || [ "$health" = starting ]; then
          bad+=" -- $(docker inspect --format '{{with .State.Health}}{{range .Log}}{{println .Output}}{{end}}{{end}}' "$id" | grep . | tail -n 1)"
        fi
        bad+=$'\n'
        [ "$state" = created ] && created+="${created:+ }$name" ;;
      */healthy) healthy=$((healthy + 1)) ;;
    esac
  done
  [ -z "$bad" ]
}

deadline=$((SECONDS + timeout))
while :; do
  created=""
  check; rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "wait-healthy: all $total infra containers recreated and up ($healthy healthy)"
    exit 0
  fi
  [ "$rc" -eq 2 ] && { echo "wait-healthy: cannot reach the Docker daemon" >&2; exit 1; }
  [ "$SECONDS" -ge "$deadline" ] && break
  sleep 5
done

echo "wait-healthy: infra not healthy after ${timeout}s:" >&2
printf '%s' "$bad" >&2
[ -n "$created" ] && echo "hint: docker start $created" >&2
exit 1
