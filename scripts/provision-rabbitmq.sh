#!/usr/bin/env bash
# Give an app its own RabbitMQ vhost and user -- the AMQP twin of provision-app.sh.
#
# Usage: scripts/provision-rabbitmq.sh <app>
#
# Creates vhost <app> and user <app> (no tags, so no management UI access),
# with configure/write/read ".*" on that vhost. A fresh user has no permission
# anywhere else; this script does not revoke grants someone added by hand. The password is <APP>_AMQP_PASSWORD from .env (rendered from the
# vault). Idempotent: re-run it after changing the password and the existing
# user is updated in place. Letters and digits only, because apps embed it in
# an amqp:// URL.
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:?usage: scripts/provision-rabbitmq.sh <app>}"
app_re='^[a-z][a-z0-9_]{0,31}$'
[[ "$app" =~ $app_re ]] || { echo "provision-rabbitmq.sh: app '$app' must be 1-32 chars of a-z, 0-9, '_'" >&2; exit 1; }

[ -f .env ] || { echo "provision-rabbitmq.sh: .env not found (run 'make init' first)" >&2; exit 1; }
# The broker's admin account: provisioning under its name would overwrite its
# password and strip its tags.
admin="$(grep -E '^RABBITMQ_DEFAULT_USER=' .env | tail -n1 | cut -d= -f2-)"
[ "$app" != "${admin:-}" ] || { echo "provision-rabbitmq.sh: '$app' is RABBITMQ_DEFAULT_USER, the broker's admin account; pick another app name" >&2; exit 1; }
var_name="$(echo "${app}_AMQP_PASSWORD" | tr '[:lower:]' '[:upper:]')"
pass="$(grep -E "^${var_name}=" .env | tail -n1 | cut -d= -f2-)"
[ -n "$pass" ] || { echo "provision-rabbitmq.sh: ${var_name} not set in .env (put it in the vault, then make vault-env)" >&2; exit 1; }
[[ "$pass" =~ ^[A-Za-z0-9]+$ ]] || { echo "provision-rabbitmq.sh: ${var_name} must be letters and digits only (it goes into an amqp:// URL)" >&2; exit 1; }

# RMQ_EXEC / RMQ_TARGET only exist so the permissions can be proven against a
# throwaway broker (docker exec -i <container>) instead of the real stack.
# `-e NAME` with no value: the password comes from this process's environment,
# not from an argv visible in ps on the host. Inside the container it reaches
# rabbitmqctl on stdin (add_user/change_password prompt for it when it is not
# an argument), so it is never in a process's argv there either; printf is a
# shell builtin.
export RMQP_APP="$app" RMQP_PASS="$pass"
# shellcheck disable=SC2086
${RMQ_EXEC:-docker compose exec -T} -e RMQP_APP -e RMQP_PASS "${RMQ_TARGET:-rabbitmq}" sh -eu -s <<'EOF2'
rabbitmqctl add_vhost "$RMQP_APP" >/dev/null
if rabbitmqctl -q list_users | cut -f1 | grep -qx "$RMQP_APP"; then
  printf '%s\n' "$RMQP_PASS" | rabbitmqctl change_password "$RMQP_APP" >/dev/null
  echo "provision-rabbitmq.sh: user '$RMQP_APP' exists, password updated" >&2
else
  printf '%s\n' "$RMQP_PASS" | rabbitmqctl add_user "$RMQP_APP" >/dev/null
  echo "provision-rabbitmq.sh: user '$RMQP_APP' created" >&2
fi
rabbitmqctl set_user_tags "$RMQP_APP" >/dev/null
rabbitmqctl set_permissions -p "$RMQP_APP" "$RMQP_APP" '.*' '.*' '.*' >/dev/null
echo "provision-rabbitmq.sh: '$RMQP_APP' has configure/write/read on vhost '$RMQP_APP' only" >&2
EOF2
