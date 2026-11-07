#!/usr/bin/env bash
# Drive the "runners" stack (docker-compose.runners.yml, five GitHub runners)
# through Portainer's API. Portainer clones docker-compose.yml's sibling from
# GitHub main; the one file the compose bind-mounts from a checkout
# (certs/infra-ca.crt, for EA) comes from INFRA_DIR.
#
# Usage: scripts/runners-stack.sh up|pull|down|delete|status|selftest
#   up      create the stack, or pull main and redeploy it
#   pull    redeploy, re-pulling every image
#   down    stop the stack
#   delete  remove the stack from Portainer
#   status  the stack's state and the commit it is deployed at
#
# Unlike portainer-stack.sh there is no drift guard and no host-checkout
# sync: the runners' compose mounts nothing tracked by git, so a checkout that
# lags main cannot deploy stale config. Only the gitignored CA is read, and
# `up` checks it exists. The env sent to Portainer is .runner.env's five PATs
# plus INFRA_DIR, never .env: that file holds the whole stack's secrets.
set -euo pipefail
cd "$(dirname "$0")/.."

STACK=runners
REPO_URL=https://github.com/nicolaslallier/Infra
REF=refs/heads/main

die() { printf 'runners-stack.sh: %b\n' "$*" >&2; exit 1; }

# .runner.env -> Portainer's [{name,value}] stack env: only the GH_RUNNER_TOKEN_*
# lines, plus INFRA_DIR pointing at this checkout.
env_json() { # <env-file> <infra-dir>
  jq -Rn --arg dir "$2" '
    [inputs
     | select(test("^GH_RUNNER_TOKEN_[A-Z]+="))
     | capture("^(?<name>[^=]+)=(?<value>.*)$")]
    + [{name: "INFRA_DIR", value: $dir}]' <"$1"
}

# Request bodies. The env (five PATs) arrives on stdin: jq --argjson would put
# it on jq's command line, readable by anyone via ps.
create_body() { # stdin: env json
  jq --arg name "$STACK" --arg url "$REPO_URL" --arg ref "$REF" \
    '{Name: $name, RepositoryURL: $url, RepositoryReferenceName: $ref,
      ComposeFile: "docker-compose.runners.yml", RepositoryAuthentication: false, Env: .}'
}
redeploy_body() { # <true|false: re-pull images>; stdin: env json
  jq --arg ref "$REF" --argjson pull "$1" \
    '{RepositoryReferenceName: $ref, RepositoryAuthentication: false, Env: .,
      Prune: false, RepullImageAndRedeploy: $pull}'
}

# Recreating or stopping the runners mid-job kills the job. One busy runner
# out of the five is enough, they are handled together.
check_idle() {
  local rc=0
  bash scripts/runner-status.sh --busy || rc=$?
  case "$rc" in
    0) ;;
    3) [ "${FORCE:-}" = 1 ] || die "a runner is running a job; wait for it, or FORCE=1 to go ahead anyway" ;;
    *) die "scripts/runner-status.sh --busy failed (exit $rc)" ;;
  esac
}

# ponytail: copy of portainer-stack.sh (daemon_dir); share it if the two drift.
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
  printf '%s\n' '# comment' '' \
    GH_RUNNER_TOKEN_DARKANGEL=a GH_RUNNER_TOKEN_EA=b GH_RUNNER_TOKEN_HEAVEN=c \
    GH_RUNNER_TOKEN_INFRA=d GH_RUNNER_TOKEN_MORIA=e \
    'PORTAINER_API_KEY=x' 'INFRA_DIR=/stale' '  GH_RUNNER_TOKEN_INDENTED=no' >"$tmp/env"
  got="$(env_json "$tmp/env" /repo | jq -c .)"
  rm -rf "$tmp"
  local cb rb
  cb="$(printf '%s' "$got" | create_body | jq -c '[.Name, .ComposeFile, (.Env | length), (.Env | map(.name) | index("INFRA_DIR"))]')"
  [ "$cb" = '["runners","docker-compose.runners.yml",6,5]' ] || die "selftest: create_body: $cb"
  rb="$(printf '%s' "$got" | redeploy_body true | jq -c '[.RepullImageAndRedeploy, (.Env | length), .Env[0].value]')"
  [ "$rb" = '[true,6,"a"]' ] || die "selftest: redeploy_body: $rb"
  want='[{"name":"GH_RUNNER_TOKEN_DARKANGEL","value":"a"},{"name":"GH_RUNNER_TOKEN_EA","value":"b"},{"name":"GH_RUNNER_TOKEN_HEAVEN","value":"c"},{"name":"GH_RUNNER_TOKEN_INFRA","value":"d"},{"name":"GH_RUNNER_TOKEN_MORIA","value":"e"},{"name":"INFRA_DIR","value":"/repo"}]'
  [ "$got" = "$want" ] || die "selftest: env_json\n  got:  $got\n  want: $want"
  echo "runners-stack.sh: selftest ok"
}

