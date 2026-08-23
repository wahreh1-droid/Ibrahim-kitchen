-- Migration 004: Add students_boys and students_girls to daily_headers
-- Run local:  npx wrangler d1 execute ibrahim-kitchen --file=ibrahim_migration_004.sql
-- Run remote: npx wrangler d1 execute ibrahim-kitchen --remote --file=ibrahim_migration_004.sql

ALTER TABLE daily_headers ADD COLUMN students_boys  INTEGER;
ALTER TABLE daily_headers ADD COLUMN students_girls INTEGER;
