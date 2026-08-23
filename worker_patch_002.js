// ═══════════════════════════════════════════════════════════════════
// WORKER PATCH 002 — Ibrahim Shah Kitchen Ledger
// Apply these changes to src/index.js
// ═══════════════════════════════════════════════════════════════════
//
// SUMMARY OF CHANGES:
// 1. GET /api/day/:date  — include daily_received rows in response
// 2. POST /api/day/:date {action:"save_block"} — consumed only (strip recv)
// 3. POST /api/day/:date/received — NEW route, day-wide received save
// 4. POST /api/items — NEW route (also included here, was missing before)
//
// ═══════════════════════════════════════════════════════════════════


// ───────────────────────────────────────────────────────────────────
// 1. GET /api/day/:date
//    ADD this query inside the existing handler, after you fetch
//    opening_balances and ledger_rows. Merge result into response.
// ───────────────────────────────────────────────────────────────────

// ADD after fetching header and rows:
const receivedRows = header ? await env.DB.prepare(`
  SELECT dr.item_id, dr.recv_qty, dr.recv_value_pkr
  FROM daily_received dr
  WHERE dr.header_id = ?
`).bind(header.id).all() : { results: [] };

// ADD to the response payload:
// daily_received: receivedRows.results,
//
// Full response shape becomes:
// {
//   exists: true,
//   header,
//   blocks,
//   rows_by_block,        // consumed only per block (unchanged)
//   daily_received,       // NEW — array of {item_id, recv_qty, recv_value_pkr}
//   opening_balances,
//   day_totals,
// }


// ───────────────────────────────────────────────────────────────────
// 2. POST /api/day/:date  {action: "save_block"}
//    REMOVE recv_qty and recv_value_pkr from the rows insert/upsert.
//    Only used_qty and used_value_pkr are written to ledger_rows now.
// ───────────────────────────────────────────────────────────────────

// REPLACE the save_block rows loop with:
if (body.action === 'save_block') {
  const { block_id, user_id = 'ibrahim', reason_type = 'correction', reason_note = '', rows = [] } = body;

  const header = await env.DB.prepare(
    `SELECT id FROM daily_headers WHERE date = ?`
  ).bind(date).first();
  if (!header) return jsonErr('Day not found', 404);

  const stmts = [];
  for (const row of rows) {
    // Upsert consumed only — received lives in daily_received now
    stmts.push(env.DB.prepare(`
      INSERT INTO ledger_rows (header_id, block_id, item_id, used_qty, used_value_pkr, updated_by)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT (header_id, block_id, item_id)
      DO UPDATE SET
        used_qty       = excluded.used_qty,
        used_value_pkr = excluded.used_value_pkr,
        updated_by     = excluded.updated_by,
        updated_at     = datetime('now')
    `).bind(header.id, block_id, row.item_id, row.used_qty ?? 0, row.used_value_pkr ?? 0, user_id));

    if (row.used_qty || row.used_value_pkr) {
      stmts.push(env.DB.prepare(`
        INSERT INTO audit_log (header_id, block_id, item_id, action, used_qty, used_value_pkr,
                               reason_type, reason, user_id)
        VALUES (?, ?, ?, 'save_block', ?, ?, ?, ?, ?)
      `).bind(header.id, block_id, row.item_id, row.used_qty ?? 0, row.used_value_pkr ?? 0,
              reason_type, reason_note, user_id));
    }
  }

  if (stmts.length) await env.DB.batch(stmts);
  return jsonResp(await getDayPayload(env, date));
}


// ───────────────────────────────────────────────────────────────────
// 3. NEW ROUTE — POST /api/day/:date/received
//    Day-wide received entry per item. Upserts daily_received.
//    Body: { rows: [{item_id, recv_qty, recv_value_pkr}], user_id }
// ───────────────────────────────────────────────────────────────────

// ADD this handler alongside /opening:
if (pathname === `/api/day/${date}/received` && method === 'POST') {
  const body = await req.json();
  const { rows = [], user_id = 'ibrahim' } = body;

  const header = await env.DB.prepare(
    `SELECT id, is_locked FROM daily_headers WHERE date = ?`
  ).bind(date).first();
  if (!header) return jsonErr('Day not found', 404);
  if (header.is_locked) return jsonErr('Day is locked', 403);

  const stmts = [];
  for (const row of rows) {
    stmts.push(env.DB.prepare(`
      INSERT INTO daily_received (header_id, item_id, recv_qty, recv_value_pkr, updated_by)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT (header_id, item_id)
      DO UPDATE SET
        recv_qty       = excluded.recv_qty,
        recv_value_pkr = excluded.recv_value_pkr,
        updated_by     = excluded.updated_by,
        updated_at     = datetime('now')
    `).bind(header.id, row.item_id, row.recv_qty ?? 0, row.recv_value_pkr ?? 0, user_id));

    stmts.push(env.DB.prepare(`
      INSERT INTO audit_log (header_id, item_id, action, recv_qty, recv_value_pkr,
                             reason_type, reason, user_id)
      VALUES (?, ?, 'save_received', ?, ?, 'entry', '', ?)
    `).bind(header.id, row.item_id, row.recv_qty ?? 0, row.recv_value_pkr ?? 0, user_id));
  }

  if (stmts.length) await env.DB.batch(stmts);
  return jsonResp(await getDayPayload(env, date));
}


// ───────────────────────────────────────────────────────────────────
// 4. NEW ROUTE — POST /api/items
//    Inserts a new item and auto-assigns it to all three blocks.
//    Body: { name_ur, name_en, name_roman, unit, user_id }
// ───────────────────────────────────────────────────────────────────

if (pathname === '/api/items' && method === 'POST') {
  const body = await req.json();
  const { name_ur, name_en, name_roman, unit = 'kg', user_id = 'ibrahim' } = body;
  if (!name_ur) return jsonErr('name_ur required', 400);

  // Insert item
  const ins = await env.DB.prepare(`
    INSERT INTO items (name_ur, name_en, name_roman, unit, is_active, created_by)
    VALUES (?, ?, ?, ?, 1, ?)
  `).bind(name_ur, name_en || name_ur, name_roman || name_en || name_ur, unit, user_id).run();

  const itemId = ins.meta.last_row_id;

  // Auto-assign to all three blocks
  const blocks = await env.DB.prepare(`SELECT id FROM meal_blocks ORDER BY id`).all();
  const assigns = blocks.results.map(b =>
    env.DB.prepare(`
      INSERT OR IGNORE INTO block_items (block_id, item_id, sort_order)
      VALUES (?, ?, 999)
    `).bind(b.id, itemId)
  );
  if (assigns.length) await env.DB.batch(assigns);

  // Return updated items list
  const items = await env.DB.prepare(
    `SELECT * FROM items WHERE is_active = 1 ORDER BY sort_order, name_ur`
  ).all();

  return jsonResp({ ok: true, item_id: itemId, items: items.results });
}


// ───────────────────────────────────────────────────────────────────
// NOTE: getDayPayload() helper
// Make sure your existing getDayPayload (or equivalent inline logic)
// now also fetches daily_received and includes it in the returned object.
// Key addition inside getDayPayload:
//
//   const recvRows = await env.DB.prepare(`
//     SELECT item_id, recv_qty, recv_value_pkr
//     FROM daily_received WHERE header_id = ?
//   `).bind(headerId).all();
//
//   // Add to return value:
//   daily_received: recvRows.results,
//
// And update v_daily_item_totals usage — the view already reads from
// daily_received after migration 002, so day_totals will be correct.
// ───────────────────────────────────────────────────────────────────
