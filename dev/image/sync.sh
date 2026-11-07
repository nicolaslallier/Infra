#!/usr/bin/env bash
# Copy a session's state to/from its prefix in the devbox bucket (rclone
# remote "s3", configured by entrypoint.sh): /work and $CLAUDE_CONFIG_DIR.
#   push     local -> bucket; refused until $STATE/ready exists
#   restore  bucket -> local (adds to what is there; never deletes)
#   loop     push every SYNC_INTERVAL seconds (default 60)
# Build outputs are not synced. No --delete-excluded, so an exclude added
# later never deletes what the bucket already holds.
set -euo pipefail
: "${SESSION:?}" "${STATE:?}" "${CLAUDE_CONFIG_DIR:?}"
dst="s3:devbox/$SESSION"
excludes=(--exclude 'target/**' --exclude 'node_modules/**' --exclude '.venv/**')
# -M keeps file modes (executable scripts), --links keeps symlinks: without
# them a restored checkout shows every script as a mode change.
flags=(-M --links)

push() {
  # A push is an `rclone sync`: it makes the bucket match local, deletions
  # included. Before the restore (or clone) has completed, local is partial,
  # and a push would delete the saved copy.
  [ -f "$STATE/ready" ] || { echo "sync: $STATE/ready missing, not pushing a partial state" >&2; return 1; }
  rclone sync "${flags[@]}" /work "$dst/work" "${excludes[@]}"
  rclone sync "${flags[@]}" "$CLAUDE_CONFIG_DIR" "$dst/claude"
}

case "${1:-}" in
  push) push ;;
  restore)
    saved="$(rclone lsf --max-depth 1 "$dst/")"
    if grep -qx 'work/' <<<"$saved"; then rclone copy "${flags[@]}" "$dst/work" /work; fi
    if grep -qx 'claude/' <<<"$saved"; then rclone copy "${flags[@]}" "$dst/claude" "$CLAUDE_CONFIG_DIR"; fi
    # S3 keeps no empty directories, and git refuses a .git without refs/
    # (empty after `git gc` packs them).
    if [ -d /work/.git ]; then
      mkdir -p /work/.git/refs/heads /work/.git/refs/tags /work/.git/objects/info /work/.git/objects/pack /work/.git/info
    fi
    ;;
  loop)
    while sleep "${SYNC_INTERVAL:-60}"; do push || echo "sync: push failed, retrying next round" >&2; done ;;
  *) echo "usage: sync.sh push|restore|loop" >&2; exit 2 ;;
esac
