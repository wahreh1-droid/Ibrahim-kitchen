-- =============================================================================
-- Ibrahim Shah — Kitchen Ledger — LOCAL TEST SEED
--
-- ⚠️  LOCAL ONLY. This file DELETES ALL DATA before seeding. Never run with
--     --remote. The first statements would wipe Ibrahim's database.
--
--   npx wrangler d1 execute ibrahim-kitchen --local --file ibrahim_seed_test.sql
--
-- WHAT THIS PROVES
--   1. چاول — opening stock, zero movement. Under the OLD view it vanished from
--      the daily report entirely. It must now appear with closing = opening.
--   2. Carry across a gap — 2026-08-03 has no header. Day 04 must carry from
--      day 02, not find nothing.
--   3. Day-wide remaining — آٹا is drawn by all three blocks on day 01. The
--      remaining figure must net all three against ONE opening balance.
--   4. Average denominator — آٹا moves on 2 of 3 operating days. The monthly
--      average must divide by 3, not 2.
--   5. Mid-period item — گھی is created before day 04 only, so it carries 0.
--
-- Re-runnable: the reset block makes repeat runs safe.
-- =============================================================================


-- =============================================================================
-- PART 1 — RESET
-- FK-safe order: children before parents.
-- =============================================================================
DELETE FROM audit_log;
DELETE FROM receipts;
DELETE FROM qurbani_entries;
DELETE FROM ledger_rows;
DELETE FROM opening_balances;
DELETE FROM daily_headers;
DELETE FROM block_items;
DELETE FROM items;
DELETE FROM meal_blocks;
DELETE FROM sqlite_sequence;


-- =============================================================================
-- PART 2 — BLOCKS AND ITEMS
-- =============================================================================
INSERT INTO meal_blocks (name_ur, name_en, is_active, sort_order) VALUES
  ('بنین',   'Boys',      1, 1),
  ('بنات',   'Girls',     1, 2),
  ('ناشتہ',  'Breakfast', 1, 3);

-- گھی is deliberately NOT created here — see Part 6. It gets added later so it
-- has no prior history to carry from.
INSERT INTO items (name_ur, name_en, name_roman, unit, is_active, sort_order, created_by) VALUES
  ('آٹا',  'Flour',   'aata',   'kg', 1, 1, 'test-ibrahim'),
  ('چاول', 'Rice',    'chawal', 'kg', 1, 2, 'test-ibrahim'),
  ('دال',  'Lentils', 'daal',   'kg', 1, 3, 'test-ibrahim');

-- Assign every item to every block. Note that چاول is assigned everywhere and
-- still never used — assignment and activity are different things, which is
-- precisely what the old view conflated.
INSERT INTO block_items (block_id, item_id, is_active)
SELECT mb.id, i.id, 1 FROM meal_blocks mb CROSS JOIN items i;


-- =============================================================================
-- PART 3 — DAY 01  (2026-08-01)
-- Opening: آٹا 100kg/30000, چاول 200kg/60000, دال 50kg/20000
-- =============================================================================
INSERT INTO daily_headers
  (entry_date, hijri_date, day_of_week_ur, day_of_week_en, students_fed, locked, is_stale, created_by)
VALUES ('2026-08-01', '۱۷ صفر ۱۴۴۸ھ', 'ہفتہ', 'Saturday', 2980, 0, 0, 'test-ibrahim');

INSERT INTO opening_balances (header_id, item_id, qty, value_pkr)
SELECT h.id, i.id,
       CASE i.name_en WHEN 'Flour' THEN 100 WHEN 'Rice' THEN 200 ELSE 50 END,
       CASE i.name_en WHEN 'Flour' THEN 30000 WHEN 'Rice' THEN 60000 ELSE 20000 END
FROM daily_headers h CROSS JOIN items i
WHERE h.entry_date = '2026-08-01';

-- آٹا: received 50kg into Boys, then drawn by all three blocks (20+15+5 = 40).
INSERT INTO ledger_rows (header_id, block_id, item_id, recv_qty, recv_value_pkr, used_qty, used_value_pkr, created_by)
SELECT h.id, mb.id, i.id, 50, 15000, 20, 6000, 'test-ibrahim'
FROM daily_headers h, meal_blocks mb, items i
WHERE h.entry_date='2026-08-01' AND mb.name_en='Boys' AND i.name_en='Flour';

