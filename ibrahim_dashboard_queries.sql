-- =============================================================================
-- Ibrahim Shah — Kitchen Ledger — Dashboard Query Set
-- Target: Cloudflare D1 (SQLite)
-- Database: ibrahim-kitchen / f49f9772-a241-4da9-8784-a08d408cfe5e
-- =============================================================================
--
-- BEFORE RUNNING — reconcile column names.
-- The handoff describes the tables but not their exact columns. The names below
-- are inferred. Check these against schema.sql and rename as needed:
--
--   daily_headers      : entry_date, hijri_date, student_count, is_locked
--   opening_balances   : entry_date, item_id, opening_qty
--   ledger_rows        : entry_date, block_id, item_id,
--                        recv_qty, recv_value_pkr, used_qty, used_value_pkr
--   items              : id, name_ur, name_en, name_roman, unit, is_active
--   meal_blocks        : id, name_ur, sort_order
--   block_items        : block_id, item_id
--   audit_log          : id, table_name, row_ref, field, old_value, new_value,
--                        user_id, changed_at
--
-- Parameters use numbered placeholders (?1, ?2 ...). D1 supports these, and
-- numbering matters here because several queries reference the same date twice.
--
-- =============================================================================


-- =============================================================================
-- SECTION 0 — MIGRATION
-- Required by the opening-balance decisions. Additive only; safe on the
-- deployed schema since there is no production data yet.
-- =============================================================================

-- Distinguishes اصل گنتی (physical count) from درستی (correction).
-- The committee reads these very differently.
ALTER TABLE audit_log ADD COLUMN reason_type TEXT;      -- 'physical_count' | 'correction'
ALTER TABLE audit_log ADD COLUMN reason_note TEXT;      -- free text, Urdu

-- Set when an upstream edit invalidates this day's carried opening balances.
-- Surfaced as a banner in the day view and a flag in reports.
ALTER TABLE daily_headers ADD COLUMN is_stale INTEGER NOT NULL DEFAULT 0;

-- Required for the upsert in Section 3. Confirm it is not already among the
-- 9 deployed indexes before creating.
CREATE UNIQUE INDEX IF NOT EXISTS ux_ledger_rows_day_block_item
  ON ledger_rows (entry_date, block_id, item_id);

CREATE UNIQUE INDEX IF NOT EXISTS ux_opening_balances_day_item
  ON opening_balances (entry_date, item_id);


-- =============================================================================
-- SECTION 1 — DAY CREATION
-- Fires when the masthead is opened on a date with no daily_headers row.
-- Wrap both statements in one transaction (D1: use batch()).
-- =============================================================================

-- 1a. Create the header.
INSERT INTO daily_headers (entry_date, hijri_date, student_count, is_locked, is_stale)
VALUES (?1, ?2, ?3, 0, 0);


-- 1b. Populate opening balances for EVERY active item (option A).
--
-- Carry rule: value comes from the most recent PRIOR day that has a row for
-- that item — not literally yesterday. This is what makes skipped days work.
-- Items never seen before land at 0.
--
-- Closing on that prior day = opening + received(all blocks) − used(all blocks).
-- No block filter anywhere: one physical store, one number.

WITH last_day AS (
  SELECT ob.item_id,
         MAX(ob.entry_date) AS last_date
  FROM opening_balances ob
  WHERE ob.entry_date < ?1
  GROUP BY ob.item_id
),
prev_closing AS (
  SELECT
    ld.item_id,
    ob.opening_qty
      + COALESCE(SUM(lr.recv_qty), 0)
      - COALESCE(SUM(lr.used_qty), 0) AS closing_qty
  FROM last_day ld
  JOIN opening_balances ob
    ON  ob.item_id    = ld.item_id
    AND ob.entry_date = ld.last_date
  LEFT JOIN ledger_rows lr
    ON  lr.item_id    = ld.item_id
    AND lr.entry_date = ld.last_date
  GROUP BY ld.item_id, ob.opening_qty
)
INSERT INTO opening_balances (entry_date, item_id, opening_qty)
SELECT ?1,
       i.id,
       COALESCE(pc.closing_qty, 0)
FROM items i
LEFT JOIN prev_closing pc ON pc.item_id = i.id
WHERE i.is_active = 1;


