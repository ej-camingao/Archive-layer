# Neulight OMS Archive Layer 2 — Project Understanding

> Living knowledge base for agents. **Update this file** when you learn something new (client answers, schema drift, decisions, blockers). Do not treat it as frozen.

**Last updated:** 2026-11-11  
**Spec:** `Neulight OMS Archive Layer 2 Specification.md` (v1.0, DEVELOPMENT SPECIFICATION)  
**Status:** Archive schema is on Supabase. First transfer path is Google Apps Script (`apps-script/ArchiveTransfer.gs`) plus `supabase/migrations/20261012000000_archive_transfer_rpc.sql` (run that SQL before the first transfer).  
**Hosting:** **Supabase PostgreSQL, Free plan** (project in region Northeast Asia / Seoul, org SPARKDPH INC). Upgrade to Pro at go-live.

---

## 1. One-sentence goal

Build **Archive Engine #2**: an idempotent, read-only-from-source pipeline that copies the Neulight OMS Archive into **MySQL** as permanent historical storage — without redesigning OMS operations or Layer 1 (Operational → Archive).

---

## 2. Architecture (frozen)

```
Layer 1  Operational Google Sheets
            │  Archive Engine #1 (EXISTS — out of scope)
            ▼
Layer 2  Archive Google Sheets  ← source for this project
            │  Archive Engine #2 (THIS PROJECT)
            ▼
Layer 3  MySQL Historical Database  ← permanent store only
```

| Rule | Detail |
|------|--------|
| Source | Archive Database (Sheets / exports). Engine must **never modify** it on normal transfer. |
| Destination | MySQL. Historical storage only — not live OMS. |
| Flow | READ → VALIDATE → TRANSFORM → WRITE MySQL → VERIFY → LOG |
| Idempotent | Safe to rerun; no duplicate inserts; classify insert / skip identical / log change. |

**Out of scope:** Operational DB, Engine #1, AppSheet, marketplace APIs, inventory/reservation/wallet/etc. business engines, moving live ops to MySQL.

---

## 3. Source files in this workspace

| File | Believed role | Size | Notes |
|------|---------------|------|--------|
| `Neulight_OMS_Archive ao 7.26.2026 17_03.xlsx` | One-time **full** dated dump (~2026-07-26 17:03) | ~30 MB | Bulk history. Spec also says end-of-July may already be in MySQL — **confirm with client**. |
| `Neulight_OMS_Archive.xlsx` | **Live** intermediary (waiting before MySQL) | ~5.5 MB | Smaller current archive queue. |
| `Neulight OMS Archive Layer 2 Specification.md` | Technical spec + delivery addendum | — | Source contract: “August 2026” workbook schema. |

Client framing (chat): one file = one-time full archive; the other = live intermediary before MySQL. Filenames/sizes support that split.

**Production source is still unclear:** live Google Sheet vs xlsx drop vs both. Spec assumes Google Sheets Archive.

---

## 4. Sheet inventory vs spec

Spec lists **33** sheets. Both workbooks include all 33. Extras:

| Workbook | Sheet count | Extra sheets |
|----------|-------------|--------------|
| Live `Neulight_OMS_Archive.xlsx` | 34 | `reservations_historical_recover` (~13.4k rows; has `order_line_id`; lacks `repack_count` / `hold_reason`) |
| July dump | 37 | `audit_log` (empty), `Beginning_Inventory`, `checkpoint_log`, `Shopee_Raw_Import` (buyer PII) |

### Volume sketch (approx. valued data rows)

| Table | July dump | Live archive | Implication |
|-------|-----------|--------------|-------------|
| orders | ~39k | ~7k | Live smaller / newer queue |
| order_lines | ~45k | ~7.7k | Same |
| reservations | ~25k | ~5.2k | Same |
| wallet_transactions | ~35k | ~5.2k | Same |
| wallet_transactions_lines | ~45k | **0** | Flushed from live? |
| missing_data / returns | populated | **0** / empty | Same |
| packing_events / turnover_lines | **0** | populated | Appeared after July |
| inventory_ledger / oms_status_history / job_execution_log | **0** | **0** | Schema only — history may be elsewhere |

**Neither file alone is a complete historical picture.** July + live (+ existing MySQL, if any) must be composed carefully.

### Header fidelity

Core Group A headers (`orders` 36 cols, `order_lines` 18, reservations, inventory_*, wallet_*, returns, packing_events, turnover_lines, oms_status_history, product_cost_history) **match the spec** in both files.

Known quirks:

- Live `wallet_transactions`: **2 unnamed columns** (AB/AC) with numeric values — schema drift.
- Mixed types on IDs (`platform_order_id` as text and number).
- Awkward names: `products.BRAND`, `missing_data.P60 days`, `warehouse_admin_bucket.Emoji`.
- `api_tokens`: live secrets (`access_token`, `refresh_token`, `app_secret`, etc.) — **do not copy plaintext into MySQL** (spec §12).