INSERT INTO ledger_rows (header_id, block_id, item_id, recv_qty, recv_value_pkr, used_qty, used_value_pkr, created_by)
SELECT h.id, mb.id, i.id, 0, 0, 15, 4500, 'test-ibrahim'
FROM daily_headers h, meal_blocks mb, items i
WHERE h.entry_date='2026-08-01' AND mb.name_en='Girls' AND i.name_en='Flour';

INSERT INTO ledger_rows (header_id, block_id, item_id, recv_qty, recv_value_pkr, used_qty, used_value_pkr, created_by)
SELECT h.id, mb.id, i.id, 0, 0, 5, 1500, 'test-ibrahim'
FROM daily_headers h, meal_blocks mb, items i
WHERE h.entry_date='2026-08-01' AND mb.name_en='Breakfast' AND i.name_en='Flour';

-- دال: drawn by Boys only.
INSERT INTO ledger_rows (header_id, block_id, item_id, recv_qty, recv_value_pkr, used_qty, used_value_pkr, created_by)
SELECT h.id, mb.id, i.id, 0, 0, 10, 4000, 'test-ibrahim'
FROM daily_headers h, meal_blocks mb, items i
WHERE h.entry_date='2026-08-01' AND mb.name_en='Boys' AND i.name_en='Lentils';

-- چاول: NO ledger rows at all. This is the case the old view dropped.


-- =============================================================================
-- PART 4 — DAY 02  (2026-08-02)
-- Opening carried by hand: آٹا 110/33000, چاول 200/60000, دال 40/16000
-- =============================================================================
INSERT INTO daily_headers
  (entry_date, hijri_date, day_of_week_ur, day_of_week_en, students_fed, locked, is_stale, created_by)
VALUES ('2026-08-02', '۱۸ صفر ۱۴۴۸ھ', 'اتوار', 'Sunday', 3010, 0, 0, 'test-ibrahim');

INSERT INTO opening_balances (header_id, item_id, qty, value_pkr)
SELECT h.id, i.id,
       CASE i.name_en WHEN 'Flour' THEN 110 WHEN 'Rice' THEN 200 ELSE 40 END,
       CASE i.name_en WHEN 'Flour' THEN 33000 WHEN 'Rice' THEN 60000 ELSE 16000 END
FROM daily_headers h CROSS JOIN items i
WHERE h.entry_date = '2026-08-02';

-- آٹا: 25 + 15 = 40kg used, no receipts. Closing 110 − 40 = 70.
INSERT INTO ledger_rows (header_id, block_id, item_id, recv_qty, recv_value_pkr, used_qty, used_value_pkr, created_by)
SELECT h.id, mb.id, i.id, 0, 0, 25, 7500, 'test-ibrahim'
FROM daily_headers h, meal_blocks mb, items i
WHERE h.entry_date='2026-08-02' AND mb.name_en='Boys' AND i.name_en='Flour';

INSERT INTO ledger_rows (header_id, block_id, item_id, recv_qty, recv_value_pkr, used_qty, used_value_pkr, created_by)
SELECT h.id, mb.id, i.id, 0, 0, 15, 4500, 'test-ibrahim'
FROM daily_headers h, meal_blocks mb, items i
WHERE h.entry_date='2026-08-02' AND mb.name_en='Girls' AND i.name_en='Flour';

-- دال and چاول: no movement on day 02.


-- =============================================================================
-- PART 5 — 2026-08-03 IS DELIBERATELY SKIPPED
-- No header, no rows. Day 04 must carry from day 02.
-- =============================================================================


-- =============================================================================
-- PART 6 — DAY 04  (2026-08-04) — THE ACTUAL TEST
-- گھی is created first so it exists as an active item with no prior history.
-- Then the header is created and opening balances are populated by the REAL
-- carry-forward query from Section 1b, not by hand.
-- =============================================================================
INSERT INTO items (name_ur, name_en, name_roman, unit, is_active, sort_order, created_by)
VALUES ('گھی', 'Ghee', 'ghee', 'L', 1, 4, 'test-ibrahim');

INSERT INTO block_items (block_id, item_id, is_active)
SELECT mb.id, i.id, 1 FROM meal_blocks mb, items i WHERE i.name_en = 'Ghee';

INSERT INTO daily_headers
  (entry_date, hijri_date, day_of_week_ur, day_of_week_en, students_fed, locked, is_stale, created_by)
VALUES ('2026-08-04', '۲۰ صفر ۱۴۴۸ھ', 'منگل', 'Tuesday', 2955, 0, 0, 'test-ibrahim');

