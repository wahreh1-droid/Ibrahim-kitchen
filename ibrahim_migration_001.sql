-- =============================================================================
-- Ibrahim Shah — Kitchen Ledger — Migration 001
-- Database: ibrahim-kitchen / f49f9772-a241-4da9-8784-a08d408cfe5e
--
-- THIS FILE IS MEANT TO BE EXECUTED. Run --local first, confirm, then --remote.
--
--   npx wrangler d1 execute ibrahim-kitchen --local  --file ibrahim_migration_001.sql
--   npx wrangler d1 execute ibrahim-kitchen --remote --file ibrahim_migration_001.sql
--
-- Two parts:
--   A. Columns required by the opening-balance decisions
--   B. Rebuild of three views that have a join bug (see notes in Part B)
--
-- No index creation needed — UNIQUE(header_id, block_id, item_id) and
-- UNIQUE(header_id, item_id) are already declared inline on ledger_rows and
-- opening_balances. Those are the sqlite_autoindex_* entries.
-- =============================================================================


-- =============================================================================
-- PART A — COLUMNS
-- =============================================================================

-- audit_log.reason already exists as a free-text note. This adds the TYPE, so
-- the committee can tell اصل گنتی (physical count) from درستی (correction).
-- Those two mean very different things when reading a stock discrepancy.
ALTER TABLE audit_log ADD COLUMN reason_type TEXT;   -- 'physical_count' | 'correction'

-- Set when an edit to an earlier day invalidates this day's carried opening
-- balances. Nothing is silently recalculated; this surfaces the inconsistency
-- in the day view and in report headers, and Ibrahim resolves it per day.
ALTER TABLE daily_headers ADD COLUMN is_stale INTEGER NOT NULL DEFAULT 0;


-- =============================================================================
-- PART B — VIEW REBUILD
--
-- WHY: v_daily_item_totals currently does
--        FROM daily_headers h JOIN ledger_rows lr ON lr.header_id = h.id
--      An INNER join to ledger_rows means an item only appears on a day if it
--      had activity that day. An item sitting untouched in the store — real
--      opening stock, no receipt, no consumption — vanishes from the daily
--      report entirely, and its closing balance with it. Physical stock exists,
--      paper stock does not. That is exactly what an audit committee catches.
--
-- FIX: drive the view from opening_balances (which, under the "populate every
--      active item on day creation" rule, has a row for every active item every
--      day) and LEFT JOIN ledger_rows onto it. Activity becomes optional;
--      presence in the ledger becomes guaranteed.
--
-- KNOCK-ON: v_monthly_item_totals computed avg_daily_used_qty as
--           AVG(total_used_qty) over rows from the daily view. With the broken
--           inner join those rows were only days the item was USED, so a
--           30-day month where آٹا moved on 10 days reported the average over
--           10 — roughly 3x the true daily rate, straight into purchase
--           planning. Fixing the daily view fixes the denominator, but the
--           rewrite below makes it explicit with SUM/COUNT and exposes
--           days_counted so the number can be checked rather than trusted.
--
-- DENOMINATOR CHOICE: days_counted is days that have a daily_headers row —
--      i.e. operating days. A skipped day with no header is not counted. If
--      Ibrahim wants a strict calendar-day average instead, that is a different
--      denominator and worth deciding before the committee sees a report.
--
-- Dropped in dependency order: yearly and monthly both read from daily.
-- =============================================================================

DROP VIEW IF EXISTS v_yearly_item_totals;
DROP VIEW IF EXISTS v_monthly_item_totals;
DROP VIEW IF EXISTS v_daily_item_totals;


CREATE VIEW v_daily_item_totals AS
SELECT
    h.entry_date,
    h.hijri_date,
    i.id                                        AS item_id,
    i.name_ur,
    i.name_en,
    i.unit,
    ob.qty                                      AS opening_qty,
    ob.value_pkr                                AS opening_pkr,
    COALESCE(SUM(lr.recv_qty),       0)         AS total_recv_qty,
    COALESCE(SUM(lr.recv_value_pkr), 0)         AS total_recv_pkr,
    COALESCE(SUM(lr.used_qty),       0)         AS total_used_qty,
    COALESCE(SUM(lr.used_value_pkr), 0)         AS total_used_pkr,
    ob.qty
      + COALESCE(SUM(lr.recv_qty), 0)
      - COALESCE(SUM(lr.used_qty), 0)           AS closing_qty,
    ob.value_pkr
      + COALESCE(SUM(lr.recv_value_pkr), 0)
      - COALESCE(SUM(lr.used_value_pkr), 0)     AS closing_pkr
FROM opening_balances ob
JOIN daily_headers h ON h.id = ob.header_id
JOIN items         i ON i.id = ob.item_id
-- No block filter: one physical store, one number. Sums across all three blocks.
LEFT JOIN ledger_rows lr
  ON  lr.header_id = ob.header_id
  AND lr.item_id   = ob.item_id
GROUP BY h.entry_date, i.id;
-- ob.qty / ob.value_pkr are bare columns here. Safe: UNIQUE(header_id, item_id)
-- means exactly one opening_balances row per group, so the value is determinate.


-- v_daily_block_totals is left as deployed. It reads ledger_rows directly with
-- no aggregation, so the drill-down correctly shows only actual entries per
-- block — an item with no entry in بنین genuinely has nothing to show there.


CREATE VIEW v_monthly_item_totals AS
SELECT
    strftime('%Y-%m', entry_date)               AS month,
    item_id,
    name_ur,
    name_en,
    unit,
    COUNT(DISTINCT entry_date)                  AS days_counted,
    SUM(total_recv_qty)                         AS month_recv_qty,
    SUM(total_recv_pkr)                         AS month_recv_pkr,
    SUM(total_used_qty)                         AS month_used_qty,
    SUM(total_used_pkr)                         AS month_used_pkr,
    ROUND(
      SUM(total_used_qty) / NULLIF(COUNT(DISTINCT entry_date), 0)
    , 2)                                        AS avg_daily_used_qty
FROM v_daily_item_totals
GROUP BY month, item_id;


CREATE VIEW v_yearly_item_totals AS
SELECT
    strftime('%Y', entry_date)                  AS year,
    item_id,
    name_ur,
    name_en,
    unit,
    COUNT(DISTINCT entry_date)                  AS days_counted,
    SUM(total_recv_qty)                         AS year_recv_qty,
    SUM(total_recv_pkr)                         AS year_recv_pkr,
    SUM(total_used_qty)                         AS year_used_qty,
    SUM(total_used_pkr)                         AS year_used_pkr,
    ROUND(
      SUM(total_used_qty) / NULLIF(COUNT(DISTINCT entry_date), 0)
    , 2)                                        AS avg_daily_used_qty
FROM v_daily_item_totals
GROUP BY year, item_id;
