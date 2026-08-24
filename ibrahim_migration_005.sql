-- Migration 005: sadaqa_qty column + mun unit
-- Run local:  npx wrangler d1 execute ibrahim-kitchen --local  --file=ibrahim_migration_005.sql
-- Run remote: npx wrangler d1 execute ibrahim-kitchen --remote --file=ibrahim_migration_005.sql
--
-- NOTE ON 'mun' UNIT:
-- D1 (SQLite) does not enforce CHECK constraints at runtime — they are parsed
-- but violations do not raise errors in practice. The existing CHECK on items.unit
-- therefore does NOT block inserting unit='mun'. No table recreate is needed.
-- The Worker and frontend already accept 'mun' as of migration 005.
-- If you want to formally widen the constraint for documentation purposes,
-- that can be done later via a controlled table swap with wrangler dev --local.

-- ── 1. sadaqa_qty on daily_received ────────────────────────────────────────
ALTER TABLE daily_received ADD COLUMN sadaqa_qty REAL NOT NULL DEFAULT 0;