---

## 5. Table classification (from spec)

| Group | Role | Tables (summary) |
|-------|------|------------------|
| **A** | Priority transactional history | orders, order_lines, reservations, inventory_ledger, wallet_*, returns, packing_events, turnover_lines, oms_status_history, product_cost_history, job_execution_log, missing_data |
| **B** | Master / reference | products, suppliers, warehouses, couriers, users, packing_stations, promo_pack_components, sku_derivative_rules, oms_status_mapping, forecast_baseline |
| **C** | Config (optional snapshot; must not control OMS) | device_settings, financial_settings, platform_settings, system_settings, system_messages |
| **D** | Dashboard snapshots (optional; never block A) | warehouse_admin_bucket, warehouse_dashboard, warehouse_dashboard_work |
| **Security** | Default: no secrets | api_tokens → metadata only unless encrypted design approved |

---

## 6. Engine requirements (must-haves)

In-scope capabilities from spec §3: Sheet reader, MySQL connection, schema + migrations, column mapping by **header name**, type conversion, batch insert (~500 configurable), duplicate prevention, incremental + initial load, backfill, dry-run, retries, error/execution logging, validation, count reconcile, RI checks, status reporting.

**Dedup keys (examples):**  
`orders` → `platform_order_id`; `order_lines` → `order_line_id`; `reservations` → `reservation_id`; `inventory_ledger` → `ledger_id`; wallet / returns / packing / turnover / status / cost history → their `*_id` columns.

**Upsert policy:** NO key → INSERT; same → SKIP; different → LOG CHANGE (`source_changed`); **do not silently overwrite**.

**Control tables in MySQL:** `archive_sync_control`, `archive_sync_log` (separate from OMS `job_execution_log`).

**Money:** `DECIMAL` (e.g. 18,4), never float. **Dates:** one timezone standard (spec recommends UTC). **Blanks:** NULL not `""` unless required.

**Pilot order:** orders → order_lines → inventory_ledger → wallet_transactions → rest.  
**Recommended load order:** masters first, then orders tree, then wallets/returns/history (spec §41).

**DoD:** schema certified, July reconciled, idempotency, dry-run, RI audit, secrets excluded, production trigger + first recurring run (spec §52).

**Delivery addendum (not frozen):** ~2–3 weeks / 40–70 hours estimate.

---

## 7. Open questions for the client

Track answers here when received. Until then, treat as blockers for production design.

| # | Question | Answer | Date |
|---|----------|--------|------|
| 1 | Is end-of-July already in MySQL, or do we load the July xlsx? Tables / counts / cutoff? | | |
| 2 | Production source: live Google Sheet, xlsx, or both? Spreadsheet ID / access? | | |
| 3 | How to compose July + live without double inserts (overlap key / cutoff)? | | |
| 4 | Why empty `inventory_ledger` / `oms_status_history` in both files? Expected? | | |
| 5 | Extra sheets in or out? (`reservations_historical_recover`, July extras, Group C/D, `api_tokens` metadata-only?) | | |
| 6 | Who runs MySQL (host/version/creds)? Sync cadence? Runtime: Apps Script vs server job? | **No server yet (2026-09-19).** Client asked for suggestions — see `database-suggestion.md` (DigitalOcean MySQL, Cloud SQL MySQL, AWS RDS MySQL, Supabase Postgres). Choice pending. **Update:** client chose Supabase (Postgres), Free plan first, Pro at go-live. Sync cadence / runtime still open. | 2026-10-07 |
| 7 | Changed-row policy: log-only forever, or later update MySQL? `inventory_balance` snapshot vs history? | | |

**MySQL hosting:** Client confirmed they do **not** have a server yet and want options. Spec was written for MySQL, but Postgres is allowed if they choose Supabase. Full client-facing comparison: `database-suggestion.md`. Engine = pipeline + schema; cloud account should be in the **client’s** name.

---

## 8. Decisions log

Record agreed decisions (agent or human). Newest first.

