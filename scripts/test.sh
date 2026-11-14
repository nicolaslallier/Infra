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
PREFECT_IMAGE="$(grep -m1 -oE 'prefecthq/prefect:[^"[:space:]]+' docker-compose.platform.yml)"
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

	echo "== runners compose"
	# ci-fake-env.sh (run by _run_all above) wrote a six-token .runner.env into $ws.
	rc() { (cd "$ws" && docker compose -f docker-compose.runners.yml --env-file "$1" "${@:2}" 2>&1); }
	if cfg="$(rc .runner.env config --format json)"; then
		names="$(jq -r '.services | keys | join(",")' <<<"$cfg")"
		if [ "$names" = "runner-ai,runner-darkangel,runner-ea,runner-heaven,runner-infra,runner-moria" ]; then
			pass "six runner-<name> services"
		else
			fail "six runner-<name> services" "got: $names"
		fi
		for n in ai darkangel ea heaven infra moria; do
			if jq -e --arg n "$n" '.services["runner-"+$n].environment | .LABELS == $n and .EPHEMERAL == "true" and .DISABLE_AUTO_UPDATE == "true"' <<<"$cfg" >/dev/null; then
				pass "runner-$n label, EPHEMERAL, no self-update"
			else
				fail "runner-$n label, EPHEMERAL, no self-update"
			fi
		done
		socks="$(jq -r '[.services | to_entries[] | select(any(.value.volumes[]?; .source == "/var/run/docker.sock")) | .key] | sort | join(",")' <<<"$cfg")"
		if [ "$socks" = "runner-darkangel,runner-heaven,runner-infra" ]; then
			pass "docker socket only on darkangel, heaven, infra"
		else
			fail "docker socket only on darkangel, heaven, infra" "got: $socks"
		fi
		if jq -e '.services["runner-ai"] | .environment.RUN_AS_ROOT == "false" and (.security_opt | index("no-new-privileges:true")) and (.volumes | all(.source != "/var/run/docker.sock" and .type != "volume"))' <<<"$cfg" >/dev/null; then
			pass "runner-ai: non-root, no-new-privileges, no socket or named volume"
		else
			fail "runner-ai: non-root, no-new-privileges, no socket or named volume"
		fi
		for n in ai ea; do
			if jq -e --arg n "$n" '.services["runner-"+$n] | any(.volumes[]?; .target == "/etc/\($n)/infra-ca.crt" and .read_only) and any(.extra_hosts[]?; startswith("vault.infra.famillelallier.net"))' <<<"$cfg" >/dev/null; then
				pass "runner-$n: Infra CA at /etc/$n/infra-ca.crt, vault/portainer pinned"
			else
				fail "runner-$n: Infra CA at /etc/$n/infra-ca.crt, vault/portainer pinned"
			fi
		done
	else
		fail "runners compose config" "$cfg"
	fi
	grep -v '^GH_RUNNER_TOKEN_MORIA=' "$ws/.runner.env" >"$ws/.runner.env.short"
	if out="$(rc .runner.env.short config -q)"; then
		fail "missing PAT is rejected" "config succeeded"
	elif grep -qF GH_RUNNER_TOKEN_MORIA <<<"$out"; then
		pass "missing PAT is rejected, naming GH_RUNNER_TOKEN_MORIA"
	else
		fail "missing PAT is rejected, naming GH_RUNNER_TOKEN_MORIA" "$out"
	fi

	echo "== runners-stack selftest"
	if out="$(cd "$ws" && bash scripts/runners-stack.sh selftest 2>&1)"; then pass "runners-stack.sh selftest"; else fail "runners-stack.sh selftest" "$out"; fi

	echo "== portainer-stack selftest"
	if out="$(cd "$ws" && bash scripts/portainer-stack.sh selftest 2>&1)"; then pass "portainer-stack.sh selftest"; else fail "portainer-stack.sh selftest" "$out"; fi

	echo "== PR workflow"
	wf=.github/workflows/test.yml
	if [ -f "$wf" ] && uv_py --with pyyaml python - "$PWD/$wf" <<-'PY'
		import sys, yaml
		d = yaml.safe_load(open(sys.argv[1]))
		on = d.get(True, d.get("on"))  # YAML 1.1 reads a bare `on` as True
		assert on == {"pull_request": {"branches": ["main"]}, "push": {"branches": ["main"]}}, on
		assert d["jobs"]["test"]["runs-on"] == "ubuntu-latest", d["jobs"]["test"]["runs-on"]
		assert d["permissions"] == {"contents": "read"}, d["permissions"]
	PY
	then pass "test.yml: pull_request + push on main, no paths, hosted runner, read-only"; else fail "test.yml: pull_request + push on main, no paths, hosted runner, read-only"; fi
	if [ -f "$wf" ] && ! grep -v '^ *#' "$wf" | grep -qE 'self-hosted|secrets\.'; then pass "test.yml: no self-hosted label, no secrets"; else fail "test.yml: no self-hosted label, no secrets"; fi

	echo "== runners Makefile targets"
	if ! grep -qE '^runner(-ea)?-' Makefile; then pass "no runner-* / runner-ea-* targets"; else fail "no runner-* / runner-ea-* targets" "$(grep -nE '^runner(-ea)?-' Makefile)"; fi
	if out="$(make -n runners-up FORCE=1 2>&1)" && grep -q 'scripts/runners-stack.sh up' <<<"$out"; then pass "make runners-up calls runners-stack.sh up"; else fail "make runners-up calls runners-stack.sh up" "$out"; fi
	if grep -q 'INFRA_HOST=' <<<"$(make -n runners-up FORCE=1 2>&1)"; then pass "make runners-up passes INFRA_HOST"; else fail "make runners-up passes INFRA_HOST"; fi
	fe="$ws/.fe-sb"; mkdir -p "$fe"; cp "$ws/.env.example" "$fe/"; : >"$fe/.runner.env"
	if ! out="$(bash "$ws/scripts/ci-fake-env.sh" "$fe" 2>&1)" && grep -qF .runner.env <<<"$out"; then pass "ci-fake-env refuses to overwrite .runner.env"; else fail "ci-fake-env refuses to overwrite .runner.env" "$out"; fi
	rm -rf "$fe"
	for f in docker-compose.runner.yml docker-compose.runner-ea.yml; do
		if [ ! -e "$f" ]; then pass "$f is gone"; else fail "$f is gone"; fi
	done

	echo "== runner scripts (fake curl)"
	# Sandbox with just the scripts; a fake curl answers per token / repo.
	sb="$ws/.runner-sb"; mkdir -p "$sb/scripts/lib" "$sb/bin"
	cp "$ws/scripts/gen-runner-env.sh" "$ws/scripts/runner-status.sh" "$sb/scripts/"
	cp "$ws/scripts/lib/runners.sh" "$sb/scripts/lib/"
	cat >"$sb/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# gen mode (-w '%{http_code}'): the code only, 404 for a token containing 404.
