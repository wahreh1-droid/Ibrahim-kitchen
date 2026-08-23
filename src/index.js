/**
 * Ibrahim Shah — Kitchen Ledger — Worker
 *
 * Read routes only at this stage:
 *   GET /api/health
 *   GET /api/items
 *   GET /api/day/:date        (date must be YYYY-MM-DD)
 *
 * No auth yet. Cloudflare Access sits in front of this when it deploys;
 * `wrangler dev` runs without it, which is what makes local testing possible.
 *
 * Run:  npx wrangler dev
 * Then: http://localhost:8787/api/day/2026-08-01
 */

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const path = url.pathname;

    if (request.method === "OPTIONS") {
      return withCors(new Response(null, { status: 204 }));
    }

    try {
      if (path === "/api/health" && request.method === "GET") {
        return json({ ok: true, time: new Date().toISOString() });
      }

      if (path === "/api/items" && request.method === "GET") {
        return json(await getItems(env));
      }

      if (path === "/api/items" && request.method === "POST") {
        const body = await request.json().catch(() => null);
        if (!body) return json({ error: "bad_request", message: "Missing body" }, 400);
        return json(await addItem(env, body));
      }

      // POST /api/day/:date/opening — must be matched before the broader day route
      const openingMatch = path.match(/^\/api\/day\/(\d{4}-\d{2}-\d{2})\/opening$/);
      if (openingMatch && request.method === "POST") {
        const body = await request.json().catch(() => null);
        if (!body) return json({ error: "bad_request", message: "Missing body" }, 400);
        return json(await saveOpening(env, openingMatch[1], body));
      }

      // POST /api/day/:date/students — boys / girls / total headcount
      const studentsMatch = path.match(/^\/api\/day\/(\d{4}-\d{2}-\d{2})\/students$/);
      if (studentsMatch && request.method === "POST") {
        const body = await request.json().catch(() => null);
        if (!body) return json({ error: "bad_request", message: "Missing body" }, 400);
        return json(await saveStudents(env, studentsMatch[1], body));
      }

      // POST /api/day/:date/received — day-wide received entry
      const receivedMatch = path.match(/^\/api\/day\/(\d{4}-\d{2}-\d{2})\/received$/);
      if (receivedMatch && request.method === "POST") {
        const body = await request.json().catch(() => null);
        if (!body) return json({ error: "bad_request", message: "Missing body" }, 400);
        return json(await saveReceived(env, receivedMatch[1], body));
      }

      const dayMatch = path.match(/^\/api\/day\/(\d{4}-\d{2}-\d{2})$/);
      if (dayMatch) {
        const date = dayMatch[1];

        if (request.method === "GET") {
          return json(await getDay(env, date));
        }

        if (request.method === "POST") {
          const body = await request.json().catch(() => null);
          if (!body || !body.action) {
            return json({ error: "bad_request", message: "Missing action in body" }, 400);
          }
          if (body.action === "create_day")  return json(await createDay(env, date, body));
          if (body.action === "save_block")  return json(await saveBlock(env, date, body));
          return json({ error: "bad_request", message: "Unknown action" }, 400);
        }
      }

      // GET /api/report/daily/:date
      const rptDailyMatch = path.match(/^\/api\/report\/daily\/(\d{4}-\d{2}-\d{2})$/);
      if (rptDailyMatch && request.method === "GET") {
        return json(await reportDaily(env, rptDailyMatch[1]));
      }

      // GET /api/report/weekly/:date  (any date within the target week)
      const rptWeeklyMatch = path.match(/^\/api\/report\/weekly\/(\d{4}-\d{2}-\d{2})$/);
      if (rptWeeklyMatch && request.method === "GET") {
        return json(await reportWeekly(env, rptWeeklyMatch[1]));
      }

      // GET /api/report/range/:from/:to  — arbitrary custom date range
      const rptRangeMatch = path.match(/^\/api\/report\/range\/(\d{4}-\d{2}-\d{2})\/(\d{4}-\d{2}-\d{2})$/);
      if (rptRangeMatch && request.method === "GET") {
        return json(await reportRange(env, rptRangeMatch[1], rptRangeMatch[2]));
      }

      // GET /api/report/monthly/:year/:month  (month as 1-12)
      const rptMonthlyMatch = path.match(/^\/api\/report\/monthly\/(\d{4})\/(\d{1,2})$/);
      if (rptMonthlyMatch && request.method === "GET") {
        return json(await reportMonthly(env, rptMonthlyMatch[1], rptMonthlyMatch[2].padStart(2,'0')));
      }

      // GET /api/report/yearly/:year
      const rptYearlyMatch = path.match(/^\/api\/report\/yearly\/(\d{4})$/);
      if (rptYearlyMatch && request.method === "GET") {
        return json(await reportYearly(env, rptYearlyMatch[1]));
      }

      return json({ error: "not_found", path }, 404);
    } catch (err) {
      return json({ error: "server_error", message: err.message }, 500);
    }
  },
};


/* ---------------------------------------------------------------------------
 * GET /api/items — catalog for the "add row" dropdowns
 * ------------------------------------------------------------------------- */
async function getItems(env) {
  const { results } = await env.DB.prepare(
    `SELECT id, name_ur, name_en, name_roman, unit, sort_order
       FROM items
      WHERE is_active = 1
      ORDER BY sort_order, name_ur`
  ).all();

  return { items: results };
}


/* ---------------------------------------------------------------------------
 * GET /api/day/:date
 *
 * Returns the WHOLE day — all three blocks, not just one. Opening balance is
 * per item per DAY and shared across blocks, so remaining stock has to net
 * every block against one opening figure. If بنات already drew 40kg of آٹا
 * this morning, بنین must see it. The block sub-selector filters this payload
 * client-side; it never round-trips to the server.
 * ------------------------------------------------------------------------- */
