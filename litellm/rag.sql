-- LiteLLM's vector database: the tables litellm-pgvector
-- (docker-compose.platform.yml) stores and searches vector stores in, in the
-- database `litellm_rag` owned by the role `litellm_rag`. Run by
-- scripts/provision-litellm-rag.sh (make provision-litellm-rag) as the
-- superuser, after provision-app has created the database, role and the
-- vector extension. Idempotent.
--
-- Same shape as litellm-pgvector's own Prisma schema (prisma/schema.prisma:
-- tables `vector_stores` and `embeddings`, whose names it hard-codes), except
-- the embedding column: vector(1024), the output of qwen3-embedding:0.6b,
-- not the upstream vector(1536). A model with another dimension needs a new
-- column type *and* every row re-embedded.
--
-- Created as litellm_rag so the app role owns them: litellm-pgvector writes
-- (create store, add embeddings) as well as reads.

\set ON_ERROR_STOP on
SET client_min_messages = warning;

SET ROLE litellm_rag;

CREATE TABLE IF NOT EXISTS vector_stores (
  id             text PRIMARY KEY DEFAULT gen_random_uuid()::text,
  name           text NOT NULL,
  file_counts    jsonb,
  status         text NOT NULL DEFAULT 'completed',
  usage_bytes    integer DEFAULT 0,
  created_at     timestamp(3) NOT NULL DEFAULT now(),
  expires_after  jsonb,
  expires_at     timestamp(3),
  last_active_at timestamp(3),
  metadata       jsonb
);

CREATE TABLE IF NOT EXISTS embeddings (
  id              text PRIMARY KEY DEFAULT gen_random_uuid()::text,
  vector_store_id text NOT NULL REFERENCES vector_stores (id) ON DELETE CASCADE,
  content         text NOT NULL,
  embedding       vector(1024) NOT NULL,
  metadata        jsonb,
  created_at      timestamp(3) NOT NULL DEFAULT now()
);

-- Every search filters on the store first, then orders by cosine distance
-- (`embedding <=> $1::vector`).
CREATE INDEX IF NOT EXISTS embeddings_vector_store_id_idx ON embeddings (vector_store_id);
CREATE INDEX IF NOT EXISTS embeddings_embedding_hnsw_idx
  ON embeddings USING hnsw (embedding vector_cosine_ops);

-- The store declared in litellm/config.yaml (vector_store_registry). More
-- can be created through the API; their ids are then uuids.
INSERT INTO vector_stores (id, name, file_counts, metadata)
VALUES ('second-brain', 'Second cerveau',
        '{"in_progress": 0, "completed": 0, "failed": 0, "cancelled": 0, "total": 0}',
        '{"embedding_model": "qwen3-embedding:0.6b", "dimensions": 1024}')
ON CONFLICT (id) DO NOTHING;

RESET ROLE;
