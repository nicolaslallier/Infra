#!/usr/bin/env bash
# Harden `main` and the Actions settings of one of the five repos.
#   scripts/github-harden.sh [--apply] <darkangel|ea|heaven|infra|moria>
# Without --apply: print the wanted ruleset/settings and the diff against what
# GitHub has now (GET only). With --apply: write them, one repo per run, after
# checking every required check exists as a job of a pull_request workflow
# (a required check that never reports blocks every merge). Never prompts,
# never reads the runner PATs: it uses your own `gh` login.
# Old rulesets (`Main`, `Protect Main`) are listed, never touched.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/runners.sh
. "$here/lib/runners.sh"

RULESET_NAME=main-protection

# checks_for <name> -> one required check per line.
# Only jobs of workflows that run on EVERY pull request: a check behind a
# `paths` filter (Heaven image/image-web, Moria server.yml image/pin) never
# reports on other PRs and would block them forever; `pin` does not run on PRs.
checks_for() {
  case "$1" in
    darkangel) printf '%s\n' 'Backend unit + regression' 'Backend integration (real SeaweedFS + Postgres)' 'Frontend (vitest + vue-tsc + vite build)' ;;
    ea) printf '%s\n' 'Backend — lint, types, contrat, tests' 'Frontend — types, lint, tests, build' 'Audit — bandit, pip-audit, npm audit' 'Pipelines — lint, types, tests (docs/adr/0028)' 'Intégration — PostgreSQL et MinIO jetables' ;;
    heaven) printf '%s\n' 'test (3.11)' 'test (3.12)' 'test (3.13)' ;;
    infra) printf '%s\n' 'test' ;;
    moria) printf '%s\n' 'build (ubuntu-latest, target/release/moria-client, moria-client-linux)' 'build (windows-latest, target/release/moria-client.exe, moria-client-windows.exe)' 'build (macos-latest, target/release/moria-client, moria-client-macos)' ;;
  esac
}

# ruleset_json <name> -> the ruleset body (pure).
ruleset_json() {
  local ctx
  ctx="$(checks_for "$1" | jq -R . | jq -s .)"
  jq -n --arg name "$RULESET_NAME" --argjson ctx "$ctx" '{
    name: $name, target: "branch", enforcement: "active", bypass_actors: [],
    conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
    rules: [
      {type: "pull_request", parameters: {
        required_approving_review_count: 0, required_review_thread_resolution: true,
        dismiss_stale_reviews_on_push: false, require_code_owner_review: false,
        require_last_push_approval: false}},
      {type: "required_status_checks", parameters: {
        strict_required_status_checks_policy: true,
        required_status_checks: ($ctx | map({context: .}))}},
      {type: "required_linear_history"},
      {type: "deletion"},
      {type: "non_fast_forward"}]}'
}

# workflow_jobs <repo> -> "ok|filtered<TAB>job name<TAB>matrix(0|1)" for each job
# of each pull_request-triggered workflow. Read-only.
workflow_jobs() {
  local repo="$1" files f raw
  files="$(gh api "repos/$repo/contents/.github/workflows" | jq -r '.[]|select(.type=="file")|.name')" || return 1
  for f in $files; do
    raw="$(gh api "repos/$repo/contents/.github/workflows/$f" -H "Accept: application/vnd.github.raw")" || return 1
    printf '%s\n' "$raw" | awk '
      /^on:/ || /^"on":/ { inon = 1 }
      /^[a-z]/ && !/^on:/ && !/^"on":/ { inon = 0 }
      inon && /pull_request(_target)?[:,\] ]|pull_request$/ { pr = 1 }
      inon && /^  pull_request:/ { blk = 1; next }
      inon && blk && /^  [^ ]/ { blk = 0 }
      inon && blk && /^    paths:/ { filtered = 1 }
      /^jobs:/ { jobs = 1; next }
      jobs && /^  [A-Za-z0-9_-]+:[ ]*$/ { flush(); id = $1; sub(":", "", id); name = id; mat = 0; next }
      jobs && /^    name:/ { n = $0; sub(/^    name:[ ]*/, "", n); gsub(/^["\x27]|["\x27]$/, "", n); name = n }
      jobs && /^      matrix:/ { mat = 1 }
      function flush() { if (id != "") out[++k] = name "\t" mat }
      END { flush(); if (pr) for (i = 1; i <= k; i++) print (filtered ? "filtered" : "ok") "\t" out[i] }'
  done
}

