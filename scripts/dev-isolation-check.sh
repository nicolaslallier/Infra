#!/usr/bin/env bash
# Assert a dev session's network box: through dev-egress only the
# allow-listed domains and s3:8333 answer, and a refused name is never even
# resolved; LAN, infra-net, the Docker host and direct egress are out of reach.
# Usage: scripts/dev-isolation-check.sh <session>   (container dev-<session>)
# DEV_EGRESS names the proxy container (default dev-egress), for a throwaway copy.
set -euo pipefail
c="dev-${1:?usage: dev-isolation-check.sh <session>}"
egress="${DEV_EGRESS:-dev-egress}"
fail=0
ok() { printf 'OK  %s\n' "$1"; }
ko() { printf 'KO  %s (got %s)\n' "$1" "$2"; fail=1; }
docker inspect "$c" >/dev/null 2>&1 || { ko "container $c exists" missing; exit 1; }

# A request through the session's proxy env: "<CONNECT code> <HTTP code> <squid error>".
# 000 = no connection; the squid error is empty when squid did not refuse.
probe() {
  local r
  r="$(docker exec "$c" curl -s -o /dev/null -D - -w '\n%{http_connect} %{http_code}' -m 10 "$@" 2>/dev/null)" || true
  local codes err
  codes="$(tail -1 <<<"$r")"
  err="$(grep -i '^x-squid-error:' <<<"$r" | head -1 | awk '{print $2}' | tr -d '\r')"
  echo "${codes:-000 000} ${err:--}"
}
reached() { # <label> <expect: tunnel|http> <curl args...>
  local label=$1 how=$2; shift 2; local r; r="$(probe "$@")"
  case "$how" in
    tunnel) [[ "$r" == "200 "* ]] ;;
    http) read -r _ code err <<<"$r"; [[ "$code" != 000 && "$err" == - ]] ;;
  esac && ok "$label reachable" || ko "$label reachable" "$r"
}
# Squid's own access denial only: ERR_CONNECT_FAIL, ERR_ZERO_SIZE_OBJECT and
# the like mean squid let the request through and tried the destination.
refused() { # <label> <curl args...>
  local label=$1; shift; local r; r="$(probe "$@")"
  [[ "$r" == *" ERR_ACCESS_DENIED" ]] && ok "$label refused ($r)" || ko "$label refused" "$r"
}
unreachable() { # <label> <curl args...>: nothing answered at all
  local label=$1; shift; local r; r="$(probe "$@")"
  [[ "$r" == "000 000 "* ]] && ok "$label unreachable" || ko "$label unreachable" "$r"
}

# HTTPS: squid's answer to CONNECT (200 = tunnelled), not the site's status --
# static.crates.io itself answers 403 on "/".
for u in https://api.anthropic.com https://github.com https://static.crates.io \
         https://registry.npmjs.org https://pypi.org; do
  reached "$u" tunnel "$u"
done
# An authenticated SeaweedFS answers 403 itself: squid's own refusal is told
# apart by its X-Squid-Error header.
reached "http://s3:8333" http http://s3:8333

refused "https://example.com" https://example.com
refused "https://140.82.112.3 (IP literal, PTR in .github.com)" -k https://140.82.112.3
refused "http://example.com" http://example.com
refused "http://140.82.112.3" http://140.82.112.3
refused "http://192.168.2.35:11434 (LAN)" http://192.168.2.35:11434
refused "http://postgres:5432 (infra-net)" http://postgres:5432
refused "http://nginx (infra-net)" http://nginx
refused "http://s3:8888 (filer)" http://s3:8888
refused "http://s3:9333 (master)" http://s3:9333
refused "CONNECT s3:8333" -p http://s3:8333
refused "http://host.docker.internal" http://host.docker.internal
refused "http://127.0.0.1 (loopback)" http://127.0.0.1/
refused "http://[::1] (IPv6 loopback)" -g 'http://[::1]/'
refused "http://[fd00::1] (IPv6 ULA)" -g 'http://[fd00::1]/'
refused "http://100.64.0.1 (CGNAT)" http://100.64.0.1/
for u in https://github.com http://host.docker.internal http://192.168.65.254 http://172.17.0.1; do
  unreachable "direct $u (no proxy)" --noproxy '*' "$u"
done

# The session itself resolves nothing outside dev-net.
docker exec "$c" getent hosts example.com >/dev/null 2>&1 && ko "no DNS in the session" "example.com resolved" \
  || ok "no DNS in the session"
# A refused name is never looked up by squid (no DNS exfiltration).
leak="leakcheck$RANDOM$RANDOM.example.org"
probe "http://$leak/" >/dev/null; probe "https://$leak/" >/dev/null
docker exec "$egress" wget -qO- http://127.0.0.1:3128/squid-internal-mgr/ipcache 2>/dev/null | grep -q "$leak" \
  && ko "refused names are not resolved" "$leak in squid's ipcache" || ok "refused names are not resolved"

docker exec "$c" test ! -e /var/run/docker.sock && ok "no docker socket" || ko "no docker socket" present
exit "$fail"
