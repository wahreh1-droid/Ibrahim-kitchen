-- Migration 009: Hijri anchors
-- An anchor pins a Gregorian date to a specific Hijri date. The Hijri date for
-- any day is then derived by counting forward from the most recent anchor at or
-- before that day (see the Worker's hijri resolution). Anchors are Ibrahim's
-- real moon-sighting corrections, so the calendar follows Pakistan sightings.
--
-- Run remote: npx wrangler d1 execute ibrahim-kitchen --remote --file=ibrahim_migration_009.sql

CREATE TABLE IF NOT EXISTS hijri_anchors (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  gregorian_date TEXT    NOT NULL UNIQUE,   -- 'YYYY-MM-DD'
  hijri_day      INTEGER NOT NULL,          -- 1..30
  hijri_month    INTEGER NOT NULL,          -- 1..12 (1 = Muharram)
  hijri_year     INTEGER NOT NULL,
  created_by     TEXT    NOT NULL DEFAULT 'ibrahim',
  created_at     TEXT    NOT NULL DEFAULT (datetime('now'))
);

-- Lookups are "latest anchor on or before date X" — index the gregorian date.
CREATE INDEX IF NOT EXISTS idx_hijri_anchors_date ON hijri_anchors(gregorian_date);
