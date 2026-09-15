#!/usr/bin/env bash
# Asserts that .env can actually bring the stack up, before anything deploys
# or provisions against it. Run by `make up`, `config`, `provision-app`,
# `dns-provision`, `dns-check`, `keycloak-seed-users` and `obsidian-minio`.
#
# Three classes of problem, all of which used to surface far from .env:
#
#   1. A setting .env.example defines that this .env never got. .env is
#      copied once, by `make init`, and then lives on (gitignored) while
#      .env.example keeps growing -- so a variable added with a new service
#      is simply absent here. Compose interpolates an absent variable as an
#      empty string and deploys anyway, and the service says nothing about
#      .env: oauth2-proxy-ea, handed an empty EA_OBSIDIAN_OAUTH_COOKIE_SECRET,
#      dies with "invalid configuration: missing setting: cookie-secret" and
#      crash-loops.
#   2. A value still at the `change-me` placeholder, or empty.
#   3. A value that is present and wrong in a way only the container finds
#      out: an oauth2-proxy cookie key that is not 16/24/32 bytes as *that
#      container* counts them (standard base64 is the usual near-miss -- see
#      section 3 below), or a LAN_IP this host does not own (the `dns`
#      service publishes its ports on that address, and a stale one fails
#      the bind and leaves every later service stuck in "Created").
#
# The two oauth2-proxy *client* secrets are deliberately not errors: Keycloak
# generates them when it imports the realm, so they cannot exist before the
# first deploy. They are warned about instead, which is also what makes the
# documented bootstrap order (deploy, then copy the secret out of the admin
# console) possible.
#
# Diagnostics go to stderr. Exit 0 = usable, 1 = do not deploy.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

ENV_FILE=.env
EXAMPLE_FILE=.env.example
PLACEHOLDER=change-me

errors=()
warnings=()

say() { printf '%s\n' "$@" >&2; }

# Values with no source other than .env, every one of which can be chosen
# freely before the first deploy. Per-app <APP>_DB_PASSWORD entries are added
# below, from APP_DATABASES.
REQUIRED=(
	POSTGRES_PASSWORD
	PGADMIN_PASSWORD
	KEYCLOAK_ADMIN_PASSWORD
	KEYCLOAK_DB_PASSWORD
	DNS_ADMIN_PASSWORD
	GRAFANA_ADMIN_PASSWORD
	MONITORING_DB_PASSWORD
	MINIO_ROOT_PASSWORD
	OBSIDIAN_MINIO_SECRET_KEY
	EA_MINIO_SECRET_KEY
	RABBITMQ_DEFAULT_PASS
	NEO4J_PASSWORD
	AIRFLOW_DB_PASSWORD
	AIRFLOW_ADMIN_PASSWORD
	AIRFLOW_FERNET_KEY
	AIRFLOW_JWT_SECRET
	JARVIS_OAUTH_COOKIE_SECRET
	EA_OBSIDIAN_OAUTH_COOKIE_SECRET
)

# oauth2-proxy encrypts its session cookie with these, and refuses to start
# unless the key is 16, 24 or 32 bytes -- raw, or base64url (not standard
# base64) of that many bytes -- so they are checked for length and alphabet,
# not just for being filled in.
COOKIE_SECRETS=(
	JARVIS_OAUTH_COOKIE_SECRET
	EA_OBSIDIAN_OAUTH_COOKIE_SECRET
)

# <var>:<service>:<realm>:<client>, for the secrets Keycloak itself generates
# on realm import. Warned about, never fatal: the first deploy is how the
# realm (and therefore the secret) comes to exist.
POST_BOOT=(
	JARVIS_OAUTH_CLIENT_SECRET:oauth2-proxy:jarvis:jarvis
	EA_OBSIDIAN_OAUTH_CLIENT_SECRET:oauth2-proxy-ea:ea:ea-obsidian
)

in_list() {
	local needle=$1 item
	shift
	for item in "$@"; do
		[ "$item" = "$needle" ] && return 0
	done
	return 1
}

# Variable names actually assigned in a dotenv file (so a commented-out
# PORTAINER_API_KEY in .env.example is not one of them).
keys_in() {
	sed -nE 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p' "$1" | sort -u
}

if [ ! -f "$ENV_FILE" ]; then
	say "check-env: $ENV_FILE not found (run 'make init' first)"
	exit 1
fi

post_boot_vars=()
for entry in "${POST_BOOT[@]}"; do
	post_boot_vars+=("${entry%%:*}")
done

# No mapfile: /bin/bash on a stock Mac is 3.2, and this runs on every `make up`.
env_keys=()
while read -r key; do
	[ -n "$key" ] || continue
	env_keys+=("$key")
