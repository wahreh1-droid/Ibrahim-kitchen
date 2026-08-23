-- =============================================================================
-- Ibrahim Shah — Kitchen Ledger — Dashboard Query Set  (v2)
-- Target: Cloudflare D1 (SQLite)
--
-- REFERENCE FILE — do not execute as a whole. These are query bodies for the
-- Worker route handlers. The runnable part lives in ibrahim_migration_001.sql.
--
-- v2 rewritten against the real deployed schema. What changed from v1:
--   - ledger_rows and opening_balances key off header_id, NOT entry_date.
--     Every join now goes through daily_headers.
--   - daily_headers.locked (not is_locked), .students_fed (not student_count)
--   - opening_balances.qty / .value_pkr (not opening_qty)
--   - audit_log uses row_id INTEGER, field_name, changed_by — so audit points
--     at a real row id. The composite-string row_ref idea in v1 is gone.
--   - ordering uses items.sort_order; is_active filtered on blocks and
--     block_items as well as items
--
-- Placeholders are numbered (?1, ?2 ...). D1 supports these.
-- Most routes take header_id, resolved once by the lock-guard query in 3a.
-- =============================================================================


-- =============================================================================
-- SECTION 1 — DAY CREATION
-- Fires when the masthead opens on a date with no daily_headers row.
-- Run as one batch so a failure can't leave a header with no opening balances.
-- =============================================================================

-- 1a. Create the header. Capture meta.last_row_id — everything below needs it.
INSERT INTO daily_headers
  (entry_date, hijri_date, day_of_week_ur, day_of_week_en, students_fed, notes, locked, is_stale, created_by)
VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0, 0, ?7);


-- 1b. Populate opening balances for EVERY active item (option A).
--     ?1 = the new header_id from 1a.
--
--     Carry rule: from the most recent PRIOR day that has a row for that item,
--     not literally yesterday — which is what makes skipped days carry through.
--     Items never seen before land at 0.
--
--     Closing on that prior day = opening + received − used, summed across ALL
--     blocks. No block filter anywhere.
--
--     NOTE ON value_pkr: this carries value as straight arithmetic, i.e. a
--     running pool. That is NOT a costing method. If آٹا arrives at three
--     different prices in a month, this pool divided by qty gives an implied
--     weighted average — which is probably what you want, but it has never been
--     decided explicitly. See the open questions at the bottom of this file.

WITH new_day AS (
  SELECT id, entry_date FROM daily_headers WHERE id = ?1
),
last_hdr AS (
  SELECT ob.item_id,
         MAX(h.entry_date) AS last_date
  FROM opening_balances ob
  JOIN daily_headers h ON h.id = ob.header_id
  WHERE h.entry_date < (SELECT entry_date FROM new_day)
  GROUP BY ob.item_id
),
prev_closing AS (
  SELECT
    lh.item_id,
    ob.qty
      + COALESCE(SUM(lr.recv_qty), 0)
      - COALESCE(SUM(lr.used_qty), 0)           AS closing_qty,
    ob.value_pkr
      + COALESCE(SUM(lr.recv_value_pkr), 0)
      - COALESCE(SUM(lr.used_value_pkr), 0)     AS closing_pkr
  FROM last_hdr lh
  JOIN daily_headers h
    ON h.entry_date = lh.last_date
  JOIN opening_balances ob
    ON  ob.header_id = h.id
    AND ob.item_id   = lh.item_id
  LEFT JOIN ledger_rows lr
    ON  lr.header_id = h.id
    AND lr.item_id   = lh.item_id
  GROUP BY lh.item_id, ob.qty, ob.value_pkr
)
INSERT INTO opening_balances (header_id, item_id, qty, value_pkr)
SELECT ?1,
       i.id,
       COALESCE(pc.closing_qty, 0),
       COALESCE(pc.closing_pkr, 0)
FROM items i
LEFT JOIN prev_closing pc ON pc.item_id = i.id
WHERE i.is_active = 1;


-- 1c. Backfill when an item is added to the catalog mid-period.
--     Option A guarantees a row per active item per day only from the day the
--     item existed onward. Existing days have no row for it. If the grid or the
--     corrected v_daily_item_totals should show it on earlier days, run this.
--     Otherwise the item simply starts existing on its creation date, which is
--     defensible — decide once and be consistent.
INSERT OR IGNORE INTO opening_balances (header_id, item_id, qty, value_pkr)
SELECT h.id, ?1, 0, 0
FROM daily_headers h
WHERE h.entry_date >= ?2;


