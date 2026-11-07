#!/usr/bin/env bash
# Session container entrypoint: keys, S3 sync, repo, plugins, then sshd on 2222.
set -euo pipefail
: "${SESSION:?}" "${REPO_URL:?}" "${SSH_PUBKEY:?}" "${S3_SECRET_KEY:?}"

mkdir -p ~/.ssh ~/.config/rclone ~/.claude
chmod 700 ~/.ssh
printf '%s\n' "$SSH_PUBKEY" > ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
[ -f ~/.ssh/ssh_host_ed25519_key ] || ssh-keygen -q -t ed25519 -N '' -f ~/.ssh/ssh_host_ed25519_key

cat > ~/.config/rclone/rclone.conf <<CONF
[devbox]
type = s3
provider = Other
endpoint = http://s3:8333
access_key_id = devbox
secret_access_key = $S3_SECRET_KEY
CONF
chmod 600 ~/.config/rclone/rclone.conf

# lsf exits 0 with no output for an absent prefix; any error (S3 down, bucket
# missing) must stop here, or a fresh clone would later be pushed over saved work.
saved="$(rclone lsf --max-depth 1 "devbox:devbox/$SESSION/work")"
if [ -n "$saved" ]; then
  sync.sh restore
else
  gh repo clone "$REPO_URL" /work
fi

if [ -n "${GH_TOKEN:-}" ]; then
  # sessions over ssh do not see GH_TOKEN, so store it in gh's own config
  printf '%s' "$GH_TOKEN" | env -u GH_TOKEN gh auth login --with-token
  gh auth setup-git
fi

IFS=',' read -ra plugins <<< "${PLUGINS:-}"
for p in "${plugins[@]}"; do
  [ -n "$p" ] || continue
  claude plugin marketplace add "${p#*@}" && claude plugin install "$p" \
    || echo "warning: plugin $p failed to install" >&2
done

sync.sh loop & loop=$!
# Proxy settings reach ssh sessions via SetEnv (sshd does not pass its own env).
sshd -D -e -p 2222 -f /dev/null \
  -o HostKey="$HOME/.ssh/ssh_host_ed25519_key" -o PidFile=none -o UsePAM=no \
  -o PasswordAuthentication=no -o AuthorizedKeysFile="$HOME/.ssh/authorized_keys" \
  -o SetEnv="HTTP_PROXY=${HTTP_PROXY:-} HTTPS_PROXY=${HTTPS_PROXY:-} http_proxy=${HTTP_PROXY:-} https_proxy=${HTTPS_PROXY:-}" &
sshd=$!

term() { kill "$loop" "$sshd" 2>/dev/null || true; sync.sh push; exit 0; }
trap term TERM INT
wait "$sshd" # returns on TERM; if sshd itself dies the container stops
echo "sshd exited" >&2
kill "$loop" 2>/dev/null || true
sync.sh push
exit 1
