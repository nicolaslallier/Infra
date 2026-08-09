-- pgcrypto covers common hashing/encryption needs for apps.
-- uuid-ossp is deliberately omitted: PG18 has native uuidv7()/uuidv4().
-- vector (pgvector) is created per app database in 10-provision-apps.sh —
-- this file only runs against POSTGRES_DB, not the per-app DBs.
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS vector;
