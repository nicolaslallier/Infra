#!/usr/bin/env bash
# Create an app's ntfy user, give it write-only access to its topics, and mint
# an access token -- the push twin of provision-s3.sh.
#
# Usage: scripts/provision-ntfy.sh <app> [topic-prefix]
#   topic-prefix defaults to <app>; the app may publish to <topic-prefix>-*
#
# Idempotent for the user and the ACL (an existing user is left alone). Every
# run mints a NEW token, printed once on stdout as the only line there; older
# tokens stay valid until revoked (`docker compose exec ntfy ntfy token list`
# / `ntfy token remove`). Progress goes to stderr so `tok=$(...)` captures just
# the token. The user's password is random and never shown: the app uses the
# token, and a human who needs the account resets it with `ntfy user change-pass`.
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:?provision-ntfy.sh: usage: scripts/provision-ntfy.sh <app> [topic-prefix]}"
prefix="${2:-$app}"

# Both values end up inside a command run in the container; validate, don't
# quote. Topic names allow [A-Za-z0-9_-] only, and the prefix is followed by
# "-*" below, so it cannot carry a wildcard or whitespace of its own.
app_re='^[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$'
prefix_re='^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$'
[[ "$app" =~ $app_re ]] || { echo "provision-ntfy.sh: app '$app' must be 2-63 chars of a-z, 0-9, '-'" >&2; exit 1; }
[[ "$prefix" =~ $prefix_re ]] || { echo "provision-ntfy.sh: topic prefix '$prefix' must be 1-63 chars of A-Z a-z 0-9 _ -" >&2; exit 1; }

command -v openssl >/dev/null || { echo "provision-ntfy.sh: openssl is required to generate the password" >&2; exit 1; }
password="$(openssl rand -hex 24)"

# `-e NAME` with no value: docker takes it from this process's environment, so
# neither the password nor anything else lands in an argv (ps). ntfy reads the
# new user's password from NTFY_PASSWORD when stdin is not a terminal.
export NTFYP_APP="$app" NTFYP_PREFIX="$prefix" NTFY_PASSWORD="$password"
docker compose exec -T -e NTFYP_APP -e NTFYP_PREFIX -e NTFY_PASSWORD \
  ntfy sh -eu -s <<'EOF2'
# Do not parse `ntfy user list` (human-readable, not a stable format): try
# the add and treat "already exists" as success. Anything else is a real
# failure and aborts with ntfy's own message.
if err=$(ntfy user add --role=user "$NTFYP_APP" 2>&1 >/dev/null); then
  echo "provision-ntfy.sh: user '$NTFYP_APP' created" >&2
elif printf '%s\n' "$err" | grep -qi 'exist'; then
  echo "provision-ntfy.sh: user '$NTFYP_APP' already exists, keeping it" >&2
else
  printf '%s\n' "$err" >&2
  echo "provision-ntfy.sh: 'ntfy user add' failed" >&2
  exit 1
fi

ntfy access "$NTFYP_APP" "${NTFYP_PREFIX}-*" write-only >/dev/null
echo "provision-ntfy.sh: '$NTFYP_APP' may write to '${NTFYP_PREFIX}-*' (write-only)" >&2

# The token is only ever printed inside prose; match its shape (tk_ + 29
# chars) and, if nothing matches, show ntfy's output so a changed format is
# diagnosable instead of a bare "could not read a token".
out=$(ntfy token add "$NTFYP_APP" 2>&1)
tok=$(printf '%s\n' "$out" | grep -oE 'tk_[A-Za-z0-9]+' | head -n1)
if [ -z "$tok" ]; then
  echo "provision-ntfy.sh: no token (tk_...) in the output of 'ntfy token add'; it said:" >&2
  printf '%s\n' "$out" | sed 's/^/  /' >&2
  exit 1
fi
printf '%s\n' "$tok"
EOF2
