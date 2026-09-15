#!/usr/bin/env bash
# Drive the "infra" stack through Portainer's API. Portainer CE deploys
# docker-compose.yml from GitHub main; the files that compose bind-mounts
# come from this checkout (INFRA_DIR). See CLAUDE.md "Portainer-managed
# stack".
#
# Usage: scripts/portainer-stack.sh up|pull|down|delete|selftest
#   up      create the stack, or pull main and redeploy it
#   pull    redeploy, re-pulling every image
#   down    stop the stack (volumes kept)
#   delete  remove the stack from Portainer (volumes kept)
set -euo pipefail
cd "$(dirname "$0")/.."

STACK=infra
REPO_URL=https://github.com/nicolaslallier/Infra
REF=refs/heads/main
CURL_IMAGE=curlimages/curl:8.5.0

die() { printf 'portainer-stack.sh: %b\n' "$*" >&2; exit 1; }

# .env -> Portainer's [{name,value}] stack env: KEY=VALUE lines only, minus
# any PORTAINER_* settings (those belong in .portainer.env and are never
# handed to containers -- filtered here too, as defence in depth) and any
# stale INFRA_DIR, plus INFRA_DIR pointing at this checkout.
env_json() { # <env-file> <infra-dir>
  jq -Rn --arg dir "$2" '
    [inputs
     | select(test("^[A-Za-z_][A-Za-z0-9_]*="))
     | capture("^(?<name>[^=]+)=(?<value>.*)$")
     | select(((.name | startswith("PORTAINER_")) or .name == "INFRA_DIR") | not)]
    + [{name: "INFRA_DIR", value: $dir}]' <"$1"
}

