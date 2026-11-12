# Archive maintenance guide

What to do when the Archive Google Sheet changes: headers renamed, columns added or removed, sheets added, renamed or deleted.

For the full system description, see `docs/archive-documentation.html`.

---

## How the pieces fit

| Piece | Where | What it decides |
|---|---|---|
| Archive tables | Supabase, schema `archive` | Which columns exist and their types |
| `archive_sync_control` | Supabase table | Which sheets are transferred, in what order, and which column is the ID |
| `archive_header_map` | Supabase table | Sheet headers whose name differs from the table column, or that should be ignored |
| Transfer functions | Supabase, `public.archive_*` | Checking and saving rows |
| `ArchiveTransfer.gs` | Apps Script in the Archive spreadsheet | Reads the sheet and sends rows |

The script reads the table columns and the header map from Supabase at the start of every run. **Most changes are made in Supabase only. The script rarely needs editing.**

### Rules the script enforces

- The **tab name** must match `source_table` in `archive_sync_control` exactly.
- Every **header** must match a table column, unless it is listed in `archive_header_map`. Otherwise the whole sheet stops with *"has headers with no column"*. This is deliberate: columns are never shifted or dropped silently.
- The **ID column** (`key_columns`) must be present, or the sheet stops with *"missing key column"*.
- Headers are matched **exactly**: `Order Date`, `order_date` and `order_date ` are three different headers. Leading and trailing spaces are trimmed.

### How "changed" works

Each stored row has a fingerprint (`_row_hash`) of its non-blank values. On every run:

| Sheet row vs stored row | Result |
|---|---|
| ID not stored yet | **inserted** |
| Same ID, same values | **skipped** |
| Same ID, different values | **changed**: logged in `archive_row_changes`, the stored row is **not** overwritten |

Blank cells are not part of the fingerprint. Adding an empty column does not mark existing rows as changed.

---

## Before and after every change

1. Make the Supabase change in **SQL Editor**.
2. Save the same SQL as a new file in `supabase/migrations/`, named with the date (e.g. `20261103000000_add_delivery_partner.sql`). This is your record of what the database looks like.
3. In the sheet: **Archive → Dry run one sheet…** and enter the tab name (or open that tab and leave the box blank).
4. Check that the dry-run result has `failed 0`. Then run the real transfer.

---

## 1. A header was renamed in the sheet

Example: `order_date` became `Order Date`. Same data, new label.

**Do not rename the table column.** Map the new header to the existing column instead. Renaming the column would make every stored row look changed.

**Supabase:**

```sql
insert into archive.archive_header_map (source_table, source_header, target_column, note)
values ('orders', 'Order Date', 'order_date', 'Renamed in sheet 2026-11-03');
```

**Script:** nothing.

**Check:** dry run the sheet. Rows should be `skipped`, not `changed`.

If the header is renamed again later, update the same row:

```sql
update archive.archive_header_map
set source_header = 'Order date'
where source_table = 'orders' and source_header = 'Order Date';
```

---

## 2. A column was added to the sheet

Example: a new `delivery_partner` column appears in `orders`.

Until you act, that sheet stops with *"orders has headers with no column: delivery_partner"*. Other sheets keep working.

**Pick one:**

### a) Archive the new column

**Supabase:** add the column. Pick the type from the table below.

```sql
alter table archive.orders add column delivery_partner text;
```

If the header is not a plain lowercase name (e.g. `Delivery Partner`), use a lowercase column name and map it:

```sql
alter table archive.orders add column delivery_partner text;

insert into archive.archive_header_map (source_table, source_header, target_column)
values ('orders', 'Delivery Partner', 'delivery_partner');
```

**Script:** nothing.

**What the next run does:**

- New rows are inserted with the new column.
- Stored rows whose new cell is **blank** are skipped.
- Stored rows whose new cell **has a value** are logged as **changed**, because they now carry data the archive doesn't have. To copy those values in, accept and apply them ([section 10](#10-reviewing-changed-rows)).

### b) Ignore the new column

Use this for helper or formula columns that are not history.

