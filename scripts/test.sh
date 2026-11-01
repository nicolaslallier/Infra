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
# Runs against a throwaway copy of the working tree (tracked + untracked, not
# ignored), so the real .env, certs/ and seal key are never read or touched.
# Needs uv, openssl and a running local Docker daemon. TEST_ONLY=unit skips 2
# and 3 (it still needs the daemon, to read the prefect image's versions).
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# make exports DOCKER_HOST=ssh://<deploy host>; the throwaway workspace below
# lives on this machine, so only the local daemon can bind-mount it.
unset DOCKER_HOST
if ! docker info >/dev/null 2>&1; then
	echo "test: no local Docker daemon. Start Docker Desktop ('make docker-start') and re-run." >&2
	exit 2
fi

# Test the flows against what prefect-flows actually runs: prefect from the
# image tag Renovate bumps, fastapi from inside that image. Left floating, uv
# picks a newer fastapi that prefect's server API no longer imports under.
PREFECT_IMAGE="$(grep -m1 -oE 'prefecthq/prefect:[^"[:space:]]+' docker-compose.yml)"
PREFECT_VERSION="$(sed -E 's/^prefecthq\/prefect:([0-9.]+).*/\1/' <<<"$PREFECT_IMAGE")"
FASTAPI_VERSION="$(docker run --rm --entrypoint pip "$PREFECT_IMAGE" show fastapi 2>/dev/null | sed -n 's/^Version: //p')"
if [ -z "$PREFECT_VERSION" ] || [ -z "$FASTAPI_VERSION" ]; then
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
# One interpreter for every file: each runs as __main__, as it would by hand.
tests=(prefect/flows/test_*.py)
if ! uv_py python - "${tests[@]#prefect/flows/}" <<-'PY'
	import runpy, sys, traceback

	bad = False
	for path in sys.argv[1:]:
	    try:
	        runpy.run_path(path, run_name="__main__")
	        print(f"  ok    {path}")
	    except BaseException:  # SystemExit included: a test file that exits non-zero failed
	        bad = True
	        print(f"  FAIL  {path}")
	        print("\n".join("        " + l for l in traceback.format_exc().splitlines()))
	sys.exit(1 if bad else 0)
	PY
then
	failures+=("flow unit tests")
fi

if [ "${TEST_ONLY:-}" != "unit" ]; then
	# Under $TMPDIR, which Docker Desktop shares with its VM: the containerised
	# checks bind-mount this path, and the daemon resolves it, not us.
	ws="$(mktemp -d "${TMPDIR:-/tmp}/infra-test.XXXXXX")"
	trap 'rm -rf "$ws"' EXIT
	# Only paths that exist: --cached still lists a file deleted in the working
	# tree, and tar would fail on it. pipefail makes any tar failure count.
	if ! git ls-files -z --cached --others --exclude-standard |
		while IFS= read -r -d '' f; do { [ -e "$f" ] || [ -L "$f" ]; } && printf '%s\0' "$f"; done |
		tar -cf - --null -T - | tar -xf - -C "$ws"; then
		echo "test: could not copy the working tree into $ws" >&2
		exit 2
	fi

	echo "== pr-validation checks"
	# _run_all writes the throwaway .env / seal key / certs into $ws, which the
	# check-env cases below reuse.
	if ! uv_py --with docker --with pyyaml python - "$ws" <<-'PY'
		import sys
		import pr_validation as pv

		bad = False
		for r in pv._run_all(sys.argv[1]):
		    print(f"  {'ok  ' if r['code'] == 0 else 'FAIL'}  {r['name']}")
		    if r["code"]:
		        bad = True
		        print("\n".join("        " + l for l in r["output"].strip()[-3000:].splitlines()))
		sys.exit(1 if bad else 0)
		PY
	then
		failures+=("pr-validation checks")
	fi

	echo "== check-env rejects broken .env files"
	run_check_env() { SKIP_DOCKER_CHECK=1 bash "$ws/scripts/check-env.sh" 2>&1 </dev/null; }
	if [ ! -f "$ws/.env" ] || [ ! -f "$ws/openbao/seal.key" ]; then
		fail "baseline" "ci-fake-env.sh wrote no .env / seal key (see 'prepare workspace' above)"
	elif ! out="$(run_check_env)"; then
		# Every case below must be rejected for its own reason, not this one.
		fail "baseline .env accepted" "$out"
	else
		pass "baseline .env accepted"
		cp "$ws/.env" "$ws/.env.good"
		cp "$ws/openbao/seal.key" "$ws/seal.key.good"

		# expect_reject <name> <expected message fragment> <mutation run in $ws>
		expect_reject() {
			cp "$ws/.env.good" "$ws/.env"
			rm -rf "$ws/openbao/seal.key"
			cp "$ws/seal.key.good" "$ws/openbao/seal.key"
			(cd "$ws" && eval "$3")
			local out code
			out="$(run_check_env)"
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
		expect_reject "STS key not base64" "S3_STS_SIGNING_KEY" "set_env S3_STS_SIGNING_KEY not-base64"
		expect_reject "prefect auth without colon" "PREFECT_AUTH_STRING" "set_env PREFECT_AUTH_STRING nocolon"
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
