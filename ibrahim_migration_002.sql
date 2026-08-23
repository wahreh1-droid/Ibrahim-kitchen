-- Migration 002: day-wide received entries
-- Received qty + value PKR moves from ledger_rows to daily_received (one row per item per day)
-- Run: npx wrangler d1 execute ibrahim-kitchen --file=ibrahim_migration_002.sql
-- Run: npx wrangler d1 execute ibrahim-kitchen --remote --file=ibrahim_migration_002.sql

-- New table: day-wide received stock per item
CREATE TABLE IF NOT EXISTS daily_received (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  header_id     INTEGER NOT NULL REFERENCES daily_headers(id) ON DELETE CASCADE,
  item_id       INTEGER NOT NULL REFERENCES items(id),
  recv_qty      REAL    NOT NULL DEFAULT 0,
  recv_value_pkr REAL   NOT NULL DEFAULT 0,
  updated_by    TEXT    NOT NULL DEFAULT 'ibrahim',
  updated_at    TEXT    NOT NULL DEFAULT (datetime('now')),
  UNIQUE (header_id, item_id)
);

CREATE INDEX IF NOT EXISTS idx_daily_received_header ON daily_received(header_id);
CREATE INDEX IF NOT EXISTS idx_daily_received_item   ON daily_received(item_id);

-- Drop recv columns from ledger_rows once data is migrated.
-- For now: leave ledger_rows intact so existing data still reads correctly.
-- The Worker will read recv from daily_received and consumed from ledger_rows.
-- Existing ledger_rows.recv_qty / recv_value_pkr data is superseded — do NOT
-- backfill them into daily_received; Ibrahim will re-enter received for any
-- historical days he needs to correct.

-- Rebuild v_daily_item_totals to pull recv from daily_received
DROP VIEW IF EXISTS v_daily_item_totals;
CREATE VIEW v_daily_item_totals AS
SELECT
  ob.header_id,
  ob.item_id,
  ob.qty           AS opening_qty,
  ob.value_pkr     AS opening_pkr,
  COALESCE(dr.recv_qty, 0)       AS recv_qty_total,
  COALESCE(dr.recv_value_pkr, 0) AS recv_pkr_total,
  COALESCE(SUM(lr.used_qty), 0)       AS used_qty_total,
  COALESCE(SUM(lr.used_value_pkr), 0) AS used_pkr_total,
  ob.qty + COALESCE(dr.recv_qty, 0) - COALESCE(SUM(lr.used_qty), 0) AS remaining_qty
FROM opening_balances ob
LEFT JOIN daily_received dr
  ON dr.header_id = ob.header_id AND dr.item_id = ob.item_id
LEFT JOIN ledger_rows lr
  ON lr.header_id = ob.header_id AND lr.item_id = ob.item_id
GROUP BY ob.header_id, ob.item_id;

-- Rebuild monthly and yearly views to use new daily totals
DROP VIEW IF EXISTS v_monthly_item_totals;
CREATE VIEW v_monthly_item_totals AS
SELECT
  strftime('%Y-%m', dh.date) AS month,
  vd.item_id,
  SUM(vd.recv_qty_total)  AS recv_qty,
  SUM(vd.recv_pkr_total)  AS recv_pkr,
  SUM(vd.used_qty_total)  AS used_qty,
  SUM(vd.used_pkr_total)  AS used_pkr
FROM v_daily_item_totals vd
JOIN daily_headers dh ON dh.id = vd.header_id
GROUP BY month, vd.item_id;

DROP VIEW IF EXISTS v_yearly_item_totals;
CREATE VIEW v_yearly_item_totals AS
SELECT
  strftime('%Y', dh.date) AS year,
  vd.item_id,
  SUM(vd.recv_qty_total)  AS recv_qty,
  SUM(vd.recv_pkr_total)  AS recv_pkr,
  SUM(vd.used_qty_total)  AS used_qty,
  SUM(vd.used_pkr_total)  AS used_pkr
FROM v_daily_item_totals vd
JOIN daily_headers dh ON dh.id = vd.header_id
GROUP BY year, vd.item_id;
