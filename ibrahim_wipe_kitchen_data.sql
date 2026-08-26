-- WIPE KITCHEN ENTRY DATA — DESTRUCTIVE. RUN DELIBERATELY.
-- =============================================================================
-- Clears all kitchen ENTRY data for a clean start on the cost-per-unit model.
-- KEEPS: items (the Item column roster), meal_blocks, block_items, and the
--        entire donations side (donations, donation_items).
-- DELETES: all day records and their entry data.
--
-- Run remote: npx wrangler d1 execute ibrahim-kitchen --remote --file=ibrahim_wipe_kitchen_data.sql
--
-- Run migration 007 BEFORE this (so cost_per_unit exists) — though order does
-- not strictly matter since this only deletes rows.
--
-- This does NOT touch: items, meal_blocks, block_items, donations, donation_items.
-- =============================================================================

PRAGMA foreign_keys = OFF;

DELETE FROM ledger_rows;
DELETE FROM daily_received;
DELETE FROM opening_balances;
-- Clearing daily_headers gives a truly clean slate. Opening balances chain from
-- headers, so leaving half-populated day shells would strand orphaned openings.
DELETE FROM daily_headers;

-- Optional: reset AUTOINCREMENT counters so new days start from clean ids.
DELETE FROM sqlite_sequence WHERE name IN
  ('ledger_rows','daily_received','opening_balances','daily_headers');

PRAGMA foreign_keys = ON;
