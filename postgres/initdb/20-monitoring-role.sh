#!/bin/sh
# Creates a read-only monitoring role for postgres-exporter (pg_monitor).
# Runs on first boot via docker-entrypoint-initdb.d. For an already-
# provisioned cluster, see README "Monitoring" for the equivalent SQL.
set -eu

if [ -z "${MONITORING_DB_PASSWORD:-}" ]; then
  echo "20-monitoring-role.sh: MONITORING_DB_PASSWORD unset, skipping" >&2
  exit 0
fi

psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres \
  -v monpass="$MONITORING_DB_PASSWORD" <<-'EOSQL'
	SELECT format('CREATE ROLE monitoring WITH LOGIN PASSWORD %L', :'monpass')
	WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'monitoring')
	\gexec
	SELECT format('ALTER ROLE monitoring WITH LOGIN PASSWORD %L', :'monpass')
	WHERE EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'monitoring')
	\gexec
	GRANT pg_monitor TO monitoring;
	GRANT CONNECT ON DATABASE postgres TO monitoring;
EOSQL

echo "20-monitoring-role.sh: provisioned role 'monitoring'"