async function getDay(env, date) {
  const header = await env.DB.prepare(
    `SELECT id, entry_date, hijri_date, day_of_week_ur, day_of_week_en,
            students_boys, students_girls, students_fed,
            notes, locked, is_stale
       FROM daily_headers
      WHERE entry_date = ?1`
  ).bind(date).first();

  // No header means this day has never been opened. Not an error — the
  // frontend uses this to offer "create this day", which triggers the
  // carry-forward population.
  if (!header) {
    return { exists: false, entry_date: date };
  }

  const [blocksRes, totalsRes, gridRes, receivedRes] = await env.DB.batch([
    env.DB.prepare(
      `SELECT id, name_ur, name_en
         FROM meal_blocks
        WHERE is_active = 1
        ORDER BY sort_order`
    ),

    // Day-wide per-item position. Reads from daily_received (not ledger_rows)
    // for received figures after migration 002.
    env.DB.prepare(
      `SELECT i.id                                        AS item_id,
              i.name_ur, i.name_en, i.name_roman, i.unit,
              ob.qty                                      AS opening_qty,
              ob.value_pkr                                AS opening_pkr,
              COALESCE(dr.recv_qty,            0)         AS recv_qty_total,
              COALESCE(dr.recv_value_pkr,      0)         AS recv_pkr_total,
              COALESCE(dr.sadaqa_qty,          0)         AS sadaqa_qty_total,
              COALESCE(SUM(lr.used_qty),       0)         AS used_qty_total,
              COALESCE(SUM(lr.used_value_pkr), 0)         AS used_pkr_total,
              ob.qty
                + COALESCE(dr.recv_qty,    0)
                + COALESCE(dr.sadaqa_qty,  0)
                - COALESCE(SUM(lr.used_qty), 0)           AS remaining_qty
         FROM opening_balances ob
         JOIN items i ON i.id = ob.item_id
         LEFT JOIN daily_received dr
           ON  dr.header_id = ob.header_id
           AND dr.item_id   = ob.item_id
         LEFT JOIN ledger_rows lr
           ON  lr.header_id = ob.header_id
           AND lr.item_id   = ob.item_id
        WHERE ob.header_id = ?1
        GROUP BY i.id, ob.qty, ob.value_pkr, dr.recv_qty, dr.recv_value_pkr, dr.sadaqa_qty
        ORDER BY i.sort_order, i.name_ur`
    ).bind(header.id),

    // Grid rows for every active block and all three meal types.
    // Returns one row per (block, item, meal_type) combination.
    env.DB.prepare(
      `SELECT bi.block_id,
              mb.name_ur                          AS block_name_ur,
              mb.name_en                          AS block_name_en,
              i.id                                AS item_id,
              i.name_ur, i.name_en, i.unit,
              m.meal_type,
              COALESCE(lr.used_qty,       0)      AS used_qty,
              COALESCE(lr.used_value_pkr, 0)      AS used_value_pkr
         FROM block_items bi
         JOIN meal_blocks mb ON mb.id = bi.block_id AND mb.is_active = 1
         JOIN items       i  ON i.id  = bi.item_id  AND i.is_active  = 1
         JOIN (SELECT 'breakfast' AS meal_type UNION ALL
               SELECT 'lunch'                 UNION ALL
               SELECT 'dinner')              m
         LEFT JOIN ledger_rows lr
           ON  lr.header_id = ?1
           AND lr.block_id  = bi.block_id
           AND lr.item_id   = bi.item_id
           AND lr.meal_type = m.meal_type
        WHERE bi.is_active = 1
        ORDER BY mb.sort_order, i.sort_order, i.name_ur, m.meal_type`
    ).bind(header.id),

    // Day-wide received — one row per item per day
    env.DB.prepare(
      `SELECT item_id, recv_qty, recv_value_pkr, sadaqa_qty
         FROM daily_received
        WHERE header_id = ?1`
    ).bind(header.id),
  ]);

  // Group grid rows by block_id, then by item_id with meal_type entries
  // Structure: rowsByBlock[blockId][itemId] = { item meta, breakfast, lunch, dinner }
  const rowsByBlock = {};
  for (const row of gridRes.results) {
    const blk = (rowsByBlock[row.block_id] ||= {});
    if (!blk[row.item_id]) {
      blk[row.item_id] = {
        item_id: row.item_id,
        name_ur: row.name_ur,
        name_en: row.name_en,
        unit:    row.unit,
        breakfast: { used_qty: 0, used_value_pkr: 0 },
        lunch:     { used_qty: 0, used_value_pkr: 0 },
        dinner:    { used_qty: 0, used_value_pkr: 0 },
      };
    }
    blk[row.block_id]?.[row.item_id]; // already set above
    const entry = rowsByBlock[row.block_id][row.item_id];
    entry[row.meal_type] = {
      used_qty:       row.used_qty,
      used_value_pkr: row.used_value_pkr,
    };
  }
  // Convert to array per block for frontend compatibility
  const rowsByBlockArr = {};
  for (const [blockId, itemMap] of Object.entries(rowsByBlock)) {
    rowsByBlockArr[blockId] = Object.values(itemMap);
  }

  return {
    exists: true,
    header: {
      ...header,
      locked: !!header.locked,
      is_stale: !!header.is_stale,
    },
    blocks: blocksRes.results,
    day_totals: totalsRes.results,
    rows_by_block: rowsByBlockArr,
    daily_received: receivedRes.results,
  };
}


/* ---------------------------------------------------------------------------
 * POST /api/day/:date  { action: "create_day" }
 * ------------------------------------------------------------------------- */
async function createDay(env, date, body) {
  const { user_id, hijri_date, day_of_week_ur, day_of_week_en,
          students_boys, students_girls, students_fed } = body;
  if (!user_id) return { error: "bad_request", message: "user_id is required" };

  const existing = await env.DB.prepare(
    `SELECT id FROM daily_headers WHERE entry_date = ?1`
  ).bind(date).first();
  if (existing) return { error: "conflict", message: "Day already exists", entry_date: date };

  const boys  = Number.isFinite(+students_boys)  ? +students_boys  : null;
  const girls = Number.isFinite(+students_girls) ? +students_girls : null;
  const total = students_fed ?? (((boys ?? 0) + (girls ?? 0)) || null);

  const headerInsert = await env.DB.prepare(
    `INSERT INTO daily_headers
       (entry_date, hijri_date, day_of_week_ur, day_of_week_en,
        students_boys, students_girls, students_fed, locked, is_stale, created_by)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 0, 0, ?8)
     RETURNING id`
  ).bind(date, hijri_date??null, day_of_week_ur??null, day_of_week_en??null,
         boys, girls, total, user_id).first();

  const headerId = headerInsert.id;

  await env.DB.prepare(
    `INSERT INTO opening_balances (header_id, item_id, qty, value_pkr)
     WITH last_hdr AS (
       SELECT ob.item_id, MAX(h.entry_date) AS last_date
       FROM opening_balances ob
       JOIN daily_headers h ON h.id = ob.header_id
       WHERE h.entry_date < ?2
       GROUP BY ob.item_id
     ),
     prev_closing AS (
       SELECT lh.item_id,
              ob.qty
                + COALESCE(dr.recv_qty,   0)
                + COALESCE(dr.sadaqa_qty, 0)
                - COALESCE(SUM(lr.used_qty), 0) AS closing_qty
       FROM last_hdr lh
       JOIN daily_headers h     ON h.entry_date  = lh.last_date
       JOIN opening_balances ob ON ob.header_id  = h.id AND ob.item_id = lh.item_id
       LEFT JOIN daily_received dr ON dr.header_id = h.id AND dr.item_id = lh.item_id
       LEFT JOIN ledger_rows lr    ON lr.header_id  = h.id AND lr.item_id = lh.item_id
       GROUP BY lh.item_id, ob.qty, dr.recv_qty, dr.sadaqa_qty
     )
     SELECT ?1, i.id, COALESCE(pc.closing_qty, 0), 0
     FROM items i
     LEFT JOIN prev_closing pc ON pc.item_id = i.id
     WHERE i.is_active = 1`
  ).bind(headerId, date).run();

  return getDay(env, date);
}


