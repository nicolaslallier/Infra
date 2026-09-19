#!/usr/bin/env bash
# Renders a throwaway .env (and openbao/seal.key) into a checkout so that
# validation-only commands -- `check-env.sh`, `docker compose config`, a
# `nginx -t` that needs certs -- can run against a fresh clone that has
# neither. Nothing it writes is a real credential and nothing it writes is
# ever deployed: values are random, LAN_IP is loopback, and the intended
# caller is CI on a disposable workspace (see airflow/dags/infra_pr_validation.py).
#
# Every value has to be shaped the way the container that reads it expects,
# not merely non-empty, because check-env.sh asserts exactly that:
#   - the two oauth2-proxy cookie keys decode as 32 bytes under Go's
#     base64.RawURLEncoding -- hence `tr -- '+/' '-_'` and stripping '='
#     (see "Preflight: make check-env" in CLAUDE.md)
#   - AIRFLOW_FERNET_KEY is url-safe base64 of 32 bytes, padding kept
#   - AIRFLOW_DB_PASSWORD sits inside a URL, so it stays url-safe
#   - LAN_IP must be an address the host owns; 127.0.0.1 always is
#
# Usage: scripts/ci-fake-env.sh [checkout-dir]
set -euo pipefail

root="${1:-.}"
cd "$root"

[ -f .env.example ] || { echo "ci-fake-env: $PWD is not an Infra checkout (no .env.example)" >&2; exit 1; }

# This overwrites .env outright. Harmless on the throwaway clone it is meant
# for, ruinous in the real checkout -- where .env is the deployed secret set
# and is gitignored, so there is no copy to restore from.
if [ -f .env ] && [ "${CI_FAKE_ENV_FORCE:-0}" != "1" ]; then
	echo "ci-fake-env: refusing to overwrite an existing .env in $PWD." >&2
	echo "             This is meant for a disposable CI checkout. Set CI_FAKE_ENV_FORCE=1 if you really mean it." >&2
	exit 1
fi

rand_hex() { od -An -tx1 -N"${1:-16}" /dev/urandom | tr -d ' \n'; }

# 32 random bytes, url-safe base64. Padding stripped for the cookie keys
# (oauth2-proxy decodes with RawURLEncoding), kept for the Fernet key.
b64_32() { head -c 32 /dev/urandom | base64 | tr -d '\n' | tr -- '+/' '-_'; }

cookie_a="$(b64_32 | tr -d '=')"
cookie_b="$(b64_32 | tr -d '=')"
fernet="$(b64_32)"

# Start from the template so every key check-env diffs for is present, then
# fill in the placeholders it rejects.
awk -v c="$(rand_hex 16)" '
	/^[A-Z0-9_]+=change-me$/ { n += 1; sub(/change-me$/, c n); }
	{ print }
' .env.example > .env

# The values whose *shape* matters, re-set after the blanket pass above.
set_key() {
	local key="$1" val="$2"
	if grep -qE "^${key}=" .env; then
		# `|` as the sed delimiter: base64url values contain '/' before tr, and '-'/'_' after.
		sed -i.bak "s|^${key}=.*|${key}=${val}|" .env && rm -f .env.bak
	else
		printf '%s=%s\n' "$key" "$val" >> .env
	fi
}

set_key LAN_IP 127.0.0.1
set_key JARVIS_OAUTH_COOKIE_SECRET "$cookie_a"
set_key EA_OBSIDIAN_OAUTH_COOKIE_SECRET "$cookie_b"
set_key AIRFLOW_FERNET_KEY "$fernet"
set_key AIRFLOW_JWT_SECRET "$(rand_hex 32)"
set_key AIRFLOW_DB_PASSWORD "$(rand_hex 16)"

# openbao's static seal is AES-256: 32 bytes, nothing else. Docker turns a
# missing bind-mount source into a directory, which is why check-env.sh
# looks for this file at all.
mkdir -p openbao
head -c 32 /dev/urandom > openbao/seal.key
chmod 600 openbao/seal.key

echo "ci-fake-env: wrote $PWD/.env and $PWD/openbao/seal.key (throwaway values)"

# `nginx -t` parses nginx/snippets/ssl.conf, which names certs/infra.crt and
# certs/infra.key -- and nginx refuses to start when they are absent. certs/
# is gitignored (it is a real local CA on the dev machine), so a fresh clone
# never has them. A one-day self-signed pair is enough: the config test only
# has to load them, nothing here ever serves traffic.
if command -v openssl >/dev/null 2>&1; then
	mkdir -p certs
	openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
		-keyout certs/infra.key -out certs/infra.crt \
		-subj "/CN=infra-ci-throwaway" \
		-addext "subjectAltName=DNS:*.infra.famillelallier.net,DNS:localhost" >/dev/null 2>&1
	# Two other services bind-mount these by name; compose only needs them to
	# exist, and nothing validates their contents here.
	cp certs/infra.crt certs/infra-ca.crt
	cp certs/infra.crt certs/oauth2proxy-ca-bundle.crt
	echo "ci-fake-env: wrote throwaway certs/ (self-signed, 1 day)"
else
	echo "ci-fake-env: openssl not found -- skipping throwaway certs; an nginx -t check will fail on the missing ssl_certificate" >&2
fi
