#!/usr/bin/env bash
# Session container entrypoint: keys, S3 sync, repo, plugins, then sshd on 2222.
set -euo pipefail
: "${SESSION:?}" "${REPO_URL:?}" "${SSH_PUBKEY:?}" "${S3_SECRET_KEY:?}"
# Volume dev-<session>-state (CLAUDE_CONFIG_DIR and GIT_CONFIG_GLOBAL point
# into it, see the Dockerfile): host key, Claude state, git identity.
STATE=/home/dev/.state

# Until sshd is up, a stop pushes NOTHING: the trees may be half restored.
# Long steps run in the background (bg) so that `wait` lets this trap fire.
child=
# shellcheck disable=SC2329 # invoked by the trap
early_term() { [ -z "$child" ] || kill "$child" 2>/dev/null || true; echo "stopped during startup: nothing pushed" >&2; exit 143; }
trap early_term TERM INT
bg() { "$@" & child=$!; wait "$child"; child=; }

mkdir -p ~/.ssh ~/.config/rclone "$CLAUDE_CONFIG_DIR"
chmod 700 ~/.ssh "$STATE"
printf '%s\n' "$SSH_PUBKEY" > ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
# On the state volume: the fingerprint survives a recreate. Never synced to S3.
[ -f "$STATE/ssh_host_ed25519_key" ] || ssh-keygen -q -t ed25519 -N '' -f "$STATE/ssh_host_ed25519_key"

cat > ~/.config/rclone/rclone.conf <<CONF
[devbox]
type = s3
provider = Other
endpoint = http://s3:8333
access_key_id = devbox
secret_access_key = $S3_SECRET_KEY
CONF
chmod 600 ~/.config/rclone/rclone.conf

# saved <work|claude>: what S3 holds under that prefix. An absent prefix is
# empty (rclone exits 0 or 3); any other error (S3 down) must stop here, or a
# fresh clone would later be pushed over saved work.
saved() {
  local rc=0 out
  out="$(rclone lsf --max-depth 1 "devbox:devbox/$SESSION/$1")" || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || { echo "S3 unreachable (rclone exit $rc)" >&2; exit 1; }
  printf '%s' "$out"
}
# Restore only into an EMPTY volume: S3 lags the volume by up to a sync
# interval, so restoring over an intact one would roll work back. A marker on
# the state volume, removed only once the restore succeeded, means "not
# restored yet" whatever the directory holds: the copy (idempotent, never
# deletes local files) runs again, and sync.sh refuses to push meanwhile.
# restore <work|claude> <dir>: sets nothing_saved when S3 had nothing. Never
# call it in a condition: that would switch off set -e inside it.
nothing_saved=
restore() {
  local m="$STATE/restoring-$1" s
  nothing_saved=
  if [ -e "$m" ]; then
    echo "resuming the interrupted restore of $2" >&2
  elif [ -z "$(ls -A "$2")" ]; then
    s="$(saved "$1")"
    [ -n "$s" ] || { nothing_saved=1; return 0; }
    : > "$m"
  else
    echo "$2 already holds data: not restored from S3" >&2
    return 0
  fi
  bg sync.sh restore "$1"
  rm -f "$m"
}
restore work /work
if [ -n "$nothing_saved" ]; then
  echo "cloning $REPO_URL" >&2
  bg gh repo clone "$REPO_URL" /work
fi
restore claude "$CLAUDE_CONFIG_DIR"

# A session deleted and recreated under its name with another repo must not
# carry on with the old one's /work.
norm() { local u="${1,,}"; u="${u%/}"; u="${u%.git}"; u="${u#https://}"; u="${u#git@}"; printf '%s' "${u/github.com:/github.com/}"; }
origin="$(git -C /work remote get-url origin 2>/dev/null || true)"
if [ "$(norm "$origin")" != "$(norm "$REPO_URL")" ]; then
  echo "/work's origin is '${origin:-none}', not $REPO_URL: refusing to start. Use another session name, or delete the volume dev-$SESSION-work. The S3 prefix devbox/$SESSION/work may hold the only good copy of that work: check it (rclone ls) before deleting anything there." >&2
  exit 1
fi

if [ -n "${GH_TOKEN:-}" ]; then
  # sessions over ssh do not see GH_TOKEN, so store it in gh's own config
  printf '%s' "$GH_TOKEN" | env -u GH_TOKEN gh auth login --with-token
  gh auth setup-git
fi

# MARKETPLACES: owner/repo catalogs; PLUGINS: plugin@marketplace. A failure is a warning.
IFS=',' read -ra markets <<< "${MARKETPLACES:-}"
for m in "${markets[@]}"; do
  [ -n "$m" ] || continue
  claude plugin marketplace add "$m" || echo "warning: marketplace $m failed" >&2
done
IFS=',' read -ra plugins <<< "${PLUGINS:-}"
for p in "${plugins[@]}"; do
  [ -n "$p" ] || continue
  claude plugin install "$p" || echo "warning: plugin $p failed to install" >&2
done

sync.sh loop & loop=$!
# sshd does not pass its own env to sessions: SetEnv carries PATH (cargo), the
# state locations and the proxy. Absolute path: sshd refuses to re-exec otherwise.
/usr/sbin/sshd -D -e -p 2222 -f /dev/null \
  -h "$STATE/ssh_host_ed25519_key" -o PidFile=none -o UsePAM=no \
  -o PasswordAuthentication=no -o AuthorizedKeysFile="$HOME/.ssh/authorized_keys" \
  -o "Subsystem sftp /usr/lib/openssh/sftp-server" \
  -o SetEnv="PATH=$PATH CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR GIT_CONFIG_GLOBAL=$GIT_CONFIG_GLOBAL HTTP_PROXY=${HTTP_PROXY:-} HTTPS_PROXY=${HTTPS_PROXY:-} http_proxy=${HTTP_PROXY:-} https_proxy=${HTTPS_PROXY:-}" &
sshd=$!

# shellcheck disable=SC2329 # invoked by the trap
term() { kill "$loop" "$sshd" 2>/dev/null || true; sync.sh push; exit 0; }
trap term TERM INT
wait "$sshd" || true # returns on TERM (the trap exits); if sshd itself dies, push and stop
echo "sshd exited" >&2
kill "$loop" 2>/dev/null || true
sync.sh push
exit 1
