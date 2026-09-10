-- Migration 015: Item categories.
--
-- Adds a `category` column to items so the dashboard can group items under
-- headers (اناج / سبزی / گوشت / مصالحہ / جانور / متفرق). Deliberately a PLAIN
-- TEXT column with a DEFAULT and NO CHECK constraint — the six valid values are
-- validated in app code, so adding a 7th category later is a one-line code
-- change, never a table rebuild. (Contrast with the unit CHECK, which forced the
-- 014 rebuild.)
--
-- Also: removes the three بیسن test rows (ids 38,39,40) added during testing, by
-- soft-deleting them (is_active=0) rather than hard-deleting, so any ledger /
-- received rows that reference those ids stay valid.
--
-- Finally: assigns every active item to its category (from the reviewed worksheet).
--
-- Additive + data-only — no table rebuild, no view changes.
--
-- SAFETY: capture a Time Travel bookmark first:
--   npx wrangler d1 time-travel info ibrahim-kitchen
--
-- Run remote:
--   npx wrangler d1 execute ibrahim-kitchen --remote --file=ibrahim_migration_015.sql

-- 1. Add the column (existing rows default to 'mutafariq') ---------------------
ALTER TABLE items ADD COLUMN category TEXT NOT NULL DEFAULT 'mutafariq';

-- 2. Remove بیسن test items (soft delete keeps referential integrity) ----------
UPDATE items SET is_active = 0 WHERE id IN (38, 39, 40);

-- 3. Assign categories (reviewed assignments) --------------------------------
UPDATE items SET category = 'anaaj'     WHERE id IN (1, 4, 19, 5, 6, 28);
UPDATE items SET category = 'sabzi'     WHERE id IN (13, 14, 17, 15, 16, 18, 42, 43, 10);
UPDATE items SET category = 'gosht'     WHERE id IN (3, 20, 21);
UPDATE items SET category = 'masalah'   WHERE id IN (7, 8, 9, 11, 12);
UPDATE items SET category = 'janwar'    WHERE id IN (27, 31);
UPDATE items SET category = 'mutafariq' WHERE id IN (2, 22, 25, 30, 24, 26, 29);
