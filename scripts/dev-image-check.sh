#!/usr/bin/env bash
# Smoke test for devbox-session:1 (make dev-image): toolchain present, non-root, no sudo.
set -euo pipefail
IMG="${DEVBOX_IMAGE:-devbox-session:1}"
for c in "node --version" "python3 --version" "rustc --version" "cc --version" \
         "pkg-config --version" "claude --version" "gh --version" "rclone version"; do
  # shellcheck disable=SC2086
  docker run --rm --entrypoint ${c%% *} "$IMG" ${c#* } >/dev/null || { echo "FAIL: $c" >&2; exit 1; }
  echo "ok: $c"
done
uid="$(docker run --rm --entrypoint id "$IMG" -u)"
[ "$uid" != 0 ] || { echo "FAIL: runs as root" >&2; exit 1; }
echo "ok: uid $uid"
if docker run --rm --entrypoint sh "$IMG" -c 'command -v sudo' >/dev/null; then echo "FAIL: sudo present" >&2; exit 1; fi
echo "ok: no sudo"
