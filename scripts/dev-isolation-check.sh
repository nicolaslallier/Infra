#!/usr/bin/env bash
# Usage: scripts/dev-isolation-check.sh <session>
# Runs inside container dev-<session> and asserts the egress policy: the
# session reaches only the allow-listed Internet hosts and s3:8333, through
# dev-egress. One OK/KO line per control; exits 1 at the first KO.
# DEV_CONTAINER / DEV_EGRESS / DEV_INFRA_NET rename the three for a throwaway copy.
set -u
session=${1:?usage: $0 <session>}
c=${DEV_CONTAINER:-dev-$session}
egress=${DEV_EGRESS:-dev-egress}
infra_net=${DEV_INFRA_NET:-infra-net}
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

# headers <url> [curl args]: response headers (proxy's CONNECT reply for https).
headers() { local u=$1; shift; run curl -s -o /dev/null -m 15 -D - "$@" "$u" || true; }

# s3 is plain http: any answer from SeaweedFS (even 403) beats a proxy refusal.
hdr=$(headers http://s3:8333/)
echo "$hdr" | grep -q '^HTTP' && ! echo "$hdr" | grep -qi '^X-Squid-Error' \
  && ok "reachable via proxy: http://s3:8333" || ko "not reachable via proxy: http://s3:8333"

# Refused means squid itself said 403 (X-Squid-Error), not an origin's 403.
# The port-80/443 targets are the ones that reach the private_dst rule; the
# others fall to Safe_ports or deny all first.
for u in https://example.com http://192.168.2.35:11434 http://postgres:5432 \
         http://s3:9333 "http://$egress:3128" \
         http://192.168.2.35/ http://s3/ http://nginx/ https://192.168.2.35/ \
         http://127.0.0.1/ 'http://[::1]/'; do
  hdr=$(headers "$u" -g)
  echo "$hdr" | grep -q ' 403' && echo "$hdr" | grep -qi '^X-Squid-Error' \
    && ok "refused by proxy (403): $u" || ko "NOT refused by proxy: $u"
done

# The proxy serves dev-net only: from a container on infra-net (where dev-egress
# also sits) even a whitelisted site must be refused by squid itself.
img=$(docker inspect -f '{{.Config.Image}}' "$c")
hdr=$(docker run --rm --network "$infra_net" --entrypoint curl "$img" \
  -s -o /dev/null -m 15 -D - -x "http://$egress:3128" http://github.com/ || true)
echo "$hdr" | grep -q ' 403' && echo "$hdr" | grep -qi '^X-Squid-Error' \
  && ok "proxy refuses a client on $infra_net" || ko "proxy usable from $infra_net"

# Plain-http s3 without the proxy: no route, so this must fail.
if run curl -s -o /dev/null -m 8 --noproxy '*' http://s3:8333/; then
  ko "direct http://s3:8333 works without proxy"
else ok "direct s3 without proxy fails"; fi

if run curl -s -o /dev/null -m 8 --noproxy '*' https://github.com; then
  ko "direct access without proxy works"
else ok "direct access without proxy fails"; fi

# Positive "absent" answer: a failing `docker exec` must not read as "no socket".
[ "$(run sh -c 'test -e /var/run/docker.sock && echo present || echo absent')" = absent ] \
  && ok "no docker.sock" || ko "/var/run/docker.sock present (or docker exec failed)"
echo "all isolation checks passed for $c"
