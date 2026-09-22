-- Migration 016: Donor receipts + meat weight.
--
--   donations.donor_phone       optional phone (for the receipt / WhatsApp)
--   donations.receipt_year      Gregorian year of donation_date
--   donations.receipt_seq       running number within that year → shown as 2026-0001
--   donation_items.meat_weight       optional meat weight
--   donation_items.meat_weight_unit  'kg' | 'mun' (stored as entered, never converted)
--
-- Additive only (ADD COLUMN + index + backfill) — no table rebuild, no view changes.
-- Existing donations are numbered per year in date order (then id).
--
-- SAFETY: capture a Time Travel bookmark first:
--   npx wrangler d1 time-travel info ibrahim-kitchen
--
-- --file tends to fail with auth error 10000, so run each statement with --command:
--   npx wrangler d1 execute ibrahim-kitchen --remote --command "<statement>"

ALTER TABLE donations ADD COLUMN donor_phone TEXT;
ALTER TABLE donations ADD COLUMN receipt_year INTEGER;
ALTER TABLE donations ADD COLUMN receipt_seq INTEGER;
ALTER TABLE donation_items ADD COLUMN meat_weight REAL;
ALTER TABLE donation_items ADD COLUMN meat_weight_unit TEXT;

UPDATE donations SET receipt_year = CAST(substr(donation_date,1,4) AS INTEGER), receipt_seq = (SELECT COUNT(*) FROM donations d2 WHERE substr(d2.donation_date,1,4) = substr(donations.donation_date,1,4) AND (d2.donation_date < donations.donation_date OR (d2.donation_date = donations.donation_date AND d2.id <= donations.id)));

CREATE UNIQUE INDEX IF NOT EXISTS idx_donations_receipt ON donations(receipt_year, receipt_seq);
