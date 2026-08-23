-- Migration 005: sadaqa_qty column + mun unit
-- Run local:  npx wrangler d1 execute ibrahim-kitchen --local  --file=ibrahim_migration_005.sql
-- Run remote: npx wrangler d1 execute ibrahim-kitchen --remote --file=ibrahim_migration_005.sql
--
-- D1 does not support ALTER TABLE ... ADD CONSTRAINT, so the unit CHECK
-- constraint is widened by recreating the items table.

-- ── 1. sadaqa_qty on daily_received ────────────────────────────────────────
ALTER TABLE daily_received ADD COLUMN sadaqa_qty REAL NOT NULL DEFAULT 0;

-- ── 2. Widen unit CHECK constraint to include 'mun' ────────────────────────
-- D1 does not support DROP CONSTRAINT, so we rename → recreate → copy → drop.

CREATE TABLE items_new (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  name_ur     TEXT    NOT NULL,
  name_en     TEXT,
  name_roman  TEXT,
  unit        TEXT    NOT NULL DEFAULT 'kg'
              CHECK (unit IN ('kg','g','L','pcs','mun')),
  is_active   INTEGER NOT NULL DEFAULT 1,
  sort_order  INTEGER NOT NULL DEFAULT 99,
  created_by  TEXT,
  created_at  TEXT    NOT NULL DEFAULT (datetime('now'))
);

INSERT INTO items_new
  SELECT id, name_ur, name_en, name_roman, unit, is_active, sort_order, created_by, created_at
  FROM items;

DROP TABLE items;
ALTER TABLE items_new RENAME TO items;