/* ---------------------------------------------------------------------------
 * POST /api/day/:date  { action: "save_block" }
 * ------------------------------------------------------------------------- */
async function saveBlock(env, date, body) {
  const { block_id, user_id, reason_type, reason_note, rows } = body;

  if (!block_id || !user_id) return { error: "bad_request", message: "block_id and user_id required" };
  if (!Array.isArray(rows) || !rows.length) return { error: "bad_request", message: "rows must be non-empty" };
  if (!["physical_count","correction","entry"].includes(reason_type ?? "entry"))
    return { error: "bad_request", message: "reason_type must be physical_count, correction or entry" };

  const header = await env.DB.prepare(
    `SELECT id, locked FROM daily_headers WHERE entry_date = ?1`
  ).bind(date).first();
  if (!header) return { error: "not_found", message: "Day does not exist. Create it first." };
  if (header.locked) return { error: "locked", message: "This day is locked and cannot be edited." };

  const headerId = header.id;
  const now = new Date().toISOString().replace("T"," ").slice(0,19);
  const itemIds = rows.map(r => r.item_id);
  const ph = itemIds.map((_,i) => `?${i+3}`).join(",");

  const existingRows = await env.DB.prepare(
    `SELECT id, item_id, meal_type, used_qty, used_value_pkr
       FROM ledger_rows
      WHERE header_id=?1 AND block_id=?2 AND item_id IN (${ph})`
  ).bind(headerId, block_id, ...itemIds).all();

  const byItem = {};
  for (const r of existingRows.results) byItem[`${r.item_id}|${r.meal_type}`] = r;

  // Consumed only — received lives in daily_received, meal_type required per row
  const upserts = rows.map(row =>
    env.DB.prepare(
      `INSERT INTO ledger_rows
         (header_id,block_id,item_id,meal_type,used_qty,used_value_pkr,created_by,updated_at)
       VALUES (?1,?2,?3,?4,?5,?6,?7,?8)
       ON CONFLICT(header_id,block_id,item_id,meal_type) DO UPDATE SET
         used_qty=excluded.used_qty, used_value_pkr=excluded.used_value_pkr,
         updated_at=excluded.updated_at
       RETURNING id`
    ).bind(headerId, block_id, row.item_id, row.meal_type??'lunch',
           row.used_qty??0, row.used_value_pkr??0, user_id, now)
  );

  const upsertRes = await env.DB.batch(upserts);
  const FIELDS = ["used_qty","used_value_pkr"];
  const audits = [];

  for (let i=0; i<rows.length; i++) {
    const row   = rows[i];
    const rowId = upsertRes[i]?.results?.[0]?.id ?? null;
    const prior = byItem[`${row.item_id}|${row.meal_type??'lunch'}`] ?? null;
    for (const f of FIELDS) {
      const oldV = prior ? String(prior[f]??0) : null;
      const newV = String(row[f]??0);
      if (prior !== null && oldV === newV) continue;
      audits.push(env.DB.prepare(
        `INSERT INTO audit_log(table_name,row_id,field_name,old_value,new_value,changed_by,changed_at,reason_type,reason)
         VALUES('ledger_rows',?1,?2,?3,?4,?5,?6,?7,?8)`
      ).bind(rowId,f,oldV,newV,user_id,now,reason_type??null,reason_note??null));
    }
  }

  const today = new Date().toISOString().slice(0,10);
  if (date < today) {
    audits.push(env.DB.prepare(
      `UPDATE daily_headers SET is_stale=1 WHERE entry_date>?1`
    ).bind(date));
  }

  let warning = null;
  if (audits.length) {
    try { await env.DB.batch(audits); }
    catch(e) { warning = e.message; }
  }

  const payload = await getDay(env, date);
  if (warning) payload.warning = `Data saved. Audit log error: ${warning}`;
  return payload;
}


/* ---------------------------------------------------------------------------
 * POST /api/day/:date/opening — update a single opening balance
 *
 * Used for first-day seed entry and physical-count corrections.
 * Writes an audit entry, marks downstream days stale.
 * Returns updated day_totals so the frontend can refresh remaining live.
 * ------------------------------------------------------------------------- */
async function saveOpening(env, date, body) {
  const { item_id, opening_qty, user_id, reason_type, reason_note } = body;

  if (!item_id || !user_id) return { error: "bad_request", message: "item_id and user_id required" };
  if (opening_qty == null || isNaN(opening_qty))
    return { error: "bad_request", message: "opening_qty must be a number" };

  const header = await env.DB.prepare(
    `SELECT id, locked FROM daily_headers WHERE entry_date = ?1`
  ).bind(date).first();
  if (!header) return { error: "not_found", message: "Day does not exist." };
  if (header.locked) return { error: "locked", message: "This day is locked." };

  // Read old value for audit
  const old = await env.DB.prepare(
    `SELECT id, qty FROM opening_balances WHERE header_id=?1 AND item_id=?2`
  ).bind(header.id, item_id).first();
  if (!old) return { error: "not_found", message: "Opening balance row not found for this item." };

  const now = new Date().toISOString().replace("T"," ").slice(0,19);
  const today = new Date().toISOString().slice(0,10);

  const stmts = [
    env.DB.prepare(
      `UPDATE opening_balances SET qty=?1 WHERE header_id=?2 AND item_id=?3`
    ).bind(opening_qty, header.id, item_id),

    env.DB.prepare(
      `INSERT INTO audit_log(table_name,row_id,field_name,old_value,new_value,changed_by,changed_at,reason_type,reason)
       VALUES('opening_balances',?1,'qty',?2,?3,?4,?5,?6,?7)`
    ).bind(old.id, String(old.qty??0), String(opening_qty), user_id, now,
           reason_type??'physical_count', reason_note??null),
  ];

  if (date < today) {
    stmts.push(env.DB.prepare(
      `UPDATE daily_headers SET is_stale=1 WHERE entry_date>?1`
    ).bind(date));
  }

  await env.DB.batch(stmts);

  // Return fresh day_totals so frontend can update remaining without a full reload
  return getDay(env, date);
}


