#!/usr/bin/env bash
# Reports whether the Docker Desktop VM this stack runs on is actually
# usable, not just alive. Docker Desktop can be running and still be the
# wrong daemon (a leftover `colima` context wins over it silently), be sized
# too small for the stack, or be storing its disk image on the internal SSD
# -- none of which announce themselves (see "Runtime: Docker Desktop" in
# CLAUDE.md).
#
# The disk-image location is checked first, before the daemon, because it is
# pure filesystem state: when the external volume is unmounted the answer is
# "do not start Docker Desktop at all", not "start it and see".
#
# Diagnostics go to stderr; the state is the exit code, so `make docker-start`
# can decide whether to launch the app and `make check-docker` can decide
# whether to stop the build:
#
#   0  running, correctly targeted, repo is bind-mountable, sized right
#   1  the disk image location does not resolve (external volume unmounted)
#   2  no docker CLI, or no reachable daemon (Docker Desktop is not running)
#   3  a daemon answers, but it is not Docker Desktop
#   4  running, but this repo is outside Docker Desktop's shared directories
#   5  usable, but under-sized or storing its disk image on the internal SSD
set -uo pipefail

REPO_DIR="${1:-$PWD}"

# Escape hatch for the environments this stack is also run in that are not a
# Mac with Docker Desktop -- CI, a cloud dev VM, a plain Linux dockerd. Every
# check below is macOS/Docker-Desktop specific, so there is nothing useful to
# assert there; the compose stack itself is portable.
if [ -n "${SKIP_DOCKER_CHECK:-}" ]; then
	printf '%s\n' "docker: SKIP_DOCKER_CHECK set, skipping the Docker Desktop preflight." >&2
	exit 0
fi

# Docker Desktop's own defaults. Settings -> Resources -> File sharing.
SHARED_ROOTS=(/Users /Volumes /private /tmp)

say() { printf '%s\n' "$@" >&2; }

# The host-side folder holding the VM's disk image. Docker Desktop stores it
# under ~/Library/Containers by default; "Disk image location" in Settings ->
# Resources -> Advanced writes a "dataFolder" key instead, and this machine
# has historically pointed either that key or a symlink at /Volumes/Docker.
dd_data_folder() {
	local f
	for f in "$HOME/Library/Group Containers/group.com.docker/settings-store.json" \
	         "$HOME/Library/Group Containers/group.com.docker/settings.json"; do
		[ -f "$f" ] || continue
		sed -n 's/.*"[dD]ataFolder"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -1
		return
	done
}

data_folder="$(dd_data_folder)"
default_data="$HOME/Library/Containers/com.docker.docker/Data"

if [ -n "$data_folder" ] && [ ! -d "$data_folder" ]; then
	say "docker: Docker Desktop's disk image location '$data_folder' does not resolve." \
	    "  The VM's disk lives on an external volume (see 'Runtime: Docker Desktop'" \
	    "  in CLAUDE.md). Mount it before starting Docker Desktop -- started without" \
	    "  it, Docker Desktop builds a fresh empty VM on the internal SSD."
	exit 1
fi

if [ -z "$data_folder" ] && [ -L "$default_data" ] && [ ! -d "$default_data" ]; then
	say "docker: $default_data is a symlink that does not resolve." \
	    "  It points at the external volume holding the VM's disk image (see" \
	    "  'Runtime: Docker Desktop' in CLAUDE.md). Mount it, then retry."
	exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
	say "docker: the docker CLI is not on PATH." \
	    "  Install Docker Desktop (https://docs.docker.com/desktop/setup/install/mac-install/)."
	exit 2
fi

info="$(docker info --format '{{.Name}}|{{.OperatingSystem}}|{{.MemTotal}}|{{.NCPU}}' 2>/dev/null)"
if [ -z "$info" ]; then
	say "docker: no reachable daemon." \
	    "  Docker Desktop is not running (or is still starting). Launch it with" \
	    "  'make docker-start', or open Docker.app."
	exit 2
fi

IFS='|' read -r dd_name dd_os dd_mem dd_cpu <<<"$info"

# Under Docker Desktop these are "docker-desktop" / "Docker Desktop"; under
# Colima they are "colima" / "Alpine Linux v3.x". A leftover DOCKER_CONTEXT,
# DOCKER_HOST, or `docker context use colima` is the whole reason this check
# exists -- the stack would come up against the old VM, on the old volumes,
# and look completely fine.
case "$dd_name$dd_os" in
	*[Dd]ocker?[Dd]esktop*|docker-desktop*) ;;
	*)
		say "docker: the active daemon is not Docker Desktop (reports '$dd_name' / '$dd_os')." \
		    "  Current context: $(docker context show 2>/dev/null || echo unknown)" \
		    "  This stack was migrated to Docker Desktop; bringing it up against" \
		    "  another daemon starts a second copy on that daemon's own volumes." \
		    "  Fix with 'docker context use desktop-linux', and unset DOCKER_HOST/" \
		    "  DOCKER_CONTEXT if either is set."
		exit 3
		;;
esac

# Bind mounts under a directory Docker Desktop does not share resolve to an
# empty auto-created directory inside the VM instead of failing loudly: the
# services mounting a single file (loki, tempo, prometheus, alloy, nginx,
# oauth2-proxy, rabbitmq) then die with a confusing OCI "not a directory"
# error, while the ones mounting a directory (grafana provisioning, postgres
# initdb, keycloak realm-import) start successfully against empty config.
repo_shared=""
for root in "${SHARED_ROOTS[@]}"; do
	case "$REPO_DIR/" in
		"$root"/*) repo_shared=1; break ;;
	esac
done

if [ -z "$repo_shared" ]; then
	say "docker: $REPO_DIR is outside Docker Desktop's shared directories." \
	    "  Every bind mount in docker-compose.yml is resolved inside the VM, and a" \
	    "  path Docker Desktop does not share comes back as an empty auto-created" \
	    "  directory -- half the stack dies on 'not a directory', the other half" \
	    "  starts against empty config." \
	    "  Add it under Settings -> Resources -> File sharing, or move the repo" \
	    "  under one of: ${SHARED_ROOTS[*]}"
	exit 4
fi

# Warnings only past this point.
warned=""

# The stack needs roughly 6 CPU / 12 GB; Docker Desktop's own defaults are
# smaller, and a reinstall or a "Reset to factory defaults" puts them back.
if [ "${dd_mem:-0}" -lt $((11 * 1024 * 1024 * 1024)) ] 2>/dev/null; then
	say "docker: the VM has only $((dd_mem / 1024 / 1024 / 1024)) GB of memory." \
	    "  Keycloak's JVM, Postgres, the LGTM stack, MinIO and RabbitMQ together" \
	    "  need ~12 GB. Raise it in Settings -> Resources."
	warned=1
fi

if [ "${dd_cpu:-0}" -lt 4 ] 2>/dev/null; then
	say "docker: the VM has only $dd_cpu CPUs (this stack is sized for 6)." \
	    "  Raise it in Settings -> Resources."
	warned=1
fi

if [ -z "$data_folder" ] && [ ! -L "$default_data" ]; then
	say "docker: Docker Desktop is storing its disk image on the internal SSD." \
	    "  This Mac has under 90 GB free there and the image grows to the VM's" \
	    "  full disk size. Point Settings -> Resources -> Advanced -> 'Disk image" \
	    "  location' at the external volume (see CLAUDE.md)."
	warned=1
fi

[ -n "$warned" ] && exit 5
exit 0
