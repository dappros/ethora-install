// ai-pg-schema.js - creates the ai-service's Postgres schema (the pgvector
// extension and the documents table) from the drizzle migrations shipped in
// the ethora-ai image: the compose bundle's form of the host installer's
// ensure_ai_postgres_schema (deploy/scripts/setup-node-services.sh).
// Idempotent: every statement that reports "already exists" is skipped, and
// each migration file is applied in name order.
//
//   AI_PG_URL=postgresql://... AI_PG_APP_DIR=/app/ai-service \
//   AI_PG_MIGRATIONS_DIR=/app/ai-service/drizzle node ai-pg-schema.js
const fs = require('fs')
const path = require('path')
const { createRequire } = require('module')

async function main() {
  const appDir = (process.env.AI_PG_APP_DIR || process.cwd()).replace(/\/$/, '')
  const pgUrl = process.env.AI_PG_URL || process.env.PG_URL || ''
  const dir = process.env.AI_PG_MIGRATIONS_DIR || path.join(appDir, 'drizzle')
  if (!pgUrl) throw new Error('AI_PG_URL is empty')
  // pg comes from the ai-service's own node_modules.
  const { Client } = createRequire(`${appDir}/package.json`)('pg')
  const files = fs.readdirSync(dir).filter((f) => f.endsWith('.sql')).sort()
  if (!files.length) throw new Error(`no .sql migrations in ${dir}`)

  // 42P07 duplicate table, 42710 duplicate object, 42701 duplicate column.
  const ignorable = (e) => ['42P07', '42710', '42701'].includes(String(e && e.code)) || /already exists/i.test(String(e && e.message))
  const client = new Client({ connectionString: pgUrl })
  await client.connect()
  try {
    for (const f of files) {
      const statements = fs.readFileSync(path.join(dir, f), 'utf8').split(/--> statement-breakpoint/g).map((s) => s.trim()).filter(Boolean)
      for (const statement of statements) {
        try { await client.query(statement) } catch (e) { if (!ignorable(e)) throw e }
      }
    }
    const ext = await client.query("SELECT 1 FROM pg_extension WHERE extname = 'vector' LIMIT 1")
    if (ext.rowCount === 0) throw new Error('pgvector extension was not created (is this a Postgres with pgvector?)')
    const tbl = await client.query("SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'documents' LIMIT 1")
    if (tbl.rowCount === 0) throw new Error('documents table was not created')
  } finally {
    await client.end().catch(() => {})
  }
  console.log(`[ai] Postgres schema ready (${files.length} migration file(s))`)
}

main().catch((e) => { console.error(`[ai] ${e && e.message ? e.message : e}`); process.exit(1) })