/* ---------------------------------------------------------------------------
 * POST /api/day/:date/received — day-wide received entry per item
 * ------------------------------------------------------------------------- */
async function saveReceived(env, date, body) {
  const { rows, user_id } = body;
  if (!user_id) return { error: "bad_request", message: "user_id required" };
  if (!Array.isArray(rows) || !rows.length) return { error: "bad_request", message: "rows must be non-empty" };

  const header = await env.DB.prepare(
    `SELECT id, locked FROM daily_headers WHERE entry_date = ?1`
  ).bind(date).first();
  if (!header) return { error: "not_found", message: "Day does not exist. Create it first." };
  if (header.locked) return { error: "locked", message: "This day is locked and cannot be edited." };

  const headerId = header.id;
  const now = new Date().toISOString().replace("T"," ").slice(0,19);
  const itemIds = rows.map(r => r.item_id);
  const ph = itemIds.map((_,i) => `?${i+2}`).join(",");

  // Prior values for the audit trail, before we overwrite them
  const priorRes = await env.DB.prepare(
    `SELECT id, item_id, recv_qty, recv_value_pkr, sadaqa_qty
       FROM daily_received
      WHERE header_id = ?1 AND item_id IN (${ph})`
  ).bind(headerId, ...itemIds).all();

  const prior = {};
  for (const r of priorRes.results) prior[r.item_id] = r;

  // Upsert without RETURNING — D1 batch does not reliably return rows from upserts
  const upserts = rows.map(row =>
    env.DB.prepare(
      `INSERT INTO daily_received (header_id, item_id, recv_qty, recv_value_pkr, sadaqa_qty, updated_by, updated_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
       ON CONFLICT(header_id, item_id) DO UPDATE SET
         recv_qty       = excluded.recv_qty,
         recv_value_pkr = excluded.recv_value_pkr,
         sadaqa_qty     = excluded.sadaqa_qty,
         updated_by     = excluded.updated_by,
         updated_at     = excluded.updated_at`
    ).bind(headerId, row.item_id, row.recv_qty??0, row.recv_value_pkr??0, row.sadaqa_qty??0, user_id, now)
  );
  await env.DB.batch(upserts);

  // Re-read to get row ids (audit_log.row_id is NOT NULL)
  const afterRes = await env.DB.prepare(
    `SELECT id, item_id FROM daily_received
      WHERE header_id = ?1 AND item_id IN (${ph})`
  ).bind(headerId, ...itemIds).all();

  const idByItem = {};
  for (const r of afterRes.results) idByItem[r.item_id] = r.id;

  const FIELDS = ["recv_qty","recv_value_pkr","sadaqa_qty"];
  const audits = [];
  for (const row of rows) {
    const rowId = idByItem[row.item_id];
    if (!rowId) continue;
    const p = prior[row.item_id] ?? null;
    for (const f of FIELDS) {
      const oldV = p ? String(p[f] ?? 0) : null;
      const newV = String(row[f] ?? 0);
      if (p !== null && oldV === newV) continue;
      audits.push(env.DB.prepare(
        `INSERT INTO audit_log(table_name,row_id,field_name,old_value,new_value,changed_by,changed_at,reason_type,reason)
         VALUES('daily_received',?1,?2,?3,?4,?5,?6,'entry',NULL)`
      ).bind(rowId, f, oldV, newV, user_id, now));
    }
  }

  let warning = null;
  if (audits.length) {
    try { await env.DB.batch(audits); }
    catch(e) { warning = e.message; }
  }

  const payload = await getDay(env, date);
  if (warning) payload.warning = `Data saved. Audit log error: ${warning}`;
  return payload;
}


/* ---------------------------------------------------------------------------
 * POST /api/day/:date/students — save boys / girls headcount for one day
 * Total is derived server-side so the two never drift apart.
 * ------------------------------------------------------------------------- */
async function saveStudents(env, date, body) {
  const { students_boys, students_girls, user_id } = body;
  if (!user_id) return { error: "bad_request", message: "user_id required" };

  const header = await env.DB.prepare(
    `SELECT id, locked FROM daily_headers WHERE entry_date = ?1`
  ).bind(date).first();
  if (!header) return { error: "not_found", message: "Day does not exist. Create it first." };
  if (header.locked) return { error: "locked", message: "This day is locked and cannot be edited." };

  const boys  = Number.isFinite(+students_boys)  ? +students_boys  : null;
  const girls = Number.isFinite(+students_girls) ? +students_girls : null;
  const total = (boys ?? 0) + (girls ?? 0);
  const now   = new Date().toISOString().replace("T"," ").slice(0,19);

  await env.DB.prepare(
    `UPDATE daily_headers
        SET students_boys  = ?2,
            students_girls = ?3,
            students_fed   = ?4
      WHERE id = ?1`
  ).bind(header.id, boys, girls, total || null).run();

  try {
    await env.DB.prepare(
      `INSERT INTO audit_log(table_name,row_id,field_name,old_value,new_value,changed_by,changed_at,reason_type,reason)
       VALUES('daily_headers',?1,'students_fed',NULL,?2,?3,?4,'entry',NULL)`
    ).bind(header.id, String(total), user_id, now).run();
  } catch (e) { /* audit failure must not block the save */ }

  return getDay(env, date);
}


/* ---------------------------------------------------------------------------
 * POST /api/items — add a new item and assign it to all blocks
 * ------------------------------------------------------------------------- */
async function addItem(env, body) {
  const { name_ur, name_en, name_roman, unit, user_id } = body;
  if (!name_ur) return { error: "bad_request", message: "name_ur is required" };

  const ins = await env.DB.prepare(
    `INSERT INTO items (name_ur, name_en, name_roman, unit, is_active, created_by)
     VALUES (?1, ?2, ?3, ?4, 1, ?5)
     RETURNING id`
  ).bind(
    name_ur,
    name_en   || name_ur,
    name_roman || name_en || name_ur,
    unit || 'kg',
    user_id || 'ibrahim'
  ).first();

  const itemId = ins.id;

  const blocks = await env.DB.prepare(
    `SELECT id FROM meal_blocks WHERE is_active = 1 ORDER BY sort_order`
  ).all();

  const assigns = blocks.results.map(b =>
    env.DB.prepare(
      `INSERT OR IGNORE INTO block_items (block_id, item_id)
       VALUES (?1, ?2)`
    ).bind(b.id, itemId)
  );
  if (assigns.length) await env.DB.batch(assigns);

  // Insert zero opening balance for all existing day headers
  const headers = await env.DB.prepare(
    `SELECT id FROM daily_headers`
  ).all();
  if (headers.results.length) {
    const obInserts = headers.results.map(h =>
      env.DB.prepare(
        `INSERT OR IGNORE INTO opening_balances (header_id, item_id, qty, value_pkr)
         VALUES (?1, ?2, 0, 0)`
      ).bind(h.id, itemId)
    );
    await env.DB.batch(obInserts);
  }

  const { results: items } = await env.DB.prepare(
    `SELECT id, name_ur, name_en, name_roman, unit, sort_order
       FROM items WHERE is_active = 1 ORDER BY sort_order, name_ur`
  ).all();

  return { ok: true, item_id: itemId, items };
}


