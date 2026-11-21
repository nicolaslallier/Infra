#!/bin/sh
# Read-only role Grafana charts LiteLLM usage with (datasource litellm-db):
# SELECT on an allowlist of "LiteLLM_SpendLogs" columns in database litellm.
# Never the columns holding content or secrets: messages, response,
# proxy_server_request, metadata, api_key, cache_key, requester_ip_address.
# An allowlist, not a denylist: a column a LiteLLM upgrade adds stays
# unreadable until it is named here.
# Not an initdb step in practice: LiteLLM (Prisma) creates the table on its
# first start, so this runs through scripts/provision-grafana-litellm.sh,
# and again if an upgrade recreates the table. Idempotent.
set -eu

if [ -z "${GRAFANA_LITELLM_DB_PASSWORD:-}" ]; then
  echo "30-grafana-litellm-role.sh: GRAFANA_LITELLM_DB_PASSWORD unset, skipping" >&2
  exit 0
fi

psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres \
  -v pass="$GRAFANA_LITELLM_DB_PASSWORD" <<-'EOSQL'
	SELECT format('CREATE ROLE grafana_litellm WITH LOGIN PASSWORD %L', :'pass')
	WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'grafana_litellm')
	\gexec
	SELECT format('ALTER ROLE grafana_litellm WITH LOGIN PASSWORD %L', :'pass')
	WHERE EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'grafana_litellm')
	\gexec
	SELECT 'GRANT CONNECT ON DATABASE litellm TO grafana_litellm'
	WHERE EXISTS (SELECT 1 FROM pg_database WHERE datname = 'litellm')
	\gexec
EOSQL

if [ "$(psql -U "$POSTGRES_USER" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = 'litellm'")" != 1 ]; then
  echo "30-grafana-litellm-role.sh: no database 'litellm' yet (make provision-app app=litellm), role created without grants" >&2
  exit 0
fi

psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d litellm <<-'EOSQL'
	GRANT USAGE ON SCHEMA public TO grafana_litellm;
	-- Table-level REVOKE also drops every column grant: a shrunk allowlist takes effect on a re-run.
	SELECT 'REVOKE ALL ON TABLE public."LiteLLM_SpendLogs" FROM grafana_litellm'
	WHERE to_regclass('public."LiteLLM_SpendLogs"') IS NOT NULL
	\gexec
	SELECT format('GRANT SELECT (%s) ON TABLE public."LiteLLM_SpendLogs" TO grafana_litellm',
	              string_agg(format('%I', column_name), ', ' ORDER BY ordinal_position))
	FROM information_schema.columns
	WHERE table_schema = 'public' AND table_name = 'LiteLLM_SpendLogs'
	  AND column_name IN (
	    'request_id', 'call_type', 'spend', 'total_tokens', 'prompt_tokens',
	    'completion_tokens', 'startTime', 'endTime', 'completionStartTime',
	    'model', 'model_id', 'model_group', 'custom_llm_provider', 'api_base',
	    'user', 'cache_hit', 'request_tags', 'team_id', 'end_user', 'session_id',
	    'status', 'mcp_namespaced_tool_name', 'organization_id', 'agent_id',
	    'request_duration_ms')
	HAVING count(*) > 0
	\gexec
EOSQL

if [ "$(psql -U "$POSTGRES_USER" -d litellm -tAc "SELECT to_regclass('public.\"LiteLLM_SpendLogs\"') IS NOT NULL")" = t ]; then
  echo "30-grafana-litellm-role.sh: provisioned role 'grafana_litellm' (column SELECT on LiteLLM_SpendLogs)"
else
  echo "30-grafana-litellm-role.sh: role 'grafana_litellm' created, but LiteLLM_SpendLogs does not exist yet: start LiteLLM once, then re-run" >&2
fi
