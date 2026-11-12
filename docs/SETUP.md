# Setup walkthrough — Archive sheet to Supabase

Do these in order. Part 1 is already done.

The script only **reads** the live Archive Google Sheet. It never edits cells.

---

## Part 1 — Archive tables (already done)

You already ran `supabase/migrations/20261007000000_archive_schema.sql`.

Confirm: Supabase → **Table Editor** → schema dropdown → **archive**. You should see empty tables (`orders`, `products`, …) and `archive_sync_control` with rows in it.

---

## Part 2 — Add the transfer and maintenance SQL (once)

1. Open the project → **SQL Editor** → **New query**.
2. Paste all of `supabase/migrations/20261012000000_archive_transfer_rpc.sql`. Click **Run**.
3. New query. Paste all of `supabase/migrations/20261012010000_archive_maintenance.sql`. Click **Run**.

If the RLS warning appears, choose **Run and enable RLS**.

You should see Success with no red error. The second file is safe to run again. The first one is meant to run once.

---

## Part 3 — Copy two values from Supabase

Go to **Project Settings → API** (or **API Keys**).

| What | Where | Looks like |
| --- | --- | --- |
| Project URL | Project Settings → API / Data API | `https://xxxxxxxx.supabase.co` |
| Secret key | API Keys → **service_role** (on newer projects it may be under Legacy API keys) | a long `eyJ...` string |

Do not use the `anon` / publishable key. It is blocked on purpose.

Treat the service_role key like a password. Do not put it in a sheet cell, chat, or email.

---

## Part 4 — Put the script on the live Archive Google Sheet

1. Open the **live** Neulight OMS Archive Google Sheet (the one the existing archive engine writes to). Not the xlsx file.
2. **Extensions → Apps Script**.
3. Delete whatever is in `Code.gs`, or add a file named `ArchiveTransfer`.
4. Paste all of `apps-script/ArchiveTransfer.gs`. Click **Save**.
5. Click the gear icon (**Project Settings**). Set **Time zone** to `(GMT+08:00) Manila`.
6. On the same Project Settings page, under **Script properties**, add:
   - `SUPABASE_URL` = the Project URL from Part 3 (no trailing slash)
   - `SUPABASE_SERVICE_ROLE_KEY` = the service_role key
7. Click **Save script properties**.
8. Close the Apps Script tab and **reload the spreadsheet**.
9. An **Archive** menu appears next to Help. It can take a few seconds.

Tab names must match exactly (`orders`, `products`, `order_lines`, …). A renamed tab fails with "No sheet named …".

---

## Part 5 — Connect and test

1. **Archive → Test connection**. Google asks you to authorize the script. Choose **Continue**, then **Advanced → Go to (project) (unsafe) → Allow**. "Unsafe" means Google has not reviewed the script. It is your own code.
2. If the alert did not appear after authorizing, click **Test connection** again. You should see "Connected" and a list of enabled sheets.

| Error | Meaning |
| --- | --- |
| `401` / `Invalid API key` | Wrong key. Use the **service_role** key, not anon or publishable. |
| `404` / function not found | Part 2 did not run, or it errored. |
| `Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY…` | Script properties were not saved. Add them in Apps Script Project Settings. |

---

## Part 6 — Test with a small sheet

1. **Archive → Dry run products**. This checks rows and saves nothing. Expect about `read 134, inserted 134, failed 0`. In a dry run, "inserted" means "would insert".
2. If `failed` is 0, **Archive → Transfer products**.
3. In Supabase → Table Editor → schema **archive** → `products`. You should see about 134 rows.
4. Run **Transfer products** again. Expect `inserted 0, skipped 134`. That proves a rerun does not duplicate rows.

---

## Part 7 — Other sheets, then everything else

For a single tab (including `orders`): **Archive → Dry run one sheet…** or **Transfer one sheet…**. Leave the name blank to use the tab you have open.

Then **Archive → Transfer all enabled sheets**. It goes through every enabled sheet in load order: masters, then orders, then wallets, then the rest.

### The 6-minute limit

Google stops a script at about 6 minutes. A large sheet can end as **PARTIAL — Stopped before the Apps Script time limit**. That is expected. Run the same menu item again. Rows already saved are skipped and it continues. Repeat until the sheet says SUCCESS.

**Transfer all enabled sheets** stops at the first sheet that ends PARTIAL or FAILED. The next run starts from that sheet.

---

## Part 8 — Check the results

Run these in the Supabase SQL Editor.

```sql
select source_table, last_status, rows_read, rows_inserted, rows_skipped, rows_changed, rows_failed, last_error
from archive.archive_sync_control
order by load_order;
```

```sql
select source_table, source_row_number, row_key, failure_reason
from archive.archive_row_failures
order by detected_at desc
limit 50;
```

```sql
select source_table, row_key, detected_at
from archive.archive_row_changes
where resolution = 'PENDING';
```

A few failures can be normal (for example a blank ID). Read `failure_reason` before rerunning. After a time-limit stop, the `read` count can include a batch that was still in progress.

---

## Part 9 — After setup

- Sheets that are **off** by default: `warehouse_admin_bucket`, `warehouse_dashboard`, `warehouse_dashboard_work`, `reservations_historical_recover`, `api_tokens`. To turn one on:

```sql
update archive.archive_sync_control
set enabled = true
where source_table = 'reservations_historical_recover';
```

- **Free plan:** the project pauses after about a week of low activity. Run a transfer at least weekly. The script is not on a timer yet, because its pop-ups do not work in a scheduled trigger.
- **When you update the script:** paste the new `ArchiveTransfer.gs` into Apps Script and save. Script properties stay. To rotate the key, edit `SUPABASE_SERVICE_ROLE_KEY` in Project Settings → Script properties.
- **When the sheet changes** (headers, columns, new tabs): follow `docs/MAINTENANCE.md`. The full reference is `docs/archive-documentation.html`.
- Do not rename headers in the middle of a run. A new header stops that sheet with "has headers with no column" until you add the column or map the header.
