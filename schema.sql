-- ============================================================
-- Jamia Darul Uloom Eidgah — Kitchen Ledger
-- Cloudflare D1 (SQLite) Schema
-- ============================================================

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- ------------------------------------------------------------
-- 1. ITEM CATALOG
--    Shared across all blocks. Adding here makes the item
--    available in all block dropdowns.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS items (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name_ur     TEXT    NOT NULL,           -- Urdu (Nastaliq)
    name_en     TEXT    NOT NULL,           -- English (auto-translated)
    name_roman  TEXT,                       -- Roman Urdu (auto-translated)
    unit        TEXT    NOT NULL CHECK(unit IN ('kg','g','L','pcs')),
    is_active   INTEGER NOT NULL DEFAULT 1, -- 0 = soft-deleted
    sort_order  INTEGER NOT NULL DEFAULT 0, -- display order in dropdown
    created_at  TEXT    NOT NULL DEFAULT (datetime('now')),
    created_by  TEXT    NOT NULL            -- user_id of Ibrahim
);

-- ------------------------------------------------------------
-- 2. MEAL BLOCKS
--    Seeded: بنین (boys), بنات (girls), ناشتہ (breakfast)
--    Ibrahim can add more in future without schema change.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS meal_blocks (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name_ur     TEXT    NOT NULL,           -- e.g. بنین
    name_en     TEXT    NOT NULL,           -- e.g. Boys
    is_active   INTEGER NOT NULL DEFAULT 1,
    sort_order  INTEGER NOT NULL DEFAULT 0
);

-- ------------------------------------------------------------
-- 3. BLOCK–ITEM ASSIGNMENT
--    Each block has its own selectable item list.
--    Assigning an item here adds it to that block's dropdown.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS block_items (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    block_id    INTEGER NOT NULL REFERENCES meal_blocks(id),
    item_id     INTEGER NOT NULL REFERENCES items(id),
    is_active   INTEGER NOT NULL DEFAULT 1,
    UNIQUE(block_id, item_id)
);

-- ------------------------------------------------------------
-- 4. DAILY ENTRY HEADER
--    One row per calendar day. Stores both dates and the
--    opening balance snapshot taken at day-start.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS daily_headers (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    entry_date      TEXT    NOT NULL UNIQUE,    -- ISO: 2026-08-17
    hijri_date      TEXT,                       -- display only: ۲۴ صفر ۱۴۴۸ھ
    day_of_week_ur  TEXT,                       -- پیر
    day_of_week_en  TEXT,                       -- Monday
    students_fed    INTEGER,                    -- total for the day
    notes           TEXT,                       -- optional day-level note
    locked          INTEGER NOT NULL DEFAULT 0, -- 1 = finalized, no edits
    created_by      TEXT    NOT NULL,
    created_at      TEXT    NOT NULL DEFAULT (datetime('now'))
);

-- ------------------------------------------------------------
-- 5. OPENING BALANCE SNAPSHOT
--    Written once at day-start from prior day's closing.
--    Editable (with audit log) if a correction is needed.
--    Separate table so it's queryable independent of entries.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS opening_balances (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    header_id   INTEGER NOT NULL REFERENCES daily_headers(id),
    item_id     INTEGER NOT NULL REFERENCES items(id),
    qty         REAL    NOT NULL DEFAULT 0,     -- quantity in item's unit
    value_pkr   REAL    NOT NULL DEFAULT 0,     -- PKR value at opening
    UNIQUE(header_id, item_id)
);

-- ------------------------------------------------------------
-- 6. DAILY LEDGER ROWS
--    One row per item per block per day.
--    recv_* = received/purchased that day
--    used_* = consumed that day
--    Remaining = opening_qty + recv_qty - used_qty (computed at read)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ledger_rows (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    header_id       INTEGER NOT NULL REFERENCES daily_headers(id),
    block_id        INTEGER NOT NULL REFERENCES meal_blocks(id),
    item_id         INTEGER NOT NULL REFERENCES items(id),

    recv_qty        REAL    NOT NULL DEFAULT 0,
    recv_value_pkr  REAL    NOT NULL DEFAULT 0,

    used_qty        REAL    NOT NULL DEFAULT 0,
    used_value_pkr  REAL    NOT NULL DEFAULT 0,

    created_by      TEXT    NOT NULL,
    created_at      TEXT    NOT NULL DEFAULT (datetime('now')),
    updated_at      TEXT    NOT NULL DEFAULT (datetime('now')),

    UNIQUE(header_id, block_id, item_id)
);

