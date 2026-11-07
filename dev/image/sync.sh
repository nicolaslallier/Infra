#!/usr/bin/env bash
# Copy a session's state to/from the devbox bucket (rclone remote "s3",
# configured by entrypoint.sh): /work and ~/.claude (credentials included).
#   push     local -> bucket       restore  bucket -> local (only what is empty)
#   loop     push every SYNC_INTERVAL seconds (default 60)
# Build outputs and the session's SSH host key (.devbox/) are not synced; a restore rebuilds them. No --delete-excluded,
# so an exclude added later never deletes what the bucket already holds.
set -euo pipefail
: "${SESSION:?}"
dst="s3:devbox/$SESSION"
excludes=(--exclude 'target/**' --exclude 'node_modules/**' --exclude '.venv/**' --exclude '/.devbox/**')
# -M keeps file modes (executable scripts), --links keeps symlinks: without
# them a restored checkout shows every script as a mode change.
flags=(-M --links)

push() {
  rclone sync "${flags[@]}" /work "$dst/work" "${excludes[@]}"
  rclone sync "${flags[@]}" "$HOME/.claude" "$dst/claude"
}

case "${1:-}" in
  push) push ;;
  restore)
    # A local copy that already has content is newer than the bucket (the
    # last push happened at stop): never overwrite it.
    [ -n "$(ls -A /work)" ] || rclone copy "${flags[@]}" "$dst/work" /work
    [ -n "$(ls -A "$HOME/.claude")" ] || rclone copy "${flags[@]}" "$dst/claude" "$HOME/.claude"
    ;;
  loop)
    while sleep "${SYNC_INTERVAL:-60}"; do push || echo "sync: push failed, retrying next round" >&2; done ;;
  *) echo "usage: sync.sh push|restore|loop" >&2; exit 2 ;;
esac
