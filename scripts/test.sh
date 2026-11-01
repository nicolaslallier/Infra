#!/usr/bin/env bash
# `make test`: everything that can be checked without deploying the stack.
#
#   1. the flows' plain-assert tests (prefect/flows/test_*.py)
#   2. the pr-validation flow's checks -- shellcheck, compose config, nginx -t,
#      promtool, JSON/YAML, check-env -- through the flow's own _run_all(), the
#      function its nightly run_checks calls, so the two run the same steps
#   3. check-env.sh *rejecting* broken .env files, which nothing else covers:
#      every other run only ever shows it accepting a good one
#
# Runs against a throwaway copy of the files git lists in the working tree
# (tracked + untracked, not ignored), so the real .env, certs/ and seal key are
# never read or touched. Needs uv, openssl and a running local Docker daemon.
# TEST_ONLY=unit skips 2 and 3 (it still needs the daemon once per prefect
# image, to read the image's fastapi version).
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
cache="${XDG_CACHE_HOME:-$HOME/.cache}/infra-test"
mkdir -p "$cache"

# The throwaway workspace below lives on this machine, so only the local daemon
# can bind-mount it. make exports DOCKER_HOST=ssh://<deploy host>, and a docker
# context can point there too -- and the CLI follows contexts while the Python
# SDK in _run_all only reads DOCKER_HOST. Pin both to the local endpoint.
unset DOCKER_HOST DOCKER_CONTEXT
local_host="$(docker context inspect desktop-linux --format '{{.Endpoints.docker.Host}}' 2>/dev/null)"
export DOCKER_HOST="${local_host:-unix:///var/run/docker.sock}"
if ! docker info >/dev/null 2>&1; then
	echo "test: no local Docker daemon at $DOCKER_HOST. Start Docker Desktop ('make docker-start') and re-run." >&2
	exit 2
fi

# Test the flows against what prefect-flows actually runs: prefect from the
# image tag Renovate bumps, fastapi from inside that image (cached per image
# ref, digest included, so the image is only started when the pin moves). Left
# floating, uv picks a newer fastapi that prefect's server API won't import under.
PREFECT_IMAGE="$(grep -m1 -oE 'prefecthq/prefect:[^"[:space:]]+' docker-compose.yml)"
PREFECT_VERSION="$(sed -E 's/^prefecthq\/prefect:([0-9.]+).*/\1/' <<<"$PREFECT_IMAGE")"
fastapi_cache="$cache/fastapi-$(tr -c 'A-Za-z0-9._-' '_' <<<"$PREFECT_IMAGE")"
if [ ! -s "$fastapi_cache" ]; then
	docker run --rm --entrypoint pip "$PREFECT_IMAGE" show fastapi 2>/dev/null | sed -n 's/^Version: //p' >"$fastapi_cache"
fi
FASTAPI_VERSION="$(cat "$fastapi_cache")"
if [ -z "$PREFECT_VERSION" ] || [ -z "$FASTAPI_VERSION" ]; then
	rm -f "$fastapi_cache"
	echo "test: could not read prefect/fastapi versions from '$PREFECT_IMAGE'" >&2
	exit 2
fi
uv_py() {
	(cd prefect/flows && uv run -q --no-project --python 3.12 \
		--with "prefect==$PREFECT_VERSION" --with "fastapi==$FASTAPI_VERSION" "$@")
}

failures=()
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; failures+=("$1"); }

echo "== flow unit tests (prefect $PREFECT_VERSION, fastapi $FASTAPI_VERSION)"
# One interpreter per file: test_backup patches the backup module in place, and
# a shared process would hand that patched module to every later file.
for t in prefect/flows/test_*.py; do
	if out="$(uv_py python "$(basename "$t")" 2>&1)"; then
		pass "$t"
	else
		fail "$t" "$out"
	fi
done

