#!/usr/bin/env bash
# Build the images the stack references but cannot pull, through Portainer's
# API (see lib/portainer-api.sh): the daemon clones and builds the git ref
# itself, so nothing is built or sent from this machine. A tag already on the
# daemon is not rebuilt. Needs OLLAMA_PROXY_REF (the Makefile sets it).
set -euo pipefail
# shellcheck source=scripts/lib/portainer-api.sh
. "$(dirname "$0")/lib/portainer-api.sh"

build() { # <tag> <git-url#ref>
  local tag="$1" remote="$2" img out
  printf '\n\033[1mImage %s\033[0m\n' "$tag"
  if img="$(api GET "$d/images/$tag/json" 2>/dev/null)"; then
    ok "already on the daemon, not rebuilt"
  else
    ok "not found, building from $remote"
    # BuildKit (version=2): the Dockerfile uses FROM --platform=$BUILDPLATFORM,
    # which the legacy builder rejects. Portainer's proxy 500s on a JSON
    # Content-Type here, so the (empty) body is declared a tar.
    out="$(API_CONTENT_TYPE=application/x-tar api POST "$d/build?t=$tag&rm=1&version=2&remote=$(jq -rn --arg r "$remote" '$r | @uri')")"
    # The build stream (NDJSON) reports failures as {"error": ...} lines on HTTP 200.
    jq -r 'select(.error) | .error' <<<"$out" | grep . >&2 && die "build of $tag failed"
    img="$(api GET "$d/images/$tag/json")"
    ok "built"
  fi
  ok "id $(jq -r '.Id[7:19]' <<<"$img"), $(jq -r '(.Size / 1048576 | floor)' <<<"$img") MB, created $(jq -r .Created <<<"$img")"
}

: "${OLLAMA_PROXY_REF:?}"
build "infra-ollama-proxy:${OLLAMA_PROXY_REF:0:7}" "https://github.com/nicolaslallier/ollama-metrics.git#$OLLAMA_PROXY_REF"
