#!/usr/bin/env bash
# Dev-session start: SSH key, rclone, repo (restored or cloned), GitHub auth,
# plugins, then sshd on :2222 with a background sync. SIGTERM pushes once
# more before exiting (stop_grace_period gives it the time).
set -euo pipefail
: "${SESSION:?}" "${REPO_URL:?}" "${GH_TOKEN:?}" "${SSH_PUBKEY:?}" "${S3_SECRET_KEY:?}"
export GH_TOKEN

install -m 600 /dev/null ~/.ssh/authorized_keys
printf '%s\n' "$SSH_PUBKEY" > ~/.ssh/authorized_keys

mkdir -p ~/.config/rclone
cat > ~/.config/rclone/rclone.conf <<CONF
[s3]
type = s3
provider = SeaweedFS
endpoint = http://s3:8333
access_key_id = devbox
secret_access_key = $S3_SECRET_KEY
CONF
chmod 600 ~/.config/rclone/rclone.conf

gh auth setup-git
# Listed into a variable so that an unreachable bucket fails the start (set -e;
# the container restarts and tries again) instead of reading as "empty": a
# fresh clone would then be pushed over the saved work 60 s later.
saved="$(rclone lsf --max-depth 1 "s3:devbox/$SESSION/")"
if [ -n "$saved" ]; then
  echo "restoring $SESSION from the bucket"
  sync.sh restore
fi
if [ ! -d /work/.git ]; then
  echo "cloning $REPO_URL"
  gh repo clone "$REPO_URL" /work
fi

# Host key on the /work volume, so a recreated container (Portainer's stop
# and start recreate it) keeps the fingerprint clients trust. Not synced to
# the shared bucket (sync.sh), and kept out of git.
mkdir -p /work/.devbox
[ -f /work/.devbox/ssh_host_ed25519_key ] || ssh-keygen -q -t ed25519 -N '' -f /work/.devbox/ssh_host_ed25519_key
grep -qx '/.devbox/' /work/.git/info/exclude 2>/dev/null || echo '/.devbox/' >> /work/.git/info/exclude

# Marketplaces first (comma-separated GitHub repos), then plugin@marketplace.
# A plugin that fails to install is a warning: the session is still usable.
IFS=, read -ra markets <<<"${MARKETPLACES:-}"
for m in "${markets[@]}"; do
  [ -n "$m" ] && { claude plugin marketplace add "$m" || echo "WARN: marketplace $m not added" >&2; }
done
IFS=, read -ra plugins <<<"${PLUGINS:-}"
for p in "${plugins[@]}"; do
  [ -n "$p" ] && { claude plugin install "$p" || echo "WARN: plugin $p not installed" >&2; }
done

# Variables an SSH login should see (sshd does not pass the container env on).
env | grep -E '^(GH_TOKEN|SESSION|HTTPS?_PROXY|https?_proxy|NO_PROXY|no_proxy|CLAUDE_CONFIG_DIR|PATH)=' \
  > ~/.ssh/environment
chmod 600 ~/.ssh/environment

sync.sh loop &
sync_pid=$!

cat > ~/.ssh/sshd_config <<CONF
Port 2222
HostKey /work/.devbox/ssh_host_ed25519_key
AuthorizedKeysFile $HOME/.ssh/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
PermitUserEnvironment yes
# No agent/TCP/X11 forwarding: a forwarded agent would let the session push
# with the owner's SSH key, past the one-repo token.
DisableForwarding yes
PidFile none
Subsystem sftp internal-sftp
CONF
/usr/sbin/sshd -D -e -f ~/.ssh/sshd_config &
sshd_pid=$!

stop() {
  kill "$sync_pid" "$sshd_pid" 2>/dev/null || true
  echo "final sync before stop"
  sync.sh push
  exit 0
}
trap stop TERM INT
wait "$sshd_pid"