/* ---------------------------------------------------------------------------
 * GET /api/report/daily/:date
 *
 * Returns everything needed to render the daily PDF:
 *   header   — date, hijri, day_of_week, students_boys/girls/fed
 *   items    — per item: opening, purchased (qty+pkr), consumed per meal type
 *              (ناشتہ/دوپہر/رات, totalled across all blocks), remaining
 *   totals   — day-level purchased_pkr, consumed_pkr totals per meal type
 * ------------------------------------------------------------------------- */
async function reportDaily(env, date) {
  const header = await env.DB.prepare(
    `SELECT id, entry_date, hijri_date, day_of_week_ur, day_of_week_en,
            students_boys, students_girls, students_fed
       FROM daily_headers WHERE entry_date = ?1`
  ).bind(date).first();

  if (!header) return { error: "not_found", message: `No entry for ${date}` };

  // Day-wide positions (opening, received, remaining)
  const [totalsRes, mealRes, receivedRes] = await env.DB.batch([

    // Item list is driven by block_items — the same source the grid uses — so
    // the report can never show an item that is not assigned to a block.
    env.DB.prepare(
      `SELECT i.id AS item_id, i.name_ur, i.name_en, i.unit,
              COALESCE(ob.qty,             0) AS opening_qty,
              COALESCE(dr.recv_qty,        0) AS recv_qty,
              COALESCE(dr.recv_value_pkr,  0) AS recv_pkr,
              COALESCE(SUM(lr.used_qty),   0) AS used_qty_total,
              COALESCE(SUM(lr.used_value_pkr),0) AS used_pkr_total,
              COALESCE(dr.sadaqa_qty,       0) AS sadaqa_qty,
              COALESCE(ob.qty, 0) + COALESCE(dr.recv_qty,0) + COALESCE(dr.sadaqa_qty,0)
                     - COALESCE(SUM(lr.used_qty),0) AS remaining_qty
         FROM items i
         JOIN (SELECT DISTINCT item_id FROM block_items WHERE is_active = 1) bi
           ON bi.item_id = i.id
         LEFT JOIN opening_balances ob
           ON ob.header_id = ?1 AND ob.item_id = i.id
         LEFT JOIN daily_received dr
           ON dr.header_id = ?1 AND dr.item_id = i.id
         LEFT JOIN ledger_rows lr
           ON lr.header_id = ?1 AND lr.item_id = i.id
        WHERE i.is_active = 1
        GROUP BY i.id, i.name_ur, i.name_en, i.unit,
                 ob.qty, dr.recv_qty, dr.recv_value_pkr, dr.sadaqa_qty
        ORDER BY i.sort_order, i.name_ur`
    ).bind(header.id),

    // Consumed per item per meal_type (all blocks combined)
    env.DB.prepare(
      `SELECT lr.item_id, lr.meal_type,
              SUM(lr.used_qty)        AS used_qty,
              SUM(lr.used_value_pkr)  AS used_pkr
         FROM ledger_rows lr
        WHERE lr.header_id = ?1
        GROUP BY lr.item_id, lr.meal_type`
    ).bind(header.id),

    env.DB.prepare(
      `SELECT item_id, recv_qty, recv_value_pkr
         FROM daily_received WHERE header_id = ?1`
    ).bind(header.id),
  ]);

  // Pivot meal rows onto each item
  const mealMap = {};
  for (const r of mealRes.results) {
    if (!mealMap[r.item_id]) mealMap[r.item_id] = {};
    mealMap[r.item_id][r.meal_type] = { used_qty: r.used_qty, used_pkr: r.used_pkr };
  }

  const items = totalsRes.results.map(row => ({
    ...row,
    breakfast: mealMap[row.item_id]?.breakfast ?? { used_qty: 0, used_pkr: 0 },
    lunch:     mealMap[row.item_id]?.lunch     ?? { used_qty: 0, used_pkr: 0 },
    dinner:    mealMap[row.item_id]?.dinner    ?? { used_qty: 0, used_pkr: 0 },
  }));

  // Day totals row
  const totals = {
    recv_qty_total:   items.reduce((s,i) => s + (i.recv_qty||0), 0),
    recv_pkr_total:   items.reduce((s,i) => s + (i.recv_pkr||0), 0),
    breakfast_qty:    items.reduce((s,i) => s + (i.breakfast.used_qty||0), 0),
    breakfast_pkr:    items.reduce((s,i) => s + (i.breakfast.used_pkr||0), 0),
    lunch_qty:        items.reduce((s,i) => s + (i.lunch.used_qty||0), 0),
    lunch_pkr:        items.reduce((s,i) => s + (i.lunch.used_pkr||0), 0),
    dinner_qty:       items.reduce((s,i) => s + (i.dinner.used_qty||0), 0),
    dinner_pkr:       items.reduce((s,i) => s + (i.dinner.used_pkr||0), 0),
  };

  return { report_type: "daily", header, items, totals };
}


/* ---------------------------------------------------------------------------
 * GET /api/report/weekly/:date
 *
 * Computes the Mon–Sun week that contains :date.
 * Returns:
 *   week        — { start, end } ISO dates
 *   students    — array of { entry_date, day_of_week_en, students_fed } for each day
 *   students_total
 *   items       — per item: opening (Mon), purchased QTY+PKR, consumed QTY+PKR, closing
 * ------------------------------------------------------------------------- */
async function reportWeekly(env, date) {
  // Compute Mon-Sun boundaries for the week containing :date
  const dt  = new Date(date + 'T12:00:00');
  const dow = dt.getDay(); // 0=Sun
  const diffToMon = (dow === 0) ? -6 : 1 - dow;
  const mon = new Date(dt); mon.setDate(dt.getDate() + diffToMon);
  const sun = new Date(mon); sun.setDate(mon.getDate() + 6);
  const weekStart = mon.toISOString().slice(0,10);
  const weekEnd   = sun.toISOString().slice(0,10);
  const out = await buildRangeReport(env, weekStart, weekEnd);
  return { ...out, report_type: "weekly", week: { start: weekStart, end: weekEnd } };
}


