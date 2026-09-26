#!/usr/bin/env bash
# Copies this stack's named volumes from one Docker daemon to another --
# specifically, from the Colima VM this stack used to run on to Docker
# Desktop. Named volumes live inside the daemon's own VM, so switching
# contexts does NOT bring them along: without this, Docker Desktop starts
# the stack on empty volumes and you get a brand-new Postgres cluster (no
# app databases, no Keycloak realms, no Grafana state), an empty object store, and
# a fresh RabbitMQ.
#
# Nothing is deleted or modified on the source daemon; each volume is
# streamed through tar into the matching volume on the target. Re-runnable:
# a volume that already holds data on the target is skipped unless --force.
#
#   ./scripts/migrate-volumes.sh --dry-run     # list what would be copied
#   ./scripts/migrate-volumes.sh               # copy colima -> desktop-linux
set -euo pipefail

FROM_CTX="colima"
TO_CTX="desktop-linux"
PROJECT=""
FORCE=""
DRY_RUN=""
# Helper container that does the tar on both ends. Pinned so the two sides
# never disagree about tar's behaviour.
HELPER_IMAGE="alpine:3.22"

usage() {
	cat >&2 <<EOF
usage: $0 [--from CONTEXT] [--to CONTEXT] [--project NAME] [--force] [--dry-run]

  --from CONTEXT   docker context to read volumes from (default: $FROM_CTX)
  --to CONTEXT     docker context to write volumes to   (default: $TO_CTX)
  --project NAME   compose project name (default: this directory's name)
  --force          overwrite target volumes that already hold data
  --dry-run        list what would be copied, copy nothing
EOF
	exit 2
}

while [ $# -gt 0 ]; do
	case "$1" in
		--from) FROM_CTX="${2:?--from needs a context}"; shift 2 ;;
		--to) TO_CTX="${2:?--to needs a context}"; shift 2 ;;
		--project) PROJECT="${2:?--project needs a name}"; shift 2 ;;
		--force) FORCE=1; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h|--help) usage ;;
		*) echo "$0: unknown argument '$1'" >&2; usage ;;
	esac
done

die() { printf '%s\n' "$@" >&2; exit 1; }

# Compose derives the default project name from the directory name, lowercased
# with anything outside [a-z0-9_-] dropped.
if [ -z "$PROJECT" ]; then
	PROJECT="$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
fi

for ctx in "$FROM_CTX" "$TO_CTX"; do
	docker context inspect "$ctx" >/dev/null 2>&1 ||
		die "migrate-volumes: no docker context named '$ctx'." \
		    "  Available: $(docker context ls --format '{{.Name}}' | tr '\n' ' ')"
	docker --context "$ctx" info >/dev/null 2>&1 ||
		die "migrate-volumes: the '$ctx' daemon is not reachable." \
		    "  Start it first (Colima: 'colima start'; Docker Desktop: 'make docker-start')."
done

[ "$FROM_CTX" = "$TO_CTX" ] && die "migrate-volumes: --from and --to are both '$FROM_CTX'."

# Copying a live Postgres data directory produces a corrupt cluster, and the
# same goes for every other service holding files open. Both ends must be idle.
for ctx in "$FROM_CTX" "$TO_CTX"; do
	running="$(docker --context "$ctx" ps -q \
		--filter "label=com.docker.compose.project=$PROJECT" | wc -l | tr -d ' ')"
	[ "$running" = "0" ] ||
		die "migrate-volumes: $running '$PROJECT' container(s) still running on '$ctx'." \
		    "  Copying a volume out from under a running Postgres/SeaweedFS/RabbitMQ" \
		    "  corrupts it. Stop the stack there first:" \
		    "    docker --context $ctx compose down"
done

# Compose labels the volumes it creates; fall back to the name prefix for
# volumes created before that label existed, or by hand.
mapfile -t volumes < <(docker --context "$FROM_CTX" volume ls \
	--filter "label=com.docker.compose.project=$PROJECT" --format '{{.Name}}' | sort)

if [ "${#volumes[@]}" -eq 0 ]; then
	mapfile -t volumes < <(docker --context "$FROM_CTX" volume ls \
		--format '{{.Name}}' | grep "^${PROJECT}_" | sort || true)
fi

[ "${#volumes[@]}" -eq 0 ] &&
	die "migrate-volumes: no volumes for project '$PROJECT' on '$FROM_CTX'." \
	    "  Pass --project if the stack ran under a different compose project name" \
	    "  ('docker --context $FROM_CTX volume ls' shows what is there)."

echo "migrate-volumes: $FROM_CTX -> $TO_CTX, project '$PROJECT', ${#volumes[@]} volume(s):"
printf '  %s\n' "${volumes[@]}"
echo

if [ -n "$DRY_RUN" ]; then
	echo "migrate-volumes: --dry-run, nothing copied."
	exit 0
fi

for ctx in "$FROM_CTX" "$TO_CTX"; do
	docker --context "$ctx" image inspect "$HELPER_IMAGE" >/dev/null 2>&1 ||
		docker --context "$ctx" pull -q "$HELPER_IMAGE" >/dev/null
done

copied=0
skipped=0

for vol in "${volumes[@]}"; do
	# 'docker run -v' creates the target volume if it is missing, so this
	# doubles as the "does it already hold data" probe.
	existing="$(docker --context "$TO_CTX" run --rm -v "$vol:/data" "$HELPER_IMAGE" \
		sh -c 'ls -A /data 2>/dev/null | head -1')"

	if [ -n "$existing" ] && [ -z "$FORCE" ]; then
		echo "  skip  $vol (already holds data on $TO_CTX; --force to overwrite)"
		skipped=$((skipped + 1))
		continue
	fi

	if [ -n "$existing" ]; then
		echo "  wipe  $vol (--force)"
		docker --context "$TO_CTX" run --rm -v "$vol:/data" "$HELPER_IMAGE" \
			sh -c 'rm -rf /data/..?* /data/.[!.]* /data/*' 2>/dev/null || true
	fi

	printf '  copy  %s ... ' "$vol"
	# --numeric-owner: uids matter (Postgres data is owned by uid 999 inside
	# its image), and the two helper containers do not share a passwd file.
	docker --context "$FROM_CTX" run --rm -v "$vol:/data:ro" "$HELPER_IMAGE" \
		tar -C /data --numeric-owner -cf - . |
	docker --context "$TO_CTX" run --rm -i -v "$vol:/data" "$HELPER_IMAGE" \
		tar -C /data --numeric-owner -xf -
	echo "done"
	copied=$((copied + 1))
done

echo
echo "migrate-volumes: $copied copied, $skipped skipped. Nothing on '$FROM_CTX' was changed."
echo "Next: 'docker context use $TO_CTX', then 'make up'."
