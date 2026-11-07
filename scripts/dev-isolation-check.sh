#!/usr/bin/env bash
# Usage: scripts/dev-isolation-check.sh <session>
# Runs inside container dev-<session> and asserts the egress policy: the
# session reaches only the allow-listed Internet hosts and s3:8333, through
# dev-egress. One OK/KO line per control; exits 1 at the first KO.
set -u
session=${1:?usage: $0 <session>}
c=dev-$session
docker inspect "$c" >/dev/null 2>&1 || { echo "KO  container $c not found" >&2; exit 1; }

run() { docker exec "$c" "$@"; }
ok() { echo "OK  $1"; }
ko() { echo "KO  $1" >&2; exit 1; }

# status <url>: HTTP status of the request, or of the proxy's CONNECT for https
# (000 = no answer at all). Goes through the proxy from the container's env.
status() {
  case $1 in
    https://*) run curl -s -o /dev/null -m 15 -w '%{http_connect}' "$1" ;;
    *)         run curl -s -o /dev/null -m 15 -w '%{http_code}' "$1" ;;
  esac
}

for u in https://api.anthropic.com https://github.com https://static.crates.io \
         https://registry.npmjs.org https://pypi.org; do
  [ "$(status "$u")" = 200 ] && ok "reachable via proxy: $u" || ko "not reachable via proxy: $u"
done

# s3 is plain http: any answer from SeaweedFS (even 403) beats a proxy refusal,
# so insist on not-000 and not squid's own 403 page (X-Squid-Error).
hdr=$(run curl -s -o /dev/null -m 15 -D - http://s3:8333/ || true)
echo "$hdr" | grep -q '^HTTP' && ! echo "$hdr" | grep -qi '^X-Squid-Error' \
  && ok "reachable via proxy: http://s3:8333" || ko "not reachable via proxy: http://s3:8333"

for u in https://example.com http://192.168.2.35:11434 http://postgres:5432 http://nginx \
         http://s3:9333 http://dev-egress:3128; do
  [ "$(status "$u")" = 403 ] && ok "refused (403): $u" || ko "NOT refused: $u"
done

if run curl -s -o /dev/null -m 8 --noproxy '*' https://github.com; then
  ko "direct access without proxy works"
else ok "direct access without proxy fails"; fi

run test -e /var/run/docker.sock && ko "/var/run/docker.sock present" || ok "no docker.sock"
echo "all isolation checks passed for $c"
