#!/usr/bin/env bash
# Generates a local CA + leaf cert covering *.infra.famillelallier.net,
# plus pgadmin.famillelallier.net as a standalone extra SAN (pgAdmin is
# deliberately served outside the .infra. subdomain convention).
#
# Uses mkcert if it's installed (simplest, auto-trusts on some platforms);
# otherwise falls back to openssl, which is always present on macOS.
#
# Re-run with --force to regenerate. Otherwise it's a no-op if certs
# already exist, so `make init` can call this unconditionally.
set -euo pipefail
cd "$(dirname "$0")/.."

DOMAIN="infra.famillelallier.net"
EXTRA_SAN="pgadmin.famillelallier.net"
CERT_DIR="certs"
FORCE="${1:-}"

mkdir -p "$CERT_DIR"

if [ -f "$CERT_DIR/infra.crt" ] && [ "$FORCE" != "--force" ]; then
  echo "gen-certs.sh: $CERT_DIR/infra.crt already exists, skipping (use --force to regenerate)"
  exit 0
fi

if command -v mkcert >/dev/null 2>&1; then
  echo "gen-certs.sh: using mkcert"
  CAROOT="$(mkcert -CAROOT)"
  mkcert -cert-file "$CERT_DIR/infra.crt" -key-file "$CERT_DIR/infra.key" \
    "$DOMAIN" "*.$DOMAIN" "$EXTRA_SAN" localhost 127.0.0.1
  cp "$CAROOT/rootCA.pem" "$CERT_DIR/infra-ca.crt"
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

# 2. Leaf key + CSR with SANs for the wildcard domain and localhost.
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
DNS.1 = $DOMAIN
DNS.2 = *.$DOMAIN
DNS.3 = localhost
DNS.4 = $EXTRA_SAN
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

echo "gen-certs.sh: done."
echo ""
echo "Browsers will warn until the local CA is trusted. To trust it on macOS:"
echo ""
echo "  sudo security add-trusted-cert -d -r trustRoot \\"
echo "    -k /Library/Keychains/System.keychain $CA_CRT"
echo ""
echo "That command modifies your system trust store — run it yourself when ready."
