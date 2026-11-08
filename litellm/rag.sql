-- LiteLLM's read-only window onto Jarvis's RAG chunks (pgvector), for the
-- litellm-pgvector service (docker-compose.platform.yml). Run by
-- scripts/provision-litellm-rag.sh (make provision-litellm-rag) as the
-- superuser, in the jarvis database. Idempotent: re-run it after a Jarvis
-- migration renames file_chunks/files columns, or after a restore.
--
-- litellm-pgvector queries two fixed table names, `vector_stores` and
-- `embeddings`, with the columns of its own Prisma schema. Here they are
-- views in a schema of their own (litellm_rag, reached through
-- ?schema=litellm_rag in its DATABASE_URL), mapping Jarvis's tables:
--   file_chunks.id::text      -> id
--   file_chunks.chunk_text    -> content
--   file_chunks.embedding     -> embedding  (vector(768), nomic-embed-text-v1.5)
--   files.filename, ...       -> metadata   (jsonb; `filename` is what search shows)
--   'jarvis-files'            -> vector_store_id
-- Jarvis stays the only writer: the role can SELECT and nothing else, so
-- litellm-pgvector's create/insert endpoints fail, which is intended.
--
-- Why the views go through SQL functions: a plain view over file_chunks
-- would be a dependency Postgres enforces, and a Jarvis Alembic migration
-- altering file_chunks.embedding (a dimension change) or dropping the table
-- would then fail with "cannot alter type of a column used by a view".
-- A LANGUAGE sql body written as a string is not dependency-tracked, and a
-- STABLE, non-SECURITY-DEFINER, single-SELECT set-returning SQL function is
-- inlined by the planner, so the vector_store_id filter is still pushed down.
-- Inlined, it runs with the caller's rights, hence the direct SELECT grants.
--
-- psql variable: ragpass (LITELLM_RAG_DB_PASSWORD).

\set ON_ERROR_STOP on

SELECT format('CREATE ROLE litellm_rag WITH LOGIN PASSWORD %L', :'ragpass')
WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'litellm_rag')
\gexec
SELECT format('ALTER ROLE litellm_rag WITH LOGIN PASSWORD %L', :'ragpass')
WHERE EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'litellm_rag')
\gexec

-- Never writes, whatever a later grant says.
ALTER ROLE litellm_rag SET default_transaction_read_only = on;
GRANT CONNECT ON DATABASE jarvis TO litellm_rag;

BEGIN;

CREATE SCHEMA IF NOT EXISTS litellm_rag;
REVOKE ALL ON SCHEMA litellm_rag FROM PUBLIC;
GRANT USAGE ON SCHEMA litellm_rag TO litellm_rag;

GRANT USAGE ON SCHEMA public TO litellm_rag;
GRANT SELECT ON public.file_chunks, public.files TO litellm_rag;

-- litellm-pgvector connects with ?schema=litellm_rag, and Prisma turns that
-- into `SET search_path = "litellm_rag"`: public, where the vector
-- extension lives, drops out, and its search query (`$1::vector`,
-- `embedding <=> ...`) would fail with "type vector does not exist" /
-- "operator does not exist". So the schema gets its own name for both: a
-- domain over public.vector and a cosine-distance operator on public.vector.
DO $do$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_type t
                   JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
                  WHERE n.nspname = 'litellm_rag' AND t.typname = 'vector') THEN
    CREATE DOMAIN litellm_rag.vector AS public.vector;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_operator o
                   JOIN pg_catalog.pg_namespace n ON n.oid = o.oprnamespace
                  WHERE n.nspname = 'litellm_rag' AND o.oprname = '<=>') THEN
    CREATE OPERATOR litellm_rag.<=> (
      LEFTARG = public.vector, RIGHTARG = public.vector,
      FUNCTION = public.cosine_distance, COMMUTATOR = OPERATOR(litellm_rag.<=>)
    );
  END IF;
END
$do$;
GRANT USAGE ON DOMAIN litellm_rag.vector TO litellm_rag;

CREATE OR REPLACE FUNCTION litellm_rag.jarvis_file_chunks()
RETURNS TABLE (
  id text,
  vector_store_id text,
  content text,
  embedding vector,
  metadata jsonb,
  created_at timestamptz
)
LANGUAGE sql STABLE
AS $fn$
  SELECT fc.id::text,
         'jarvis-files'::text,
         fc.chunk_text,
         fc.embedding,
         jsonb_build_object(
           'filename', f.filename,
           'file_id', f.id,
           'chunk_index', fc.chunk_index,
           'content_type', f.content_type,
           'source', 'jarvis'
         ),
         fc.created_at
    FROM public.file_chunks fc
    JOIN public.files f ON f.id = fc.file_id
$fn$;

CREATE OR REPLACE FUNCTION litellm_rag.jarvis_file_count()
RETURNS bigint
LANGUAGE sql STABLE
AS $fn$
  SELECT count(DISTINCT file_id) FROM public.file_chunks
$fn$;

CREATE OR REPLACE VIEW litellm_rag.embeddings AS
  SELECT * FROM litellm_rag.jarvis_file_chunks();

-- One store per row; its id is the vector_store_id clients pass to LiteLLM
-- (vector_store_registry in litellm/config.yaml).
CREATE OR REPLACE VIEW litellm_rag.vector_stores AS
  SELECT 'jarvis-files'::text AS id,
         'Jarvis - documents'::text AS name,
         jsonb_build_object('in_progress', 0, 'completed', n, 'failed', 0,
                            'cancelled', 0, 'total', n) AS file_counts,
         'completed'::text AS status,
         0 AS usage_bytes,
         NULL::jsonb AS expires_after,
         NULL::timestamptz AS expires_at,
         NULL::timestamptz AS last_active_at,
         jsonb_build_object('source', 'jarvis', 'table', 'file_chunks') AS metadata,
         TIMESTAMPTZ '2026-11-08 00:00:00+00' AS created_at
    FROM (SELECT litellm_rag.jarvis_file_count() AS n) s;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA litellm_rag FROM PUBLIC;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA litellm_rag TO litellm_rag;
GRANT SELECT ON litellm_rag.embeddings, litellm_rag.vector_stores TO litellm_rag;

COMMIT;
