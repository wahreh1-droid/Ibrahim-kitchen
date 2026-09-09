-- Migration 014: Reinstate 'mun' as a selectable unit.
--
-- Migration 008 rebuilt items with CHECK (unit IN ('kg','g','L','pcs','dozen'))
-- and dropped 'mun'. Ibrahim now wants 'mun' back as a distinct unit, so we
-- WIDEN the CHECK to include it. 'dozen' is retained; no existing row changes.
--
-- SQLite cannot alter a CHECK in place, so items is rebuilt (same table-swap
-- pattern as 005b / 008). The items_new definition below reproduces the CURRENT
-- live schema exactly — read from sqlite_master before writing this — INCLUDING
-- is_temporary, which was added by ALTER after 008 and is NOT in 008's file.
--
-- Dependent views are dropped and recreated around the swap (definitions copied
-- verbatim from the live database).
--
-- SAFETY: D1 Time Travel covers this. Capture the current bookmark first:
--   npx wrangler d1 time-travel info ibrahim-kitchen
-- so you can restore if anything looks wrong afterwards.
--
-- Run remote (preferred):
--   npx wrangler d1 execute ibrahim-kitchen --remote --file=ibrahim_migration_014.sql
-- If --file returns auth error 10000, use the single --command fallback (see chat).

PRAGMA foreign_keys = OFF;

-- 1. Drop dependent views ----------------------------------------------------
DROP VIEW IF EXISTS v_yearly_item_totals;
DROP VIEW IF EXISTS v_monthly_item_totals;
DROP VIEW IF EXISTS v_daily_item_totals;
DROP VIEW IF EXISTS v_daily_block_totals;

-- 2. Recreate items with widened unit CHECK (adds 'mun') ---------------------
--    Columns are identical to the live table.
CREATE TABLE items_new (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  name_ur      TEXT    NOT NULL,
  name_en      TEXT,
  name_roman   TEXT,
  unit         TEXT    NOT NULL DEFAULT 'kg'
               CHECK (unit IN ('kg','g','L','pcs','dozen','mun')),
  is_active    INTEGER NOT NULL DEFAULT 1,
  sort_order   INTEGER NOT NULL DEFAULT 99,
  created_by   TEXT,
  created_at   TEXT    NOT NULL DEFAULT (datetime('now')),
  is_temporary INTEGER NOT NULL DEFAULT 0
);

-- 3. Copy every row unchanged (all existing units remain valid) --------------
INSERT INTO items_new
  (id, name_ur, name_en, name_roman, unit, is_active, sort_order, created_by, created_at, is_temporary)
  SELECT
   id, name_ur, name_en, name_roman, unit, is_active, sort_order, created_by, created_at, is_temporary
  FROM items;

-- 4. Swap in the new table ---------------------------------------------------
DROP TABLE items;
ALTER TABLE items_new RENAME TO items;

PRAGMA foreign_keys = ON;

-- 5. Recreate views (verbatim from live) -------------------------------------
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
