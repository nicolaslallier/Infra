#!/usr/bin/env bash
# sync.sh push|restore|loop -- mirror /work and ~/.claude to the S3 store.
# Layout: devbox:devbox/<SESSION>/{work,claude} (remote "devbox", bucket "devbox").
set -euo pipefail
: "${SESSION:?}"
R="devbox:devbox/$SESSION"
# --delete-excluded is deliberately absent: excluded dirs are never rebuilt remotely.
EXCL=(--exclude 'target/**' --exclude 'node_modules/**' --exclude '.venv/**')

case "${1:-}" in
  push)
    exec 9>/tmp/devbox-sync.lock; flock 9 # loop and SIGTERM push never overlap
    rclone sync /work "$R/work" "${EXCL[@]}"
    rclone sync "$HOME/.claude" "$R/claude" # includes .credentials.json
    ;;
  restore)
    rclone copy "$R/work" /work
    rclone copy "$R/claude" "$HOME/.claude"
    ;;
  loop)
    while sleep "${SYNC_INTERVAL:-60}"; do
      "$0" push || echo "sync: push failed, retrying in ${SYNC_INTERVAL:-60}s" >&2
    done
    ;;
  *) echo "usage: sync.sh push|restore|loop" >&2; exit 2 ;;
esac
