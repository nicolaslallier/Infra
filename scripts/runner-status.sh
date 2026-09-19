#!/usr/bin/env bash
# The self-hosted CI runner's state, reported from both sides: the container
# on this Docker host, and what GitHub itself has registered.
#
# Both sides, because the failure that matters is the one where they
# disagree. The runner is EPHEMERAL (docker-compose.runner.yml): it
# de-registers after every job and re-registers on restart, so "the
# container is up" says nothing about whether GitHub has a runner to hand
# the next deploy to. And GitHub never reports the absence as a failure --
# a job whose labels match nothing just queues, silently, forever. That is
# the same trap the LABELS comment in the compose file warns about, seen
# from the operator's side.
#
# Usage:
#   scripts/runner-status.sh            # print both sides
#   scripts/runner-status.sh --busy     # exit 3 if a job is running now
#
# --busy is what runner-down / -restart / -pull check before recreating the
# container: doing that mid-job leaves the deploy hanging with no result.
set -euo pipefail

cd "$(dirname "$0")/.."

[ -f .runner.env ] || {
  echo "runner-status: .runner.env not found -- see 'make runner-up'" >&2
  exit 1
}
# shellcheck disable=SC1091
set -a; . ./.runner.env; set +a

REPO="${GH_RUNNER_REPO:-nicolaslallier/Infra}"
BUSY_ONLY=0
[ "${1:-}" = "--busy" ] && BUSY_ONLY=1

RUNNER_COMPOSE=(docker compose -f docker-compose.runner.yml --env-file .runner.env)

# GitHub's view. Needs the same PAT that registers the runner (admin on the
# repo), so there is nothing extra to provision. Unreachable GitHub, a
# missing token or a missing jq are *warnings*: an operator who cannot
# reach GitHub must still be able to stop the runner, and refusing would
# make this check worse than the nothing it replaces.
runners_json() {
  command -v jq >/dev/null 2>&1 || { echo "jq-missing"; return; }
  [ -n "${GH_RUNNER_TOKEN:-}" ] || { echo "no-token"; return; }
  curl -sS --max-time 15 \
    -H "Authorization: Bearer ${GH_RUNNER_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${REPO}/actions/runners" 2>/dev/null \
    || echo "unreachable"
}

json="$(runners_json)"

case "$json" in
  jq-missing)  gh_state=unknown; gh_why="jq is not installed on this host" ;;
  no-token)    gh_state=unknown; gh_why="GH_RUNNER_TOKEN is not set in .runner.env" ;;
  unreachable) gh_state=unknown; gh_why="could not reach api.github.com" ;;
  *)
    if ! jq -e 'has("runners")' >/dev/null 2>&1 <<<"$json"; then
      gh_state=unknown
      gh_why="$(jq -r '.message // "unexpected response"' <<<"$json" 2>/dev/null || echo "unexpected response")"
    else
      gh_state=ok
    fi
    ;;
esac

if [ "$BUSY_ONLY" = 1 ]; then
  if [ "$gh_state" != ok ]; then
    echo "runner-status: cannot tell whether a job is running ($gh_why) -- continuing" >&2
    exit 0
  fi
  # Scoped to the 'infra' label rather than to every runner on the repo:
  # that label is the contract with .github/workflows/deploy.yml, and so
  # names exactly the runner these targets recreate.
  busy="$(jq -r '[.runners[] | select(.busy) | select(.labels[].name == "infra")] | length' <<<"$json")"
  [ "$busy" = 0 ] && exit 0
  jq -r '.runners[] | select(.busy) | select(.labels[].name == "infra")
    | "  \(.name) is running a job"' <<<"$json" >&2
  cat >&2 <<'MSG'
runner-status: refusing -- recreating the runner now kills that job, and
GitHub gets no result for it (the workflow run just stops reporting).
Wait for it, or re-run with FORCE=1 if you mean to kill it.
MSG
  exit 3
fi

echo "== container (this Docker host) =="
"${RUNNER_COMPOSE[@]}" ps || true

echo
echo "== registered with GitHub (${REPO}) =="
if [ "$gh_state" != ok ]; then
  echo "  unknown: ${gh_why}"
  echo "  check by hand: https://github.com/${REPO}/settings/actions/runners"
else
  count="$(jq -r '.runners | length' <<<"$json")"
  if [ "$count" = 0 ]; then
    cat <<'MSG'
  none registered.
  A push to main will queue its deploy job forever rather than fail: GitHub
  does not treat "no runner matches these labels" as an error. Start it with
  'make runner-up' and watch 'make runner-logs' for "Listening for Jobs".
MSG
  else
    jq -r '.runners[]
      | "  \(.name)  \(.status)\(if .busy then " (busy)" else "" end)  labels: "
        + ([.labels[].name] | join(","))' <<<"$json"
    jq -e '[.runners[] | select(.labels[].name == "infra")] | length > 0' >/dev/null <<<"$json" || cat <<'MSG'
  none of them carries the 'infra' label that .github/workflows/deploy.yml
  selects on -- the deploy job matches nothing and queues silently.
MSG
  fi
fi