/* ---------------------------------------------------------------------------
 * GET /api/report/range/:from/:to
 *
 * Arbitrary custom range. Honours the exact dates given rather than snapping
 * to a week or month boundary.
 * ------------------------------------------------------------------------- */
async function reportRange(env, from, to) {
  // Tolerate reversed input
  const start = from <= to ? from : to;
  const end   = from <= to ? to   : from;
  const out = await buildRangeReport(env, start, end);
  return { ...out, report_type: "range", range: { start, end } };
}


/* ---------------------------------------------------------------------------
 * Shared range builder — used by both weekly and custom range.
 *
 * Returns:
 *   days           — every calendar day in the range, with students_fed.
 *                    Days with no header are included with days_present=false
 *                    so the report can show them as zero rather than omitting.
 *   students_total
 *   items          — per item: opening (first day in range), purchased, consumed, closing
 * ------------------------------------------------------------------------- */
async function buildRangeReport(env, rangeStart, rangeEnd) {
  const weekStart = rangeStart;
  const weekEnd   = rangeEnd;

  const [studentsRes, itemsRes] = await env.DB.batch([

    env.DB.prepare(
      `SELECT entry_date, day_of_week_en, day_of_week_ur,
              students_boys, students_girls, students_fed
         FROM daily_headers
        WHERE entry_date >= ?1 AND entry_date <= ?2
        ORDER BY entry_date`
    ).bind(weekStart, weekEnd),

    // Per item across the week. Driven by block_items, not opening_balances.
    // Received and consumed are aggregated in separate subqueries so the two
    // LEFT JOINs cannot multiply each other's rows.
    env.DB.prepare(
      `SELECT i.id AS item_id, i.name_ur, i.name_en, i.unit,
              COALESCE(op.opening_qty, 0) AS opening_qty,
              COALESCE(rc.recv_qty,    0) AS recv_qty,
              COALESCE(rc.recv_pkr,    0) AS recv_pkr,
              COALESCE(rc.sadaqa_qty,  0) AS sadaqa_qty,
              COALESCE(us.used_qty,    0) AS used_qty,
              COALESCE(us.used_pkr,    0) AS used_pkr
         FROM items i
         JOIN (SELECT DISTINCT item_id FROM block_items WHERE is_active = 1) bi
           ON bi.item_id = i.id
         LEFT JOIN (
              SELECT ob.item_id, ob.qty AS opening_qty
                FROM opening_balances ob
                JOIN daily_headers h ON h.id = ob.header_id
               WHERE h.entry_date = (
                     SELECT MIN(h2.entry_date) FROM daily_headers h2
                      WHERE h2.entry_date >= ?1 AND h2.entry_date <= ?2)
         ) op ON op.item_id = i.id
         LEFT JOIN (
              SELECT dr.item_id,
                     SUM(dr.recv_qty)       AS recv_qty,
                     SUM(dr.recv_value_pkr) AS recv_pkr,
                     SUM(dr.sadaqa_qty)     AS sadaqa_qty
                FROM daily_received dr
                JOIN daily_headers h ON h.id = dr.header_id
               WHERE h.entry_date >= ?1 AND h.entry_date <= ?2
               GROUP BY dr.item_id
         ) rc ON rc.item_id = i.id
         LEFT JOIN (
              SELECT lr.item_id,
                     SUM(lr.used_qty)       AS used_qty,
                     SUM(lr.used_value_pkr) AS used_pkr
                FROM ledger_rows lr
                JOIN daily_headers h ON h.id = lr.header_id
               WHERE h.entry_date >= ?1 AND h.entry_date <= ?2
               GROUP BY lr.item_id
         ) us ON us.item_id = i.id
        WHERE i.is_active = 1
        ORDER BY i.sort_order, i.name_ur`
    ).bind(weekStart, weekEnd),
  ]);

  const items = itemsRes.results.map(row => ({
    ...row,
    closing_qty: (row.opening_qty||0) + (row.recv_qty||0) + (row.sadaqa_qty||0) - (row.used_qty||0),
  }));

  const students_total = studentsRes.results.reduce((s,d) => s + (d.students_fed||0), 0);

  /* Fill in every calendar day in the range, including ones with no header,
   * so a closure reads as an explicit zero instead of a missing column.     */
  const byDate = {};
  for (const d of studentsRes.results) byDate[d.entry_date] = d;

  const DOW_EN = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
  const DOW_UR = ['اتوار','پیر','منگل','بدھ','جمعرات','جمعہ','ہفتہ'];

  const days = [];
  let cur = new Date(weekStart + 'T12:00:00');
  const stop = new Date(weekEnd + 'T12:00:00');
  while (cur <= stop) {
    const iso = cur.toISOString().slice(0,10);
    const hit = byDate[iso];
    days.push(hit ? { ...hit, has_entry: true } : {
      entry_date:     iso,
      day_of_week_en: DOW_EN[cur.getDay()],
      day_of_week_ur: DOW_UR[cur.getDay()],
      students_boys:  0,
      students_girls: 0,
      students_fed:   0,
      has_entry:      false,
    });
    cur.setDate(cur.getDate() + 1);
  }

  return {
    students: days,
    students_total,
    days_with_entries: studentsRes.results.length,
    items,
  };
}


/* ---------------------------------------------------------------------------
 * GET /api/report/monthly/:year/:month  (month zero-padded, e.g. 08)
 *
 * Returns:
 *   period         — { year, month, label_en, label_ur }
 *   summary        — operating_days, total_students, purchased_pkr, consumed_pkr
 *   weekly_rows    — array of { week_label, days, students, purchased_pkr,
 *                               consumed_pkr, per_student_pkr }
 *   items          — per item monthly: purchased + consumed QTY/PKR
 * ------------------------------------------------------------------------- */
