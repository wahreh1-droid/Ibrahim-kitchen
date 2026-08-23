# Ibrahim Shah — Kitchen Ledger App — Handoff v4
## Paste this at the start of a new chat

---

## Client
- **Ibrahim Shah** — kitchen manager, Jamia Darul Uloom Eidgah, Kabirwala, Punjab, Pakistan
- Feeds ~3,000 students daily (Boys ~1,820 / Girls ~1,180)
- Two users: Ibrahim (owner/full access) + one assistant (entry + view)
- Report PIN system: Ibrahim assigns PINs to committee/audit team (view + export only) — **deferred**

---

## Confirmed Tech Stack
- **Frontend** — `kitchen.html` — single-file Urdu RTL, Nastaliq for Urdu, IBM Plex Mono for numbers, Inter for English. Desktop Tab 1 (Daily Kitchen) fully built and working. Mobile view deferred. Tab 2 (Qurbani) not started.
- **Auth** — Cloudflare Access (email OTP) for Ibrahim + assistant. Report role uses PIN hash in D1. **Deferred.**
- **Backend** — Cloudflare Worker (`src/index.js`). All read + write routes built and working locally and remote.
- **Database** — D1 `ibrahim-kitchen`, ID `f49f9772-a241-4da9-8784-a08d408cfe5e`. Migrations 001–004 applied to **both local and remote**.
- **File storage** — R2 for receipts. Bucket **not yet created**.
- **Reports** — jsPDF client-side. Dialog mockup done. Report format mockups (daily/weekly/monthly/yearly) done. **Build not started.**
- **LLM at runtime** — Qwen2-VL (receipt OCR), Qwen2.5 (item translation) via OpenRouter. Claude dev-side only, never runtime.

---

## Project Folder
`/Users/softwareprofiles/Documents/AI Solutions/X Project Dashboard/Ibrahim Shah/`

```
wrangler.toml                      D1 binding + main entry, working
src/index.js                       Worker — ALL routes built (see table below)
kitchen.html                       Frontend — Tab 1 desktop, wired to localhost:8787
ibrahim_migration_001.sql          APPLIED local + remote
ibrahim_migration_002.sql          APPLIED local + remote
ibrahim_migration_003.sql          APPLIED local + remote
ibrahim_migration_004.sql          APPLIED local + remote
ibrahim_dashboard_queries_v2.sql   Query reference for remaining routes
ibrahim_seed_test.sql              LOCAL ONLY test data, re-runnable
schema.sql / schema_d1.sql         Original schema
ibrahim_dashboard_queries.sql      ⚠️ v1, WRONG column names — DELETE THIS
worker_patch_002.js                ⚠️ superseded — DELETE THIS
```

Wrangler: v4.125.0, authenticated as wahreh1@gmail.com, account `e69f0f358f10d166af99d4bc03c1c41b`.

---

## Migration History
| Migration | What it does | Status |
|---|---|---|
| 001 | Added `is_stale` to `daily_headers`, `reason_type` to `audit_log`, rebuilt views | ✅ local + remote |
| 002 | Added `daily_received` table (day-wide received qty/PKR per item), rebuilt views to read from it | ✅ local + remote |
| 003 | Added `meal_type` column to `ledger_rows` (breakfast/lunch/dinner), deactivated ناشتہ block (id=3), rebuilt views | ✅ local + remote |
| 004 | Added `students_boys` + `students_girls` columns to `daily_headers` | ✅ local + remote |

---

## Schema State
- `daily_headers`: `entry_date`, `hijri_date`, `day_of_week_ur/en`, `students_fed`, `students_boys`, `students_girls`, `locked`, `is_stale`, `created_by`
- `daily_received`: `header_id`, `item_id`, `recv_qty`, `recv_value_pkr`, `updated_by`, `updated_at` — UNIQUE(header_id, item_id)
- `ledger_rows`: `header_id`, `block_id`, `item_id`, `meal_type` (breakfast/lunch/dinner), `used_qty`, `used_value_pkr` — UNIQUE(header_id, block_id, item_id, meal_type)
- `meal_blocks`: id=1 بنین (Boys), id=2 بنات (Girls), id=3 ناشتہ (deactivated)
- `opening_balances`: `value_pkr` always written as 0 — PKR tracking dropped from opening
- `audit_log`: `reason_type` (physical_count / correction / entry), `reason` (free-text note)
- Views: `v_daily_item_totals`, `v_daily_block_totals` (groups by meal_type), `v_monthly_item_totals`, `v_yearly_item_totals`

---

## Architecture Decisions (locked)