```sql
insert into archive.archive_header_map (source_table, source_header, target_column, note)
values ('orders', 'temp_calc', null, 'Helper column, not archived');
```

`target_column = null` means "skip this header".

### Choosing a column type

| Sheet content | Column type |
|---|---|
| IDs, codes, names, statuses, anything with leading zeros or over 15 digits | `text` |
| Money, prices, fees, costs, weights, quantities | `numeric(18,4)` |
| Whole counts only (e.g. `repack_count`) | `integer` |
| Dates or date + time | `timestamptz` |
| TRUE/FALSE, Y/N, yes/no, 1/0 | `boolean` |
| JSON text | `jsonb` |

When unsure, use `text`. Text never rejects a value. You can change the type later ([section 6](#6-a-columns-data-type-changed)).

---

## 3. A column was removed from the sheet

**Supabase:** nothing. **Never drop the table column.** The archive keeps the values it already has.

**Script:** nothing. A header that is missing from the sheet is fine, unless it is the ID column.

**What the next run does:**

- New rows store blank for that column.
- Stored rows that are still in the sheet and had a value in that column are logged as **changed** (the value is now missing). Accept and apply them ([section 10](#10-reviewing-changed-rows)). Applying keeps the stored value, because it never erases data, and stops these rows from being flagged again.

---

## 4. A new sheet (tab) was added

Example: a new `courier_rates` tab.

New tabs are **not** transferred until they are registered. The script only reads sheets listed in `archive_sync_control`.

**Supabase, step 1: create the table.** Mirror the headers. Choose a primary key from the sheet's stable ID column.

```sql
create table archive.courier_rates (
  rate_id        text primary key,
  courier_code   text,
  weight_from_kg numeric(18,4),
  weight_to_kg   numeric(18,4),
  rate           numeric(18,4),
  effective_date timestamptz
);
```

If you see the RLS warning, choose **Run and enable RLS**.

**Supabase, step 2: add bookkeeping columns and lock it down.**

```sql
select archive.prepare_archive_table('courier_rates');
```

**Supabase, step 3: register it.**

```sql
insert into archive.archive_sync_control
  (source_table, target_table, table_group, load_order, enabled, key_mode, key_columns)
values
  ('courier_rates', 'courier_rates', 'B', 21, true, 'pk', array['rate_id']);
```

| Field | Meaning |
|---|---|
| `source_table` | Exact tab name in the Google Sheet |
| `target_table` | Table name in `archive` (normally the same) |
| `table_group` | `A` history, `B` master/reference, `C` settings, `D` dashboard, `X` other |
| `load_order` | Position in "Transfer all". Masters 10–29, orders 30–39, wallet 40–49, returns 50–59, others 60–69, settings 70–79 |
| `key_mode` | How a row is identified (below) |
| `key_columns` | The ID column(s) |

| The sheet has… | `key_mode` | `key_columns` |
|---|---|---|
| One ID column that is always filled and never reused | `pk` | `array['the_id']` |
| No single ID, but 2–3 columns together are unique | `composite` | `array['col_a', 'col_b']`, also make them the primary key |
| No reliable ID at all | `hash` | `array[]::text[]` |

For `composite`, the table needs `primary key (col_a, col_b)` instead of a single primary key.

For `hash`, the table needs a generated ID and a unique fingerprint:

```sql
create table archive.some_log (
  archive_row_id bigint generated always as identity primary key,
  -- sheet columns
  note text
);
select archive.prepare_archive_table('some_log');
create unique index some_log_row_hash_key on archive.some_log (_row_hash);
```

With `hash`, any edit to a row makes it a new row. Use it only for sheets whose rows are never edited.

**Script:** nothing. Test it with **Archive → Dry run one sheet…** → `courier_rates`, then **Transfer one sheet…**. After that it is included in **Archive → Transfer all enabled sheets**.

---

## 5. A sheet was renamed or deleted

### Renamed tab

The run stops with *"No sheet named …"*.

**Preferred:** rename the tab back. Nothing else changes.

**If the new name must stay:** first resolve any pending changes for the old name ([section 10](#10-reviewing-changed-rows)), then:

```sql
update archive.archive_sync_control
set source_table = 'new_tab_name'
where source_table = 'old_tab_name';

update archive.archive_header_map
set source_table = 'new_tab_name'
where source_table = 'old_tab_name';
```

Keep `target_table` as it is. The archive table name does not need to change.

### Deleted tab

Turn it off. **Never drop the table.** It holds history.

```sql
update archive.archive_sync_control
set enabled = false
where source_table = 'old_tab_name';
```

---

## 6. A column's data type changed

Symptom: rows fail with errors like *invalid input syntax for type numeric: "N/A"* or *Column matched expects true/false, got "maybe"*.

Find them:

```sql
select source_row_number, row_key, failure_reason
from archive.archive_row_failures
where source_table = 'orders'
order by detected_at desc;
```

**Pick one:**

- **The sheet value is a mistake.** Fix the cell, then rerun. Nothing in Supabase.
- **The column really holds a new kind of value.** Widen the type. `text` accepts anything:

```sql
alter table archive.orders
  alter column shipping_status type text using shipping_status::text;
```

After a type change, values are fingerprinted differently. Rows still in the sheet show up as **changed** once. Accept and apply them ([section 10](#10-reviewing-changed-rows)). The values are the same; this only refreshes the fingerprints.

Avoid narrowing a type (e.g. `text` → `numeric`) on a table that already has data. It fails if any stored value doesn't convert.

---

## 7. The ID column changed or has problems

| Problem | Symptom | What to do |
|---|---|---|
| ID header renamed | *"missing key column"* | Map the new header to the ID column ([section 1](#1-a-header-was-renamed-in-the-sheet)) |
| Some rows have a blank ID | Those rows fail with *missing key* | Fill the IDs in the sheet. If blanks are normal for this sheet, ask before changing `key_mode` |
| Same ID twice in the sheet | Second one fails with *duplicate key in this batch*, or shows as **changed** | Fix the duplicate in the sheet. Only one row per ID is archived |
| Client switches to a different ID column | Old and new rows won't match | Don't change `key_columns` on a table with data. Create a new table and register it as a new sheet |

---

## 8. The unnamed wallet columns get names

`wallet_transactions` has two blank headers (columns AB and AC), stored as `unnamed_col_ab` and `unnamed_col_ac`. If the client names them, the sheet stops with *"has headers with no column"*.

**Supabase:** map the names to the existing columns:

```sql
insert into archive.archive_header_map (source_table, source_header, target_column) values
  ('wallet_transactions', 'voucher_amount', 'unnamed_col_ab'),
  ('wallet_transactions', 'coin_cashback',  'unnamed_col_ac');
```

Use the real names in place of `voucher_amount` and `coin_cashback`. Don't rename the table columns.

---

## 9. A sensitive column appears

If any sheet gains a column with passwords, tokens, keys, or personal data that shouldn't be archived, mark it ignored before the next run:

```sql
insert into archive.archive_header_map (source_table, source_header, target_column, note)
values ('api_tokens', 'webhook_secret', null, 'Secret, never archived');
```

`api_tokens` already skips `access_token`, `refresh_token`, `app_key`, `app_secret`, `shop_cipher` and `main_account_id`.

---

## 10. Reviewing changed rows

When a stored row's values differ from the sheet, the archive keeps the stored version and logs the sheet version.

**See what is waiting:**

```sql
select source_table, count(*) as pending
from archive.archive_row_changes
where resolution = 'PENDING' and applied_at is null
group by source_table;
```

**Compare one row** (stored vs sheet):

```sql
select
  (select to_jsonb(o) from archive.orders o where o.platform_order_id = c.row_key) as stored,
  c.incoming_row as from_sheet
from archive.archive_row_changes c
where c.source_table = 'orders' and c.resolution = 'PENDING'
limit 5;
```

**Accept the sheet version** (all pending for one sheet):

```sql
update archive.archive_row_changes
set resolution = 'ACCEPTED', resolved_at = now(), resolved_by = 'ethan'
where source_table = 'orders' and resolution = 'PENDING';

select archive.apply_accepted_changes('orders');
```

The result looks like `{"applied": 120, "stale": 0}`. *Stale* means the stored row was updated by an earlier change after this one was logged; it is safe to ignore.

**Reject** (keep the stored version):

```sql
update archive.archive_row_changes
set resolution = 'REJECTED', resolved_at = now(), resolved_by = 'ethan'
where source_table = 'orders' and row_key = '2606144CHNV8Q1';
```

A rejected row keeps showing up as *changed* in run counts while the sheet still has the different value. It is not logged twice.

What applying does:

- Copies the sheet values into the stored row.
- Never erases a stored value. A blank cell in the sheet keeps what was stored.
- Never changes the ID column.
- Updates the fingerprint, so the next run skips the row.

`hash` sheets (`missing_data`, the dashboards) have no change queue. An edited row there is stored as a new row.

---

## 11. Turning sheets on or off

```sql
select source_table, enabled, load_order
from archive.archive_sync_control
order by load_order;

update archive.archive_sync_control set enabled = true  where source_table = 'reservations_historical_recover';
update archive.archive_sync_control set enabled = false where source_table = 'warehouse_dashboard';
```

Off by default: `warehouse_admin_bucket`, `warehouse_dashboard`, `warehouse_dashboard_work`, `reservations_historical_recover`, `api_tokens`.

---

## 12. When the script itself needs editing

Only for:

- Changing `ARCHIVE_BATCH_SIZE` (rows per request, default 150) or `ARCHIVE_TIME_BUDGET_MS` (stop before Google's 6-minute limit).
- A column that needs special conversion, like `packing_duration_seconds` (times converted to seconds) in `coerceDuration_`.
- Changing the timezone (`ARCHIVE_TIMEZONE`, default `Asia/Manila`).

After editing `apps-script/ArchiveTransfer.gs` on your PC, paste the whole file into Extensions → Apps Script and save. Saved credentials stay.

---

## Error messages

| Message | Cause | Fix |
|---|---|---|
| `No sheet named X` | Tab renamed or deleted | [Section 5](#5-a-sheet-was-renamed-or-deleted) |
| `Sheet X has headers with no column: …` | New or renamed header | [Section 1](#1-a-header-was-renamed-in-the-sheet) or [section 2](#2-a-column-was-added-to-the-sheet) |
| `Sheet X is missing key column Y` | ID header renamed or removed | [Section 7](#7-the-id-column-changed-or-has-problems) |
| `Duplicate header for Y` | Two headers map to the same column | Rename or remove one header, or fix the header map |
| `Unknown archive sheet: X` | Sheet not in `archive_sync_control` | [Section 4](#4-a-new-sheet-tab-was-added) step 3 |
| `Sheet X is turned off in archive_sync_control` | `enabled = false` | [Section 11](#11-turning-sheets-on-or-off) |
| `invalid input syntax for type …` (in failures) | Value doesn't fit the column type | [Section 6](#6-a-columns-data-type-changed) |
| `Column X expects true/false, got "…"` | Unrecognised boolean | Fix the cell, or change the column to `text` |
| `missing key` (in failures) | Blank ID cell | Fill the ID in the sheet |
| `401` / `Invalid API key` | Wrong or rotated key | Update `SUPABASE_SERVICE_ROLE_KEY` in Apps Script Project Settings → Script properties |
| `Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY…` | Script properties missing | Add `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` in Apps Script Project Settings |
| `404` on an `archive_*` function | Transfer SQL not run | Run the migrations in `supabase/migrations/` |
| `PARTIAL – Stopped before the Apps Script time limit` | Big sheet, 6-minute limit | Run the same transfer again |
| `PARTIAL – N row(s) failed` | Some rows were rejected | Check `archive_row_failures` ([section 6](#6-a-columns-data-type-changed), [section 7](#7-the-id-column-changed-or-has-problems)) |

---

## Never do these

- Drop an archive table or column that has data.
- Rename an archive column to match a renamed header. Map the header instead.
- Change `key_columns` on a table that already has rows.
- Put the service_role key in a sheet cell, chat or email.
- Edit stored rows in Table Editor by hand. Use the change queue so there's a record.
