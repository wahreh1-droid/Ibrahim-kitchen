-- Migration 012: تقریب کا عنوان (per-day Occasion Title) for خاص مواقع
--
-- Adds a single free-text title to each day's header. It belongs to the
-- Special Occasions (خاص مواقع) block only — the Boys/Girls blocks are
-- unaffected — and it is intentionally NOT carried forward: every day starts
-- with an empty title until one is entered for that specific day.
--
-- The Worker reads it in getDay (returned inside `header`) and writes it via
-- POST /api/day/:date/occasion (saveOccasion). NULL / empty means "no title".
--
-- Run remote:
--   npx wrangler d1 execute ibrahim-kitchen --remote --file=ibrahim_migration_012.sql
--
-- Note: the D1 database name is `ibrahim-kitchen` (not ibrahim-kitchen-db).
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE daily_headers ADD COLUMN occasion_title TEXT;
