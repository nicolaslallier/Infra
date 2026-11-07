#!/usr/bin/env bash
# Writes .runner.env -- what `make runners-up` needs: one GitHub PAT per repo
# (GH_RUNNER_TOKEN_DARKANGEL|EA|HEAVEN|INFRA|MORIA), each allowed to register
# self-hosted runners on its own repo. The repos are listed in scripts/lib/runners.sh.
#
# The tokens themselves cannot be generated here, or by any script: GitHub
# mints personal access tokens only through its web UI, signed in as the
# account they belong to. There is no API that issues one. What this script
# does is everything around them -- take each token without leaving it in a
# shell history or a process list, prove it is the kind of token the runner
# needs *before* the runner fails obscurely on it, and write the file with the
# permissions a credential deserves. One PAT may be reused for several repos:
# give it again when asked.
#
# Why the round trip to GitHub is worth it: a token with the wrong scope
# registers nothing, and says so only in the runner's own logs, as an HTTP
# 403 from a container that then restarts forever -- `make runners-up` itself
# reports success. The endpoint asked here is the one
# scripts/runner-status.sh already uses, so a token that passes this check is
# also a token that makes `make runner-status` work. All five are checked
# before anything is written: a file with four good tokens and one bad one
# would leave four runners up and the fifth silently absent.
#
# The file belongs to *this* checkout, not to the Docker host, even when the
# daemon is remote (DOCKER_HOST=ssh://...): compose reads --env-file locally
# and only the interpolated result crosses the connection.
#
# Usage:
#   scripts/gen-runner-env.sh [--force]
#   printf '%s\n' "$T1" "$T2" "$T3" "$T4" "$T5" | scripts/gen-runner-env.sh
#       # non-interactive: one token per line, in the order of RUNNERS
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck source=lib/runners.sh
. scripts/lib/runners.sh

ENV_FILE=".runner.env"
FORCE="${1:-}"

if [ -f "$ENV_FILE" ] && [ "$FORCE" != "--force" ]; then
  echo "gen-runner-env.sh: $ENV_FILE already exists, leaving it alone (--force to replace)."
  echo "  'make runner-status' says whether the tokens in it still work."
  exit 0
fi

if [ -t 0 ]; then
  echo "One GitHub PAT per repo, each allowed to register runners on it:"
  echo "    classic       -> 'repo' scope"
  echo "    fine-grained  -> that repository, Administration: read and write"
  echo "    https://github.com/settings/tokens"
  echo
  echo "  Not the 'A...' token on a repo's Runners page -- that is a runner"
  echo "  *registration* token, good for one hour. These runners are EPHEMERAL"
  echo "  and re-register after every job, so they need a PAT they can exchange"
  echo "  for a fresh registration token each time."
  echo
fi

# The token goes to curl through a -K config file on stdin rather than in an
# -H argument, so it never appears in this machine's process list. Same idiom
# as scripts/portainer-stack.sh, for the same reason.
check_token() { # <repo> <token>
  command -v curl >/dev/null 2>&1 || { echo "no-curl"; return; }
  printf 'header = "Authorization: Bearer %s"\n' "$2" \
    | curl -sS -K - -o /dev/null -w '%{http_code}' --max-time 15 \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${1}/actions/runners" 2>/dev/null \
    || echo "unreachable"
}

lines=""
for entry in "${RUNNERS[@]}"; do
  name="${entry%%:*}"
  repo="$(runner_repo "$name")"
  var="$(runner_token_var "$name")"
  if [ -t 0 ]; then
    printf 'Token for %s (not echoed): ' "$repo"
    read -rs token
    echo
  else
    read -r token || true
  fi

  # PATs contain no whitespace, so stripping all of it is safe -- and it is
  # what makes a token pasted into a WSL terminal, or piped in from a file
  # written on Windows, not arrive with a CR glued to the end. That CR would
  # reach GitHub inside the Authorization header and read as a bad credential.
  token="$(printf '%s' "${token:-}" | tr -d '[:space:]')"
  [ -n "$token" ] || { echo "gen-runner-env.sh: no token given for $repo, nothing written." >&2; exit 1; }

  code="$(check_token "$repo" "$token")"
  case "$code" in
    200)
      echo "gen-runner-env.sh: token accepted -- it can administer runners on $repo."
      ;;
    401)
      echo "gen-runner-env.sh: GitHub rejected the token for $repo (401). Nothing written." >&2
      echo "  It is expired, revoked, mistyped, or not a PAT at all -- a runner" >&2
      echo "  registration token from the Runners page authenticates nothing here." >&2
      exit 1
      ;;
    403|404)
      echo "gen-runner-env.sh: the token for $repo cannot administer runners on it ($code). Nothing written." >&2
      echo "  It authenticates, but the runners endpoint is not visible to it:" >&2
      echo "  a classic token needs the 'repo' scope, and a fine-grained one needs" >&2
      echo "  this repository selected with Administration: read and write." >&2
      echo "  (GitHub answers 404, not 403, for a permission a fine-grained token" >&2
      echo "  was never granted -- so the two cases look the same from here.)" >&2
      exit 1
      ;;
    no-curl|unreachable|000)
      echo "gen-runner-env.sh: could not check the token for $repo with GitHub (${code}) -- writing it unverified." >&2
      echo "  'make runner-status' is the same question, asked again later." >&2
      ;;
    *)
      echo "gen-runner-env.sh: unexpected answer from GitHub for $repo (HTTP $code) -- writing the token unverified." >&2
      echo "  Confirm with 'make runner-status' once the runners are up." >&2
      ;;
  esac
  lines+="${var}=${token}"$'\n'
done

umask 077
{
  echo "# The self-hosted CI runners' credentials: one GitHub PAT per repo, each"
  echo "# allowed to register runners on it. Written by scripts/gen-runner-env.sh."
  echo "#"
  echo "# They live here and not in .env because .env is handed to containers"
  echo "# wholesale (postgres's env_file) and shipped to Portainer as the stack"
  echo "# env -- the same reasoning that keeps PORTAINER_API_KEY in"
  echo "# .portainer.env. Gitignored; never commit it."
  printf '%s' "$lines"
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"

echo "gen-runner-env.sh: wrote $ENV_FILE (mode 600)."
echo
echo "  Next:  make runners-up      # registers one runner per repo"
echo "         make runner-status   # the containers here, and GitHub's view of them"
