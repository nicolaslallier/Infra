-- pgcrypto covers common hashing/encryption needs for apps.
-- uuid-ossp is deliberately omitted: PG18 has native uuidv7()/uuidv4().
CREATE EXTENSION IF NOT EXISTS pgcrypto;
