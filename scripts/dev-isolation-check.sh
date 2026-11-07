#!/usr/bin/env bash
# Assert a dev session's network box: through dev-egress only the
# allow-listed domains and s3 answer; LAN, infra-net and direct egress don't.
# Usage: scripts/dev-isolation-check.sh <session>   (container dev-<session>)
set -euo pipefail
c="dev-${1:?usage: dev-isolation-check.sh <session>}"

# HTTP code via the session's own proxy env; 000 = no connection at all.
code() { local r; r="$(docker exec "$c" curl -s -o /dev/null -w '%{http_code}' -m 10 "$@")" || true; echo "${r:-000}"; }
ok() { printf 'OK  %s\n' "$1"; }
ko() { printf 'KO  %s (got %s)\n' "$1" "$2"; exit 1; }
docker inspect "$c" >/dev/null 2>&1 || ko "container $c exists" missing

# HTTPS: judge squid's answer to CONNECT (200 = tunnelled), not the site's
# status -- static.crates.io itself answers 403 on "/".
tunnel() { local r; r="$(docker exec "$c" curl -s -o /dev/null -w '%{http_connect}' -m 10 "$@")" || true; echo "${r:-000}"; }
for u in https://api.anthropic.com https://github.com https://static.crates.io \
         https://registry.npmjs.org https://pypi.org; do
  r="$(tunnel "$u")"; [[ "$r" == 200 ]] && ok "$u reachable" || ko "$u reachable (CONNECT)" "$r"
done
r="$(code http://s3:8333)"; [[ "$r" != 000 && "$r" != 403 ]] && ok "s3:8333 reachable ($r)" || ko "s3:8333 reachable" "$r"
# Refused by squid (403), or not even resolvable/connectable (000).
r="$(tunnel https://example.com)"; [[ "$r" != 200 ]] && ok "https://example.com refused ($r)" || ko "https://example.com refused" "$r"
for u in http://example.com http://192.168.2.35:11434 http://postgres:5432 http://nginx; do
  r="$(code "$u")"; [[ "$r" == 403 || "$r" == 000 ]] && ok "$u refused ($r)" || ko "$u refused" "$r"
done
r="$(code --noproxy '*' https://github.com)"; [[ "$r" == 000 ]] && ok "direct egress blocked" || ko "direct egress blocked" "$r"
docker exec "$c" test ! -e /var/run/docker.sock && ok "no docker socket" || ko "no docker socket" present
