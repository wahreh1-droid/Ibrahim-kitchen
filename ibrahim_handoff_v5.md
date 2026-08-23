# Ibrahim Shah — Kitchen Ledger App — Handoff v5
## Paste this at the start of a new chat (or upload to Claude Project)

---

## Version History Summary
| Version | Key changes |
|---|---|
| v1 | Initial schema, stack decisions, basic architecture |
| v2 | Carry-forward CTE, opening balance logic, stale flagging |
| v3 | Migration 003 — meal_type column, ناشتہ deactivated as block, became consumed column |
| v4 | Migration 004 — students_boys/girls; daily_received table; all Worker routes built; Tab 1 desktop grid complete |
| v5 | PDF reports built + fixed; sadaqa column decision; Mun unit; کبیر والا spelling; go-live plan |

---

## Client
- **Ibrahim Shah** — kitchen manager, Jamia Darul Uloom Eidgah, **کبیر والا** (Kabirwala), Khanewal District, Punjab, Pakistan
- Feeds ~3,000 students daily (Boys ~1,820 / Girls ~1,180)
- Two users: Ibrahim (owner/full access) + one assistant (entry + view)
- Report PIN system: Ibrahim assigns PINs to committee/audit team — **deferred**
- Desktop computer in the kitchen is the primary device; mobile data available but secondary
- Ibrahim is happy with progress as of Aug 2026 demo

---

## Confirmed Tech Stack
- **Frontend** — `kitchen.html` — single-file Urdu RTL, Noto Nastaliq Urdu for Urdu text, IBM Plex Mono for numbers, Inter for English. Tab 1 (Daily Kitchen) fully built and working desktop. Mobile view deferred. Tab 2 (Qurbani) not started.
- **Auth** — Cloudflare Access (email OTP) for Ibrahim + assistant. Report role uses PIN hash in D1. **Deferred.**
- **Backend** — Cloudflare Worker (`src/index.js`). All read + write routes built and working. Report routes built and tested.
- **Database** — D1 `ibrahim-kitchen`, ID `f49f9772-a241-4da9-8784-a08d408cfe5e`. Migrations 001–004 applied to both local and remote. Migration 005 pending (sadaqa + Mun).
- **File storage** — R2 for receipts. Bucket **not yet created**.
- **Reports** — Browser print-to-PDF (NOT jsPDF — jsPDF has no Arabic shaping engine and cannot render Nastaliq). Report HTML opens in new tab, browser auto-triggers print dialog, Ibrahim saves as PDF. Tested and working in Chrome, Edge, Safari.
- **LLM at runtime** — Qwen2-VL (receipt OCR), Qwen2.5 (item translation) via OpenRouter. Claude dev-side only, never runtime.

---

## Project Folder
`/Users/softwareprofiles/Documents/AI Solutions/X Project Dashboard/Ibrahim Shah/`

```
wrangler.toml                        D1 binding + main entry
src/index.js                         Worker — ALL routes built including 4 report routes
kitchen.html                         Frontend — Tab 1 desktop, wired to localhost:8787
ibrahim_migration_001.sql            APPLIED local + remote
ibrahim_migration_002.sql            APPLIED local + remote
ibrahim_migration_003.sql            APPLIED local + remote
ibrahim_migration_004.sql            APPLIED local + remote
ibrahim_cleanup_dupe_items.sql       APPLIED local (soft-deleted چینی ids 6,7,8)
ibrahim_migration_005.sql            PENDING — sadaqa_qty + Mun unit
ibrahim_dashboard_queries_v2.sql     Query reference
ibrahim_seed_test.sql                LOCAL ONLY test data
schema.sql / schema_d1.sql           Original schema (reference only)
ibrahim_report_mockups.html          Approved report mockups (reference)
```

Wrangler: v4.125.0, authenticated as wahreh1@gmail.com, account `e69f0f358f10d166af99d4bc03c1c41b`.

---

## Migration History
| Migration | What it does | Status |
|---|---|---|
| 001 | Added `is_stale` to `daily_headers`, `reason_type` to `audit_log`, rebuilt views | ✅ local + remote |
| 002 | Added `daily_received` table (day-wide received qty/PKR per item), rebuilt views | ✅ local + remote |
| 003 | Added `meal_type` column to `ledger_rows` (breakfast/lunch/dinner), deactivated ناشتہ block (id=3), rebuilt views | ✅ local + remote |
| 004 | Added `students_boys` + `students_girls` columns to `daily_headers` | ✅ local + remote |
| 005 | Add `sadaqa_qty` to `daily_received`; add `mun` to unit CHECK constraint | ❌ NOT YET WRITTEN |

---