async function reportMonthly(env, year, month) {
  const monthStr  = `${year}-${month}`;
  const dateStart = `${year}-${month}-01`;
  // Last day of month
  const lastDay   = new Date(+year, +month, 0).getDate();
  const dateEnd   = `${year}-${month}-${String(lastDay).padStart(2,'0')}`;

  const [headerRes, itemRes] = await env.DB.batch([
    env.DB.prepare(
      `SELECT entry_date, day_of_week_en, students_fed
         FROM daily_headers
        WHERE entry_date >= ?1 AND entry_date <= ?2
        ORDER BY entry_date`
    ).bind(dateStart, dateEnd),

    env.DB.prepare(
      `SELECT i.id AS item_id, i.name_ur, i.name_en, i.unit,
              COALESCE(rc.recv_qty,   0) AS recv_qty,
              COALESCE(rc.recv_pkr,   0) AS recv_pkr,
              COALESCE(rc.sadaqa_qty, 0) AS sadaqa_qty,
              COALESCE(us.used_qty,   0) AS used_qty,
              COALESCE(us.used_pkr,   0) AS used_pkr
         FROM items i
         JOIN (SELECT DISTINCT item_id FROM block_items WHERE is_active = 1) bi
           ON bi.item_id = i.id
         LEFT JOIN (
              SELECT dr.item_id,
                     SUM(dr.recv_qty)       AS recv_qty,
                     SUM(dr.recv_value_pkr) AS recv_pkr,
                     SUM(dr.sadaqa_qty)     AS sadaqa_qty
                FROM daily_received dr
                JOIN daily_headers h ON h.id = dr.header_id
               WHERE h.entry_date >= ?1 AND h.entry_date <= ?2
               GROUP BY dr.item_id
         ) rc ON rc.item_id = i.id
         LEFT JOIN (
              SELECT lr.item_id,
                     SUM(lr.used_qty)       AS used_qty,
                     SUM(lr.used_value_pkr) AS used_pkr
                FROM ledger_rows lr
                JOIN daily_headers h ON h.id = lr.header_id
               WHERE h.entry_date >= ?1 AND h.entry_date <= ?2
               GROUP BY lr.item_id
         ) us ON us.item_id = i.id
        WHERE i.is_active = 1
        ORDER BY i.sort_order, i.name_ur`
    ).bind(dateStart, dateEnd),
  ]);

  const days = headerRes.results;

  /* ---- Build the full list of Mon–Sun weeks the month touches ----
   * Every week is generated, including ones with no operating days, so the
   * committee sees closures explicitly rather than as a gap in the table.   */
  const iso = d => d.toISOString().slice(0,10);
  const weekKeys = [];
  const weekMeta = {};

  let cursor = new Date(dateStart + 'T12:00:00');
  const dow0 = cursor.getDay();
  cursor.setDate(cursor.getDate() + ((dow0 === 0) ? -6 : 1 - dow0)); // back to Monday

  const endBound = new Date(dateEnd + 'T12:00:00');
  while (cursor <= endBound) {
    const wStart = iso(cursor);
    const sun    = new Date(cursor); sun.setDate(cursor.getDate() + 6);
    const wEnd   = iso(sun);
    // Clamp the displayed label to the month boundaries
    const labelStart = wStart < dateStart ? dateStart : wStart;
    const labelEnd   = wEnd   > dateEnd   ? dateEnd   : wEnd;
    weekKeys.push(wStart);
    weekMeta[wStart] = {
      week_label: `${labelStart} – ${labelEnd}`,
      range_start: labelStart,
      range_end:   labelEnd,
      days: 0,
      students: 0,
    };
    cursor.setDate(cursor.getDate() + 7);
  }

  // Drop operating days into their week
  for (const d of days) {
    const dt  = new Date(d.entry_date + 'T12:00:00');
    const dw  = dt.getDay();
    const mon = new Date(dt); mon.setDate(dt.getDate() + ((dw === 0) ? -6 : 1 - dw));
    const key = iso(mon);
    if (!weekMeta[key]) continue;
    weekMeta[key].days++;
    weekMeta[key].students += (d.students_fed || 0);
  }

  /* ---- PKR per week ----
   * Received and consumed are summed in separate subqueries. Joining both to
   * daily_headers at once multiplies the rows and inflates both figures.     */
  const weekRows = await Promise.all(weekKeys.map(async wStart => {
    const m = weekMeta[wStart];
    const res = await env.DB.prepare(
      `SELECT
         (SELECT COALESCE(SUM(dr.recv_value_pkr),0)
            FROM daily_received dr
            JOIN daily_headers h ON h.id = dr.header_id
           WHERE h.entry_date >= ?1 AND h.entry_date <= ?2) AS purchased_pkr,
         (SELECT COALESCE(SUM(lr.used_value_pkr),0)
            FROM ledger_rows lr
            JOIN daily_headers h ON h.id = lr.header_id
           WHERE h.entry_date >= ?1 AND h.entry_date <= ?2) AS consumed_pkr`
    ).bind(m.range_start, m.range_end).first();

    const consumed = res?.consumed_pkr || 0;
    return {
      week_label:    m.week_label,
      days:          m.days,
      students:      m.students,
      purchased_pkr: res?.purchased_pkr || 0,
      consumed_pkr:  consumed,
      per_student_pkr: m.students > 0
        ? Math.round(consumed / m.students * 100) / 100 : 0,
      is_empty:      m.days === 0,
    };
  }));

  const summary = {
    operating_days:  days.length,
    total_students:  days.reduce((s,d) => s + (d.students_fed||0), 0),
    purchased_pkr:   itemRes.results.reduce((s,i) => s + (i.recv_pkr||0), 0),
    consumed_pkr:    itemRes.results.reduce((s,i) => s + (i.used_pkr||0), 0),
  };
  summary.per_student_pkr = summary.total_students > 0
    ? Math.round(summary.consumed_pkr / summary.total_students * 100) / 100 : 0;

  const MONTH_NAMES_EN = ['','January','February','March','April','May','June',
                           'July','August','September','October','November','December'];
  const MONTH_NAMES_UR = ['','جنوری','فروری','مارچ','اپریل','مئی','جون',
                           'جولائی','اگست','ستمبر','اکتوبر','نومبر','دسمبر'];

  return {
    report_type: "monthly",
    period: {
      year, month,
      label_en: `${MONTH_NAMES_EN[+month]} ${year}`,
      label_ur: `${MONTH_NAMES_UR[+month]} ${year}`,
    },
    summary,
    weekly_rows: weekRows,
    items: itemRes.results,
  };
}


/* ---------------------------------------------------------------------------
 * GET /api/report/yearly/:year
 *
 * Returns:
 *   period         — { year }
 *   summary        — operating_days, total_students, purchased_pkr, consumed_pkr
 *   monthly_rows   — array of { month, label_en, label_ur, days, students,
 *                               purchased_pkr, consumed_pkr, per_student_pkr }
 *   items          — per item yearly: purchased + consumed QTY/PKR
 * ------------------------------------------------------------------------- */