### Opening balance
- Per item per DAY, not per block. One physical store, one number.
- Carry-forward CTE on day creation — uses `daily_received` (not `ledger_rows`) for received qty.
- Carry-forward rule: most recent prior day that has a row for that item (skipped days handled correctly).
- Editable inline — saves on blur via `POST /api/day/:date/opening`.
- Upstream edits mark downstream days stale. Never silently recalculated.
- Locked days = immutable anchors.

### Received stock
- **Day-wide** — one entry per item per day, stored in `daily_received` table.
- NOT per block. Ibrahim enters what arrived that day once.
- Shown as constant columns across all block tabs.

### Consumed
- **Per block per meal type** — Boys (بنین) and Girls (بنات) × Breakfast/Lunch/Dinner = 6 consumed entries per item per day.
- Stored in `ledger_rows` with `block_id` + `meal_type`.

### Remaining
- Day-wide = Opening + Received − sum of all consumed (all blocks × all meal types).
- Shown as constant column across all block tabs.

### Students fed
- Three fields: `students_boys`, `students_girls`, `students_fed` (total = boys + girls, auto-calculated in frontend).
- All three sent in `create_day` and `update_students` POST bodies.

### Column color coding (table)
- Opening → blue-grey
- Purchased/Received → green (QTY lighter, VALUE PKR darker shade)
- Consumed (خرچ ناشتہ / خرچ دوپہر / خرچ رات) → amber
- Remaining → neutral slate

### LOW stock threshold
- < 15% of opening → LOW badge (amber)
- 15–35% → amber progress bar
- > 35% → green progress bar

---

## Worker Routes — All Built (`src/index.js`)

| Route | Status |
|---|---|
| `GET /api/health` | ✅ working |
| `GET /api/items` | ✅ working |
| `GET /api/day/:date` | ✅ working |
| `POST /api/day/:date` `{action:"create_day"}` | ✅ working |
| `POST /api/day/:date` `{action:"save_block"}` | ✅ working — consumed only (meal_type required per row) |
| `POST /api/day/:date/opening` | ✅ working |
| `POST /api/day/:date/received` | ✅ working — day-wide received save |
| `POST /api/items` | ✅ working — inserts item + auto-assigns to all active blocks |
| Reports, Qurbani, Users, Receipts | ❌ not yet built |

### Key POST body shapes

**create_day:**
```json
{
  "action": "create_day",
  "user_id": "ibrahim",
  "hijri_date": "۸ ربیع الاول ۱۴۴۸ھ",
  "day_of_week_ur": "جمعرات",
  "day_of_week_en": "Thursday",
  "students_boys": 1820,
  "students_girls": 1180,
  "students_fed": 3000
}
```

**save_block (consumed only):**
```json
{
  "action": "save_block",
  "block_id": 1,
  "user_id": "ibrahim",
  "reason_type": "correction",
  "reason_note": "",
  "rows": [
    { "item_id": 1, "meal_type": "lunch", "used_qty": 30, "used_value_pkr": 1200 },
    { "item_id": 1, "meal_type": "dinner", "used_qty": 20, "used_value_pkr": 800 }
  ]
}
```

**received (day-wide):**
```json
{
  "rows": [{ "item_id": 1, "recv_qty": 40, "recv_value_pkr": 1600 }],
  "user_id": "ibrahim"
}
```

**opening:**
```json
{
  "item_id": 3,
  "opening_qty": 40,
  "user_id": "ibrahim",
  "reason_type": "physical_count",
  "reason_note": ""
}
```

### GET /api/day/:date response shape
```json
{
  "exists": true,
  "header": { "id", "entry_date", "hijri_date", "day_of_week_ur/en", "students_boys", "students_girls", "students_fed", "locked", "is_stale" },
  "blocks": [{ "id": 1, "name_ur": "بنین", "name_en": "Boys" }, { "id": 2, ... }],
  "day_totals": [{ "item_id", "name_ur", "name_en", "unit", "opening_qty", "recv_qty_total", "recv_pkr_total", "used_qty_total", "used_pkr_total", "remaining_qty" }],
  "rows_by_block": {
    "1": [{ "item_id", "name_ur", "name_en", "unit", "breakfast": { "used_qty", "used_value_pkr" }, "lunch": {...}, "dinner": {...} }],
    "2": [...]
  },
  "daily_received": [{ "item_id", "recv_qty", "recv_value_pkr" }]
}
```

---

## Frontend — `kitchen.html` (Tab 1 Desktop)

