# Sourced by portainer-net.sh / portainer-volumes.sh: talks to Portainer's
# API directly (no docker CLI, no SSH). Sets $url, $eid, $d (the Docker proxy
# path) and defines api/ok/warn/die plus $ver and $envname.
die() { printf 'portainer: %b\n' "$*" >&2; exit 1; }

# .portainer.env is gitignored, so a linked worktree lacks it: fall back to
# the main checkout's.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
env_file="$root/.portainer.env"
[ -f "$env_file" ] || env_file="$(cd "$(git -C "$root" rev-parse --git-common-dir)/.." && pwd)/.portainer.env"
[ -f "$env_file" ] || die ".portainer.env not found (needs PORTAINER_API_KEY; see .env.example)"
set -a; . "$env_file"; set +a
[ -n "${PORTAINER_API_KEY:-}" ] && [ "$PORTAINER_API_KEY" != change-me ] || die "set PORTAINER_API_KEY in $env_file"

# Portainer's certificate is self-signed, so it is pinned by public key rather
# than trusted blindly (-k alone would hand the API key to any MITM). curl
# enforces --pinnedpubkey even with -k. Record the pin once, in .portainer.env:
#   openssl s_client -connect HOST:9443 </dev/null 2>/dev/null | openssl x509 -pubkey -noout \
#     | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl enc -base64
[ -n "${PORTAINER_PINNEDPUBKEY:-}" ] || die "set PORTAINER_PINNEDPUBKEY=sha256//<base64> in $env_file (command in this script's comments)"

url="${PORTAINER_URL:-https://${INFRA_HOST:?set PORTAINER_URL or INFRA_HOST}:9443}/api"
# The key goes in a curl config on stdin, not on the command line.
api() { # <method> <path> [json-body]
  local out
  out="$(printf 'header = "X-API-Key: %s"\n' "$PORTAINER_API_KEY" |
    curl -sSk --pinnedpubkey "$PORTAINER_PINNEDPUBKEY" -K - --fail-with-body -X "$1" -H "Content-Type: ${API_CONTENT_TYPE:-application/json}" \
      ${3:+--data-binary "$3"} "$url$2" 2>&1)" \
    || die "$1 $2 failed (is Portainer up at $url? 'make portainer-up')\n${out:+Portainer said: $out}"
  printf '%s' "$out"
}

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }

printf '\033[1mPortainer\033[0m  %s\n' "${url%/api}"
ver="$(api GET /system/status | jq -r '.Version // "?"')"
envs="$(api GET /endpoints)"
eid="${PORTAINER_ENDPOINT_ID:-$(jq -r '[.[] | select(.Type == 1)][0].Id // empty' <<<"$envs")}"
[ -n "$eid" ] || die "no local Docker environment found in Portainer"
ok "version $ver, environment \"$(jq -r --argjson i "$eid" '.[] | select(.Id == $i) | .Name' <<<"$envs")\" (#$eid), certificate pinned"
d="/endpoints/$eid/docker"