-- =============================================================================
-- SECTION 2 — LOAD A DAY  (GET /api/day/:date)
--
-- Returns the WHOLE day, all three blocks — not just the selected block.
-- Remaining stock is day-wide, so if بنات already drew 40kg of آٹا this morning,
-- بنین must see it. The block selector is a client-side filter over this payload.
-- =============================================================================

-- 2a. Header.
SELECT entry_date,
       hijri_date,
       student_count,
       is_locked,
       is_stale
FROM daily_headers
WHERE entry_date = ?1;


-- 2b. Blocks for the sub-selector.
SELECT id, name_ur
FROM meal_blocks
ORDER BY sort_order;


-- 2c. DAY-WIDE per-item position. This drives the persistent remaining column.
--     Opening is day-scoped; received and used are summed across ALL blocks.
SELECT
  i.id                                AS item_id,
  i.name_ur,
  i.name_en,
  i.unit,
  ob.opening_qty,
  COALESCE(SUM(lr.recv_qty),  0)      AS recv_qty_total,
  COALESCE(SUM(lr.used_qty),  0)      AS used_qty_total,
  ob.opening_qty
    + COALESCE(SUM(lr.recv_qty), 0)
    - COALESCE(SUM(lr.used_qty), 0)   AS remaining_qty
FROM opening_balances ob
JOIN items i
  ON i.id = ob.item_id
LEFT JOIN ledger_rows lr
  ON  lr.item_id    = ob.item_id
  AND lr.entry_date = ob.entry_date
WHERE ob.entry_date = ?1
GROUP BY i.id, i.name_ur, i.name_en, i.unit, ob.opening_qty
ORDER BY i.name_ur;


-- 2d. Grid rows, per block × item.
--     LEFT JOIN so items assigned to a block render as empty rows before any
--     entry exists. Returns all blocks at once.
SELECT
  bi.block_id,
  mb.name_ur                          AS block_name_ur,
  i.id                                AS item_id,
  i.name_ur,
  i.name_en,
  i.unit,
  COALESCE(lr.recv_qty,        0)     AS recv_qty,
  COALESCE(lr.recv_value_pkr,  0)     AS recv_value_pkr,
  COALESCE(lr.used_qty,        0)     AS used_qty,
  COALESCE(lr.used_value_pkr,  0)     AS used_value_pkr
FROM block_items bi
JOIN meal_blocks mb ON mb.id = bi.block_id
JOIN items       i  ON i.id  = bi.item_id AND i.is_active = 1
LEFT JOIN ledger_rows lr
  ON  lr.block_id   = bi.block_id
  AND lr.item_id    = bi.item_id
  AND lr.entry_date = ?1
ORDER BY mb.sort_order, i.name_ur;


-- =============================================================================
-- SECTION 3 — SAVE A BLOCK  (POST /api/day/:date)
-- =============================================================================

-- 3a. Lock guard. Run first; abort the write if this returns 1.
SELECT is_locked FROM daily_headers WHERE entry_date = ?1;


-- 3b. Upsert one ledger row. Batch one of these per edited row.
INSERT INTO ledger_rows
  (entry_date, block_id, item_id, recv_qty, recv_value_pkr, used_qty, used_value_pkr)
VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
ON CONFLICT (entry_date, block_id, item_id) DO UPDATE SET
  recv_qty       = excluded.recv_qty,
  recv_value_pkr = excluded.recv_value_pkr,
  used_qty       = excluded.used_qty,
  used_value_pkr = excluded.used_value_pkr;


-- 3c. Audit entry. One per changed field, capturing old → new.
--     On first insert old_value is NULL; that reads correctly as "created".
INSERT INTO audit_log
  (table_name, row_ref, field, old_value, new_value, user_id, changed_at, reason_type, reason_note)
VALUES
  ('ledger_rows', ?1, ?2, ?3, ?4, ?5, datetime('now'), ?6, ?7);
  -- row_ref: 'YYYY-MM-DD|block_id|item_id'


-- 3d. Mark downstream days stale after ANY edit to a past day.
--     Blunt on purpose — flags every later day rather than tracing which items
--     actually propagate. Cheap, and it never under-reports.
--     Nothing is silently recalculated; Ibrahim decides per day.
UPDATE daily_headers
SET is_stale = 1
WHERE entry_date > ?1;


