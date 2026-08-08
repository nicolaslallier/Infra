#!/usr/bin/env bash
# Prints the /etc/hosts lines this stack needs. Nothing here edits the
# file automatically — /etc/hosts is system config, so review and add
# these yourself.
set -euo pipefail

DOMAIN="infra.famillelallier.net"
PGADMIN_HOST="pgadmin.famillelallier.net"
KEYCLOAK_HOST="keycloak.famillelallier.net"
JARVIS_HOST="jarvis.famillelallier.net"

cat <<EOF
Add these lines to /etc/hosts (they don't conflict with your existing
beacon.famillelallier.net / dev.famillelallier.net entries):

127.0.0.1 $DOMAIN
127.0.0.1 $PGADMIN_HOST
127.0.0.1 $KEYCLOAK_HOST
127.0.0.1 $JARVIS_HOST

One way to append them:

  sudo tee -a /etc/hosts <<'HOSTS'
127.0.0.1 $DOMAIN
127.0.0.1 $PGADMIN_HOST
127.0.0.1 $KEYCLOAK_HOST
127.0.0.1 $JARVIS_HOST
HOSTS
EOF