done < <(keys_in "$ENV_FILE")

# --- 1. settings .env.example defines and this .env never got --------------
missing_keys=()
missing_post_boot=()
if [ -f "$EXAMPLE_FILE" ]; then
	while read -r key; do
		[ -n "$key" ] || continue
		if in_list "$key" "${post_boot_vars[@]}"; then
			missing_post_boot+=("$key")
		else
			missing_keys+=("$key")
		fi
	done < <(comm -23 <(keys_in "$EXAMPLE_FILE") <(keys_in "$ENV_FILE"))
fi

if [ "${#missing_keys[@]}" -gt 0 ]; then
	errors+=("$ENV_FILE is missing settings that $EXAMPLE_FILE defines: ${missing_keys[*]}")
fi

# --- 2. placeholders and empties -------------------------------------------
set -a
# shellcheck disable=SC1090
if ! . "./$ENV_FILE"; then
	set +a
	say "check-env: $ENV_FILE could not be read as shell (see the error above);" \
		"  Compose parses it more loosely than this, so a value that trips bash" \
		"  here -- an unquoted '#' or a stray quote, say -- may still reach a" \
		"  container, mangled."
	exit 1
fi
set +a

old_ifs="$IFS"
IFS=','
for app in ${APP_DATABASES:-}; do
	app="${app//[[:space:]]/}"
	[ -n "$app" ] || continue
	REQUIRED+=("$(printf '%s' "$app" | tr '[:lower:]' '[:upper:]')_DB_PASSWORD")
done
IFS="$old_ifs"

placeholder=()
empty=()
absent=()
for var in $(printf '%s\n' "${REQUIRED[@]}" | sort -u); do
	# Already reported as absent from .env by the diff above; don't say it twice.
	in_list "$var" ${missing_keys[@]+"${missing_keys[@]}"} && continue
	if ! in_list "$var" ${env_keys[@]+"${env_keys[@]}"}; then
		# Not in .env.example either -- e.g. the <APP>_DB_PASSWORD for an app
		# just added to APP_DATABASES by hand.
		absent+=("$var")
	elif [ -z "${!var:-}" ]; then
		empty+=("$var")
	elif [ "${!var}" = "$PLACEHOLDER" ]; then
		placeholder+=("$var")
	fi
done

if [ "${#placeholder[@]}" -gt 0 ]; then
	errors+=("still at the '$PLACEHOLDER' placeholder in $ENV_FILE: ${placeholder[*]}")
fi
if [ "${#absent[@]}" -gt 0 ]; then
	errors+=("not set in $ENV_FILE at all: ${absent[*]}")
fi
if [ "${#empty[@]}" -gt 0 ]; then
	errors+=("set but empty in $ENV_FILE: ${empty[*]}")
fi

# --- 3. present but unusable ------------------------------------------------
# Byte length of a value read the way oauth2-proxy reads it, or "" if it does
# not read as base64 at all. This mirrors pkg/encryption.SecretBytes exactly,
# and the "exactly" is the whole point: oauth2-proxy decodes with Go's
# base64.RawURLEncoding -- the *URL-safe* alphabet, padding stripped -- and
# silently falls back to the raw string when that fails. So a standard-base64
# key is not "base64 of 32 bytes" to it. `openssl rand -base64 32` emits a
# '+' or a '/' about three times in four, and each of those becomes a 44-byte
# raw key:
#   [main.go:52] invalid configuration:
#     cookie_secret must be 16, 24, or 32 bytes to create an AES cipher,
#     but is 44 bytes
# A check that accepted any base64 would wave that value straight through to
# the crash-loop it is here to prevent.
b64url_len() {
	local value=$1 out
	while [ "${value%=}" != "$value" ]; do value="${value%=}"; done
	case "$value" in *[!A-Za-z0-9_-]*) return 0 ;; esac
	value=$(printf '%s' "$value" | tr -- '-_' '+/')
	while [ $(( ${#value} % 4 )) -ne 0 ]; do
		value="${value}="
	done
	out=$(printf '%s' "$value" | { base64 --decode 2>/dev/null || base64 -D 2>/dev/null; } | wc -c) || return 0
	printf '%s' "${out//[[:space:]]/}"
}

for var in "${COOKIE_SECRETS[@]}"; do
	value="${!var:-}"
	[ -n "$value" ] && [ "$value" != "$PLACEHOLDER" ] || continue
	raw=$(printf '%s' "$value" | wc -c)
	raw=${raw//[[:space:]]/}
	dec=$(b64url_len "$value")
	# Either branch is accepted: oauth2-proxy tries the decode first and
	# keeps the raw bytes when it fails or yields an unusable length.
	case "$raw" in 16 | 24 | 32) continue ;; esac
	case "$dec" in 16 | 24 | 32) continue ;; esac
	case "$(b64url_len "$(printf '%s' "$value" | tr -- '+/' '-_')")" in
	16 | 24 | 32)
		# The common near-miss, and unguessable from the container's error
		# message: the value *is* 32 bytes of base64, just the wrong alphabet.
		errors+=("$var is standard base64, not base64url -- oauth2-proxy only decodes the URL-safe alphabet, so it takes this as a raw $raw byte key and dies with \"cookie_secret must be 16, 24, or 32 bytes to create an AES cipher, but is $raw bytes\". Keep the same key, change the alphabet: printf '%s\\n' \"\$$var\" | tr -- '+/' '-_'")
		;;
	*)
		errors+=("$var is $raw bytes ${dec:+(decoding to $dec) }-- oauth2-proxy only accepts a 16, 24 or 32 byte cookie key, raw or base64url; generate one with \"openssl rand -base64 32 | tr -- '+/' '-_'\"")
		;;
	esac
