#!/usr/bin/env bash
# sync.sh push|restore|loop -- mirror /work and ~/.claude to the S3 store.
# Layout: devbox:devbox/<SESSION>/{work,claude} (remote "devbox", bucket "devbox").
set -euo pipefail
: "${SESSION:?}"
R="devbox:devbox/$SESSION"
# --delete-excluded is deliberately absent: excluded dirs are never rebuilt remotely.
# .git/hooks never travels: a restored hook would run on the next git command.
EXCL=(--exclude 'target/**' --exclude 'node_modules/**' --exclude '.venv/**' --exclude '.git/hooks/**')
# rclone exits 3 for an absent prefix (a new session): that means "nothing saved", not failure.
tolerant() { "$@" || [ $? -eq 3 ]; }

case "${1:-}" in
  push)
    exec 9>/tmp/devbox-sync.lock; flock 9 # loop and SIGTERM push never overlap
    rclone sync /work "$R/work" "${EXCL[@]}"
    rclone sync "$HOME/.claude" "$R/claude" # includes .credentials.json
    # ~/.claude.json sits outside ~/.claude
    if [ -f "$HOME/.claude.json" ]; then rclone copyto "$HOME/.claude.json" "$R/claude.json"; fi
    ;;
  restore)
    tolerant rclone copy "${EXCL[@]}" "$R/work" /work
    tolerant rclone copy "$R/claude" "$HOME/.claude"
    if [ -n "$(rclone lsf "$R/claude.json" 2>/dev/null)" ]; then rclone copyto "$R/claude.json" "$HOME/.claude.json"; fi
    ;;
  loop)
    while sleep "${SYNC_INTERVAL:-60}"; do
      "$0" push || echo "sync: push failed, retrying in ${SYNC_INTERVAL:-60}s" >&2
    done
    ;;
  *) echo "usage: sync.sh push|restore|loop" >&2; exit 2 ;;
esac
