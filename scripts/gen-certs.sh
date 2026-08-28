#!/usr/bin/env bash
# Generates a local CA + leaf cert covering *.infra.famillelallier.net,
# plus pgadmin.famillelallier.net, keycloak.famillelallier.net,
# jarvis.famillelallier.net, minio.famillelallier.net, and
# minio-console.famillelallier.net as standalone extra SANs (deliberately
# served outside the .infra. subdomain convention).
#
# Uses mkcert if it's installed (simplest, auto-trusts on some platforms);
# otherwise falls back to openssl, which is always present on macOS.
#
# Re-run with --force to regenerate. Otherwise it's a no-op if certs
# already exist, so `make init` can call this unconditionally.
set -euo pipefail
cd "$(dirname "$0")/.."

DOMAIN="infra.famillelallier.net"
EXTRA_SANS=(
  "pgadmin.famillelallier.net"
  "keycloak.famillelallier.net"
  "jarvis.famillelallier.net"
  "minio.famillelallier.net"
  "minio-console.famillelallier.net"
)
CERT_DIR="certs"
FORCE="${1:-}"
OAUTH2_PROXY_BUNDLE="$CERT_DIR/oauth2proxy-ca-bundle.crt"
# Read out of docker-compose.yml rather than duplicated here: a comment
# saying "keep these in sync" is not a mechanism, and a compose image bump
# would otherwise keep building the bundle from the roots of an image that
# is no longer the one running.
OAUTH2_PROXY_IMAGE="$(
  awk '/^[[:space:]]*image:[[:space:]]*quay\.io\/oauth2-proxy\/oauth2-proxy:/ { print $2; exit }' \
    docker-compose.yml
)"

mkdir -p "$CERT_DIR"

# oauth2-proxy's server-to-server calls to Keycloak (token exchange, jwks)
# route through NGINX and hit this local CA (see the keycloak.famillelallier.net
# alias on the nginx service in docker-compose.yml). Its image is distroless
# (no shell, so no --provider-ca-file+RUN cat trick at build time, and
# --provider-ca-file isn't wired into every internal HTTP client anyway as
# of v7.6.0) — so instead we replace its baked-in system CA bundle wholesale
# with one that also trusts our CA, mounted over
# /etc/ssl/certs/ca-certificates.crt (see the oauth2-proxy service's
# volumes in docker-compose.yml). Every Go http.Client in that process uses
# the system pool by default, so this covers discovery, token exchange, and
# jwks fetches alike, regardless of which internal code path each one takes.
#
# A missing bundle is not a benign "skip": Docker creates a *directory* at a
# bind-mount source that doesn't exist, so oauth2-proxy would come up with an
# empty root store and every outbound TLS call would die with "certificate
# signed by unknown authority", far from the actual cause. Every failure path
# below is therefore fatal and says exactly how to recover.
gen_oauth2proxy_bundle() {
  local ca_crt="$1"
  local bundle="$OAUTH2_PROXY_BUNDLE"

  if [ -d "$bundle" ]; then
    echo "gen-certs.sh: $bundle is a DIRECTORY, not a file." >&2
    echo "  Docker created it as a bind-mount stub because it was missing at" >&2
    echo "  'docker compose up' time. Remove it and re-run:" >&2
    echo "" >&2
    echo "    docker compose rm -sf oauth2-proxy && rm -rf $bundle && make certs" >&2
    exit 1
  fi

  # A --force run mints a new CA, so any existing bundle embeds the old one.
  # Drop it up front rather than merely overwriting it on success: if the
  # rebuild below fails, a later plain `make certs` must not find a leftover
  # bundle, conclude it is current, and leave oauth2-proxy trusting a CA that
  # nginx no longer serves.
  if [ "$FORCE" = "--force" ]; then
    rm -f "$bundle"
  fi

  if [ -s "$bundle" ]; then
    echo "gen-certs.sh: $bundle already exists, skipping"
    return 0
  fi

  if [ -z "$OAUTH2_PROXY_IMAGE" ]; then
    echo "gen-certs.sh: could not read the oauth2-proxy image tag from docker-compose.yml." >&2
    echo "  Expected a line like 'image: quay.io/oauth2-proxy/oauth2-proxy:vX.Y.Z'." >&2
    exit 1
  fi

  if ! docker info >/dev/null 2>&1; then
    echo "gen-certs.sh: cannot build $bundle — the Docker daemon is not reachable." >&2
    echo "  oauth2-proxy mounts this file over its system CA bundle; leaving it" >&2
    echo "  missing makes Docker mount an empty directory in its place and breaks" >&2
    echo "  every TLS call it makes. Start Docker, then re-run:  make certs" >&2
    exit 1
  fi

  echo "gen-certs.sh: building $bundle from $OAUTH2_PROXY_IMAGE's CA bundle + $ca_crt"

  local cid err
  # Keep stderr: without it a failed pull/daemon error is invisible and the
  # script just dies with a bare non-zero exit under `set -e`.
  if ! cid="$(docker create "$OAUTH2_PROXY_IMAGE" 2>"$CERT_DIR/.docker-create.err")"; then
    err="$(cat "$CERT_DIR/.docker-create.err")"
    rm -f "$CERT_DIR/.docker-create.err"
    echo "gen-certs.sh: 'docker create $OAUTH2_PROXY_IMAGE' failed:" >&2
    echo "  ${err:-(no output)}" >&2
    exit 1
  fi
  rm -f "$CERT_DIR/.docker-create.err"

  if [ -z "$cid" ]; then
    echo "gen-certs.sh: 'docker create $OAUTH2_PROXY_IMAGE' printed no container id" >&2
    exit 1
  fi

  # Clean up the scratch container on both paths, explicitly rather than via a
  # RETURN trap: a RETURN trap does not fire when the function leaves through
  # `exit`, so the failure branch below would still leak one container per run.
  if ! docker cp "$cid:/etc/ssl/certs/ca-certificates.crt" "$bundle"; then
    docker rm -f "$cid" >/dev/null 2>&1 || true
    echo "gen-certs.sh: could not copy /etc/ssl/certs/ca-certificates.crt out of" >&2
    echo "  $OAUTH2_PROXY_IMAGE — has the image moved its CA bundle?" >&2
    rm -f "$bundle"
    exit 1
  fi
  docker rm -f "$cid" >/dev/null 2>&1 || true

  cat "$ca_crt" >> "$bundle"
}

