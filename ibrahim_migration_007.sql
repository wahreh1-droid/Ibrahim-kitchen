-- Migration 007: Cost per Unit (per-day, per-item)
-- Adds cost_per_unit to opening_balances. Because opening_balances already has
-- exactly one row per (day, item) with UNIQUE(header_id, item_id), it is the
-- natural home for a per-day price.
--
-- Run local:  npx wrangler d1 execute ibrahim-kitchen --local  --file=ibrahim_migration_007.sql
-- Run remote: npx wrangler d1 execute ibrahim-kitchen --remote --file=ibrahim_migration_007.sql
--
-- NOTES
--  * Default 0. Existing rows get 0; values render blank until a cost is entered.
--  * cost_per_unit is carried forward to FUTURE days at day-creation time
--    (handled in the Worker's createDay). Editing a past day's cost does NOT
--    propagate — it stays on that day only.
--  * Values (مالیت) are computed on the client as qty x cost_per_unit and the
--    computed number is what gets written to the *_value_pkr columns on save,
--    so the existing report views keep working unchanged.

ALTER TABLE opening_balances ADD COLUMN cost_per_unit REAL NOT NULL DEFAULT 0;