-- =============================================================================
-- SECTION 2 — LOAD A DAY  (GET /api/day/:date)
--
-- Returns the WHOLE day, all blocks — not just the selected one. Opening
-- balance is per item per DAY, shared across blocks, so remaining stock is
-- day-wide: if بنات already drew 40kg of آٹا this morning, بنین must see it.
-- The block sub-selector is a client-side filter over this payload, not a
-- server round-trip. That is the only way the remaining column stays honest
-- with two people entering at once.
-- =============================================================================

-- 2a. Header. Resolves entry_date -> header_id for everything else.
SELECT id,
       entry_date,
       hijri_date,
       day_of_week_ur,
       day_of_week_en,
       students_fed,
       notes,
       locked,
       is_stale
FROM daily_headers
WHERE entry_date = ?1;


-- 2b. Blocks for the sub-selector.
SELECT id, name_ur, name_en
FROM meal_blocks
WHERE is_active = 1
ORDER BY sort_order;


-- 2c. DAY-WIDE per-item position. Drives the persistent remaining column.
--     ?1 = header_id. Driven from opening_balances, so untouched items appear.
SELECT
  i.id                                        AS item_id,
  i.name_ur,
  i.name_en,
  i.name_roman,
  i.unit,
  ob.qty                                      AS opening_qty,
  ob.value_pkr                                AS opening_pkr,
  COALESCE(SUM(lr.recv_qty),       0)         AS recv_qty_total,
  COALESCE(SUM(lr.recv_value_pkr), 0)         AS recv_pkr_total,
  COALESCE(SUM(lr.used_qty),       0)         AS used_qty_total,
  COALESCE(SUM(lr.used_value_pkr), 0)         AS used_pkr_total,
  ob.qty
    + COALESCE(SUM(lr.recv_qty), 0)
    - COALESCE(SUM(lr.used_qty), 0)           AS remaining_qty
FROM opening_balances ob
JOIN items i ON i.id = ob.item_id
LEFT JOIN ledger_rows lr
  ON  lr.header_id = ob.header_id
  AND lr.item_id   = ob.item_id
WHERE ob.header_id = ?1
GROUP BY i.id, ob.qty, ob.value_pkr
ORDER BY i.sort_order, i.name_ur;


-- 2d. Grid rows, per block × item, all blocks at once.
--     ?1 = header_id.
--     LEFT JOIN so an assigned item with no entry yet renders as an empty row.
--     ledger_row_id comes back NULL for those — the client needs that to know
--     whether a save is an insert or an update, and audit needs it after.
SELECT
  bi.block_id,
  mb.name_ur                                  AS block_name_ur,
  mb.name_en                                  AS block_name_en,
  i.id                                        AS item_id,
  i.name_ur,
  i.name_en,
  i.unit,
  lr.id                                       AS ledger_row_id,
  COALESCE(lr.recv_qty,       0)              AS recv_qty,
  COALESCE(lr.recv_value_pkr, 0)              AS recv_value_pkr,
  COALESCE(lr.used_qty,       0)              AS used_qty,
  COALESCE(lr.used_value_pkr, 0)              AS used_value_pkr
FROM block_items bi
JOIN meal_blocks mb ON mb.id = bi.block_id AND mb.is_active = 1
JOIN items       i  ON i.id  = bi.item_id  AND i.is_active  = 1
LEFT JOIN ledger_rows lr
  ON  lr.header_id = ?1
  AND lr.block_id  = bi.block_id
  AND lr.item_id   = bi.item_id
WHERE bi.is_active = 1
ORDER BY mb.sort_order, i.sort_order, i.name_ur;


-- =============================================================================
-- SECTION 3 — SAVE A BLOCK  (POST /api/day/:date)
-- =============================================================================

-- 3a. Lock guard + header resolution. Run first. Abort the write if locked = 1.
SELECT id, locked FROM daily_headers WHERE entry_date = ?1;


-- 3b. Upsert one ledger row. Batch one per edited row.
--     RETURNING gives the row id for the audit entry in 3c, whether the
--     statement inserted or updated.
INSERT INTO ledger_rows
  (header_id, block_id, item_id, recv_qty, recv_value_pkr, used_qty, used_value_pkr, created_by)
VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
ON CONFLICT (header_id, block_id, item_id) DO UPDATE SET
  recv_qty       = excluded.recv_qty,
  recv_value_pkr = excluded.recv_value_pkr,
  used_qty       = excluded.used_qty,
  used_value_pkr = excluded.used_value_pkr,
  updated_at     = datetime('now')
