#!/usr/bin/env bash
# `make test`: everything that can be checked without deploying the stack.
#
#   1. the flows' plain-assert tests (prefect/flows/test_*.py)
#   2. the pr-validation flow's own checks -- shellcheck, compose config,
#      nginx -t, promtool, JSON/YAML, check-env -- imported from
#      prefect/flows/pr_validation.py rather than copied, so this and the
#      nightly PR comment can never disagree
#   3. check-env.sh *rejecting* broken .env files, which nothing else covers:
#      every other run only ever shows it accepting a good one
#
# Runs against a throwaway copy of the working tree (tracked + untracked, not
# ignored), so the real .env, certs/ and seal key are never read or touched.
# Needs uv, openssl and a local Docker daemon. TEST_ONLY=unit skips 2 and 3.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# fastapi pinned to what the prefect-flows image ships: left floating, uv picks
# a newer one that prefect 3.8.7's server API no longer imports under.
PREFECT_PIN="prefect==3.8.7"
FASTAPI_PIN="fastapi==0.141.1"
# make exports DOCKER_HOST=ssh://<deploy host>; the throwaway workspace below
# lives on this machine, so only the local daemon can bind-mount it.
unset DOCKER_HOST

failures=()
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; failures+=("$1"); }

echo "== flow unit tests"
for t in prefect/flows/test_*.py; do
	if out="$(cd prefect/flows && uv run -q --no-project --python 3.12 --with "$PREFECT_PIN" --with "$FASTAPI_PIN" --with docker \
		python "$(basename "$t")" 2>&1)"; then
		pass "$t"
	else
		fail "$t" "$out"
	fi
done

if [ "${TEST_ONLY:-}" != "unit" ]; then
	# Under $TMPDIR, which Docker Desktop shares with its VM: the containerised
	# checks bind-mount this path, and the daemon resolves it, not us.
	ws="$(mktemp -d "${TMPDIR:-/tmp}/infra-test.XXXXXX")"
	trap 'rm -rf "$ws"' EXIT
	git ls-files -z --cached --others --exclude-standard | tar -cf - --null -T - | tar -xf - -C "$ws"
	if ! out="$(bash "$ws/scripts/ci-fake-env.sh" "$ws" 2>&1)"; then
		fail "ci-fake-env.sh" "$out"
	else
		echo "== pr-validation checks"
		# The driver prints its own ok/FAIL lines (multi-line logs included); any
		# non-zero exit, a crash part way through as much as a red check, fails it.
		if ! (cd prefect/flows && uv run -q --no-project --python 3.12 --with "$PREFECT_PIN" --with "$FASTAPI_PIN" --with docker --with pyyaml \
			python - "$ws" <<-'PY'
			import sys
			import pr_validation as pv

			ws, bad = sys.argv[1], False
			def report(name, code, log):
			    global bad
			    print(f"  {'ok  ' if code == 0 else 'FAIL'}  {name}")
			    if code:
			        bad = True
			        print("\n".join("        " + l for l in log.strip()[-3000:].splitlines()))
			for name, fn in (("check-env", pv._check_env_script), ("json/yaml", pv._check_json_yaml)):
			    report(name, *fn(ws))
			for c in pv._checks(ws):
			    report(c["name"], *pv._docker_run(c["image"], c["command"], c["volumes"],
			                                      c.get("working_dir"), entrypoint=c.get("entrypoint")))
			sys.exit(1 if bad else 0)
			PY
		); then
			failures+=("pr-validation checks")
		fi

		echo "== check-env rejects broken .env files"
		cp "$ws/.env" "$ws/.env.good"
		# expect_reject <name> <expected message fragment> <mutation run in $ws>
		expect_reject() {
			cp "$ws/.env.good" "$ws/.env"
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
		expect_reject "STS key not base64" "S3_STS_SIGNING_KEY" "set_env S3_STS_SIGNING_KEY not-base64"
		expect_reject "prefect auth without colon" "PREFECT_AUTH_STRING" "set_env PREFECT_AUTH_STRING nocolon"
		expect_reject "LAN_IP not on this host" "not an address on this host" "set_env LAN_IP 203.0.113.7"
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