cmd="${1:-}"
case "$cmd" in
  # Before the API lib below: it calls Portainer as soon as it is sourced.
  selftest) selftest; exit 0 ;;
  up|pull|down|delete|status) ;;
  *) die "usage: scripts/runners-stack.sh up|pull|down|delete|status|selftest" ;;
esac

if [ "$cmd" = up ] || [ "$cmd" = pull ]; then
  # shellcheck source=lib/runners.sh
  . scripts/lib/runners.sh
  [ -f .runner.env ] || die ".runner.env not found (run 'make runners-env')"
  for e in "${RUNNERS[@]}"; do
    v="$(runner_token_var "${e%%:*}")"
    val="$(sed -n "s/^$v=//p" .runner.env | tail -n 1)"
    if [ -z "$val" ] || [ "$val" = change-me ]; then
      die "$v is missing, empty or change-me in .runner.env (run 'make runners-env FORCE=1')"
    fi
  done
  [ -s certs/infra-ca.crt ] || die "certs/infra-ca.crt not found (EA's runner mounts it; run 'make init' or ./scripts/gen-certs.sh)"
  check_idle
fi
if [ "$cmd" = down ]; then
  [ -f .runner.env ] || die ".runner.env not found (run 'make runners-env')"
  check_idle
fi

# shellcheck source=lib/portainer-api.sh
. scripts/lib/portainer-api.sh

stacks="$(api GET /stacks)"
stack="$(jq -c --arg n "$STACK" 'first(.[] | select(.Name == $n)) // empty' <<<"$stacks")"
sid=""
[ -z "$stack" ] || sid="$(jq -r .Id <<<"$stack")"

case "$cmd" in
  up|pull)
    # PORTAINER_INFRA_DIR: this checkout's path as the daemon sees it, when
    # that daemon is remote (set by the Makefile); $PWD otherwise.
    env="$(env_json .runner.env "$(daemon_dir "${PORTAINER_INFRA_DIR:-$PWD}")")"
    if [ -z "$sid" ]; then
      [ "$cmd" = up ] || die "stack '$STACK' does not exist yet -- 'make runners-up' first"
      body="$(printf '%s' "$env" | create_body)"
      api POST "/stacks/create/standalone/repository?endpointId=$eid" "$body" >/dev/null
      echo "runners-stack.sh: created stack '$STACK' from $REPO_URL ($REF)"
    else
      if [ "$(jq -r .Status <<<"$stack")" = 2 ]; then
        api POST "/stacks/$sid/start?endpointId=$eid" >/dev/null
      fi
      body="$(printf '%s' "$env" | redeploy_body "$([ "$cmd" = pull ] && echo true || echo false)")"
      api PUT "/stacks/$sid/git/redeploy?endpointId=$eid" "$body" >/dev/null
      echo "runners-stack.sh: redeployed stack '$STACK'"
    fi
    ;;
  down)
    [ -n "$sid" ] || die "stack '$STACK' does not exist in Portainer"
    if [ "$(jq -r .Status <<<"$stack")" = 2 ]; then
      echo "runners-stack.sh: stack '$STACK' is already stopped"
      exit 0
    fi
    api POST "/stacks/$sid/stop?endpointId=$eid" >/dev/null
    echo "runners-stack.sh: stopped stack '$STACK'"
    ;;
  status)
    git fetch -q origin main 2>/dev/null || echo "runners-stack.sh: git fetch failed; origin/main may be stale" >&2
    [ -n "$stack" ] || { echo "runners-stack.sh: no stack '$STACK' in Portainer"; exit 0; }
    jq -r --arg main "$(git rev-parse origin/main)" '
      (.GitConfig.ConfigHash // "") as $h
      | [.Name, (if .Status == 1 then "running" else "stopped" end), (if $h == "" then "-" else $h[0:7] end),
         (if $h == $main then "= origin/main" else "behind origin/main (\($main[0:7]))" end)]
      | @tsv' <<<"$stack"
    ;;
  delete)
    [ -n "$sid" ] || { echo "runners-stack.sh: no stack '$STACK' in Portainer"; exit 0; }
    api DELETE "/stacks/$sid?endpointId=$eid" >/dev/null
    echo "runners-stack.sh: deleted stack '$STACK' from Portainer"
    ;;
esac
