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
# Two docker CLI calls per poll (ps + one batched inspect): over
# DOCKER_HOST=ssh://... each call is its own ssh session.
# Runs under busybox + bash (CI container).
set -uo pipefail

timeout=${1:-600}
before=" ${BEFORE_IDS:-} "
label=com.docker.compose.project=infra

# One line per container: id|name|state|health|last health log (json, one line).
# `index .State "Health"`, not `.State.Health`: with {{.Id}} in the format the
# CLI templates over a raw map, where a container that never started has no
# Health key and a plain field access errors.
# shellcheck disable=SC2016 # Go template, not shell
fmt='{{.Id}}|{{.Name}}|{{.State.Status}}|{{with index .State "Health"}}{{.Status}}{{else}}none{{end}}|{{$l := ""}}{{with index .State "Health"}}{{range .Log}}{{$l = .Output}}{{end}}{{end}}{{json $l}}'

# Sets total/healthy/bad/created. Returns 0 ready, 1 not ready, 2 daemon unreachable.
check() {
  total=0 healthy=0 bad=""
  local ids out id name state health log
  ids=$(docker ps -a -q --no-trunc --filter "label=$label") || return 2
  [ -n "$ids" ] || { bad="  (no containers found for project infra)"; return 1; }
  # shellcheck disable=SC2086 # ids are hex, one word each
  if ! out=$(docker inspect --format "$fmt" $ids 2>/dev/null); then
    # a container vanished between ps and inspect (mid-recreate): poll again
    bad="  (a container disappeared while inspecting; retrying)"$'\n'; return 1
  fi
  while IFS='|' read -r id name state health log; do
    [ -n "$id" ] || continue
    name=${name#/}
    total=$((total + 1))
    if [[ "$before" == *" $id "* ]]; then
      bad+="  $name: not recreated yet ($state)"$'\n'; continue
    fi
    case "$state/$health" in
      created/*|restarting/*|exited/*|dead/*|paused/*|*/starting|*/unhealthy)
        bad+="  $name: $state / health=$health"
        if [ "$health" = unhealthy ] || [ "$health" = starting ]; then
          log=${log#\"}; log=${log%\"}; log=${log//\\n/ }; log=${log//\\r/}
          log=${log%"${log##*[![:space:]]}"}
          bad+=" -- $log"
        fi
        bad+=$'\n'
        [ "$state" = created ] && created+="${created:+ }$name" ;;
      */healthy) healthy=$((healthy + 1)) ;;
    esac
  done <<< "$out"
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
