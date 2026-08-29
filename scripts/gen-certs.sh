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
# Must match the oauth2-proxy image tag in docker-compose.yml.
OAUTH2_PROXY_IMAGE="quay.io/oauth2-proxy/oauth2-proxy:v7.6.0"

mkdir -p "$CERT_DIR"

if [ -f "$CERT_DIR/infra.crt" ] && [ "$FORCE" != "--force" ]; then
  echo "gen-certs.sh: $CERT_DIR/infra.crt already exists, skipping (use --force to regenerate)"
  exit 0
fi

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
gen_oauth2proxy_bundle() {
  local ca_crt="$1"
  local bundle="$CERT_DIR/oauth2proxy-ca-bundle.crt"
  if ! command -v docker >/dev/null 2>&1; then
    echo "gen-certs.sh: docker not found, skipping $bundle (oauth2-proxy needs it — run this script again once docker is available)"
    return 0
  fi
  echo "gen-certs.sh: building $bundle from $OAUTH2_PROXY_IMAGE's CA bundle + $ca_crt"
  local cid
  cid="$(docker create "$OAUTH2_PROXY_IMAGE" 2>/dev/null)"
  docker cp "$cid:/etc/ssl/certs/ca-certificates.crt" "$bundle"
  docker rm "$cid" >/dev/null
  cat "$ca_crt" >> "$bundle"
}

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