-- ------------------------------------------------------------
-- 7. LEDGER AUDIT LOG
--    Written on every UPDATE to opening_balances or ledger_rows.
--    Provides the tamper-evident trail the audit team needs.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_log (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    table_name  TEXT    NOT NULL,           -- 'ledger_rows' | 'opening_balances'
    row_id      INTEGER NOT NULL,
    field_name  TEXT    NOT NULL,
    old_value   TEXT,
    new_value   TEXT,
    changed_by  TEXT    NOT NULL,
    changed_at  TEXT    NOT NULL DEFAULT (datetime('now')),
    reason      TEXT                        -- optional note from Ibrahim
);

-- ------------------------------------------------------------
-- 8. QURBANI & DONATIONS LEDGER
--    Separate table — never mixed into daily kitchen totals.
--    kind: 'animal' | 'hide' | 'cash' | 'inkind'
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS qurbani_entries (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    entry_date      TEXT    NOT NULL,
    hijri_date      TEXT,
    item_id         INTEGER REFERENCES items(id),   -- NULL for cash
    item_name_ur    TEXT,                           -- override for one-off items
    item_name_en    TEXT,
    kind            TEXT    NOT NULL CHECK(kind IN ('animal','hide','cash','inkind')),
    qty             REAL    NOT NULL DEFAULT 1,
    est_value_pkr   REAL    NOT NULL DEFAULT 0,
    donor_name      TEXT,                           -- optional
    disposal        TEXT,                           -- 'slaughtered'|'sold'|'deposited'|'to_stock'
    proceeds_pkr    REAL,                           -- if sold
    receipt_r2_key  TEXT,                           -- R2 object key for receipt photo
    notes           TEXT,
    created_by      TEXT    NOT NULL,
    created_at      TEXT    NOT NULL DEFAULT (datetime('now'))
);

-- ------------------------------------------------------------
-- 9. RECEIPT PHOTOS
--    R2 stores the file. This table stores metadata + OCR result.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS receipts (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    r2_key          TEXT    NOT NULL UNIQUE,    -- R2 object key
    linked_to       TEXT    NOT NULL,           -- 'ledger' | 'qurbani'
    linked_id       INTEGER NOT NULL,           -- ledger_rows.id or qurbani_entries.id
    ocr_raw         TEXT,                       -- raw Qwen2-VL output
    ocr_parsed      TEXT,                       -- JSON: {items:[{name,qty,pkr}]}
    uploaded_by     TEXT    NOT NULL,
    uploaded_at     TEXT    NOT NULL DEFAULT (datetime('now'))
);

-- ------------------------------------------------------------
-- 10. USERS & PIN ROLES
--     Ibrahim (owner) created via Cloudflare Access OTP.
--     Assistant created by Ibrahim with entry+view role.
--     Report PINs created by Ibrahim, shared with committee.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS users (
    id          TEXT    PRIMARY KEY,            -- Cloudflare Access sub / UUID
    name_ur     TEXT,
    name_en     TEXT    NOT NULL,
    role        TEXT    NOT NULL CHECK(role IN ('owner','assistant','report')),
    pin_hash    TEXT,                           -- bcrypt hash, for report role
    is_active   INTEGER NOT NULL DEFAULT 1,
    created_by  TEXT,                           -- NULL for owner (self)
    created_at  TEXT    NOT NULL DEFAULT (datetime('now'))
);

-- ------------------------------------------------------------
-- INDEXES — cover the most common query patterns
-- ------------------------------------------------------------

-- Daily entry lookup by date
CREATE INDEX IF NOT EXISTS idx_headers_date
    ON daily_headers(entry_date);

-- Ledger rows by header (most common fetch)
CREATE INDEX IF NOT EXISTS idx_ledger_header
    ON ledger_rows(header_id);

-- Ledger rows by item (for monthly/yearly reports)
CREATE INDEX IF NOT EXISTS idx_ledger_item
    ON ledger_rows(item_id);