done

if [ -z "${LAN_IP:-}" ]; then
	errors+=("LAN_IP is not set in $ENV_FILE")
else
	addrs="$( { { ifconfig 2>/dev/null || ip -4 -o addr show 2>/dev/null; } \
		| grep -oE 'inet (addr:)?[0-9.]+' | grep -oE '[0-9.]+$'; \
		ipconfig.exe 2>/dev/null | grep -i 'IPv4' | grep -oE '([0-9]+\.){3}[0-9]+'; } \
		|| true)"
	# The Makefile passes INFRA_HOST; standalone, derive it from a
	# ssh://user@host DOCKER_HOST so the check still means something.
	infra_host="${INFRA_HOST:-}"
	if [ -z "$infra_host" ] && [[ "${DOCKER_HOST:-}" =~ ^ssh://([^@/]+@)?([^:/]+) ]]; then
		infra_host="${BASH_REMATCH[2]}"
	fi
	if [ -n "${DOCKER_HOST:-}" ] && [ -n "$infra_host" ]; then
		# The addresses of *this* machine say nothing here: the ports are
		# published on the remote daemon's host, which is the one that has
		# to own LAN_IP.
		if [ "$LAN_IP" != "$infra_host" ]; then
			errors+=("LAN_IP=$LAN_IP but DOCKER_HOST targets $infra_host")
		fi
	elif [ -z "${DOCKER_HOST:-}" ] && [ -n "$addrs" ] \
		&& ! printf '%s\n' "$addrs" | grep -qxF "$LAN_IP"; then
		errors+=("LAN_IP=$LAN_IP is not an address on this host (have: $(echo $addrs))")
	fi
fi

# --- the client secrets Keycloak has to generate first ----------------------
for entry in "${POST_BOOT[@]}"; do
	var=${entry%%:*}
	rest=${entry#*:}
	service=${rest%%:*}
	rest=${rest#*:}
	realm=${rest%%:*}
	client=${rest#*:}
	value="${!var:-}"
	if in_list "$var" ${missing_post_boot[@]+"${missing_post_boot[@]}"}; then
		state="not in $ENV_FILE at all"
	elif [ -z "$value" ]; then
		state="empty"
	elif [ "$value" = "$PLACEHOLDER" ]; then
		state="still '$PLACEHOLDER'"
	else
		continue
	fi
	warnings+=("$var is $state, so $service will crash-loop on \"missing setting: client-secret\". Copy it from the Keycloak admin console (realm $realm -> Clients -> $client -> Credentials) into $ENV_FILE, then redeploy.")
done

if [ "${#warnings[@]}" -gt 0 ]; then
	for warning in "${warnings[@]}"; do
		say "check-env: warning: $warning"
	done
fi

if [ "${#errors[@]}" -gt 0 ]; then
	for error in "${errors[@]}"; do
		say "check-env: $error"
	done
	if [ "${#missing_keys[@]}" -gt 0 ]; then
		say "" \
			"  Those were added to $EXAMPLE_FILE after this $ENV_FILE was created." \
			"  Compose interpolates an absent variable as an empty string and" \
			"  deploys anyway, so the failure would show up as a container dying on" \
			"  its own config rather than as anything naming $ENV_FILE. Append them:" \
			""
		for key in "${missing_keys[@]}"; do
			say "    $(grep -m1 -E "^[[:space:]]*$key=" "$EXAMPLE_FILE")"
		done
		say "" \
			"  and fill each one in -- 'grep -B4 -n <VAR> $EXAMPLE_FILE' shows what" \
			"  it is for."
	fi
	exit 1
fi

exit 0