| Date | Decision | Source |
|------|----------|--------|
| 2026-11-13 | `oms_status_mapping` sheet has duplicate `platform_status` values. Switched to `key_mode = hash` so identical extra rows skip instead of failing Transfer all. SQL: `supabase/migrations/20261113000000_oms_status_mapping_allow_duplicate_status.sql`. | Client sheet + agent |
| 2026-11-11 | Live Archive has two historical-reservation tabs. `reservations_historical_recover` already existed. New tab `reservations_historical_recovery` registered as its own table (same columns, PK `reservation_id`). Both stay `enabled = false`. SQL: `supabase/migrations/20261111000000_add_reservations_historical_recovery.sql`. | Client sheet + agent |
| 2026-10-12 | Maintenance migration `20261012010000_archive_maintenance.sql`: per-sheet `archive_header_map` (rename or ignore headers without editing code), `prepare_archive_table()` for new sheets, `apply_accepted_changes()` to copy ACCEPTED changes in (never erases stored values), blank cells excluded from `_row_hash`, unrecognised booleans fail the row. Script gained "Dry run / Transfer one sheet…". Guides: `docs/MAINTENANCE.md`, `docs/archive-documentation.html`. | Agent |
| 2026-10-12 | First transfer runtime is **Google Apps Script** on the live Archive spreadsheet (not AppSheet). Sheet stays read-only. Script calls service_role RPCs (`archive_begin_run`, `archive_apply_batch`, `archive_finish_run`); `archive` schema stays off the Data API. Idempotent: insert / skip identical / log change. Pilot order in the menu: products, then orders, then all enabled sheets. | Agent |
| 2026-10-07 | Archive schema written as one migration: private `archive` schema (not exposed via Data API, RLS on, no API grants), 40 data tables mirroring live sheets + `archive_sync_log`, `archive_sync_control` (seeded registry with load order), `archive_row_changes`, `archive_row_failures`. IDs as text, money/qty `numeric(18,4)`, datetimes `timestamptz` (source read as Asia/Manila), no FKs (RI checked by engine). Every data table has `_row_hash`, `_source_file`, `_execution_id`, `_loaded_at`, `_last_seen_at`. `api_tokens` → `api_tokens_metadata` (no secrets). Group D, `reservations_historical_recover`, `api_tokens` registered but disabled. | Agent |
| 2026-10-07 | Client chose **Supabase PostgreSQL**, starting on **Free**; upgrade to Pro at go-live (pausing + no backups on Free). Engine targets Postgres, not MySQL. | Client + agent |
| 2026-09-19 | Client has no DB host yet; drafted 4 options in `database-suggestion.md` (not locked). | Client + agent |
| 2026-09-19 | Initial understanding captured from spec + both xlsx analyses + client chat framing of two archives. | Agent review |

---

## 9. Risks / gotchas

- Spec says Google Sheets; workspace has **xlsx exports** only so far.
- Spec §6 “July already in MySQL” vs “use July file as initial load” — conflicting if unverified.
- Incomplete history across the two files (see volume table).
- Schema drift: unnamed wallet columns; extra sheets not in frozen 33. Live workbook (2026-10-07) has **40 sheets**: new empty sheets `goods_receipts`, `goods_receipt_lines`, `return_lines`, `supply_counts`, `supply_purchases`, `wallet_statements` (tables created for them).
- `wallet_txn_id` blank on ~2k of 9,865 live rows → not a PK; dedup on `wallet_txn_id` when present, else `_row_hash`.
- Some long IDs were stored as numbers in Sheets (e.g. `2.60708642987e+20`) — precision already lost in the export; transfer must read IDs as text from the live Google Sheet, not from float cells.
- `orders.packing_duration_seconds` mixes numbers, times and dates in source; transfer must convert to seconds.
- Free plan pauses after ~1 week of low activity and has no automatic backups.
- Secrets present in `api_tokens` in shared files — handle carefully; prefer not retaining long-term in project folder.
- Transfer runtime is Apps Script with the service_role key in Script Properties. Free-plan URL Fetch and 6-minute execution limits apply; reruns skip rows already stored.
- Long IDs that Google stored as numbers can already be rounded in the sheet. The script sends the displayed text.
- Sheets won’t scale if live archive grows back to July size — incremental + MySQL permanence matter.

---

## 10. How agents should maintain this file

1. After client answers → fill **§7** Answer/Date; move settled items into **§8 Decisions**.
2. After inspecting schema/data → update **§3–§4** (row counts, new drift, new files).
3. After implementation choices → log in **§8**; update **Status** at top.
4. Keep language concrete (paths, sheet names, keys). Prefer short tables over long prose.
5. Do **not** delete historical decisions; strike or note supersession instead.
6. Bump **Last updated** on every meaningful edit.

---

## 11. Key paths

```
c:\Users\ethan\Documents\Archive layer\
├── understanding.md                          ← this file
├── database-suggestion.md                    ← client-facing hosting options
├── Neulight OMS Archive Layer 2 Specification.md
├── supabase\migrations\20261007000000_archive_schema.sql  ← archive schema (already applied)
├── supabase\migrations\20261012000000_archive_transfer_rpc.sql  ← run once before the first transfer
├── supabase\migrations\20261012010000_archive_maintenance.sql  ← run after transfer_rpc (safe to rerun)
├── supabase\migrations\20261111000000_add_reservations_historical_recovery.sql  ← add recovery tab; both recover tabs stay off
├── apps-script\ArchiveTransfer.gs            ← paste into the Archive spreadsheet's Apps Script
├── docs\SETUP.md                             ← step-by-step setup walkthrough
├── docs\MAINTENANCE.md                       ← what to do when headers, columns or sheets change
├── docs\archive-documentation.html           ← full system documentation
├── Neulight_OMS_Archive.xlsx                 ← live / intermediary
└── Neulight_OMS_Archive ao 7.26.2026 17_03.xlsx  ← one-time full dump
```
