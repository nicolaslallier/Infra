#!/usr/bin/env bash
# The self-hosted CI runners' state, reported from both sides: the containers
# on this Docker host, and what GitHub itself has registered, repo by repo.
#
# Both sides, because the failure that matters is the one where they
# disagree. The runners are EPHEMERAL (docker-compose.runners.yml): each
# de-registers after every job and re-registers on restart, so "the container
# is up" says nothing about whether GitHub has a runner to hand the next job
# to. And GitHub never reports the absence as a failure -- a job whose labels
# match nothing just queues, silently, forever. That is the same trap the
# LABELS comment in the compose file warns about, seen from the operator's side.
#
# Usage:
#   scripts/runner-status.sh            # print both sides
#   scripts/runner-status.sh --busy     # exit 3 if a job is running now
#
# --busy is what the targets that recreate the runners check first: doing
# that mid-job leaves the workflow hanging with no result. One busy runner
# out of the five is enough to refuse, because they are recreated together.
set -euo pipefail

cd "$(dirname "$0")/.."

# shellcheck source=lib/runners.sh
. scripts/lib/runners.sh

[ -f .runner.env ] || {
  echo "runner-status: .runner.env not found -- see 'make runners-env'" >&2
  exit 1
}
# shellcheck disable=SC1091
set -a; . ./.runner.env; set +a

BUSY_ONLY=0
[ "${1:-}" = "--busy" ] && BUSY_ONLY=1

RUNNER_COMPOSE=(docker compose -f docker-compose.runners.yml --env-file .runner.env)

# GitHub's view of one repo. Needs that repo's PAT (admin on it), so there is
# nothing extra to provision. Unreachable GitHub, a missing token or a missing
# jq are *warnings*: an operator who cannot reach GitHub must still be able to
# stop the runners, and refusing would make this check worse than the nothing
# it replaces.
#
# The HTTP status is kept alongside the body rather than inferred from it,
# because the one answer worth naming is indistinguishable from the others
# once it is just "no .runners key": a PAT GitHub refuses is exactly what
# stops the runner registering, and it deserves to be reported as that and
# not as "unknown", which reads like a network blip.
#
# The PAT reaches curl through a -K config file on stdin instead of an -H
# argument, so it never enters this host's process list -- the same idiom as
# scripts/gen-runner-env.sh and scripts/portainer-stack.sh, for the same
# reason.
#
# Sets json, http_code, gh_state and gh_why for <name>.
fetch_runners() { # <name>
  local name="$1" repo var token out
  repo="$(runner_repo "$name")"
  var="$(runner_token_var "$name")"
  token="${!var:-}"
  json=""; http_code=""; gh_state=""; gh_why=""

  if ! command -v jq >/dev/null 2>&1; then
    gh_state=jq-missing; gh_why="jq is not installed on this host"; return
  fi
  if [ -z "$token" ]; then
    gh_state=no-token; gh_why="$var is not set in .runner.env"; return
  fi

  out="$(printf 'header = "Authorization: Bearer %s"\n' "$token" \
    | curl -sS -K - --max-time 15 -w $'\n%{http_code}' \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${repo}/actions/runners" 2>/dev/null)" || true

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
    401)       gh_state=bad-credential ;;
    403|404)   gh_state=bad-scope ;;
    ''|000)    gh_state=unreachable ;;
    *)         gh_state=http-other ;;
  esac

  case "$gh_state" in
    unreachable)    gh_why="could not reach api.github.com" ;;
    bad-credential) gh_why="GitHub rejected $var (401 $(gh_message))" ;;
    bad-scope)      gh_why="$var cannot administer runners on ${repo} (${http_code})" ;;
    http-other)     gh_why="unexpected answer from GitHub (HTTP ${http_code}: $(gh_message))" ;;
  esac
}

gh_message() {
  jq -r '.message // empty' <<<"$json" 2>/dev/null || true
}

if [ "$BUSY_ONLY" = 1 ]; then
  busy_found=0
  for entry in "${RUNNERS[@]}"; do
    name="${entry%%:*}"
    fetch_runners "$name"
    if [ "$gh_state" != ok ]; then
      echo "runner-status: cannot tell whether a job is running on $(runner_repo "$name") ($gh_why) -- continuing" >&2
      continue
    fi
    # Scoped to the runner's own label (its name) rather than to every runner
    # on the repo: that label is the contract with the workflows, and so
    # names exactly the runner these targets recreate.
    lines="$(jq -r --arg n "$name" '.runners[] | select(.busy) | select(any(.labels[]; .name == $n))
      | "  \(.name) is running a job"' <<<"$json")"
    if [ -n "$lines" ]; then
      busy_found=1
      echo "$lines" >&2
    fi
  done
  [ "$busy_found" = 0 ] && exit 0
  cat >&2 <<'MSG'
runner-status: refusing -- recreating the runners now kills that job, and
GitHub gets no result for it (the workflow run just stops reporting).
Wait for it, or re-run with FORCE=1 if you mean to kill it.
MSG
  exit 3
fi

echo "== containers (this Docker host) =="
"${RUNNER_COMPOSE[@]}" ps || true

for entry in "${RUNNERS[@]}"; do
  name="${entry%%:*}"
  repo="$(runner_repo "$name")"
  fetch_runners "$name"

  echo
  echo "== registered with GitHub (${repo}) =="
  if [ "$gh_state" = bad-credential ] || [ "$gh_state" = bad-scope ]; then
    # Not "unknown". This is the same credential the runner's own entrypoint
    # exchanges for a registration token on every start, so a token GitHub
    # refuses here is a token it refuses there -- and that exchange is the
    # whole of "Obtaining the token of the runner" / "curl: (22) ... 401"
    # followed by "Invalid configuration provided for token" in the runner's
    # logs, from a container that then restarts forever. Nothing else in this
    # repo reports it: the stack deploys, the container is up, and a push
    # queues its job silently because GitHub does not treat "no runner
    # matches these labels" as an error.
    echo "  ${gh_why}"
    echo
    if [ "$gh_state" = bad-credential ]; then
      cat <<'MSG'
  The PAT is expired, revoked or mistyped -- it authenticates as nothing.
  (A runner *registration* token from the Runners page is not a PAT and
  authenticates nothing here either; these runners are EPHEMERAL and need a
  PAT they can exchange for a fresh one after every job.)
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
      make runners-env FORCE=1     # checks the new tokens before writing them
      make runners-restart
MSG
  elif [ "$gh_state" != ok ]; then
    echo "  unknown: ${gh_why}"
    echo "  check by hand: https://github.com/${repo}/settings/actions/runners"
  else
    count="$(jq -r '.runners | length' <<<"$json")"
    if [ "$count" = 0 ]; then
      cat <<MSG
  none registered.
  A push to ${repo} will queue its job forever rather than fail: GitHub does
  not treat "no runner matches these labels" as an error. Start the runners
  and watch the logs for "Listening for Jobs".
MSG
    else
      jq -r '.runners[]
        | "  \(.name)  \(.status)\(if .busy then " (busy)" else "" end)  labels: "
          + ([.labels[].name] | join(","))' <<<"$json"
      jq -e --arg n "$name" '[.runners[] | select(any(.labels[]; .name == $n))] | length > 0' >/dev/null <<<"$json" || cat <<MSG
  no runner with the label '${name}' registered -- the workflows' jobs select
  on it, so they match nothing and queue silently.
MSG
    fi
  fi
done
