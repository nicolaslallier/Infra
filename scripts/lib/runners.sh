# shellcheck shell=bash
# Sourced by the runner scripts: the one table of GitHub runners.
# Each entry is <name>:<Repo>. New entries go at the end: gen-runner-env.sh
# reads piped tokens in this order.
# <name> is the compose service suffix
# (runner-<name>), the runner's label, and the lowercase part of its PAT variable.
RUNNERS=(darkangel:DarkAngel ea:EA heaven:Heaven infra:Infra moria:Moria ai:AI)

# runner_repo <name> -> nicolaslallier/<Repo>
runner_repo() {
  local e
  for e in "${RUNNERS[@]}"; do
    [ "${e%%:*}" = "$1" ] && { printf 'nicolaslallier/%s\n' "${e#*:}"; return 0; }
  done
  echo "runners.sh: unknown runner '$1'" >&2
  return 1
}

# runner_token_var <name> -> GH_RUNNER_TOKEN_<UPPERCASE>
runner_token_var() {
  printf 'GH_RUNNER_TOKEN_%s\n' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
}
