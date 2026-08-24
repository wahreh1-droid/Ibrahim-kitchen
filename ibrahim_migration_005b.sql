-- Migration 005b: widen unit CHECK constraint to include 'mun'
-- Run remote: npx wrangler d1 execute ibrahim-kitchen --remote --file=ibrahim_migration_005b.sql

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
