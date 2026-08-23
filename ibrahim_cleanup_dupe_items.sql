-- =============================================================================
-- Ibrahim Shah — Kitchen Ledger — Duplicate item cleanup
--
-- Items 6, 7, 8 are accidental duplicates of چینی (id 5) created while testing
-- the add-item modal. They are soft-deleted, not removed: opening_balances and
-- ledger_rows hold foreign keys to them, and audit_log references those rows.
-- Hard-deleting would orphan that history.
--
-- Run local:
--   npx wrangler d1 execute ibrahim-kitchen --local --file=ibrahim_cleanup_dupe_items.sql
-- Run remote (only after verifying local):
--   npx wrangler d1 execute ibrahim-kitchen --remote --file=ibrahim_cleanup_dupe_items.sql
--
-- Safe to re-run.
-- =============================================================================

-- Deactivate the duplicates. id 5 is kept as the canonical چینی.
UPDATE items
   SET is_active = 0
 WHERE id IN (6, 7, 8);

-- Remove their block assignments so they cannot reappear in the grid.
UPDATE block_items
   SET is_active = 0
 WHERE item_id IN (6, 7, 8);

-- -----------------------------------------------------------------------------
-- VERIFY — run separately after the above:
--
--   SELECT id, name_ur, name_en, unit, is_active FROM items ORDER BY id;
--
--   EXPECT: ids 1-5 with is_active = 1, ids 6-8 with is_active = 0
-- -----------------------------------------------------------------------------