RETURNING id;


-- 3c. Audit entry. One per changed field.
--     old_value NULL on first insert — reads correctly as "created".
--     reason_type stays NULL for routine entry; it is required only on the
--     opening-balance path in Section 4.
INSERT INTO audit_log
  (table_name, row_id, field_name, old_value, new_value, changed_by, reason_type, reason)
VALUES
  ('ledger_rows', ?1, ?2, ?3, ?4, ?5, NULL, ?6);


-- 3d. Mark downstream days stale after an edit to a day that is not the latest.
--     ?1 = header_id of the edited day.
--     Blunt on purpose: flags every later day rather than tracing which items
--     actually propagate. Over-flagging is the safe direction — it can annoy,
--     but it can never hide an inconsistency.
UPDATE daily_headers
SET is_stale = 1
WHERE entry_date > (SELECT entry_date FROM daily_headers WHERE id = ?1);


-- 3e. Clear the flag once Ibrahim has accepted the recalculation or kept his
--     own number with a reason on that day.
UPDATE daily_headers SET is_stale = 0 WHERE id = ?1;


-- =============================================================================
-- SECTION 4 — OPENING BALANCE EDIT
-- The reconciliation path: Ibrahim weighs the store and the ledger disagrees.
-- This is the legitimate reason opening is editable — not typo repair.
-- reason_type is REQUIRED here. Reject the write without it.
-- =============================================================================

-- 4a. Read current values first — needed for the audit old_value.
SELECT id, qty, value_pkr
FROM opening_balances
WHERE header_id = ?1 AND item_id = ?2;

-- 4b. Update.
UPDATE opening_balances
SET qty = ?2, value_pkr = ?3
WHERE id = ?1;

-- 4c. Audit. One row per changed field.
--     ?5 reason_type: 'physical_count' (اصل گنتی) | 'correction' (درستی)
INSERT INTO audit_log
  (table_name, row_id, field_name, old_value, new_value, changed_by, reason_type, reason)
VALUES
  ('opening_balances', ?1, ?2, ?3, ?4, ?5, ?6, ?7);

-- Then run 3d to flag downstream days.


-- =============================================================================
-- SECTION 5 — LOCK / UNLOCK
-- A locked day is an immutable anchor. Unlocking is itself an audit event —
-- that trail is what lets a month-end lock actually mean something.
-- =============================================================================

UPDATE daily_headers SET locked = ?2 WHERE id = ?1;

INSERT INTO audit_log
  (table_name, row_id, field_name, old_value, new_value, changed_by, reason_type, reason)
VALUES
  ('daily_headers', ?1, 'locked', ?2, ?3, ?4, 'correction', ?5);


-- =============================================================================
-- SECTION 6 — REPORTS  (GET /api/report)
-- Views only. Column names below match the REBUILT views in migration 001 —
-- the period columns are `month` and `year`, not `period`.
-- jsPDF renders client-side from this JSON.
-- =============================================================================

-- 6a. Daily summary — all blocks combined.
SELECT * FROM v_daily_item_totals WHERE entry_date = ?1 ORDER BY name_ur;

-- 6b. Daily drill-down by block.
SELECT * FROM v_daily_block_totals WHERE entry_date = ?1 ORDER BY block_ur, name_ur;

-- 6c. Weekly — inclusive range.
SELECT * FROM v_daily_item_totals
WHERE entry_date BETWEEN ?1 AND ?2
ORDER BY entry_date, name_ur;

-- 6d. Monthly. ?1 = 'YYYY-MM'.
SELECT * FROM v_monthly_item_totals WHERE month = ?1 ORDER BY name_ur;

-- 6e. Yearly. ?1 = 'YYYY'.
SELECT * FROM v_yearly_item_totals WHERE year = ?1 ORDER BY name_ur;

-- 6f. Stale-day flag for the report header, so an auditor sees that the ledger
--     knows it is inconsistent rather than discovering it later.
SELECT entry_date
FROM daily_headers
WHERE entry_date BETWEEN ?1 AND ?2 AND is_stale = 1
ORDER BY entry_date;

-- 6g. Audit trail for a period — the committee-facing view of every override.
SELECT a.changed_at, a.table_name, a.field_name, a.old_value, a.new_value,
       a.reason_type, a.reason, u.name_ur AS changed_by_ur, u.name_en AS changed_by_en
