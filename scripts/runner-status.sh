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
#
# The HTTP status is kept alongside the body rather than inferred from it,
# because the one answer worth naming is indistinguishable from the others
# once it is just "no .runners key": a PAT GitHub refuses is exactly what
# stops the runner registering, and it deserves to be reported as that and
# not as "unknown", which reads like a network blip -- the report below
# spells that case out on its own.
#
# The PAT reaches curl through a -K config file on stdin instead of an -H
# argument, so it never enters this host's process list -- the same idiom as
# scripts/gen-runner-env.sh and scripts/portainer-stack.sh, for the same
# reason.
json=""
http_code=""
gh_state=""

fetch_runners() {
  command -v jq >/dev/null 2>&1 || { gh_state=jq-missing; return; }
  [ -n "${GH_RUNNER_TOKEN:-}" ] || { gh_state=no-token; return; }

  local out
  out="$(printf 'header = "Authorization: Bearer %s"\n' "$GH_RUNNER_TOKEN" \
    | curl -sS -K - --max-time 15 -w $'\n%{http_code}' \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${REPO}/actions/runners" 2>/dev/null)" || true

  # -w appends the status on its own last line, so the body is everything
  # before it. A curl that never got an answer leaves 000 there (or nothing
  # at all, if it died before writing anything).
  http_code="${out##*$'\n'}"
  json="${out%$'\n'*}"

  case "$http_code" in
    200)
      # A 200 that is not the shape we asked for would break every jq below.
      if jq -e 'has("runners")' >/dev/null 2>&1 <<<"$json"; then
        gh_state=ok
      else
        gh_state=http-other
      fi
      ;;
    401)          gh_state=bad-credential ;;
    403|404)      gh_state=bad-scope ;;
    ''|000)       gh_state=unreachable ;;
    *)            gh_state=http-other ;;
  esac
}

gh_message() {
  jq -r '.message // empty' <<<"$json" 2>/dev/null || true
}

fetch_runners

case "$gh_state" in
  jq-missing)  gh_why="jq is not installed on this host" ;;
  no-token)    gh_why="GH_RUNNER_TOKEN is not set in .runner.env" ;;
  unreachable) gh_why="could not reach api.github.com" ;;
  bad-credential)
    gh_why="GitHub rejected GH_RUNNER_TOKEN (401 $(gh_message))" ;;
  bad-scope)
    gh_why="GH_RUNNER_TOKEN cannot administer runners on ${REPO} (${http_code})" ;;
  http-other)
    gh_why="unexpected answer from GitHub (HTTP ${http_code}: $(gh_message))" ;;
  ok)          gh_why="" ;;
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
if [ "$gh_state" = bad-credential ] || [ "$gh_state" = bad-scope ]; then
  # Not "unknown". This is the same credential the runner's own entrypoint
  # exchanges for a registration token on every start, so a token GitHub
  # refuses here is a token it refuses there -- and that exchange is the
  # whole of "Obtaining the token of the runner" / "curl: (22) ... 401"
  # followed by "Invalid configuration provided for token" in
  # `make runner-logs`, from a container that then restarts forever. Nothing
  # else in this repo reports it: `make runner-up` succeeds, the container is
  # up, and a push to main queues its deploy silently because GitHub does not
  # treat "no runner matches these labels" as an error.
  echo "  ${gh_why}"
  echo
  if [ "$gh_state" = bad-credential ]; then
    cat <<'MSG'
  The PAT is expired, revoked or mistyped -- it authenticates as nothing.
  (A runner *registration* token from the Runners page is not a PAT and
  authenticates nothing here either; this runner is EPHEMERAL and needs a
  PAT it can exchange for a fresh one after every job.)
MSG
  else
    cat <<'MSG'
  The PAT authenticates, but the runners endpoint is not visible to it: a
  classic token needs the 'repo' scope, and a fine-grained one needs this
  repository selected with Administration: read and write. (GitHub answers
  404, not 403, for a permission a fine-grained token was never granted.)
MSG
  fi
  cat <<'MSG'

  Mint a replacement at https://github.com/settings/tokens, then:
      make runner-env FORCE=1     # checks the new token before writing it
      make runner-restart
MSG
elif [ "$gh_state" != ok ]; then
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