# Deliberately *after* gen_oauth2proxy_bundle so the early exit can still build
# it. The bundle is a newer addition than the certs themselves, so every host
# whose certs/infra.crt predates it would otherwise take this branch, be told
# "skipping", exit 0, and get an empty CA store in oauth2-proxy on the next
# `make up`. `make up` does not depend on this target and certs/ is gitignored,
# so this is the only place that can notice.
if [ -f "$CERT_DIR/infra.crt" ] && [ "$FORCE" != "--force" ]; then
  echo "gen-certs.sh: $CERT_DIR/infra.crt already exists, skipping (use --force to regenerate)"
  gen_oauth2proxy_bundle "$CERT_DIR/infra-ca.crt"
  exit 0
fi

if command -v mkcert >/dev/null 2>&1; then
  echo "gen-certs.sh: using mkcert"
  CAROOT="$(mkcert -CAROOT)"
  mkcert -cert-file "$CERT_DIR/infra.crt" -key-file "$CERT_DIR/infra.key" \
    "$DOMAIN" "*.$DOMAIN" "${EXTRA_SANS[@]}" localhost 127.0.0.1
  cp "$CAROOT/rootCA.pem" "$CERT_DIR/infra-ca.crt"
  gen_oauth2proxy_bundle "$CERT_DIR/infra-ca.crt"
  echo "gen-certs.sh: done. mkcert already trusts its CA in your system store."
  exit 0
fi

echo "gen-certs.sh: mkcert not found, falling back to openssl"

CA_KEY="$CERT_DIR/infra-ca.key"
CA_CRT="$CERT_DIR/infra-ca.crt"
LEAF_KEY="$CERT_DIR/infra.key"
LEAF_CRT="$CERT_DIR/infra.crt"
LEAF_CSR="$CERT_DIR/infra.csr"
SAN_CONF="$CERT_DIR/.san.cnf"

# 1. Local CA (10 year validity — this is dev-only tooling).
openssl req -x509 -new -nodes -newkey rsa:4096 -sha256 -days 3650 \
  -subj "/CN=Infra Local Dev CA" \
  -keyout "$CA_KEY" -out "$CA_CRT"

# 2. Leaf key + CSR with SANs for the wildcard domain, localhost, and
#    each extra exception hostname.
ALT_NAMES="DNS.1 = $DOMAIN
DNS.2 = *.$DOMAIN
DNS.3 = localhost"
i=4
for san in "${EXTRA_SANS[@]}"; do
  ALT_NAMES="$ALT_NAMES
DNS.$i = $san"
  i=$((i + 1))
done

cat > "$SAN_CONF" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $DOMAIN

[v3_req]
keyUsage = keyEncipherment, digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
$ALT_NAMES
IP.1 = 127.0.0.1
EOF

openssl req -new -nodes -newkey rsa:2048 \
  -keyout "$LEAF_KEY" -out "$LEAF_CSR" -config "$SAN_CONF"

# 3. Sign the leaf with the local CA, carrying the SANs over.
openssl x509 -req -in "$LEAF_CSR" -CA "$CA_CRT" -CAkey "$CA_KEY" \
  -CAcreateserial -days 825 -sha256 \
  -extfile "$SAN_CONF" -extensions v3_req \
  -out "$LEAF_CRT"

rm -f "$LEAF_CSR" "$SAN_CONF" "$CERT_DIR/infra-ca.srl"

gen_oauth2proxy_bundle "$CA_CRT"

echo "gen-certs.sh: done."
echo ""
echo "Browsers will warn until the local CA is trusted. To trust it on macOS:"
echo ""
echo "  sudo security add-trusted-cert -d -r trustRoot \\"
echo "    -k /Library/Keychains/System.keychain $CA_CRT"
echo ""
echo "That command modifies your system trust store — run it yourself when ready."
