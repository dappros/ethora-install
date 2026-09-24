-- Ethora.com platform, copyright: Dappros Ltd (c) 2026, all rights reserved
--
-- ai-service Postgres schema baseline + forward-compatible migrations.
--
-- Applied by deploy/scripts/setup-ai-postgres.sh after the managed Postgres
-- container becomes ready. Idempotent end-to-end (CREATE ... IF NOT EXISTS,
-- ADD COLUMN IF NOT EXISTS) so re-runs on existing installs are no-ops and
-- pre-existing tables aren't disturbed.
--
-- This file is the source of truth for what columns the `documents` table
-- needs. If you add a column to services/ai/ai-service/src/dbpg/schema.ts,
-- add a matching `ADD COLUMN IF NOT EXISTS` here in the same PR. Existing
-- prod hosts pick it up on the next update.sh run; fresh installs pick it
-- up at first install. There's no separate "migrations" directory — drift
-- between code and DB is the bug class we're trying to avoid.

-- pgvector extension. The container image (pgvector/pgvector:pg16) ships
-- with the extension's files but `CREATE EXTENSION` still has to run
-- per-database before queries can use it. Safe to re-run.
CREATE EXTENSION IF NOT EXISTS vector;

-- documents: RAG corpus (chunked website / doc content + their embeddings).
CREATE TABLE IF NOT EXISTS documents (
    id          serial PRIMARY KEY,
    "appId"     text NOT NULL,
    -- Phase 1: per-Agent RAG namespace. Backfill columns rather than
    -- failing the deploy if they're missing (which is what happens on
    -- prod installs that were provisioned before the Phase 1 schema
    -- change). New rows always carry agentId; legacy rows keep it NULL
    -- and are still queryable via the appId fallback in [openai.ts].
    "agentId"   text,
    url         text,
    origin_url  text,
    content     text NOT NULL,
    embedding   vector(256),
    created_at  timestamp NOT NULL DEFAULT now(),
    updated_at  timestamp NOT NULL DEFAULT now()
);

-- Forward-compatible columns. Each one is wrapped in its own IF NOT EXISTS
-- so a partial migration history doesn't break the deploy. Order doesn't
-- matter; group by feature for clarity.
ALTER TABLE documents ADD COLUMN IF NOT EXISTS "agentId" text;

-- Indexes. HNSW for vector similarity (the hot path in retrieval) + a btree
-- on agentId for the per-Agent partition lookup.
CREATE INDEX IF NOT EXISTS embedding_index
    ON documents USING hnsw (embedding vector_cosine_ops);

CREATE INDEX IF NOT EXISTS documents_agent_id_idx
    ON documents ("agentId");
