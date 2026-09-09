-- Migration 013: Authentication (6-digit PIN lock)
--
-- Adds the tables the Worker's auth layer needs:
--   * users         — one row (username 'ibrahim') holding the PBKDF2 hash + salt
--                     of the 6-digit PIN. Created on first-run via /api/auth/bootstrap;
--                     the PIN itself is never stored or sent to us.
--   * auth_throttle — a single counter row that locks login after too many
--                     wrong PINs (brute-force protection).
--
-- Mirrors the MSP tracker's `users` schema so the same crypto applies.
-- Nothing here touches existing kitchen/donation/receipt data.
--
-- Run remote:
--   npx wrangler d1 execute ibrahim-kitchen --remote --file=ibrahim_migration_013.sql
--
-- Also required (one time):  npx wrangler secret put SESSION_SECRET
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS users (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  username      TEXT    NOT NULL UNIQUE,
  password_hash TEXT    NOT NULL,
  salt          TEXT    NOT NULL,
  role          TEXT    NOT NULL DEFAULT 'user',   -- 'admin' | 'user'
  created_at    TEXT    NOT NULL DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);

CREATE TABLE IF NOT EXISTS auth_throttle (
  id           INTEGER PRIMARY KEY,   -- always 1 (single global counter)
  fail_count   INTEGER NOT NULL DEFAULT 0,
  locked_until INTEGER                -- unix ms; NULL = not locked
);
INSERT OR IGNORE INTO auth_throttle (id, fail_count, locked_until) VALUES (1, 0, NULL);