-- 3e. Clear the stale flag once Ibrahim accepts or overrides on that day.
UPDATE daily_headers
SET is_stale = 0
WHERE entry_date = ?1;


-- =============================================================================
-- SECTION 4 — OPENING BALANCE EDIT
-- The reconciliation path: Ibrahim weighs the store and the ledger disagrees.
-- reason_type is required here — this is the whole point of the migration.
-- =============================================================================

UPDATE opening_balances
SET opening_qty = ?3
WHERE entry_date = ?1
  AND item_id    = ?2;

INSERT INTO audit_log
  (table_name, row_ref, field, old_value, new_value, user_id, changed_at, reason_type, reason_note)
VALUES
  ('opening_balances', ?1 || '|' || ?2, 'opening_qty', ?4, ?3, ?5, datetime('now'), ?6, ?7);
  -- ?6 reason_type: 'physical_count' (اصل گنتی) | 'correction' (درستی)

-- Then run 3d to flag downstream days.


-- =============================================================================
-- SECTION 5 — LOCK / UNLOCK
-- A locked day is an immutable anchor. Unlocking is itself an audit event.
-- =============================================================================

UPDATE daily_headers SET is_locked = ?2 WHERE entry_date = ?1;

INSERT INTO audit_log
  (table_name, row_ref, field, old_value, new_value, user_id, changed_at, reason_type, reason_note)
VALUES
  ('daily_headers', ?1, 'is_locked', ?3, ?2, ?4, datetime('now'), 'correction', ?5);


-- =============================================================================
-- SECTION 6 — REPORTS  (GET /api/report)
-- These hit the views only. Column lists are SELECT * because the view
-- definitions are not in the handoff — narrow them once you check schema.sql.
-- jsPDF renders client-side from this JSON.
-- =============================================================================

-- 6a. Daily summary — all blocks combined.
SELECT * FROM v_daily_item_totals WHERE entry_date = ?1;

-- 6b. Daily drill-down by block.
SELECT * FROM v_daily_block_totals WHERE entry_date = ?1;

-- 6c. Weekly — inclusive date range.
SELECT * FROM v_daily_item_totals WHERE entry_date BETWEEN ?1 AND ?2;

-- 6d. Monthly. Period arrives as 'YYYY-MM'.
SELECT * FROM v_monthly_item_totals WHERE period = ?1;

-- 6e. Yearly. Period arrives as 'YYYY'.
SELECT * FROM v_yearly_item_totals WHERE period = ?1;

-- 6f. Stale-day flag for the report header — so an auditor sees that the
--     ledger knows it is inconsistent, rather than finding out later.
SELECT entry_date
FROM daily_headers
WHERE entry_date BETWEEN ?1 AND ?2
  AND is_stale = 1
ORDER BY entry_date;


-- =============================================================================
-- SECTION 7 — QURBANI  (POST /api/qurbani)
-- Separate ledger. Never joins to ledger_rows — the exclusion from daily
-- averages is structural, not a filter someone can forget to apply.
-- =============================================================================

INSERT INTO qurbani_entries
  (entry_date, item_id, qty, est_value_pkr, donor_name, disposal, proceeds_pkr, receipt_id)
VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);

SELECT q.*, i.name_ur, i.name_en, i.unit
FROM qurbani_entries q
JOIN items i ON i.id = q.item_id
WHERE q.entry_date BETWEEN ?1 AND ?2
ORDER BY q.entry_date;


-- =============================================================================
-- SECTION 8 — ITEM CATALOG  (GET/POST /api/items)
-- =============================================================================

SELECT id, name_ur, name_en, name_roman, unit
FROM items
WHERE is_active = 1
ORDER BY name_ur;

-- New item. name_en and name_roman come from the Qwen2.5 translation call.
INSERT INTO items (name_ur, name_en, name_roman, unit, is_active)
VALUES (?1, ?2, ?3, ?4, 1);

-- Soft delete — history preserved.
UPDATE items SET is_active = 0 WHERE id = ?1;

-- Assign / unassign an item to a block.
INSERT OR IGNORE INTO block_items (block_id, item_id) VALUES (?1, ?2);
DELETE FROM block_items WHERE block_id = ?1 AND item_id = ?2;