# status mode (-w '\n%{http_code}'): a one-runner body for the repo in the URL.
tok="$(sed -n 's/.*Bearer \(.*\)".*/\1/p')"
url="${*: -1}"; w=""
while [ $# -gt 0 ]; do [ "$1" = -w ] && w="$2"; shift; done
repo="$(sed 's|.*/repos/[^/]*/\([^/]*\)/actions.*|\1|' <<<"$url" | tr '[:upper:]' '[:lower:]')"
code=200; case "$tok" in *404*) code=404 ;; esac
if [ "${w:0:1}" = $'\n' ]; then
  busy=false; [ "$repo" = "${FAKE_BUSY:-}" ] && busy=true
  printf '{"runners":[{"name":"%s-host","status":"online","busy":%s,"labels":[{"name":"%s"}]}]}\n%s' "$repo" "$busy" "$repo" "$code"
else
  printf '%s' "$code"
fi
FAKE
	chmod +x "$sb/bin/curl"
	good=$'tok-a\ntok-b\ntok-c\ntok-d\ntok-e\ntok-f\n'
	if out="$(cd "$sb" && PATH="$sb/bin:$PATH" bash scripts/gen-runner-env.sh <<<"$good" 2>&1)" \
		&& [ "$(grep -c '^GH_RUNNER_TOKEN_[A-Z]*=' "$sb/.runner.env")" = 6 ] \
		&& [ "$(stat -c %a "$sb/.runner.env" 2>/dev/null || stat -f %Lp "$sb/.runner.env")" = 600 ]; then
		pass "gen-runner-env writes six tokens, mode 600"
	else
		fail "gen-runner-env writes six tokens, mode 600" "$out"
	fi
	rm -f "$sb/.runner.env"
	bad=$'tok-a\ntok-404\ntok-c\ntok-d\ntok-e\ntok-f\n'
	out="$(cd "$sb" && PATH="$sb/bin:$PATH" bash scripts/gen-runner-env.sh <<<"$bad" 2>&1)"; code=$?
	if [ "$code" -ne 0 ] && grep -qF nicolaslallier/EA <<<"$out" && [ ! -e "$sb/.runner.env" ]; then
		pass "gen-runner-env rejects EA's 404 token, names the repo, writes nothing"
	else
		fail "gen-runner-env rejects EA's 404 token, names the repo, writes nothing" "exit $code: $out"
	fi
	printf 'GH_RUNNER_TOKEN_%s=t\n' DARKANGEL EA HEAVEN INFRA MORIA AI >"$sb/.runner.env"
	out="$(cd "$sb" && FAKE_BUSY=heaven PATH="$sb/bin:$PATH" bash scripts/runner-status.sh --busy 2>&1)"; code=$?
	if [ "$code" = 3 ] && grep -qF heaven-host <<<"$out"; then
		pass "runner-status --busy: busy heaven runner -> exit 3, named"
	else
		fail "runner-status --busy: busy heaven runner -> exit 3, named" "exit $code: $out"
	fi
	out="$(cd "$sb" && FAKE_BUSY=none PATH="$sb/bin:$PATH" bash scripts/runner-status.sh --busy 2>&1)"; code=$?
	if [ "$code" = 0 ]; then pass "runner-status --busy: all idle -> exit 0"; else fail "runner-status --busy: all idle -> exit 0" "exit $code: $out"; fi

	echo "== github-harden.sh (fake gh, no write ever)"
	hs="$ws/scripts/github-harden.sh"
	# shellcheck disable=SC1090
	rj() { (. "$hs"; ruleset_json "$1"); }
	if [ -f "$hs" ] \
		&& rj infra | jq -e '.name=="main-protection" and .target=="branch" and .enforcement=="active" and .bypass_actors==[]
			and .conditions.ref_name.include==["~DEFAULT_BRANCH"]
			and ([.rules[].type]|sort)==["deletion","non_fast_forward","pull_request","required_linear_history","required_status_checks"]
			and (.rules[]|select(.type=="pull_request").parameters.required_approving_review_count)==0
			and (.rules[]|select(.type=="required_status_checks").parameters
				| .strict_required_status_checks_policy==true and ([.required_status_checks[].context]==["test"]))' >/dev/null \
		&& [ "$(rj darkangel | jq '[.rules[]|select(.type=="required_status_checks").parameters.required_status_checks[]]|length')" = 3 ]; then
		pass "ruleset_json: infra/darkangel shape"
	else
		fail "ruleset_json: infra/darkangel shape"
	fi
	out="$(bash "$hs" nope 2>&1)"; code=$?
	if [ "$code" -ne 0 ]; then pass "github-harden nope -> usage error"; else fail "github-harden nope -> usage error" "$out"; fi

	hb="$ws/.harden-sb"; mkdir -p "$hb/bin" "$hb/fix"
	cat >"$hb/bin/gh" <<'FAKE'
