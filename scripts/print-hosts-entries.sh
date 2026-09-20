#!/usr/bin/env bash
# Prints the /etc/hosts lines this stack needs. Nothing here edits the
# file automatically — /etc/hosts is system config, so review and add
# these yourself.
set -euo pipefail

DOMAIN="infra.famillelallier.net"
GRAFANA_HOST="grafana.infra.famillelallier.net"
RABBITMQ_HOST="rabbitmq.infra.famillelallier.net"
PORTAINER_HOST="portainer.infra.famillelallier.net"
MINIO_HOST="minio.famillelallier.net"
MINIO_CONSOLE_HOST="minio-console.famillelallier.net"
PGADMIN_HOST="pgadmin.famillelallier.net"
KEYCLOAK_HOST="keycloak.famillelallier.net"
JARVIS_HOST="jarvis.famillelallier.net"
CHAT_HOST="chat.famillelallier.net"
EA_HOST="ea.infra.famillelallier.net"
OBSIDIAN_HOST="obsidian.infra.famillelallier.net"
AIRFLOW_HOST="airflow.infra.famillelallier.net"
VAULT_HOST="vault.infra.famillelallier.net"
HEAVEN_HOST="heaven.infra.famillelallier.net"

# The stack's host (LAN_IP from .env), not this machine: the stack runs on
# the Windows laptop, and loopback only reaches it when run from there.
IP="$(sed -n 's/^LAN_IP=//p' "$(dirname "$0")/../.env" 2>/dev/null | tail -1)"
IP="${IP:-127.0.0.1}"

cat <<EOF
Add these lines to /etc/hosts (they don't conflict with your existing
beacon.famillelallier.net / dev.famillelallier.net entries):

$IP $DOMAIN
$IP $GRAFANA_HOST
$IP $RABBITMQ_HOST
$IP $PORTAINER_HOST
$IP $MINIO_HOST
$IP $MINIO_CONSOLE_HOST
$IP $PGADMIN_HOST
$IP $KEYCLOAK_HOST
$IP $JARVIS_HOST
$IP $CHAT_HOST
$IP $EA_HOST
$IP $OBSIDIAN_HOST
$IP $AIRFLOW_HOST
$IP $VAULT_HOST
$IP $HEAVEN_HOST

One way to append them:

  sudo tee -a /etc/hosts <<'HOSTS'
$IP $DOMAIN
$IP $GRAFANA_HOST
$IP $RABBITMQ_HOST
$IP $PORTAINER_HOST
$IP $MINIO_HOST
$IP $MINIO_CONSOLE_HOST
$IP $PGADMIN_HOST
$IP $KEYCLOAK_HOST
$IP $JARVIS_HOST
$IP $CHAT_HOST
$IP $EA_HOST
$IP $OBSIDIAN_HOST
$IP $AIRFLOW_HOST
$IP $VAULT_HOST
$IP $HEAVEN_HOST
HOSTS
EOF