-- Section 1b, with the header_id resolved by subquery instead of a placeholder.
WITH new_day AS (
  SELECT id, entry_date FROM daily_headers WHERE entry_date = '2026-08-04'
),
last_hdr AS (
  SELECT ob.item_id, MAX(h.entry_date) AS last_date
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
  JOIN daily_headers h     ON h.entry_date = lh.last_date
  JOIN opening_balances ob ON ob.header_id = h.id AND ob.item_id = lh.item_id
  LEFT JOIN ledger_rows lr ON lr.header_id = h.id AND lr.item_id = lh.item_id
  GROUP BY lh.item_id, ob.qty, ob.value_pkr
)
INSERT INTO opening_balances (header_id, item_id, qty, value_pkr)
SELECT (SELECT id FROM new_day),
       i.id,
       COALESCE(pc.closing_qty, 0),
       COALESCE(pc.closing_pkr, 0)
FROM items i
LEFT JOIN prev_closing pc ON pc.item_id = i.id
WHERE i.is_active = 1;

-- No ledger activity on day 04 — every item sits. Under the old view the entire
-- day would have been absent from the report.


-- =============================================================================
-- PART 7 — VERIFICATION
-- Run these separately with --command and check against the expected values.
-- =============================================================================

-- V1. THE BUG CASE. Day 01 must return THREE rows including چاول.
--     Old view returned two — چاول had no ledger row and disappeared.
--
--     SELECT name_ur, opening_qty, total_recv_qty, total_used_qty, closing_qty
--     FROM v_daily_item_totals WHERE entry_date='2026-08-01' ORDER BY name_ur;
--
--     EXPECT:
--       آٹا   100    50    40    110
--       چاول  200     0     0    200   <-- must be present
--       دال    50     0    10     40

-- V2. CARRY ACROSS THE GAP. Day 04 opening, carried from day 02 not day 03.
--
--     SELECT i.name_ur, ob.qty, ob.value_pkr
--     FROM opening_balances ob
--     JOIN daily_headers h ON h.id=ob.header_id
--     JOIN items i ON i.id=ob.item_id
--     WHERE h.entry_date='2026-08-04' ORDER BY i.sort_order;
--
--     EXPECT:
--       آٹا    70   21000
--       چاول  200   60000    <-- untouched for 3 days, still carried
--       دال    40   16000
--       گھی     0       0    <-- created today, no history

-- V3. DAY-WIDE REMAINING. آٹا on day 01, netted across all three blocks
--     against ONE opening balance.
--
--     SELECT i.name_ur, ob.qty AS opening,
--            SUM(lr.recv_qty) AS recv, SUM(lr.used_qty) AS used,
--            ob.qty + SUM(lr.recv_qty) - SUM(lr.used_qty) AS remaining
--     FROM opening_balances ob
--     JOIN daily_headers h ON h.id=ob.header_id
--     JOIN items i ON i.id=ob.item_id
--     LEFT JOIN ledger_rows lr ON lr.header_id=ob.header_id AND lr.item_id=ob.item_id
--     WHERE h.entry_date='2026-08-01' AND i.name_en='Flour'
--     GROUP BY i.id, ob.qty;
--
--     EXPECT: آٹا  100  50  40  110

-- V4. AVERAGE DENOMINATOR. Three operating days (01, 02, 04).
--
--     SELECT name_ur, days_counted, month_used_qty, avg_daily_used_qty
--     FROM v_monthly_item_totals WHERE month='2026-08' ORDER BY name_ur;
--
--     EXPECT:
--       آٹا    3    80    26.67   <-- old view: 2 days, avg 40.0 (~50% high)
--       چاول   3     0     0.0    <-- old view: absent entirely
--       دال    3    10     3.33   <-- old view: 1 day, avg 10.0 (3x high)
--       گھی    1     0     0.0    <-- only exists from day 04
--
--     NOTE ON گھی: days_counted = 1 because the item did not exist earlier.
--     Arguably correct — you cannot average consumption over days before an
--     item was in the catalog — but it means mid-month additions get a smaller
--     denominator than everything else in the same report. Worth deciding
--     whether the committee sees that as a footnote or a problem.

-- V5. DRILL-DOWN IS UNCHANGED. Day 01 by block — only real entries appear.
--     چاول is correctly absent here: it has nothing to show per block.
--
--     SELECT block_ur, name_ur, recv_qty, used_qty
--     FROM v_daily_block_totals WHERE entry_date='2026-08-01'
--     ORDER BY block_ur, name_ur;
--
--     EXPECT 4 rows: Boys/آٹا, Boys/دال, Girls/آٹا, Breakfast/آٹا