### What's working
- Masthead: dark green, institution name Nastaliq, date display with prev/next arrows + date picker, Hijri auto-calculated (editable via modal), **three student inputs: بنین / بنات / کل (total auto-calculates)**
- Two tabs: روزانہ باورچی خانہ (active) + قربانی و عطیات (placeholder)
- Stats bar: ITEMS · اشیاء / PURCHASED PKR · خریداری / CONSUMED PKR · خرچ / STUDENTS FED · طلبہ
- Block selector: **بنین / بنات** (ناشتہ tab removed — now a consumed column)
- RTL table columns (RTL order, right→left):
  - اشیاء (ITEM) — Urdu name + English
  - اکائی (UNIT) — Urdu unit badge (کلو گرام / گرام / لیٹر / عدد)
  - موجود (OPENING) — editable inline, blue-grey tint
  - خریدا — PURCHASED (QTY + VALUE PKR) — green tint, day-wide constant
  - خرچ ناشتہ (QTY + VALUE PKR) — amber tint, per block
  - خرچ دوپہر (QTY + VALUE PKR) — amber tint, per block
  - خرچ رات (QTY + VALUE PKR) — amber tint, per block
  - باقی اسٹاک (REMAINING) — slate tint, with color-coded progress bar + LOW badge
- Opening editable inline — saves on blur
- Received saves on blur AND on save button click (DOM values collected before flush)
- Remaining updates live as user types (day-wide, nets all blocks × all meal types)
- Create Day banner for missing dates
- Add item modal with inline NLA Urdu keyboard (⌨ icon trigger)
- 30-second autosave debounce
- Autosave timestamp in footer
- Toast notifications

### API constant
`const API = 'http://localhost:8787'` — must change to deployed Worker URL before go-live.

### To serve locally
```bash
python3 -m http.server 8080
```
Then open `http://localhost:8080/kitchen.html`

### Known issues / pending
- گھی name rendering slightly tight — minor
- Urdu keyboard scope: add item modal only. May expand to other fields later.
- Students boys/girls saved in `create_day` but no separate update route for students yet (if Ibrahim changes count after day creation, it doesn't persist — deferred)

---

## PDF Export — Design Done, Build Not Started

### Export dialog
Modal triggered by EXPORT PDF button. Options:
1. Today · آج
2. This week · اس ہفتے
3. This month · اس مہینے
4. This year · اس سال
5. Custom date range · مخصوص تاریخیں (shows From/To date pickers)

Checkboxes for what to include:
- Daily item summary (opening / purchased / consumed / remaining)
- Meal-wise breakdown (ناشتہ · دوپہر · رات)
- Students fed per day
- PKR totals and per-student cost

### Report formats (mockups approved)
- **Daily** — full detail, all columns color-coded matching main table, students bar (boys/girls/total)
- **Weekly** — students per day row, per-item 7-day totals (purchased + consumed QTY/PKR, closing stock)
- **Monthly** — summary stats (days/students/purchased PKR/consumed PKR), weekly subtotals with per-student cost, item monthly totals
- **Yearly** — same structure as monthly but month-by-month rows, annual item totals + per-student cost trend

### Implementation plan (not built yet)
- jsPDF + AutoTable (already decided, client-side)
- Report data fetched from new Worker routes: `GET /api/report/daily/:date`, `GET /api/report/weekly/:date`, `GET /api/report/monthly/:year/:month`, `GET /api/report/yearly/:year`
- These routes aggregate from existing views (`v_daily_item_totals`, `v_monthly_item_totals`, `v_yearly_item_totals`)
- Bilingual headers (English + Urdu) in PDF

---

## Collected (not yet built)
- **Price per unit** on items — future feature for auto-calculating VALUE PKR from qty × unit price
- **Students update route** — `POST /api/day/:date/students` to update boys/girls/total after day creation
- **Received → day-wide confirmed** — architecture already implemented

---

## Remaining Build Order
1. **PDF export** — dialog + jsPDF report generation (daily/weekly/monthly/yearly) — **NEXT**
2. Wire Qwen2.5 translation in add item modal (OpenRouter secret needed)
3. Remaining Worker routes: qurbani, users, receipts
4. Tab 2 — Qurbani & Donations
5. Mobile card view in `kitchen.html`
6. Cloudflare Access + PIN auth
7. R2 bucket: `npx wrangler r2 bucket create ibrahim-kitchen-receipts`
8. OpenRouter secret: `npx wrangler secret put OPENROUTER_API_KEY`
9. Deploy Worker: `npx wrangler deploy`
10. Update `API` constant in `kitchen.html` to deployed Worker URL
11. Run all migrations `--remote` before go-live (001–004 already done)
12. Tighten CORS in `src/index.js` before deploy

---

## DS Standard Rules
- Claude is never called at runtime — dev side only
- No Postgres — D1 only
- All assets embedded as base64 in the HTML file (self-contained)
- **Do not generate code unless Rehan explicitly says to generate code**
- Local and remote are separate databases. Never run `ibrahim_seed_test.sql` with `--remote`.
- CORS in `src/index.js` is wide open for local dev — tighten before deploy.
- When discussing client/lead projects, refer to them by owner's name (Ibrahim's app, not "the kitchen app").