## Schema State (post-migration 004)
- `daily_headers`: `entry_date`, `hijri_date`, `day_of_week_ur/en`, `students_fed`, `students_boys`, `students_girls`, `locked`, `is_stale`, `created_by`
- `daily_received`: `header_id`, `item_id`, `recv_qty`, `recv_value_pkr`, `updated_by`, `updated_at` — UNIQUE(header_id, item_id). **Migration 005 adds `sadaqa_qty` here.**
- `ledger_rows`: `header_id`, `block_id`, `item_id`, `meal_type` (breakfast/lunch/dinner), `used_qty`, `used_value_pkr` — UNIQUE(header_id, block_id, item_id, meal_type)
- `meal_blocks`: id=1 بنین (Boys), id=2 بنات (Girls), id=3 ناشتہ (**deactivated** — is_active=0, sort_order=3)
- `items`: unit CHECK constraint currently `('kg','g','L','pcs')`. **Migration 005 adds `mun`.**
- `opening_balances`: `value_pkr` always written as 0 — PKR tracking dropped from opening balances
- `audit_log`: `reason_type` (physical_count / correction / entry), `reason` (free-text note)
- Views: `v_daily_item_totals`, `v_daily_block_totals` (groups by meal_type), `v_monthly_item_totals`, `v_yearly_item_totals`

### Item catalog state (post-cleanup)
| id | name_ur | name_en | unit | is_active |
|---|---|---|---|---|
| 1 | آٹا | Flour | kg | 1 |
| 2 | چاول | Rice | kg | 1 |
| 3 | دال | Lentils | kg | 1 |
| 4 | گھی | Ghee | L | 1 |
| 5 | چینی | چینی | kg | 1 |
| 6-8 | چینی | چینی | kg | **0** (soft-deleted duplicates) |
| 9 | چینی | چینی | kg | 1 (added by Ibrahim during testing) |

**Note:** ids 6-8 were accidental duplicates from testing the add-item modal. Soft-deleted via `ibrahim_cleanup_dupe_items.sql`. Id 5 and 9 are both active چینی — may need consolidation with Ibrahim.

---

## Architecture Decisions (locked)

### Opening balance
- Per item per DAY, not per block. One physical store, one number.
- Carry-forward CTE on day creation — uses `daily_received` (not `ledger_rows`) for received qty.
- **Migration 005:** carry-forward CTE will also add `sadaqa_qty` to the forward calculation.
- Carry-forward rule: most recent prior day that has a row for that item (skipped days handled correctly).
- Editable inline — saves on blur via `POST /api/day/:date/opening`.
- Upstream edits mark downstream days stale. Never silently recalculated.
- Locked days = immutable anchors.

### Received stock
- **Day-wide** — one entry per item per day, stored in `daily_received` table.
- NOT per block. Ibrahim enters what arrived that day once.
- Currently: `recv_qty` (purchased quantity) + `recv_value_pkr` (purchase price from bill).
- **Migration 005 adds:** `sadaqa_qty` — donated goods quantity, NO price. Stored as-is in the item's native unit (kg, mun, L, etc.).

### Sadaqa (donated goods) — DECIDED Aug 2026
- Ibrahim confirmed: two sources of stock — purchased (bill in hand, exact price) and sadaqa (donated, no price).
- Current system annotated sadaqa as text. New: separate `sadaqa_qty` column in `daily_received`.
- **No sadaqa price** — donated goods tracked by quantity only. Clean separation from purchase records.
- **Sadaqa quantity IS included in remaining stock and carry-forward.** Formula: Opening + Purchased QTY + Sadaqa QTY − Consumed = Remaining.
- Grid: new Sadaqa QTY column between Purchased and Consumed column groups.
- Reports: sadaqa column shown in daily report; weekly/monthly/yearly aggregate sadaqa totals separately from purchased.
- The `qurbani_entries` table has `kind='inkind'` + `disposal='to_stock'` which could theoretically cover this, but Ibrahim confirmed sadaqa stock belongs in Tab 1 (kitchen ledger), not Tab 2 (qurbani/donations).

### Consumed
- **Per block per meal type** — Boys (بنین) and Girls (بنات) × Breakfast/Lunch/Dinner = 6 consumed entries per item per day.
- Stored in `ledger_rows` with `block_id` + `meal_type`.

### Remaining
- Day-wide = Opening + Purchased QTY + **Sadaqa QTY** − sum of all consumed (all blocks × all meal types).
- Shown as constant column across all block tabs.

### Units — DECIDED Aug 2026
- Current: `kg`, `g`, `L`, `pcs`
- **Adding: `mun`** — Ibrahim's kitchen uses Mun (traditional Pakistani unit, 1 Mun = 40 kg) for daily quantities.
- **Store as-is in Mun.** No backend conversion to kg. Ibrahim thinks in Mun, reports show Mun.
- Migration 005 widens the CHECK constraint to include `mun`.
- UI: add `مَن` as a unit option in the add-item modal.