if [ "${TEST_ONLY:-}" != "unit" ]; then
	# Under $HOME, not $TMPDIR: the checks bind-mount this path and the daemon
	# resolves it, and $HOME is shared with the VM by Docker Desktop and Colima
	# alike (Colima does not share /var/folders).
	ws="$(mktemp -d "$cache/ws.XXXXXX")"
	trap 'rm -rf "$ws"' EXIT
	# Exactly the files git lists, nothing under them: --no-recursion, because
	# from the main checkout a nested worktree (.claude/worktrees/*) is listed
	# as one untracked directory, and tar would copy it whole -- its real .env
	# and seal key included. Paths deleted in the working tree are dropped
	# (--cached still lists them). pipefail makes any tar failure count.
	if ! git ls-files -z --cached --others --exclude-standard |
		while IFS= read -r -d '' f; do [ -f "$f" ] || [ -L "$f" ] && printf '%s\0' "$f"; done |
		tar -cf - --no-recursion --null -T - | tar -xf - -C "$ws"; then
		echo "test: could not copy the working tree into $ws" >&2
		exit 2
	fi

	echo "== pr-validation checks"
	# _run_all writes the throwaway .env / seal key / certs into $ws, which the
	# check-env cases below reuse, and its check-env step is their baseline:
	# .baseline-ok is left only when that step accepted the unmutated .env.
	if ! uv_py --with docker --with pyyaml python - "$ws" <<-'PY'
		import pathlib, sys
		import pr_validation as pv

		ws, bad = sys.argv[1], False
		for r in pv._run_all(ws):
		    print(f"  {'ok  ' if r['code'] == 0 else 'FAIL'}  {r['name']}")
		    if r["code"]:
		        bad = True
		        print("\n".join("        " + l for l in r["output"].strip()[-3000:].splitlines()))
		    elif r["name"] == "check-env":
		        pathlib.Path(ws, ".baseline-ok").touch()
		sys.exit(1 if bad else 0)
		PY
	then
		failures+=("pr-validation checks")
	fi

	echo "== check-env rejects broken .env files"
	if [ ! -f "$ws/.baseline-ok" ]; then
		# Already a failure above; every case would be rejected for that reason.
		echo "  skip  all cases: check-env did not accept the unmutated .env (see above)"
	else
		cp "$ws/.env" "$ws/.env.good"
		cp "$ws/openbao/seal.key" "$ws/seal.key.good"

		# expect_reject <name> <expected message fragment> <mutation run in $ws>
		expect_reject() {
			cp "$ws/.env.good" "$ws/.env"
			rm -rf "$ws/openbao/seal.key"
			cp "$ws/seal.key.good" "$ws/openbao/seal.key"
			(cd "$ws" && eval "$3")
			local out code
			out="$(SKIP_DOCKER_CHECK=1 bash "$ws/scripts/check-env.sh" 2>&1 </dev/null)"
			code=$?
			if [ "$code" -ne 0 ] && grep -qF -- "$2" <<<"$out"; then
				pass "$1"
			else
				fail "$1" "exit $code, wanted a non-zero exit mentioning '$2':"$'\n'"$out"
			fi
		}
		set_env() { sed -i.sed "s|^$1=.*|$1=$2|" .env && rm -f .env.sed; }

		expect_reject "missing key" "missing settings" "sed -i.sed '/^POSTGRES_PASSWORD=/d' .env && rm -f .env.sed"
		expect_reject "change-me placeholder" "placeholder" "set_env POSTGRES_PASSWORD change-me"
		expect_reject "empty password" "set but empty" "set_env POSTGRES_PASSWORD ''"
		expect_reject "standard-base64 cookie secret" "not base64url" \
			"set_env JARVIS_OAUTH_COOKIE_SECRET \"\$(printf '\\xfb\\xff%.0s' {1..16} | base64)\""
		expect_reject "short cookie secret" "byte cookie key" "set_env JARVIS_OAUTH_COOKIE_SECRET abc"
		expect_reject "STS key not base64" "is not padded standard base64" "set_env S3_STS_SIGNING_KEY not-base64"
		expect_reject "prefect auth without colon" "must be user:password" "set_env PREFECT_AUTH_STRING nocolon"
		# check-env passes LAN_IP by design where it cannot list addresses.
		if command -v ifconfig >/dev/null 2>&1 || command -v ip >/dev/null 2>&1; then
			expect_reject "LAN_IP not on this host" "not an address on this host" "set_env LAN_IP 203.0.113.7"
		else
			echo "  skip  LAN_IP not on this host (no ifconfig/ip here)"
		fi
		expect_reject "seal key missing" "seal.key is missing" "rm -f openbao/seal.key"
		expect_reject "seal key wrong size" "bytes; OpenBao" "head -c 16 /dev/urandom > openbao/seal.key"
		expect_reject "seal key is a directory" "is a directory" "rm -f openbao/seal.key && mkdir openbao/seal.key"
	fi
fi

echo
if [ "${#failures[@]}" -gt 0 ]; then
	echo "${#failures[@]} failed: ${failures[*]}"
	exit 1
fi
echo "all passed"
