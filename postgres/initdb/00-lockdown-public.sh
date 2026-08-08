#!/bin/sh
# Postgres grants CONNECT on every database to PUBLIC by default, so
# without this, any per-app role could still connect to the shared
# admin database (POSTGRES_DB) even after 10-provision-apps.sh revokes
# PUBLIC connect on the app's own database. Superusers bypass this
# entirely, so it doesn't affect the postgres superuser or pgAdmin's
# admin connection.
set -eu

psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres -v dbname="$POSTGRES_DB" <<-'EOSQL'
	REVOKE CONNECT ON DATABASE :"dbname" FROM PUBLIC;
EOSQL
