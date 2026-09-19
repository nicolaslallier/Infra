#!/usr/bin/env bash
# Deploy the stack from CI. .github/workflows/deploy.yml runs this on the
# self-hosted runner after a push to main; `up` redeploys, `pull` redeploys
# re-pulling every image.
#
# The thing being deployed is NOT the runner's checkout. Portainer takes the
# compose file from GitHub main but every bind mount from the host checkout
# (CLAUDE.md "Portainer-managed stack"), so what has to be brought up to date
# is that directory -- INFRA_CHECKOUT -- and the throwaway tree
# actions/checkout wrote under the runner's _work only supplies this script.
# Confusing the two deploys the right compose against the wrong configs,
# which is the exact failure portainer-stack.sh's drift guard exists to stop.
#
# The work runs in a throwaway docker:*-cli container rather than on the
# runner itself, for the reason portainer-stack.sh runs curl in one: the
# runner image then carries no part of the deploy, and swapping or updating
# it cannot silently change what gets deployed. Everything the Makefile needs
# is installed into that container, never assumed to be there.
#
# Usage: scripts/ci-deploy.sh [up|pull]
#
# Environment:
#   INFRA_CHECKOUT  the host checkout Portainer bind-mounts from, as the
#                   *daemon* sees it (same value as PORTAINER_INFRA_DIR).
#   INFRA_HOST      the LAN address of the Docker host, for check-env.
set -euo pipefail

# Pinned: unlike the runner image, nothing upstream forces this one forward,
# and it is the toolchain the deploy actually runs on.
DEPLOY_IMAGE="${DEPLOY_IMAGE:-docker:28.5.2-cli}"

die() { printf 'ci-deploy.sh: %s\n' "$*" >&2; exit 1; }

cmd="${1:-up}"
case "$cmd" in
  up|pull) ;;
  *) die "usage: scripts/ci-deploy.sh [up|pull]" ;;
esac

: "${INFRA_CHECKOUT:?set INFRA_CHECKOUT to the host checkout as the daemon sees it}"
: "${INFRA_HOST:?set INFRA_HOST to the LAN address of the Docker host}"

# The compose project name is the working directory's basename, and the live
# stack's volumes are prefixed infra_. `make up` reaches the vault with
# `docker compose exec openbao` (scripts/vault-env.sh), which finds nothing
# under any other project name -- and CLAUDE.md already requires the main
# checkout to be named Infra for the same reason.
case "$INFRA_CHECKOUT" in
  */Infra) ;;
  *) die "INFRA_CHECKOUT=$INFRA_CHECKOUT must end in /Infra: its basename becomes the compose project name, and the live stack is 'infra'" ;;
esac

echo "ci-deploy.sh: make $cmd against $INFRA_CHECKOUT (daemon host $INFRA_HOST)"

# Mounted at *the same path* inside the container as outside it. That is what
# makes $PWD a path the daemon can also resolve, so portainer-stack.sh's
# ${PORTAINER_INFRA_DIR:-$PWD} is already the right bind-mount source for
# Portainer with nothing to translate -- the same identical-paths idiom
# airflow/dags/infra_pr_validation.py uses for its workspace, and for the
# same reason: a nested bind mount is resolved by the daemon, not by the
# container that asks for it.
#
# DOCKER_HOST is set to the socket rather than left unset, and that is
# load-bearing: check-env.sh verifies LAN_IP against the addresses of the
# machine it runs on unless a DOCKER_HOST says the daemon is elsewhere, and
# the addresses of this throwaway container are not the deploy host's. With
# it set, the check compares LAN_IP against INFRA_HOST instead -- which is
# the question actually worth asking, since that host is where the dns
# service's ports get published.
#
# SKIP_DOCKER_CHECK: check-docker.sh asserts Docker Desktop on macOS (disk
# image location, file sharing, VM sizing). None of it applies from in here,
# and AGENTS.md already documents this as its escape hatch.
exec docker run --rm \
  -v "$INFRA_CHECKOUT:$INFRA_CHECKOUT" \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -w "$INFRA_CHECKOUT" \
  -e DOCKER_HOST=unix:///var/run/docker.sock \
  -e INFRA_HOST="$INFRA_HOST" \
  -e SKIP_DOCKER_CHECK=1 \
  "$DEPLOY_IMAGE" sh -euc '
    # Install only what is missing, so a base image that already ships a
    # tool is not shadowed by a second copy of it.
    missing=""
    for t in bash make jq git; do
      command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
    done
    docker compose version >/dev/null 2>&1 || missing="$missing docker-cli-compose"
    [ -z "$missing" ] || apk add --no-cache $missing >/dev/null

    # Docker auto-creates a bind-mount source that does not exist, so a
    # wrong INFRA_CHECKOUT arrives as an empty directory rather than as an
    # error -- the trap ${INFRA_DIR} and the airflow workspace mount are both
    # documented against. Name it here instead of letting make fail on a
    # missing target.
    [ -f docker-compose.yml ] || {
      echo "ci-deploy.sh: $PWD holds no docker-compose.yml -- INFRA_CHECKOUT does not point at the host checkout (Docker mounted an empty directory in its place)." >&2
      exit 1
    }

    # The checkout is owned by another uid as far as this container is
    # concerned; without this, git refuses to touch it at all.
    git config --global --add safe.directory "$PWD"

    branch="$(git rev-parse --abbrev-ref HEAD)"
    [ "$branch" = main ] || {
      echo "ci-deploy.sh: the host checkout is on '"'"'$branch'"'"', not main -- Portainer deploys main." >&2
      exit 1
    }

    # Bring the host checkout to origin/main. Everything portainer-stack.sh
    # then refuses to deploy over -- a dirty tree, a checkout behind the
    # remote -- fails here or in its own drift guard, loudly, rather than
    # deploying main'"'"'s compose against yesterday'"'"'s configs.
    git fetch --quiet origin main
    git pull --quiet --ff-only

    echo "ci-deploy.sh: host checkout at $(git rev-parse --short HEAD)"
    exec make "$1"
  ' sh "$cmd"