### Students fed
- Three fields: `students_boys`, `students_girls`, `students_fed` (total = boys + girls, auto-calculated in frontend).
- All three sent in `create_day` and `update_students` POST bodies.

### Week boundaries — DECIDED but NOT YET BUILT
- Institution week runs **Saturday → Friday** (Thursday is half-day, Friday is full day off, but meals continue daily regardless).
- Current weekly report and monthly breakdown use Monday→Sunday. **Needs updating to Saturday→Friday.**
- Deferred — not blocking current work.

### Column color coding (table)
- Opening → blue-grey
- Purchased (QTY + PKR) → green
- **Sadaqa QTY → teal/cyan** (distinct from purchased green)
- Consumed (خرچ ناشتہ / خرچ دوپہر / خرچ رات) → amber
- Remaining → neutral slate

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
| `POST /api/items` | ✅ working — inserts item + auto-assigns to active blocks |
| `GET /api/report/daily/:date` | ✅ working — tested |
| `GET /api/report/weekly/:date` | ✅ working — tested (Mon→Sun, needs Sat→Fri update) |
| `GET /api/report/monthly/:year/:month` | ✅ working — tested |
| `GET /api/report/yearly/:year` | ✅ working — tested |
| `GET /api/report/range/:from/:to` | ✅ working — custom date range |
| Reports, Qurbani, Users, Receipts | ❌ not yet built (Qurbani pending Ibrahim input) |

### Critical: Report item source
All four report functions (`reportDaily`, `reportWeekly`, `reportMonthly`, `reportYearly`, `buildRangeReport`) drive their item lists from **`block_items` JOIN `items`** (not `opening_balances`). This matches the grid and prevents phantom items from appearing in reports. This was a bug that was fixed — do not revert to `opening_balances` as the item source.

### Known report issues (minor, not blocking demo)
- Monthly report splits to 2 pages in Edge when item count is high (Ghee orphans). Page-break rules partially help but not fully solved. Decision pending: force 2-page layout or keep compressing.
- Week boundaries use Mon→Sun instead of Sat→Fri (decided, not yet built).

---

## PDF Reports — Built and Working

### Approach
- **Browser print-to-PDF** — NOT jsPDF. jsPDF was attempted first but has no Arabic shaping engine; Nastaliq rendered as garbled characters. Browser print-to-PDF renders Nastaliq correctly via Google Fonts.
- `printHtml(html)` function builds a complete styled HTML document in memory, opens it in a new browser tab, waits for fonts to load (using `document.fonts.ready`), then auto-triggers `window.print()`.
- Ibrahim selects "Save as PDF" in the print dialog. Works in Chrome, Edge, Safari.
- `@page { size: A4 landscape }` CSS handles orientation.

### Export dialog (in kitchen.html)
- EXPORT PDF button → modal opens
- 5 range options: Today / This week / This month / This year / Custom date range
- 4 checkboxes: Daily item summary / Meal-wise breakdown / Students fed / PKR totals and per-student cost
- PKR checkbox governs EVERYTHING — stat bar cards, item columns, per-student figures. Unchecked = quantities only report.
- Custom date range: single day routes to Daily (has meal breakdown); multi-day routes to Range report.

### Report types
| Type | Orientation | Route |
|---|---|---|
| Daily | Landscape A4 | `/api/report/daily/:date` |
| Weekly | Landscape A4 | `/api/report/weekly/:date` |
| Monthly | Portrait A4 | `/api/report/monthly/:year/:month` |
| Yearly | Portrait A4 | `/api/report/yearly/:year` |
| Custom range | Landscape A4 | `/api/report/range/:from/:to` |

### Report content
- **Daily**: Masthead (dark green, Nastaliq institution name, کبیر والا), students bar (Boys/Girls/Total), item table with Opening / Purchased / Meal consumed × 3 / Remaining, DAY TOTALS row, footer with generated date + ابراہیم شاہ
- **Weekly**: Students per day row (all 7 calendar days shown, empty ones dimmed), item summary (Opening / Purchased / Consumed / Closing)
- **Monthly**: Stats bar (Operating Days / Total Students / ±Purchased PKR / ±Consumed PKR), weekly breakdown with empty weeks shown in italic ("no entries"), item monthly totals
- **Yearly**: Stats bar, monthly breakdown rows (partial months shown in italic with "(to date)"), item yearly totals

### Institution name in reports
- Urdu: `جامعہ دارالعلوم عیدگاہ`
- Location: **کبیر والا** ← correct spelling confirmed by Rehan Aug 2026 (not کابروالہ as previously used — fix this in kitchen.html masthead AND report HTML)

---

## Frontend — `kitchen.html` (Tab 1 Desktop)