async function reportYearly(env, year) {
  const dateStart = `${year}-01-01`;
  const dateEnd   = `${year}-12-31`;

  const [headerRes, itemRes] = await env.DB.batch([
    env.DB.prepare(
      `SELECT entry_date, students_fed,
              strftime('%m', entry_date) AS month_num
         FROM daily_headers
        WHERE entry_date >= ?1 AND entry_date <= ?2
        ORDER BY entry_date`
    ).bind(dateStart, dateEnd),

    env.DB.prepare(
      `SELECT i.id AS item_id, i.name_ur, i.name_en, i.unit,
              COALESCE(rc.recv_qty,   0) AS recv_qty,
              COALESCE(rc.recv_pkr,   0) AS recv_pkr,
              COALESCE(rc.sadaqa_qty, 0) AS sadaqa_qty,
              COALESCE(us.used_qty,   0) AS used_qty,
              COALESCE(us.used_pkr,   0) AS used_pkr
         FROM items i
         JOIN (SELECT DISTINCT item_id FROM block_items WHERE is_active = 1) bi
           ON bi.item_id = i.id
         LEFT JOIN (
              SELECT dr.item_id,
                     SUM(dr.recv_qty)       AS recv_qty,
                     SUM(dr.recv_value_pkr) AS recv_pkr,
                     SUM(dr.sadaqa_qty)     AS sadaqa_qty
                FROM daily_received dr
                JOIN daily_headers h ON h.id = dr.header_id
               WHERE h.entry_date >= ?1 AND h.entry_date <= ?2
               GROUP BY dr.item_id
         ) rc ON rc.item_id = i.id
         LEFT JOIN (
              SELECT lr.item_id,
                     SUM(lr.used_qty)       AS used_qty,
                     SUM(lr.used_value_pkr) AS used_pkr
                FROM ledger_rows lr
                JOIN daily_headers h ON h.id = lr.header_id
               WHERE h.entry_date >= ?1 AND h.entry_date <= ?2
               GROUP BY lr.item_id
         ) us ON us.item_id = i.id
        WHERE i.is_active = 1
        ORDER BY i.sort_order, i.name_ur`
    ).bind(dateStart, dateEnd),
  ]);

  // Group days by month
  const monthBuckets = {};
  for (const d of headerRes.results) {
    const m = d.month_num;
    if (!monthBuckets[m]) monthBuckets[m] = { days: 0, students: 0 };
    monthBuckets[m].days++;
    monthBuckets[m].students += (d.students_fed || 0);
  }

  // Get PKR totals per month from DB
  // Received and consumed summed separately — joining both to daily_headers
  // in one query multiplies rows and inflates both figures.
  const monthPkrRes = await env.DB.prepare(
    `SELECT m.month_num,
            COALESCE(r.purchased_pkr, 0) AS purchased_pkr,
            COALESCE(c.consumed_pkr,  0) AS consumed_pkr
       FROM (SELECT DISTINCT strftime('%m', entry_date) AS month_num
               FROM daily_headers
              WHERE entry_date >= ?1 AND entry_date <= ?2) m
       LEFT JOIN (
            SELECT strftime('%m', h.entry_date) AS month_num,
                   SUM(dr.recv_value_pkr)       AS purchased_pkr
              FROM daily_received dr
              JOIN daily_headers h ON h.id = dr.header_id
             WHERE h.entry_date >= ?1 AND h.entry_date <= ?2
             GROUP BY month_num
       ) r ON r.month_num = m.month_num
       LEFT JOIN (
            SELECT strftime('%m', h.entry_date) AS month_num,
                   SUM(lr.used_value_pkr)       AS consumed_pkr
              FROM ledger_rows lr
              JOIN daily_headers h ON h.id = lr.header_id
             WHERE h.entry_date >= ?1 AND h.entry_date <= ?2
             GROUP BY month_num
       ) c ON c.month_num = m.month_num
      ORDER BY m.month_num`
  ).bind(dateStart, dateEnd).all();

  const pkrByMonth = {};
  for (const r of monthPkrRes.results) pkrByMonth[r.month_num] = r;

  const MONTH_NAMES_EN = ['','January','February','March','April','May','June',
                           'July','August','September','October','November','December'];
  const MONTH_NAMES_UR = ['','جنوری','فروری','مارچ','اپریل','مئی','جون',
                           'جولائی','اگست','ستمبر','اکتوبر','نومبر','دسمبر'];

  const monthly_rows = Object.keys(monthBuckets).sort().map(m => {
    const bkt = monthBuckets[m];
    const pkr = pkrByMonth[m] ?? {};
    const per_student = bkt.students > 0
      ? Math.round((pkr.consumed_pkr||0) / bkt.students * 100) / 100 : 0;
    // Flag partial months (current month, data ends before month-end)
    const lastDayOfMonth = new Date(+year, +m, 0).getDate();
    const lastEntry = headerRes.results.filter(d => d.month_num === m).slice(-1)[0];
    const isPartial = lastEntry
      ? new Date(lastEntry.entry_date).getDate() < lastDayOfMonth
        && `${year}-${m}-${String(lastDayOfMonth).padStart(2,'0')}` > dateEnd.slice(0,10)
      : false;

    return {
      month:         m,
      label_en:      MONTH_NAMES_EN[+m],
      label_ur:      MONTH_NAMES_UR[+m],
      days:          bkt.days,
      students:      bkt.students,
      purchased_pkr: pkr.purchased_pkr || 0,
      consumed_pkr:  pkr.consumed_pkr  || 0,
      per_student_pkr: per_student,
      is_partial:    isPartial,
    };
  });

  const summary = {
    operating_days:  headerRes.results.length,
    total_students:  headerRes.results.reduce((s,d) => s + (d.students_fed||0), 0),
    purchased_pkr:   itemRes.results.reduce((s,i) => s + (i.recv_pkr||0), 0),
    consumed_pkr:    itemRes.results.reduce((s,i) => s + (i.used_pkr||0), 0),
  };
  summary.per_student_pkr = summary.total_students > 0
    ? Math.round(summary.consumed_pkr / summary.total_students * 100) / 100 : 0;

  return {
    report_type: "yearly",
    period: { year },
    summary,
    monthly_rows,
    items: itemRes.results,
  };
}


/* ---------------------------------------------------------------------------
 * Helpers
 * ------------------------------------------------------------------------- */
function json(body, status = 200) {
  return withCors(
    new Response(JSON.stringify(body, null, 2), {
      status,
      headers: { "Content-Type": "application/json; charset=utf-8" },
    })
  );
}

// Wide open for local development. Tighten to the real origin before deploy —
// Cloudflare Access will gate it, but CORS should not be a hole behind that.
function withCors(res) {
  res.headers.set("Access-Control-Allow-Origin", "*");
  res.headers.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.headers.set("Access-Control-Allow-Headers", "Content-Type");
  return res;
}
