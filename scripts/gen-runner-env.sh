#!/usr/bin/env bash
# Writes .runner.env -- the one value `make runner-up` needs: GH_RUNNER_TOKEN,
# a GitHub PAT that may register self-hosted runners on this repo.
#
# The token itself cannot be generated here, or by any script: GitHub mints
# personal access tokens only through its web UI, signed in as the account
# they belong to. There is no API that issues one. What this script does is
# everything around it -- take the token without leaving it in a shell
# history or a process list, prove it is the kind of token the runner needs
# *before* the runner fails obscurely on it, and write the file with the
# permissions a credential deserves.
#
# Why the round trip to GitHub is worth it: a token with the wrong scope
# registers nothing, and says so only in the runner's own logs, as an HTTP
# 403 from a container that then restarts forever -- `make runner-up` itself
# reports success. The endpoint asked here is the one
# scripts/runner-status.sh already uses, so a token that passes this check is
# also a token that makes `make runner-status` work.
#
# The file belongs to *this* checkout, not to the Docker host, even when the
# daemon is remote (DOCKER_HOST=ssh://...): compose reads --env-file locally
# and only the interpolated result crosses the connection. So this runs
# wherever `make runner-up` runs, though the container lands over there.
#
# Usage:
#   scripts/gen-runner-env.sh [--force]
#   printf '%s' "$TOKEN" | scripts/gen-runner-env.sh   # non-interactive
set -euo pipefail
cd "$(dirname "$0")/.."

ENV_FILE=".runner.env"
REPO="${GH_RUNNER_REPO:-nicolaslallier/Infra}"
FORCE="${1:-}"

if [ -f "$ENV_FILE" ] && [ "$FORCE" != "--force" ]; then
  echo "gen-runner-env.sh: $ENV_FILE already exists, leaving it alone (--force to replace)."
  echo "  'make runner-status' says whether the token in it still works."
  exit 0
fi

if [ -t 0 ]; then
  echo "A GitHub PAT that may register runners on $REPO:"
  echo "    classic       -> 'repo' scope"
  echo "    fine-grained  -> this repository, Administration: read and write"
  echo "    https://github.com/settings/tokens"
  echo
  echo "  Not the 'A...' token on the repo's Runners page -- that is a runner"
  echo "  *registration* token, good for one hour. This runner is EPHEMERAL and"
  echo "  re-registers after every job, so it needs a PAT it can exchange for a"
  echo "  fresh registration token each time."
  echo
  printf 'Token (not echoed): '
  read -rs token
  echo
else
  read -r token || true
fi

# PATs contain no whitespace, so stripping all of it is safe -- and it is what
# makes a token pasted into a WSL terminal, or piped in from a file written on
# Windows, not arrive with a CR glued to the end. That CR would reach GitHub
# inside the Authorization header and read as an ordinary bad credential.
token="$(printf '%s' "${token:-}" | tr -d '[:space:]')"

[ -n "$token" ] || { echo "gen-runner-env.sh: no token given, nothing written." >&2; exit 1; }

# The token goes to curl through a -K config file on stdin rather than in an
# -H argument, so it never appears in this machine's process list. Same idiom
# as scripts/portainer-stack.sh, for the same reason.
check_token() {
  command -v curl >/dev/null 2>&1 || { echo "no-curl"; return; }
  printf 'header = "Authorization: Bearer %s"\n' "$token" \
    | curl -sS -K - -o /dev/null -w '%{http_code}' --max-time 15 \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${REPO}/actions/runners" 2>/dev/null \
    || echo "unreachable"
}

code="$(check_token)"

case "$code" in
  200)
    echo "gen-runner-env.sh: token accepted -- it can administer runners on $REPO."
    ;;
  401)
    echo "gen-runner-env.sh: GitHub rejected that token (401). Nothing written." >&2
    echo "  It is expired, revoked, mistyped, or not a PAT at all -- a runner" >&2
    echo "  registration token from the Runners page authenticates nothing here." >&2
    exit 1
    ;;
  403|404)
    echo "gen-runner-env.sh: that token cannot administer runners on $REPO ($code). Nothing written." >&2
    echo "  It authenticates, but the runners endpoint is not visible to it:" >&2
    echo "  a classic token needs the 'repo' scope, and a fine-grained one needs" >&2
    echo "  this repository selected with Administration: read and write." >&2
    echo "  (GitHub answers 404, not 403, for a permission a fine-grained token" >&2
    echo "  was never granted -- so the two cases look the same from here.)" >&2
    exit 1
    ;;
  no-curl|unreachable|000)
    echo "gen-runner-env.sh: could not check the token with GitHub (${code}) -- writing it unverified." >&2
    echo "  'make runner-status' is the same question, asked again later." >&2
    ;;
  *)
    echo "gen-runner-env.sh: unexpected answer from GitHub (HTTP $code) -- writing the token unverified." >&2
    echo "  Confirm with 'make runner-status' once the runner is up." >&2
    ;;
esac

umask 077
{
  echo "# The self-hosted CI runner's one credential: a GitHub PAT that may"
  echo "# register runners on this repo. Written by scripts/gen-runner-env.sh."
  echo "#"
  echo "# It lives here and not in .env because .env is handed to containers"
  echo "# wholesale (postgres's env_file) and shipped to Portainer as the stack"
  echo "# env -- the same reasoning that keeps PORTAINER_API_KEY in"
  echo "# .portainer.env. Gitignored; never commit it."
  printf 'GH_RUNNER_TOKEN=%s\n' "$token"
  echo "# GH_RUNNER_NAME=infra-host        # how the runner is named in GitHub's UI"
  echo "# GH_RUNNER_REPO=${REPO}   # only read by scripts/runner-status.sh"
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"

echo "gen-runner-env.sh: wrote $ENV_FILE (mode 600)."
echo
echo "  Next:  make runner-up       # registers it with the label 'infra'"
echo "         make runner-status   # the container here, and GitHub's view of it"