# verify_checks <name> <repo>: every required context is a job of an unfiltered
# pull_request workflow (matrix jobs expand to "<name> (<values>)").
verify_checks() {
  local jobs c st n m found rc=0
  jobs="$(workflow_jobs "$2")" || { echo "cannot read workflows of $2" >&2; return 1; }
  while IFS= read -r c; do
    found=""
    while IFS=$'\t' read -r st n m; do
      if [ "$c" = "$n" ] || { [ "$m" = 1 ] && [ "${c#"$n ("}" != "$c" ]; }; then
        [ "$st" = ok ] && { found=ok; break; }
        found=filtered
      fi
    done <<<"$jobs"
    case "$found" in
      ok) ;;
      filtered) echo "required check '$c' is behind a pull_request paths filter in $2: it would block PRs forever" >&2; rc=1 ;;
      *) echo "required check '$c' is not a job of any pull_request workflow in $2" >&2; rc=1 ;;
    esac
  done < <(checks_for "$1")
  return $rc
}

# normalise: only the fields we set, rules sorted, so desired and current compare.
norm='{name,target,enforcement,bypass_actors,conditions,
  rules:(.rules|map({type}+(if .parameters then {parameters} else {} end))|sort_by(.type))}'

SEL='{"github_owned_allowed":true,"verified_allowed":true,"patterns_allowed":[]}'
PERM='{"enabled":true,"allowed_actions":"selected"}'
FORK='{"approval_policy":"all_external_contributors"}'

# put <repo> <path> <json>
put() { printf '%s' "$3" | gh api -X PUT "repos/$1/$2" --input - >/dev/null; }

main() {
  local apply=0 name repo rid rs
  [ "${1:-}" = --apply ] && { apply=1; shift; }
  if [ "$#" -ne 1 ]; then echo "usage: github-harden.sh [--apply] <darkangel|ea|heaven|infra|moria>" >&2; return 2; fi
  name="$1"
  repo="$(runner_repo "$name")" || { echo "usage: github-harden.sh [--apply] <darkangel|ea|heaven|infra|moria>" >&2; return 2; }

  rs="$(gh api "repos/$repo/rulesets")" || { echo "cannot list rulesets of $repo" >&2; return 1; }
  rid="$(jq -r --arg n "$RULESET_NAME" '[.[]|select(.name==$n)|.id][0] // empty' <<<"$rs")"

  if [ "$apply" = 1 ]; then
    verify_checks "$name" "$repo" || { echo "refusing to apply to $repo" >&2; return 1; }
    if [ -n "$rid" ]; then
      ruleset_json "$name" | gh api -X PUT "repos/$repo/rulesets/$rid" --input - >/dev/null || return 1
    else
      ruleset_json "$name" | gh api -X POST "repos/$repo/rulesets" --input - >/dev/null || return 1
    fi
    put "$repo" actions/permissions/fork-pr-contributor-approval "$FORK" || return 1
    put "$repo" actions/permissions "$PERM" || return 1
    put "$repo" actions/permissions/selected-actions "$SEL" || return 1
    if [ -n "$rid" ]; then echo "applied to $repo (ruleset #$rid updated)"; else echo "applied to $repo (ruleset created)"; fi
    return 0
  fi

  echo "# $repo (dry run, nothing is written)"
  echo "## desired ruleset"; ruleset_json "$name"
  echo "## other rulesets (never touched)"
  jq -r --arg n "$RULESET_NAME" '.[]|select(.name!=$n)|"  \(.name) (#\(.id), \(.enforcement))"' <<<"$rs"
  echo "## ruleset diff (< current, > desired)"
  if [ -n "$rid" ]; then
    diff <(gh api "repos/$repo/rulesets/$rid" | jq -S "$norm") <(ruleset_json "$name" | jq -S "$norm") && echo "  none"
  else
    echo "  $RULESET_NAME does not exist: --apply would POST it"
  fi
  local p want
  for p in "actions/permissions/fork-pr-contributor-approval:$FORK" "actions/permissions:$PERM" "actions/permissions/selected-actions:$SEL"; do
    want="${p#*:}"
    echo "## ${p%%:*} diff (< current, > desired)"
    diff <(gh api "repos/$repo/${p%%:*}" 2>/dev/null | jq -S --argjson w "$want" 'with_entries(select(.key as $k | $w|has($k)))') \
         <(jq -S . <<<"$want") && echo "  none"
  done
  echo "## required checks"
  verify_checks "$name" "$repo" && echo "  all found" || echo "  --apply would REFUSE"
  return 0
}

[ "${BASH_SOURCE[0]}" = "$0" ] && main "$@"