FROM audit_log a
LEFT JOIN users u ON u.id = a.changed_by
WHERE date(a.changed_at) BETWEEN ?1 AND ?2
ORDER BY a.changed_at DESC;


-- =============================================================================
-- SECTION 7 — QURBANI  (POST /api/qurbani)
-- Separate ledger. Never joins to ledger_rows — the exclusion from daily
-- averages is structural, not a filter someone can forget to apply.
-- item_id is NULL for cash; item_name_ur/_en carry one-off items.
-- =============================================================================

INSERT INTO qurbani_entries
  (entry_date, hijri_date, item_id, item_name_ur, item_name_en, kind, qty,
   est_value_pkr, donor_name, disposal, proceeds_pkr, receipt_r2_key, notes, created_by)
VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14);
  -- kind: 'animal' | 'hide' | 'cash' | 'inkind'
  -- disposal: 'slaughtered' | 'sold' | 'deposited' | 'to_stock'

SELECT q.*,
       COALESCE(i.name_ur, q.item_name_ur) AS display_name_ur,
       COALESCE(i.name_en, q.item_name_en) AS display_name_en,
       i.unit
FROM qurbani_entries q
LEFT JOIN items i ON i.id = q.item_id
WHERE q.entry_date BETWEEN ?1 AND ?2
ORDER BY q.entry_date, q.id;


-- =============================================================================
-- SECTION 8 — ITEM CATALOG  (GET/POST /api/items)
-- =============================================================================

SELECT id, name_ur, name_en, name_roman, unit, sort_order
FROM items
WHERE is_active = 1
ORDER BY sort_order, name_ur;

-- New item. name_en / name_roman come from the Qwen2.5 translation call.
-- unit must be one of: 'kg', 'g', 'L', 'pcs' (CHECK constraint).
INSERT INTO items (name_ur, name_en, name_roman, unit, sort_order, created_by)
VALUES (?1, ?2, ?3, ?4, ?5, ?6)
RETURNING id;

-- Soft delete — history preserved. Existing ledger rows and opening balances
-- remain and still report correctly.
UPDATE items SET is_active = 0 WHERE id = ?1;

-- Assign / unassign an item to a block. block_items has its own is_active, so
-- unassigning should flip the flag rather than DELETE, to keep the history.
INSERT INTO block_items (block_id, item_id, is_active)
VALUES (?1, ?2, 1)
ON CONFLICT (block_id, item_id) DO UPDATE SET is_active = 1;

UPDATE block_items SET is_active = 0 WHERE block_id = ?1 AND item_id = ?2;


-- =============================================================================
-- SECTION 9 — RECEIPTS  (POST /api/receipt)
-- =============================================================================

INSERT INTO receipts (r2_key, linked_to, linked_id, ocr_raw, ocr_parsed, uploaded_by)
VALUES (?1, ?2, ?3, ?4, ?5, ?6);
  -- linked_to: 'ledger' (linked_id = ledger_rows.id) | 'qurbani' (= qurbani_entries.id)

SELECT id, r2_key, ocr_parsed, uploaded_at
FROM receipts
WHERE linked_to = ?1 AND linked_id = ?2;


-- =============================================================================
-- OPEN QUESTIONS — decide before the routes are built
-- =============================================================================
--
-- 1. COSTING METHOD. opening_balances.value_pkr is NOT NULL and something must
--    populate it on carry-forward. Query 1b carries it as a running arithmetic
--    pool, which yields an implied weighted average. Confirm that, or pick FIFO
--    and the carry logic changes shape.
--
-- 2. TWO PATHS TO A QURBANI RECEIPT. qurbani_entries.receipt_r2_key holds a key
--    inline, and receipts.linked_to='qurbani' holds one relationally. Two
--    sources of truth for the same fact. Pick one before the upload route is
--    written.
--
-- 3. MID-PERIOD ITEM BACKFILL. Query 1c is optional — see its comment.
--
-- 4. AVERAGE DENOMINATOR. days_counted = days with a daily_headers row. If the
--    committee expects a calendar-day average, the monthly/yearly views change.
--
-- 5. QURBANI AND THE LOCK FLAG. daily_headers.locked gates the kitchen ledger.
--    qurbani_entries has no header_id and no lock of its own, so a locked day
--    currently still accepts Qurbani entries. Separate ledgers argue for
--    independent locking; a month-end close argues for one lock over both.
-- =============================================================================