-- Ledger rows by date range via header join (report queries)
CREATE INDEX IF NOT EXISTS idx_ledger_header_item
    ON ledger_rows(header_id, item_id);

-- Qurbani by date
CREATE INDEX IF NOT EXISTS idx_qurbani_date
    ON qurbani_entries(entry_date);

-- Audit log by table+row
CREATE INDEX IF NOT EXISTS idx_audit_row
    ON audit_log(table_name, row_id);

-- ------------------------------------------------------------
-- SEED DATA — meal blocks
-- ------------------------------------------------------------
INSERT OR IGNORE INTO meal_blocks (id, name_ur, name_en, sort_order)
VALUES
    (1, 'بنین',  'Boys',      1),
    (2, 'بنات',  'Girls',     2),
    (3, 'ناشتہ', 'Breakfast', 3);

-- ------------------------------------------------------------
-- REPORT VIEWS
--    Pre-built views for weekly / monthly / yearly reports.
--    Worker queries these directly; no report logic in frontend.
-- ------------------------------------------------------------

-- Daily totals per item (all blocks combined) — for summary reports
CREATE VIEW IF NOT EXISTS v_daily_item_totals AS
SELECT
    h.entry_date,
    h.hijri_date,
    i.name_ur,
    i.name_en,
    i.unit,
    COALESCE(ob.qty, 0)                                     AS opening_qty,
    COALESCE(ob.value_pkr, 0)                               AS opening_pkr,
    SUM(lr.recv_qty)                                        AS total_recv_qty,
    SUM(lr.recv_value_pkr)                                  AS total_recv_pkr,
    SUM(lr.used_qty)                                        AS total_used_qty,
    SUM(lr.used_value_pkr)                                  AS total_used_pkr,
    COALESCE(ob.qty, 0) + SUM(lr.recv_qty) - SUM(lr.used_qty) AS closing_qty
FROM daily_headers h
JOIN ledger_rows lr ON lr.header_id = h.id
JOIN items i        ON i.id = lr.item_id
LEFT JOIN opening_balances ob ON ob.header_id = h.id AND ob.item_id = lr.item_id
GROUP BY h.entry_date, i.id;

-- Daily totals per item per block — for block-level drill-down
CREATE VIEW IF NOT EXISTS v_daily_block_totals AS
SELECT
    h.entry_date,
    mb.name_ur  AS block_ur,
    mb.name_en  AS block_en,
    i.name_ur,
    i.name_en,
    i.unit,
    lr.recv_qty,
    lr.recv_value_pkr,
    lr.used_qty,
    lr.used_value_pkr
FROM daily_headers h
JOIN ledger_rows lr  ON lr.header_id = h.id
JOIN meal_blocks mb  ON mb.id = lr.block_id
JOIN items i         ON i.id = lr.item_id;

-- Monthly summary — Worker passes ?month=2026-08 as filter
CREATE VIEW IF NOT EXISTS v_monthly_item_totals AS
SELECT
    strftime('%Y-%m', entry_date)   AS month,
    name_ur,
    name_en,
    unit,
    SUM(total_recv_qty)             AS month_recv_qty,
    SUM(total_recv_pkr)             AS month_recv_pkr,
    SUM(total_used_qty)             AS month_used_qty,
    SUM(total_used_pkr)             AS month_used_pkr,
    ROUND(AVG(total_used_qty), 2)   AS avg_daily_used_qty
FROM v_daily_item_totals
GROUP BY month, name_ur, name_en, unit;

-- Yearly summary
CREATE VIEW IF NOT EXISTS v_yearly_item_totals AS
SELECT
    strftime('%Y', entry_date)      AS year,
    name_ur,
    name_en,
    unit,
    SUM(total_recv_qty)             AS year_recv_qty,
    SUM(total_recv_pkr)             AS year_recv_pkr,
    SUM(total_used_qty)             AS year_used_qty,
    SUM(total_used_pkr)             AS year_used_pkr,
    ROUND(AVG(total_used_qty), 2)   AS avg_daily_used_qty
FROM v_daily_item_totals
GROUP BY year, name_ur, name_en, unit;
