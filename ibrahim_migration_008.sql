-- Migration 008: Unit set change — drop 'mun', add 'dozen'
-- Standardise on kg; mun is no longer a selectable unit (Ibrahim enters kg
-- directly, e.g. 2 mun = 80 kg). Adds 'dozen' for eggs etc.
--
-- Requires the items table-swap because the unit CHECK constraint is being
-- changed. Views that depend on items must be dropped and recreated (same
-- pattern as migration 005b).
--
-- Run remote: npx wrangler d1 execute ibrahim-kitchen --remote --file=ibrahim_migration_008.sql

-- FK enforcement must be OFF while items is dropped/recreated, because
-- ledger_rows, opening_balances, block_items and daily_received all hold
-- foreign keys onto items(id). Recreating the table with the same ids keeps
-- those references valid; the pragma just prevents the mid-swap check from
-- firing. (Migration 003 uses the same guard for its table swap.)
PRAGMA foreign_keys = OFF;

-- ── 1. Drop all views that depend on items / daily_received ──────────────────
DROP VIEW IF EXISTS v_yearly_item_totals;
DROP VIEW IF EXISTS v_monthly_item_totals;
DROP VIEW IF EXISTS v_daily_item_totals;
DROP VIEW IF EXISTS v_daily_block_totals;

-- ── 2. Recreate items with new unit CHECK (kg,g,L,pcs,dozen) — no mun ────────
CREATE TABLE items_new (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  name_ur     TEXT    NOT NULL,
  name_en     TEXT,
  name_roman  TEXT,
  unit        TEXT    NOT NULL DEFAULT 'kg'
              CHECK (unit IN ('kg','g','L','pcs','dozen')),
  is_active   INTEGER NOT NULL DEFAULT 1,
  sort_order  INTEGER NOT NULL DEFAULT 99,
  created_by  TEXT,
  created_at  TEXT    NOT NULL DEFAULT (datetime('now'))
);

-- Migrate rows; any existing 'mun' becomes 'kg'. (Quantities are test data and
-- are being wiped separately, so no numeric rescale is needed here.)
INSERT INTO items_new
  SELECT id, name_ur, name_en, name_roman,
         CASE WHEN unit = 'mun' THEN 'kg' ELSE unit END,
         is_active, sort_order, created_by, created_at
  FROM items;

DROP TABLE items;
ALTER TABLE items_new RENAME TO items;

PRAGMA foreign_keys = ON;

-- ── 3. Recreate views (unchanged definitions, carried from 005b) ─────────────
CREATE VIEW v_daily_block_totals AS
SELECT
  lr.header_id,
  lr.block_id,
  lr.meal_type,
  lr.item_id,
  SUM(lr.used_qty)       AS used_qty,
  SUM(lr.used_value_pkr) AS used_pkr
FROM ledger_rows lr
GROUP BY lr.header_id, lr.block_id, lr.meal_type, lr.item_id;

CREATE VIEW v_daily_item_totals AS
SELECT
  ob.header_id,
  ob.item_id,
  ob.qty                                   AS opening_qty,
  ob.value_pkr                             AS opening_pkr,
  COALESCE(dr.recv_qty,          0)        AS recv_qty_total,
  COALESCE(dr.recv_value_pkr,    0)        AS recv_pkr_total,
  COALESCE(dr.sadaqa_qty,        0)        AS sadaqa_qty_total,
  COALESCE(SUM(lr.used_qty),     0)        AS used_qty_total,
  COALESCE(SUM(lr.used_value_pkr), 0)      AS used_pkr_total,
  ob.qty
    + COALESCE(dr.recv_qty,    0)
    + COALESCE(dr.sadaqa_qty,  0)
    - COALESCE(SUM(lr.used_qty), 0)        AS remaining_qty
FROM opening_balances ob
LEFT JOIN daily_received dr
  ON dr.header_id = ob.header_id AND dr.item_id = ob.item_id
LEFT JOIN ledger_rows lr
  ON lr.header_id = ob.header_id AND lr.item_id = ob.item_id
GROUP BY ob.header_id, ob.item_id;

CREATE VIEW v_monthly_item_totals AS
SELECT
  strftime('%Y-%m', dh.entry_date) AS month,
  vd.item_id,
  SUM(vd.recv_qty_total)    AS recv_qty,
  SUM(vd.recv_pkr_total)    AS recv_pkr,
  SUM(vd.sadaqa_qty_total)  AS sadaqa_qty,
  SUM(vd.used_qty_total)    AS used_qty,
  SUM(vd.used_pkr_total)    AS used_pkr
FROM v_daily_item_totals vd
JOIN daily_headers dh ON dh.id = vd.header_id
GROUP BY month, vd.item_id;

CREATE VIEW v_yearly_item_totals AS
SELECT
  strftime('%Y', dh.entry_date) AS year,
  vd.item_id,
  SUM(vd.recv_qty_total)    AS recv_qty,
  SUM(vd.recv_pkr_total)    AS recv_pkr,
  SUM(vd.sadaqa_qty_total)  AS sadaqa_qty,
  SUM(vd.used_qty_total)    AS used_qty,
  SUM(vd.used_pkr_total)    AS used_pkr
FROM v_daily_item_totals vd
JOIN daily_headers dh ON dh.id = vd.header_id
GROUP BY year, vd.item_id;