### What's working
- Masthead: dark green, institution name Nastaliq, date display with prev/next arrows + date picker, Hijri auto-calculated (editable via modal), three student inputs: بنین / بنات / کل (total auto-calculates)
- Two tabs: روزانہ باورچی خانہ (active) + قربانی و عطیات (placeholder)
- Stats bar: ITEMS / PURCHASED PKR / CONSUMED PKR / STUDENTS FED
- Block selector: بنین / بنات (ناشتہ tab removed — now a consumed column)
- RTL table with color-coded columns (opening/purchased/consumed×3/remaining)
- Opening editable inline — saves on blur
- Received saves on blur AND on save button click
- Remaining updates live as user types (day-wide, nets all blocks × all meal types)
- Create Day banner for missing dates
- Add item modal with inline NLA Urdu keyboard
- 30-second autosave debounce
- Autosave timestamp in footer
- Toast notifications

### Pending frontend changes (Migration 005 scope)
- Add `sadaqa_qty` column group in the grid (between Purchased and Consumed)
- Add `مَن` unit option in add-item modal
- Update remaining calculation to include sadaqa_qty
- Fix کبیر والا spelling in masthead
- Wire `save_received` route to also send `sadaqa_qty`

### API constant — MUST CHANGE BEFORE GO-LIVE
```javascript
const API = 'http://localhost:8787'  // ← change to deployed Worker URL
```

### To serve locally
```bash
# Terminal 1
npx wrangler dev

# Terminal 2
python3 -m http.server 8080
```
Then open `http://localhost:8080/kitchen.html`

### Known port conflict pattern
Wrangler sometimes claims port 8788 instead of 8787 if an old `workerd` process is still running. Fix:
```bash
lsof -i:8787
kill -9 <PID>   # kill the workerd process
npx wrangler dev
```

---

## Tab 2 — Qurbani & Donations (NOT STARTED)

### Decisions made
- Running ledger design (NOT day-scoped like Tab 1) — confirmed
- Per-entry locking OR period close — **awaiting Ibrahim's answer on how they do it manually today** (Rehan asked him Aug 22, 2026 — no answer yet)
- `qurbani_entries` table already exists in schema with all needed fields

### Still to confirm with Ibrahim
- Do qurbani and general عطیات live in one register or two?
- Are donor names always recorded or only sometimes?
- What happens to hide sale proceeds — deposited to an account or back into kitchen spending?
- How do they currently finalize/close a period in their paper register?

---

## Go-Live Plan

### Sequence
1. Build Migration 005 (sadaqa_qty + mun unit)
2. Apply migration 005 local + verify
3. Build frontend changes (sadaqa column, mun unit, کبیر والا fix)
4. Apply migration 005 remote
5. `npx wrangler deploy` (deploys updated Worker with sadaqa routes)
6. Update `API` constant in `kitchen.html` to deployed Worker URL
7. Host `kitchen.html` at `digsyndemos.com/ibrahim` (or similar)
8. Share link with Ibrahim for testing

### Remaining build order (priority order)
1. **Migration 005** — sadaqa_qty column + mun unit (NEXT)
2. **Frontend sadaqa column** — grid update + remaining calculation
3. **Fix کبیر والا** in masthead and all report templates
4. **Mun unit** in add-item modal
5. **Students update route** — `POST /api/day/:date/students` (update boys/girls after day creation)
6. **Saturday→Friday week boundaries** in weekly report and monthly breakdown
7. **Wire Qwen2.5 translation** in add-item modal (OpenRouter secret needed)
8. **Tab 2** — Qurbani & Donations (pending Ibrahim's manual process answer)
9. **Monthly page-break fix** — Ghee orphaning on Edge (low priority, not blocking demo)
10. **Mobile card view** in `kitchen.html`
11. **Cloudflare Access + PIN auth**
12. **R2 bucket** for receipts: `npx wrangler r2 bucket create ibrahim-kitchen-receipts`
13. **OpenRouter secret**: `npx wrangler secret put OPENROUTER_API_KEY`
14. **Tighten CORS** in `src/index.js` before deploy

---

## DS Standard Rules (always apply)
- Claude is never called at runtime — dev side only
- No Postgres — D1 only
- All assets embedded as base64 in the HTML file (self-contained)
- **Do not generate code unless Rehan explicitly says to generate code** — this applies even when a task implies it, even when a problem is noticed mid-task, and even when Rehan picks an option from a list without separately authorizing a build. Always confirm.
- Local and remote are separate databases. Never run `ibrahim_seed_test.sql` with `--remote`.
- CORS in `src/index.js` is wide open for local dev — tighten before deploy.
- When discussing client/lead projects, refer to them by owner's name.
- Report item lists are driven by `block_items` not `opening_balances` — do not revert.
- When providing project summaries, always deliver as a copy-paste artifact, not inline text.
- The institution location is **کبیر والا** — use this spelling everywhere, not کابروالہ.
