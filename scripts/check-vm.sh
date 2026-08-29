#!/usr/bin/env bash
# Reports whether the Colima VM this stack runs on is actually usable, not
# just alive. `colima status` says "running" for a VM that came up from a
# bare `colima start` with its config reset to defaults -- no host mount and
# no bridged LAN address -- which breaks the stack in two confusing ways
# (see "Runtime: Colima" in CLAUDE.md).
#
# Diagnostics go to stderr; the state is the exit code, so `make vm-start`
# can decide whether a restart is needed and `make check-vm` can decide
# whether to stop the build:
#
#   0  running, host mount present, bridged LAN address present
#   1  ~/.colima/_lima does not resolve (external volume unmounted)
#   2  not running
#   3  running, but the host mount is missing
#   4  running with the host mount, but no bridged LAN address
set -uo pipefail

REPO_DIR="${1:-$PWD}"

say() { printf '%s\n' "$@" >&2; }

if [ ! -d "$HOME/.colima/_lima" ]; then
	say "colima: $HOME/.colima/_lima does not resolve." \
	    "  The VM's disks live on an external volume (see 'Runtime: Colima'" \
	    "  in CLAUDE.md). Mount it, then retry."
	exit 1
fi

if ! colima status >/dev/null 2>&1; then
	say "colima: the VM is not running."
	exit 2
fi

if ! colima ssh -- test -f "$REPO_DIR/docker-compose.yml" >/dev/null 2>&1; then
	say "colima: the VM cannot see $REPO_DIR." \
	    "  Every bind mount in docker-compose.yml is resolved inside the VM, so a" \
	    "  VM with no host mount fails on the first file mount with a confusing" \
	    "  OCI 'not a directory' error -- and silently starts the services whose" \
	    "  mounts are directories with empty config instead." \
	    "  A bare 'colima start' -- including the one 'brew services' runs at" \
	    "  login -- drops the host mount along with the CPU/memory sizing and the" \
	    "  bridged LAN address."
	exit 3
fi

if ! colima list 2>/dev/null |
	awk 'NR > 1 && $2 == "Running" { print $NF }' |
	grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
	say "colima: the VM has no bridged LAN address." \
	    "  The stack still comes up, but the dns service cannot answer other LAN" \
	    "  devices -- see 'Bridged networking is mandatory' in CLAUDE.md."
	exit 4
fi

exit 0
