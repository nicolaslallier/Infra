#!/bin/sh
# Creates a per-app database + least-privilege role.
#
# Two ways to invoke this file:
#
#   1. No arguments (how docker-entrypoint runs it on first init):
#      reads APP_DATABASES ("jarvis,beacon") and, for each app,
#      <APPNAME>_DB_PASSWORD (e.g. JARVIS_DB_PASSWORD) from the environment.
#
#   2. `10-provision-apps.sh --single` (how scripts/provision-app.sh drives
#      it against an already-running cluster): reads APP_NAME and
#      APP_PASSWORD from the environment for just one app.
#
# Both paths call the same provision_one() logic so initdb-time and
# late provisioning can never drift apart. Idempotent: safe to re-run
# for an app that already exists.
set -eu

provision_one() {
  app="$1"
  pass="$2"

  # NB: psql does not interpolate :'var'/:"var" references inside
  # $$-quoted strings (so a DO $$ ... $$ block can't use variables in its
  # body) or in -c command strings (only in scripts/stdin). \gexec --
  # generate SQL via a SELECT, then execute the results -- sidesteps both,
  # since format() is a plain top-level expression fed via stdin.
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres \
    -v appname="$app" -v apppass="$pass" <<-'EOSQL'
		SELECT format('CREATE ROLE %I WITH LOGIN PASSWORD %L', :'appname', :'apppass')
		WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = :'appname')
		\gexec
		SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'appname', :'apppass')
		WHERE EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = :'appname')
		\gexec
		SELECT format('CREATE DATABASE %I OWNER %I', :'appname', :'appname')
		WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'appname')
		\gexec
		REVOKE CONNECT ON DATABASE :"appname" FROM PUBLIC;
		GRANT CONNECT ON DATABASE :"appname" TO :"appname";
	EOSQL

  # Create pgvector as the superuser inside the app DB. App roles are not
  # superusers, so Jarvis's migration `CREATE EXTENSION IF NOT EXISTS vector`
  # would otherwise fail with a permissions error even though the image
  # ships the extension files. Idempotent: safe when the extension already
  # exists (e.g. re-running provision-app after an image swap).
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$app" \
    -c "CREATE EXTENSION IF NOT EXISTS vector;"

  echo "10-provision-apps.sh: provisioned database/role '$app'"
}

if [ "${1:-}" = "--single" ]; then
  : "${APP_NAME:?APP_NAME is required in --single mode}"
  : "${APP_PASSWORD:?APP_PASSWORD is required in --single mode}"
  provision_one "$APP_NAME" "$APP_PASSWORD"
  exit 0
fi

if [ -z "${APP_DATABASES:-}" ]; then
  echo "10-provision-apps.sh: APP_DATABASES is empty, nothing to provision"
  exit 0
fi

old_ifs=$IFS
IFS=','
for app in $APP_DATABASES; do
  IFS=$old_ifs
  app=$(echo "$app" | tr -d '[:space:]')
  [ -z "$app" ] && continue

  var_name=$(echo "${app}_DB_PASSWORD" | tr '[:lower:]' '[:upper:]')
  eval "pass=\${$var_name:-}"
  if [ -z "$pass" ]; then
    echo "10-provision-apps.sh: missing $var_name for app '$app', skipping" >&2
    continue
  fi

  provision_one "$app" "$pass"
  IFS=','
done
IFS=$old_ifs
