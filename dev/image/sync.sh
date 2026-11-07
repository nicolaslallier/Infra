#!/usr/bin/env bash
# sync.sh push [work|all] | restore work|claude | loop -- mirror /work and the
# Claude state ($CLAUDE_CONFIG_DIR, which holds .claude.json too) to the S3 store.
# Layout: devbox:devbox/<SESSION>/{work,claude} (remote "devbox", bucket "devbox").
set -euo pipefail
: "${SESSION:?}" "${CLAUDE_CONFIG_DIR:?}"
R="devbox:devbox/$SESSION"
# --delete-excluded is deliberately absent: excluded dirs are never rebuilt remotely.
# .git/hooks never travels: a restored hook would run on the next git command.
EXCL=(--exclude 'target/**' --exclude 'node_modules/**' --exclude '.venv/**' --exclude '.git/hooks/**')
# rclone exits 3 for an absent prefix (a new session): that means "nothing saved", not failure.
tolerant() { "$@" || [ $? -eq 3 ]; }
usage() { echo "usage: sync.sh push [work|all] | restore work|claude | loop" >&2; exit 2; }

case "${1:-}" in
  push)
    exec 9>/tmp/devbox-sync.lock; flock 9 # loop and SIGTERM push never overlap
    # Both halves are attempted even if one fails; the exit status reports it.
    rc=0
    rclone sync /work "$R/work" "${EXCL[@]}" || rc=$?
    case "${2:-all}" in
      all) rclone sync "$CLAUDE_CONFIG_DIR" "$R/claude" || rc=$? ;; # includes .credentials.json
      work) ;;
      *) usage ;;
    esac
    exit "$rc"
    ;;
  restore)
    case "${2:-}" in
      work) tolerant rclone copy "${EXCL[@]}" "$R/work" /work ;;
      claude) tolerant rclone copy "$R/claude" "$CLAUDE_CONFIG_DIR" ;;
      *) usage ;;
    esac
    ;;
  loop)
    # /work every SYNC_INTERVAL; the Claude state (transcripts, into a
    # versioned bucket) only every CLAUDE_SYNC_INTERVAL, and always on stop.
    last=$(date +%s)
    while sleep "${SYNC_INTERVAL:-60}"; do
      what=work
      [ $(( $(date +%s) - last )) -lt "${CLAUDE_SYNC_INTERVAL:-600}" ] || what=all
      if "$0" push "$what"; then
        [ "$what" = work ] || last=$(date +%s)
      else
        echo "sync: push failed, retrying in ${SYNC_INTERVAL:-60}s" >&2
      fi
    done
    ;;
  *) usage ;;
esac
