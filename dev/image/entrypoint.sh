#!/usr/bin/env bash
# Dev-session start: SSH keys, rclone, repo (restored from the bucket or
# cloned), GitHub auth and git identity, plugins, then sshd on :2222 with a
# background sync. SIGTERM pushes once more before exiting
# (stop_grace_period gives it the time).
set -euo pipefail
: "${SESSION:?}" "${REPO_URL:?}" "${GH_TOKEN:?}" "${SSH_PUBKEYS:?}" "${S3_ACCESS_KEY:?}" "${S3_SECRET_KEY:?}"
export GH_TOKEN

# PID 1 ignores SIGTERM unless it traps it, and a trap waits for the
# foreground command to finish -- so long steps run through `bg`, whose
# `wait` the trap does interrupt.
child='' sync_pid='' sshd_pid=''
bg() { "$@" & child=$!; wait "$child"; }
stop() {
  trap - TERM INT
  for p in $child $sshd_pid $sync_pid; do kill "$p" 2>/dev/null || true; done
  # Let claude (in tmux/SSH sessions) and an in-flight push finish writing.
  pkill -TERM -f 'claude-code/bin/claude' 2>/dev/null || true
  for _ in $(seq 20); do pgrep -f 'claude-code/bin/claude|^rclone' >/dev/null || break; sleep 0.5; done
  pkill -KILL -x rclone 2>/dev/null || true
  if [ -f "$STATE/ready" ]; then
    echo "final sync before stop"
    sync.sh push
  fi
  exit 0
}
trap stop TERM INT

# Every machine the owner connects from, comma-separated (a key has no comma).
install -m 600 /dev/null ~/.ssh/authorized_keys
tr ',' '\n' <<<"$SSH_PUBKEYS" > ~/.ssh/authorized_keys

mkdir -p ~/.config/rclone
cat > ~/.config/rclone/rclone.conf <<CONF
[s3]
type = s3
provider = SeaweedFS
endpoint = http://s3:8333
# The identity is scoped to devbox/$SESSION/* and may not look at the bucket.
no_check_bucket = true
access_key_id = $S3_ACCESS_KEY
secret_access_key = $S3_SECRET_KEY
CONF
chmod 600 ~/.config/rclone/rclone.conf

gh auth setup-git
if bg gh api user --jq '[.name // .login, "\(.id)+\(.login)@users.noreply.github.com"] | @tsv' > /tmp/ghuser; then
  IFS=$'\t' read -r gname gmail < /tmp/ghuser
  git config --global user.name "$gname"
  git config --global user.email "$gmail"
else
  echo "WARN: could not read the GitHub user; set git user.name/user.email by hand" >&2
fi

# $STATE/ready is written once /work and Claude's state are complete; until
# then sync.sh refuses to push. A start without it restores (or clones)
# again, so an interrupted restore is finished rather than pushed over.
if [ ! -f "$STATE/ready" ]; then
  # Into a file, not a test: an unreachable bucket must fail the start (the
  # container restarts and retries), not read as "nothing saved".
  bg rclone lsf --max-depth 1 "s3:devbox/$SESSION/" > /tmp/saved
  if [ -s /tmp/saved ]; then
    echo "restoring $SESSION from the bucket"
    bg sync.sh restore
  fi
  if [ ! -d /work/.git ]; then
    echo "cloning $REPO_URL"
    bg gh repo clone "$REPO_URL" /work
  fi
  touch "$STATE/ready"
fi

# A name reused for another repo would otherwise restore the old checkout and
# run it with a token for the new one.
norm() { sed -E 's#^(https?://|ssh://)?(git@)?##; s#:#/#; s#\.git/?$##; s#/$##' <<<"$1" | tr '[:upper:]' '[:lower:]'; }
origin="$(git -C /work remote get-url origin)"
if [ "$(norm "$origin")" != "$(norm "$REPO_URL")" ]; then
  echo "ERROR: /work is a checkout of $origin, but this session is for $REPO_URL." >&2
  echo "  The bucket keeps an older session of the same name: delete it with another name, or drop devbox/$SESSION/." >&2
  exit 1
fi

# Host key in the state volume: a recreated container (Portainer's stop and
# start recreate it) keeps the fingerprint clients trust.
[ -f "$STATE/ssh_host_ed25519_key" ] || ssh-keygen -q -t ed25519 -N '' -f "$STATE/ssh_host_ed25519_key"

# Marketplaces first (comma-separated GitHub repos), then plugin@marketplace.
# A plugin that fails to install is a warning: the session is still usable.
IFS=, read -ra markets <<<"${MARKETPLACES:-}"
for m in "${markets[@]}"; do
  [ -n "$m" ] && { bg claude plugin marketplace add "$m" || echo "WARN: marketplace $m not added" >&2; }
done
IFS=, read -ra plugins <<<"${PLUGINS:-}"
for p in "${plugins[@]}"; do
  [ -n "$p" ] && { bg claude plugin install "$p" || echo "WARN: plugin $p not installed" >&2; }
done

# Variables an SSH login should see (sshd does not pass the container env on).
env | grep -E '^(GH_TOKEN|SESSION|STATE|HTTPS?_PROXY|https?_proxy|NO_PROXY|no_proxy|CLAUDE_CONFIG_DIR|DISABLE_AUTOUPDATER|NPM_CONFIG_PREFIX|PATH)=' \
  > ~/.ssh/environment
chmod 600 ~/.ssh/environment

sync.sh loop &
sync_pid=$!

cat > ~/.ssh/sshd_config <<CONF
Port 2222
HostKey $STATE/ssh_host_ed25519_key
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
wait "$sshd_pid"