# A checkout path as Docker Desktop's daemon sees it. WSL's /mnt/c exists
# only inside the distro; the daemon (and so Portainer's compose) sees that
# drive at /run/desktop/mnt/host/c. Handed /mnt/c/..., it auto-creates an
# empty directory there: file mounts fail with "not a directory" and
# directory mounts start silently empty.
daemon_dir() { # <path>
  case "$1" in
    /mnt/[a-z]/*) printf '/run/desktop/mnt/host/%s' "${1#/mnt/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

selftest() {
  [ "$(daemon_dir /mnt/c/Users/nicol/OpenCode/Infra)" = /run/desktop/mnt/host/c/Users/nicol/OpenCode/Infra ] \
    || die "selftest: daemon_dir did not translate a WSL path"
  [ "$(daemon_dir /Users/me/Infra)" = /Users/me/Infra ] \
    || die "selftest: daemon_dir changed a non-WSL path"
  local tmp got want
  tmp="$(mktemp -d)"
  printf '%s\n' '# comment' '' 'A=1' 'URL=postgres://u:p@h/db?x=y' 'EMPTY=' \
    'PORTAINER_API_KEY=secret' 'INFRA_DIR=/stale' '  INDENTED=no' >"$tmp/env"
  got="$(env_json "$tmp/env" /repo | jq -c .)"
  rm -rf "$tmp"
  want='[{"name":"A","value":"1"},{"name":"URL","value":"postgres://u:p@h/db?x=y"},{"name":"EMPTY","value":""},{"name":"INFRA_DIR","value":"/repo"}]'
  [ "$got" = "$want" ] || die "selftest: env_json\n  got:  $got\n  want: $want"
  echo "portainer-stack.sh: selftest ok"
}

# Runs curl in a throwaway container on infra-net, so deploying never
# depends on nginx or dns -- both are part of the stack being deployed.
# The key reaches curl via -K (a config file written inside the container
# from stdin's first line, the body following it), never as a command-line
# argument, so it doesn't show up in any process list. Not `-e
# PORTAINER_API_KEY`: whether the docker CLI forwards its env depends on
# the shell (from WSL, a Windows docker.exe doesn't see it), and a missing
# key only surfaces as Portainer's "A valid authorization token is missing".
api() { # <method> <path> [json-body]
  # MSYS_NO_PATHCONV/MSYS2_ARG_CONV_EXCL: under Git for Windows, the MSYS
  # runtime rewrites arguments that look like POSIX paths before handing
  # them to the native docker.exe, so "/endpoints" arrives as
  # "C:/Program Files/Git/endpoints" and curl rejects the URL. No-ops on
  # macOS and Linux.
  printf '%s\n%s' "$PORTAINER_API_KEY" "${3:-}" | MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
    docker run --rm -i --network infra-net \
    --entrypoint sh "$CURL_IMAGE" -c '
      IFS= read -r key
      printf "header = \"X-API-Key: %s\"\n" "$key" >/tmp/curl.cfg
      out="$(curl -sSk -K /tmp/curl.cfg --fail-with-body -X "$1" \
        -H "Content-Type: application/json" \
        --data-binary @- "https://portainer:9443/api$2" 2>&1)" \
        || { printf "%s\n" "$out" >&2; exit 1; }
      printf "%s" "$out"' sh "$1" "$2" \
    || die "$1 $2 failed (is Portainer up? 'make portainer-up')"
}

# Refuse to run from a linked worktree: Portainer mounts files from
# INFRA_DIR (this directory) and this script addresses the live stack, but
# a worktree can be deleted out from under a running deployment.
check_main_checkout() {
  local gitdir commondir
  gitdir="$(git rev-parse --git-dir)" || die "not a git checkout"
  commondir="$(git rev-parse --git-common-dir)" || die "not a git checkout"
  [ "$gitdir" = "$commondir" ] \
    || die "run this from the main checkout, not a linked worktree -- Portainer mounts files from this directory and this addresses the live stack"
}

# Portainer deploys GitHub main while the mounted configs come from this
# checkout: refuse to deploy whenever the two could differ.
check_synced() {
  local branch head remote status
  branch="$(git rev-parse --abbrev-ref HEAD)" || die "not a git checkout"
  [ "$branch" = main ] || die "this checkout is on '$branch'; Portainer deploys main"
  status="$(git status --porcelain)" || die "git status failed"
  [ -z "$status" ] || die "uncommitted changes here would not match what Portainer deploys"
  git fetch -q origin main \
    || die "git fetch origin main failed -- cannot confirm this checkout matches what Portainer deploys"
  head="$(git rev-parse HEAD)" || die "git rev-parse HEAD failed"
  remote="$(git rev-parse origin/main)" || die "origin/main unknown -- git fetch origin main first"
  [ "$head" = "$remote" ] \
    || die "this checkout is not at origin/main -- 'git pull --ff-only' (or push) first"
}

cmd="${1:-}"
case "$cmd" in
  selftest) selftest; exit 0 ;;
  up|pull|down|delete) ;;
  *) die "usage: scripts/portainer-stack.sh up|pull|down|delete|selftest" ;;
esac

check_main_checkout

[ -f .env ] || die ".env not found (run 'make init' first)"
set -a; . ./.env; set +a

# PORTAINER_API_KEY lives in its own gitignored file, not .env: .env is
# handed to containers (postgres's env_file), and this key is a
# Docker-daemon-root token that must never land in one.
[ -f .portainer.env ] || die ".portainer.env not found -- create it with PORTAINER_API_KEY (Portainer -> My account -> Access tokens); see .env.example"
set -a; . ./.portainer.env; set +a
if [ -z "${PORTAINER_API_KEY:-}" ] || [ "$PORTAINER_API_KEY" = change-me ]; then
  die "set PORTAINER_API_KEY in .portainer.env (Portainer -> My account -> Access tokens)"
fi

eid="${PORTAINER_ENDPOINT_ID:-$(api GET /endpoints | jq -r '[.[] | select(.Type == 1)][0].Id // empty')}"
[ -n "$eid" ] || die "no local Docker environment found in Portainer"
stack="$(api GET /stacks | jq -c --arg n "$STACK" 'first(.[] | select(.Name == $n)) // empty')"
sid=""
[ -z "$stack" ] || sid="$(jq -r .Id <<<"$stack")"

case "$cmd" in
  up|pull)
    check_synced
    # PORTAINER_INFRA_DIR: this checkout's path as the daemon sees it, when
    # that daemon is remote (set by the Makefile); $PWD otherwise.
    env="$(env_json .env "$(daemon_dir "${PORTAINER_INFRA_DIR:-$PWD}")")"
    if [ -z "$sid" ]; then
      [ "$cmd" = up ] || die "stack '$STACK' does not exist yet -- 'make up' first"
      body="$(jq -n --arg name "$STACK" --arg url "$REPO_URL" --arg ref "$REF" --argjson env "$env" \
        '{Name: $name, RepositoryURL: $url, RepositoryReferenceName: $ref,
          ComposeFile: "docker-compose.yml", RepositoryAuthentication: false, Env: $env}')"
      api POST "/stacks/create/standalone/repository?endpointId=$eid" "$body" >/dev/null
      echo "portainer-stack.sh: created stack '$STACK' from $REPO_URL ($REF)"
    else
      if [ "$(jq -r .Status <<<"$stack")" = 2 ]; then
        api POST "/stacks/$sid/start?endpointId=$eid" >/dev/null
      fi
      body="$(jq -n --arg ref "$REF" --argjson env "$env" --argjson pull "$([ "$cmd" = pull ] && echo true || echo false)" \
        '{RepositoryReferenceName: $ref, RepositoryAuthentication: false, Env: $env,
          Prune: false, RepullImageAndRedeploy: $pull}')"
      api PUT "/stacks/$sid/git/redeploy?endpointId=$eid" "$body" >/dev/null
      echo "portainer-stack.sh: redeployed stack '$STACK' at $(git rev-parse --short HEAD)"
    fi
    ;;
  down)
    [ -n "$sid" ] || die "stack '$STACK' does not exist in Portainer"
    if [ "$(jq -r .Status <<<"$stack")" = 2 ]; then
      echo "portainer-stack.sh: stack '$STACK' is already stopped"
      exit 0
    fi
    api POST "/stacks/$sid/stop?endpointId=$eid" >/dev/null
    echo "portainer-stack.sh: stopped stack '$STACK'"
    ;;
  delete)
    [ -n "$sid" ] || { echo "portainer-stack.sh: no stack '$STACK' in Portainer"; exit 0; }
    api DELETE "/stacks/$sid?endpointId=$eid" >/dev/null
    echo "portainer-stack.sh: deleted stack '$STACK' from Portainer"
    ;;
esac
