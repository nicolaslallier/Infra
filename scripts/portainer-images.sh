#!/usr/bin/env bash
# Build the images the stack references but cannot pull, through Portainer's
# API (see lib/portainer-api.sh): the daemon clones and builds the git ref
# itself, so nothing is built or sent from this machine. A tag already on the
# daemon is not rebuilt unless FORCE is set. Needs OLLAMA_PROXY_REF and LITELLM_PGVECTOR_REF (the Makefile sets them).
set -euo pipefail
# shellcheck source=lib/portainer-api.sh
. "$(dirname "$0")/lib/portainer-api.sh"

build() { # <tag> <git-url#ref>
  local tag="$1" remote="$2" img out
  printf '\n\033[1mImage %s\033[0m\n' "$tag"
  if [ -z "${FORCE:-}" ] && img="$(api GET "$d/images/$tag/json" 2>/dev/null)"; then
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

# `make dev-image`: the dev images (session, egress proxy, SSH gateway), from
# the Infra repo on GitHub (DEV_IMAGE_REF, default main -- so dev/ must be
# merged first), on the dev environment (PORTAINER_ENDPOINT_ID, the Makefile's
# DEV_ENDPOINT). `dev-plumbing`: only the proxy and the gateway.
if [ "${1:-}" = dev ] || [ "${1:-}" = dev-plumbing ]; then
  git="https://github.com/nicolaslallier/Infra.git#${DEV_IMAGE_REF:-main}"
  [ "$1" = dev-plumbing ] || build "devbox-session:1" "$git:dev/image"
  build "dev-egress:1" "$git:dev/egress"
  build "dev-gateway:1" "$git:dev/gateway"
  exit 0
fi

: "${OLLAMA_PROXY_REF:?}"
build "infra-ollama-proxy:${OLLAMA_PROXY_REF:0:7}" "https://github.com/nicolaslallier/ollama-metrics.git#$OLLAMA_PROXY_REF"
: "${LITELLM_PGVECTOR_REF:?}"
build "infra-litellm-pgvector:${LITELLM_PGVECTOR_REF:0:7}" "https://github.com/BerriAI/litellm-pgvector.git#$LITELLM_PGVECTOR_REF"
