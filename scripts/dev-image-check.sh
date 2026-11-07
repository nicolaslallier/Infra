#!/usr/bin/env bash
# Smoke test for the dev-session image: the toolchains a session needs are
# there, it runs as a non-root user, and sudo is not installed.
# Usage: scripts/dev-image-check.sh [image]   (default devbox-session:1)
set -euo pipefail
img="${1:-devbox-session:1}"
fail=0
check() { # <label> <command...>
  if out="$(docker run --rm --entrypoint "" "$img" bash -lc "$2" 2>&1)"; then
    printf 'OK  %-10s %s\n' "$1" "$(head -1 <<<"$out")"
  else
    printf 'KO  %-10s %s\n' "$1" "$(tail -1 <<<"$out")"; fail=1
  fi
}
check node 'node --version'
check python 'python3 --version'
check rustc 'rustc --version'
check cargo 'cargo clippy --version'
check cc 'cc --version'
check pkgconf 'pkg-config --version && pkg-config --exists openssl'
check claude 'claude --version'
check gh 'gh --version'
check rclone 'rclone version'
check git 'git --version'
check sshd 'test -x /usr/sbin/sshd'
check non-root '[ "$(id -u)" != 0 ] && id -un'
check no-sudo '! command -v sudo'
exit "$fail"