#!/usr/bin/env bash
# Records every call in $LOG; GETs answer from $FIX/<path with / as _>, else 404.
# Bodies sent with --input - are recorded after the call line.
shift # api
m=GET; path=""; body=""
while [ $# -gt 0 ]; do
  case "$1" in -X) m="$2"; shift ;; -H) shift ;; --input) body="$(cat)"; shift ;; *) path="$1" ;; esac
  shift
done
path="${path%%\?*}"
printf '%s %s %s\n' "$m" "$path" "$body" >>"$LOG"
if [ "$m" != GET ]; then
  n=$(( $(cat "$LOG.n" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$LOG.n"
  [ "$n" = "${FAKE_FAIL_NTH:-}" ] && { echo "HTTP 500" >&2; exit 1; }
  exit 0
fi
f="$FIX/$(tr / _ <<<"$path")"
[ -f "$f" ] && cat "$f" || { echo "HTTP 404" >&2; exit 1; }
FAKE
	chmod +x "$hb/bin/gh"
	fx="$hb/fix"; W=repos_nicolaslallier_Infra_contents_.github_workflows
	echo '[{"name":"test.yml","type":"file"},{"name":"deploy.yml","type":"file"}]' >"$fx/$W"
	printf 'name: test\non:\n  pull_request:\n    branches: [main]\njobs:\n  test:\n    runs-on: ubuntu-latest\n' >"$fx/${W}_test.yml"
	printf 'name: deploy\non:\n  push:\n    branches: [main]\njobs:\n  deploy:\n    runs-on: [self-hosted, infra]\n' >"$fx/${W}_deploy.yml"
	R=repos_nicolaslallier_Infra
	echo '[{"id":7,"name":"Main","enforcement":"active"}]' >"$fx/${R}_rulesets"
	echo '{"allow_squash_merge":true,"allow_rebase_merge":false}' >"$fx/$R"
	cr() { printf '{"check_runs":[%s]}' "$(for c in "$@"; do printf '{"name":"%s","conclusion":"success"},' "$c"; done | sed 's/,$//')"; }
	cr test >"$fx/${R}_commits_main_check-runs"
	cr 'build (ubuntu-latest, target/release/moria-client, moria-client-linux)' 'build (windows-latest, target/release/moria-client.exe, moria-client-windows.exe)' 'build (macos-latest, target/release/moria-client, moria-client-macos)' >"$fx/repos_nicolaslallier_Moria_commits_main_check-runs"
	hg() { (cd "$hb" && rm -f "$hb/log.n" && LOG="$hb/log" FIX="$fx" PATH="$hb/bin:$PATH" bash "$hs" "$@" 2>&1); }

	: >"$hb/log"; out="$(hg infra)"; code=$?
	if [ "$code" = 0 ] && ! grep -qE '^(POST|PUT|PATCH|DELETE) ' "$hb/log" && grep -qF 'Main' <<<"$out" && grep -qF 'would POST' <<<"$out"; then
		pass "github-harden dry run: lists old ruleset, writes nothing"
	else fail "github-harden dry run: lists old ruleset, writes nothing" "exit $code: $out"; fi

	: >"$hb/log"; out="$(hg --apply infra)"; code=$?
	if [ "$code" = 0 ] && grep -q '^POST repos/nicolaslallier/Infra/rulesets {' "$hb/log" \
		&& ! grep -q '^PUT repos/nicolaslallier/Infra/rulesets' "$hb/log" \
		&& grep -q '^PUT repos/nicolaslallier/Infra/actions/permissions/fork-pr-contributor-approval {"approval_policy":"all_external_contributors"}' "$hb/log" \
		&& grep -q '^PUT repos/nicolaslallier/Infra/actions/permissions {"enabled":true,"allowed_actions":"selected"}' "$hb/log" \
		&& grep -q '^PUT repos/nicolaslallier/Infra/actions/permissions/selected-actions {"github_owned_allowed":true,"verified_allowed":true,"patterns_allowed":\[\]}' "$hb/log"; then
		pass "github-harden --apply: POST ruleset + three PUT settings, old ruleset untouched"
	else fail "github-harden --apply: POST ruleset + three PUT settings" "exit $code: $out"$'\n'"$(cat "$hb/log")"; fi

	echo '[{"id":7,"name":"Main","enforcement":"active"},{"id":9,"name":"main-protection","enforcement":"active"}]' >"$fx/${R}_rulesets"
	: >"$hb/log"; hg --apply infra >/dev/null
	if grep -q '^PUT repos/nicolaslallier/Infra/rulesets/9 {' "$hb/log" && ! grep -q '^POST ' "$hb/log" && ! grep -q 'rulesets/7' "$hb/log"; then
		pass "github-harden --apply twice: PUT by id, no duplicate, #7 untouched"
	else fail "github-harden --apply twice: PUT by id" "$(cat "$hb/log")"; fi

	# A required check that never succeeded on main refuses --apply (nothing written); the dry run still reports it.
	echo '{"check_runs":[{"name":"test","conclusion":"failure"}]}' >"$fx/${R}_commits_main_check-runs"
	: >"$hb/log"; out="$(hg --apply infra)"; code=$?
	if [ "$code" -ne 0 ] && grep -qF "'test' has no successful run" <<<"$out" && ! grep -qE '^(POST|PUT|PATCH|DELETE) ' "$hb/log"; then
		pass "github-harden --apply: check never green on main refused, named, nothing written"
	else fail "github-harden --apply: check never green on main refused" "exit $code: $out"; fi
	: >"$hb/log"; out="$(hg infra)"; code=$?
	if [ "$code" = 0 ] && grep -qF 'would REFUSE' <<<"$out" && ! grep -qE '^(POST|PUT|PATCH|DELETE) ' "$hb/log"; then
		pass "github-harden dry run: reports a check never green, writes nothing"
	else fail "github-harden dry run: reports a check never green" "exit $code: $out"; fi
	cr test >"$fx/${R}_commits_main_check-runs"
	: >"$hb/log"; out="$(hg --apply infra)"; code=$?
	if [ "$code" = 0 ] && grep -q '^PUT repos/nicolaslallier/Infra/rulesets/9 {' "$hb/log"; then
		pass "github-harden --apply: accepted once every check succeeded on main"
	else fail "github-harden --apply: accepted once green" "exit $code: $out"; fi

	# Third-party actions: derived from the workflows' `uses:`, GitHub-owned and local refs ignored.
	M=repos_nicolaslallier_Moria; MW=${M}_contents_.github_workflows
	echo '[{"name":"client.yml","type":"file"}]' >"$fx/$MW"
	printf 'name: client\non:\n  pull_request:\n    branches: [main]\njobs:\n  build:\n    strategy:\n      matrix:\n        os: [ubuntu-latest, windows-latest, macos-latest]\n    runs-on: ${{ matrix.os }}\n    steps:\n      - uses: actions/checkout@v4\n      - uses: dtolnay/rust-toolchain@stable\n      - uses: "Swatinem/rust-cache@v2"\n      - uses: ./.github/actions/x\n      - uses: foo/bar/sub@v1 # c\n      - uses: docker://alpine:3\n' >"$fx/${MW}_client.yml"
	echo '[]' >"$fx/${M}_rulesets"; echo '{"allow_rebase_merge":true}' >"$fx/$M"
	: >"$hb/log"; hg --apply moria >/dev/null
	want='{"github_owned_allowed":true,"verified_allowed":true,"patterns_allowed":["Swatinem/rust-cache@*","dtolnay/rust-toolchain@*","foo/bar/sub@*"]}'
	if grep -qF "PUT repos/nicolaslallier/Moria/actions/permissions/selected-actions $want" "$hb/log"; then
		pass "github-harden: patterns_allowed derived from uses: (owner/repo[/sub]@*, byte-sorted)"
	else fail "github-harden: patterns_allowed derived from uses:" "$(cat "$hb/log")"; fi
	# bash 3.2-safe: build the fixtures for the filter test
	H=repos_nicolaslallier_Heaven; HW=${H}_contents_.github_workflows
	echo '[{"name":"ci.yml","type":"file"},{"name":"docker.yml","type":"file"},{"name":"ign.yml","type":"file"}]' >"$fx/$HW"
	printf 'on:\n  push:\n    paths: [x]\n  pull_request:\njobs:\n  test:\n    strategy:\n      matrix:\n        v: [1]\n' >"$fx/${HW}_ci.yml"
	printf 'on:\n  pull_request:\n    paths:\n      - a\njobs:\n  image:\n    runs-on: x\n' >"$fx/${HW}_docker.yml"
	printf 'on:\n  pull_request:\n    paths-ignore:\n      - a\njobs:\n  ignored:\n    runs-on: x\n' >"$fx/${HW}_ign.yml"
	out="$(cd "$hb" && LOG="$hb/log" FIX="$fx" PATH="$hb/bin:$PATH" bash -c '. "$1"; workflow_jobs nicolaslallier/Heaven' _ "$hs" 2>&1)"
	if [ "$out" = "$(printf 'ok\ttest\t1\nfiltered\timage\t0\nfiltered\tignored\t0')" ]; then
		pass "workflow_jobs: matrix accepted, paths and paths-ignore filtered, push paths ignored"
	else fail "workflow_jobs: paths/paths-ignore/matrix" "$out"; fi

	# required_linear_history needs squash or rebase merging.
	echo '{"allow_squash_merge":false,"allow_rebase_merge":false,"allow_merge_commit":true}' >"$fx/$R"
	: >"$hb/log"; out="$(hg --apply infra)"; code=$?
	if [ "$code" -ne 0 ] && grep -qF allow_squash_merge <<<"$out" && ! grep -qE '^(POST|PUT|PATCH|DELETE) ' "$hb/log"; then
		pass "github-harden --apply: merge-commit-only repo refused, nothing written"
	else fail "github-harden --apply: merge-commit-only repo refused" "exit $code: $out"; fi
	echo '{"allow_squash_merge":true}' >"$fx/$R"

	# A failing third write reports what was and was not applied.
	: >"$hb/log"; out="$(FAKE_FAIL_NTH=3 hg --apply infra)"; code=$?
	if [ "$code" -ne 0 ] && grep -qF 'applied: ruleset main-protection' <<<"$out" \
		&& grep -qF 'FAILED: actions/permissions' <<<"$out" \
		&& grep -qF 'applied before the failure: ruleset main-protection fork-pr-contributor-approval' <<<"$out" \
		&& grep -qF 'NOT applied: actions/permissions, selected-actions' <<<"$out"; then
		pass "github-harden --apply: failure on write 3 lists applied and pending steps"
	else fail "github-harden --apply: partial failure report" "exit $code: $out"; fi

	# A required check that is no job (here: the workflow renamed it) refuses before any write.
	sed -i.sed 's/^  test:/  tests:/' "$fx/${W}_test.yml"; rm -f "$fx/${W}_test.yml.sed"
	: >"$hb/log"; out="$(hg --apply infra)"; code=$?
	if [ "$code" -ne 0 ] && grep -qF "'test'" <<<"$out" && ! grep -qE '^(POST|PUT|PATCH|DELETE) ' "$hb/log"; then
		pass "github-harden --apply: missing check refused, named, nothing written"
	else fail "github-harden --apply: missing check refused" "exit $code: $out"; fi

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
		expect_reject "amqp password not url-safe" "MORIA_AMQP_PASSWORD must be letters and digits" "set_env MORIA_AMQP_PASSWORD 'a@b/c'"
		expect_reject "portail db password not url-safe" "PORTAIL_DB_PASSWORD must be letters and digits" "set_env PORTAIL_DB_PASSWORD 'a@b/c'"
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
