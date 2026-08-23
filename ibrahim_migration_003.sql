-- Migration 003: Three meals per block (breakfast/lunch/dinner)
-- Run local:  npx wrangler d1 execute ibrahim-kitchen --file=ibrahim_migration_003.sql
-- Run remote: npx wrangler d1 execute ibrahim-kitchen --remote --file=ibrahim_migration_003.sql

PRAGMA foreign_keys = OFF;

-- Step 1: Drop all views first
DROP VIEW IF EXISTS v_yearly_item_totals;
DROP VIEW IF EXISTS v_monthly_item_totals;
DROP VIEW IF EXISTS v_daily_item_totals;
DROP VIEW IF EXISTS v_daily_block_totals;

-- Step 2: Create new ledger_rows with meal_type under temp name
CREATE TABLE ledger_rows_m003 (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  header_id       INTEGER NOT NULL REFERENCES daily_headers(id) ON DELETE CASCADE,
  block_id        INTEGER NOT NULL REFERENCES meal_blocks(id),
  item_id         INTEGER NOT NULL REFERENCES items(id),
  meal_type       TEXT    NOT NULL DEFAULT 'lunch'
                          CHECK (meal_type IN ('breakfast','lunch','dinner')),
  used_qty        REAL    NOT NULL DEFAULT 0,
  used_value_pkr  REAL    NOT NULL DEFAULT 0,
  created_by      TEXT    NOT NULL DEFAULT 'ibrahim',
  updated_at      TEXT    NOT NULL DEFAULT (datetime('now')),
  UNIQUE (header_id, block_id, item_id, meal_type)
);

-- Step 3: Copy existing rows as 'lunch', drop block 3 (Naashta) rows
INSERT INTO ledger_rows_m003
  (id, header_id, block_id, item_id, meal_type,
   used_qty, used_value_pkr, created_by, updated_at)
SELECT
  id, header_id, block_id, item_id, 'lunch',
  used_qty, used_value_pkr, created_by, updated_at
FROM ledger_rows
WHERE block_id IN (1, 2);

-- Step 4: Drop old table, rename new one
DROP TABLE ledger_rows;
ALTER TABLE ledger_rows_m003 RENAME TO ledger_rows;

-- Step 5: Recreate indexes
CREATE INDEX IF NOT EXISTS idx_lr_header ON ledger_rows(header_id);
CREATE INDEX IF NOT EXISTS idx_lr_block  ON ledger_rows(block_id);
CREATE INDEX IF NOT EXISTS idx_lr_item   ON ledger_rows(item_id);
CREATE INDEX IF NOT EXISTS idx_lr_meal   ON ledger_rows(meal_type);

PRAGMA foreign_keys = ON;

-- Step 6: Deactivate Naashta block
UPDATE meal_blocks SET is_active = 0 WHERE id = 3;

-- Step 7: Recreate all views now that ledger_rows is stable
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
  ob.qty                                AS opening_qty,
  ob.value_pkr                          AS opening_pkr,
  COALESCE(dr.recv_qty,          0)     AS recv_qty_total,
  COALESCE(dr.recv_value_pkr,    0)     AS recv_pkr_total,
  COALESCE(SUM(lr.used_qty),     0)     AS used_qty_total,
  COALESCE(SUM(lr.used_value_pkr), 0)   AS used_pkr_total,
  ob.qty
    + COALESCE(dr.recv_qty, 0)
    - COALESCE(SUM(lr.used_qty), 0)     AS remaining_qty
FROM opening_balances ob
LEFT JOIN daily_received dr
  ON dr.header_id = ob.header_id AND dr.item_id = ob.item_id
LEFT JOIN ledger_rows lr
  ON lr.header_id = ob.header_id AND lr.item_id = ob.item_id
GROUP BY ob.header_id, ob.item_id;

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
