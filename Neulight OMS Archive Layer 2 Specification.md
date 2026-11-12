NEULIGHT OMS
Archive Layer 2: Google Sheets Archive → MySQL
Technical Development Specification v1.0
Status: DEVELOPMENT SPECIFICATION
Scope: Archive Database → MySQL
Previous layer: Operational Database → Archive Database
Source schema: Neulight OMS Archive workbook, August 2026
Target: MySQL Historical Archive Database
1. PURPOSE
Build an end-to-end archival engine that transfers historical data from the existing Neulight OMS Archive
Google Spreadsheet into MySQL.
This is the second layer of the OMS archival architecture.
The existing operational archive engine is already responsible for:
Operational Google Sheets
↓
Archive Google Sheets
This project is responsible only for:
Archive Google Sheets
↓
MySQL
The existing Operational → Archive process must not be redesigned as part of this project.
2. FROZEN ARCHITECTURE
The final architecture is:
1

NEULIGHT OMS
OPERATIONAL DATABASE
Google Sheets
│
│
Archive Engine #1
│
▼
ARCHIVE DATABASE
Google Sheets
│
│
Archive Engine #2
│
▼
MySQL
Historical Database
Layer 1: Operational Database
Used for current OMS operations.
Layer 2: Archive Database
Receives historical records from the operational database.
This is the source for the MySQL archival engine.
Layer 3: MySQL
Permanent high-volume historical storage.
MySQL is intended to become the scalable historical data layer.
3. PROJECT BOUNDARY
IN SCOPE
The developer must build:
1. Archive Google Sheet reader
2

2. MySQL connection layer
3. MySQL schema
4. Table creation/migration utility
5. Source-to-target column mapping
6. Data type conversion
7. Batch insertion
8. Duplicate prevention
9. Incremental archival
10. Retry handling
11. Error logging
12. Execution logging
13. Validation
14. Record-count reconciliation
15. Referential-integrity checks
16. Backfill capability
17. Dry-run capability
18. Migration status reporting
19. Initial historical load
20. Recurring incremental loads
OUT OF SCOPE
Do not redesign:
• Operational database
• Operational → Archive Engine
• OMS business logic
• Inventory engine
• Reservation engine
• Wallet engine
• Replenishment engine
• Warehouse execution
• AppSheet
• Marketplace APIs
The new system is an archival transport and persistence layer.
4. CRITICAL DESIGN PRINCIPLE
The Archive Database is the source.
MySQL is the destination.
The archive engine must never modify the Archive Google Sheet as part of the normal MySQL transfer.
3

The flow must be:
READ Archive
↓
VALIDATE
↓
TRANSFORM
↓
WRITE MySQL
↓
VERIFY
↓
LOG RESULT
Not:
Archive
↓
Delete source
↓
Write MySQL
The source archive must remain available independently of MySQL.
5. WHY THE ENGINE MUST BE IDEMPOTENT
The Archive Database is maintained by another process.
The existing archive engine performs activities including:
• archival
• orphan handling
• retention cleanup
• duplicate cleanup
• blank-row cleanup
• sheet shrinking
These behaviors are already present in the existing archive implementation.
Therefore the MySQL engine cannot assume:
"Every row appearing in Google Sheets is brand new."
4

It must be safe to run the same archive transfer multiple times.
Example:
Run 1
Archive → MySQL
10,000 records inserted
Run 2
Archive → MySQL
Same 10,000 records encountered
Result:
0 duplicates
The engine must recognize existing records and avoid duplicate insertion.
6. INITIAL LOAD
The first MySQL load must support the existing historical archive.
The first known archive snapshot has already been loaded into MySQL as of the end-of-July archive process.
Therefore the new engine must support:
Existing MySQL data
+
Current Archive Database
↓
Reconciliation
↓
Only missing records transferred
The engine must not blindly reload the entire archive into MySQL.
It should be possible to point the engine at an archive containing records already present in MySQL and
have it safely determine:
• already archived
• missing from MySQL
• duplicate in source
• invalid
5

• failed previously
• requiring retry
7. SOURCE DATABASE
The current archive workbook contains 33 sheets.
The schema must be treated as the source contract.
Current sheets:
api_tokens
couriers
device_settings
financial_settings
forecast_baseline
inventory_balance
inventory_ledger
job_execution_log
missing_data
oms_status_history
oms_status_mapping
order_lines
orders
packing_events
packing_stations
platform_settings
product_cost_history
products
promo_pack_components
reservations
returns
sku_derivative_rules
suppliers
system_messages
system_settings
turnover_lines
users
wallet_transactions
wallet_transactions_lines
warehouse_admin_bucket
warehouse_dashboard
6

warehouse_dashboard_work
warehouses
The engine must discover headers by name.
It must not rely solely on column position.
8. TABLE CLASSIFICATION
The tables should be classified into four groups.
GROUP A: HISTORICAL TRANSACTION DATA
These are the highest-priority archive tables.
orders
order_lines
reservations
inventory_ledger
wallet_transactions
wallet_transactions_lines
returns
packing_events
turnover_lines
oms_status_history
product_cost_history
job_execution_log
missing_data
These contain historical operational or financial events and should be retained in MySQL.
9. GROUP B: MASTER / REFERENCE DATA
These should also be available in MySQL where useful for historical interpretation.
products
suppliers
warehouses
couriers
users
7

packing_stations
promo_pack_components
sku_derivative_rules
oms_status_mapping
forecast_baseline
These are not transactional history, but they provide the reference context necessary to understand
historical records.
10. GROUP C: CONFIGURATION DATA
These may be migrated, but they should be treated as reference/configuration rather than transaction
history.
device_settings
financial_settings
platform_settings
system_settings
system_messages
The developer should preserve them if the MySQL historical database is intended to provide a complete
historical snapshot.
However, configuration tables must not be allowed to control OMS operations from MySQL.
MySQL is historical storage only.
11. GROUP D: DERIVED / OPERATIONAL SNAPSHOTS
These tables require special treatment:
warehouse_admin_bucket
warehouse_dashboard
warehouse_dashboard_work
These are dashboard/work-state data rather than core transactional history.
Default implementation:
Do not make these part of the critical transactional archive pipeline.
8

If they are migrated, they should be classified as optional snapshot tables.
They must never block successful archival of the core transactional tables.
12. SECURITY-SENSITIVE TABLE
api_tokens
The source contains fields including:
access_token
refresh_token
app_key
app_secret
shop_cipher
main_account_id
These are credentials/secrets.
They should NOT be copied into the historical MySQL database in plaintext merely because they exist in
the Archive Database.
Default rule:
api_tokens
↓
DO NOT ARCHIVE SECRETS
If a historical representation is required, store only non-sensitive metadata such as:
• platform
• store_id
• shop_id
• expire_at
• updated_at
• authorization_expiry
Do not copy:
• access_token
• refresh_token
• app_secret
9

unless a separate security design explicitly approves encrypted secret storage.
13. MYSQL SCHEMA STRATEGY
For the first implementation, use a schema-preserving design.
The MySQL tables should closely mirror the Google Sheet archive tables.
Example:
Google Sheet
orders
↓
MySQL
orders
Google Sheet
order_lines
↓
MySQL
order_lines
This avoids introducing unnecessary transformations during the first migration.
The initial goal is:
Preserve the historical OMS dataset faithfully.
Optimization and analytical restructuring can happen later.
14. COLUMN MAPPING RULE
Column names should map by exact header name.
Example:
Google Sheet:
platform_order_id
10

MySQL:
platform_order_id
Do not map:
Column 1 → Column 1
Column 2 → Column 2
because the Google Sheet schema may evolve.
Instead:
header name
↓
mapping dictionary
↓
MySQL column
If a source column is missing from the expected schema:
FAIL THAT TABLE LOAD SAFELY.
Do not silently shift columns.
15. CURRENT CORE SCHEMA
orders
Current archive schema contains 36 data columns:
platform
platform_order_id
tracking_number
order_date
platform_courier
platform_status
shipping_status
paid_date
grand_total
import_batch_id
created_datetime
11

store_code
wh_status
picked_at
packed_at
packing_photo_temp
items_verified_temp
photo_taken_datetime_temp
packing_station_temp
oms_status
dispatch_datetime
turnover_id
repack_count
package_id
cancel_reason
cancelled_by
courier
packing_duration_seconds
packing_labor_cost
warehouse_signature
work_bucket
payment_status
net_settlement
return_amount
shipment_batch_id
shipment_package_id
The developer must verify the exact current workbook header before creating the MySQL table.
16. order_lines
Current schema:
order_line_id
platform_order_id
sku_code
quantity_pcs
product_name
store_code
import_batch_id
reservation_status
platform_sku
marketplace_item_id
sku_resolution_status
platform_parent_sku
12

platform_model_sku
platform_line_id
sale_price
original_price
cogs
variant
Note that the archive workbook currently contains 18 columns for this table.
The developer must not assume that an earlier OMS version of this table is authoritative.
The uploaded archive schema is authoritative for this build.
17. reservations
Current schema:
reservation_id
platform_order
original_sku
original_qty
resolved_sku
reserved_qty
status
created_datetime
reservation_type
repack_count
hold_reason
The relationship to Orders is through the platform order identifier represented by:
platform_order
18. inventory_balance
Current schema:
warehouse_code
sku_code
13

on_hand_pcs
reserved_pcs
for_turnover_qty
on_hold_qty
available_pcs
inventory_balance_id
last_updated
return_hold_qty
This should be treated as a historical balance snapshot, not as the authoritative mechanism for
reconstructing every inventory movement.
The authoritative movement history is:
inventory_ledger
19. inventory_ledger
Current schema:
ledger_id
txn_datetime
sku_code
warehouse_code
movement_type
quantity_pcs
reference_type
reference_id
order_id
created_by
This is a high-priority historical transaction table.
The ledger_id should be the primary deduplication key where valid.
14

20. WALLET DATA
wallet_transactions
Current schema:
wallet_txn_id
platform
store_code
statement_id
txn_datetime
platform_order_id
transaction_id
txn_type
wallet_type
gross_sales
seller_discount
platform_discount
affiliate_commission
platform_fee
shipping_fee
shipping_subsidy
adjustment_amount
tax_withheld
net_settlement
currency
matched
order_id
created_at
raw_json
campaign_fee
reverse_shipping_fee
escrow_downloaded
wallet_transactions_lines
Current schema:
wallet_transaction_line_id
platform
store_code
transaction_id
statement_id
platform_order_id
15

platform_order_line_id
txn_datetime
txn_type
fee_name
fee_type
amount
currency
raw_json
created_at
import_batch_id
These tables must preserve monetary precision.
Do not store monetary values as floating-point types.
Use an appropriate fixed-precision MySQL type, for example:
DECIMAL(18,4)
or another precision approved during schema certification.
21. RETURNS
Current schema:
return_id
platform
platform_order_id
tracking_number
return_type
return_status
return_reason_code
return_reason_text
refund_reason_code
refund_reason_text
refund_amount
request_datetime
approved_datetime
closed_datetime
initiator
store_code
return_received
unpack_required
16

unpacked
unpacked_datetime
photo_unopened_parcel
received_photo
opened_photo
inspection_photo_datetime
inspection_datetime
packing_station
inventory_processed
inspection_completed
inventory_released
This should be retained as historical return state.
22. PACKING EVENTS
Current schema:
packing_event_id
platform_order_id
packing_station
packed_by
packed_datetime
items_verified
packing_photo
prepack_photo_datetime
packing_duration_seconds
tracking_number
event_source
original_platform_order_id
Packing event records must be inserted independently from the Orders table.
23. TURNOVER LINES
Current schema:
turnover_line_id
turnover_id
platform_order_id
tracking_number
17

scan_datetime
scan_user
exception_type
override_reason
wh_status_at_scan
24. STATUS HISTORY
Current schema:
history_id
platform_order_id
old_oms_status
new_oms_status
status_datetime
updated_by
remarks
This should be treated as an append-style historical event table.
25. PRODUCT COST HISTORY
Current schema:
cost_record_id
sku_code
effective_date
cost_basis
cost_value
remarks
created_by
created_datetime
cost_value must use fixed-precision numeric storage.
26. DATA TYPE MAPPING
The developer must implement explicit Google Sheets → MySQL conversion.
18

General mapping:
Google Sheets text
↓
VARCHAR / TEXT
Google Sheets number
↓
DECIMAL / BIGINT / INT
Google Sheets date/time
↓
DATETIME
Boolean
↓
BOOLEAN / TINYINT
Long JSON text
↓
JSON where valid
or TEXT if JSON validation fails
Do not allow MySQL implicit type conversion to determine the schema.
27. NULL HANDLING
Blank Google Sheet cells must normally become:
NULL
not:
""
unless the source schema explicitly requires an empty string.
This distinction is important for historical queries.
19

28. DATE/TIME HANDLING
Dates must be normalized before insertion.
The developer must explicitly handle:
• blank dates
• invalid dates
• Google Sheets Date objects
• ISO strings
• timezone conversion
The system must establish one MySQL timezone standard.
Recommended:
UTC storage
with application-level conversion to Philippine time when displayed.
If the existing OMS database standard requires another timezone, use that existing standard consistently.
Do not silently mix timezones.
29. PRIMARY KEY / DEDUPLICATION STRATEGY
The developer must identify a stable unique key for every table.
Priority:
1. Existing explicit ID
2. Natural unique business key
3. Composite business key
Examples:
orders
→ platform_order_id
20

order_lines
→ order_line_id
reservations
→ reservation_id
inventory_ledger
→ ledger_id
wallet_transactions
→ wallet_txn_id
wallet_transactions_lines
→ wallet_transaction_line_id
returns
→ return_id
packing_events
→ packing_event_id
turnover_lines
→ turnover_line_id
oms_status_history
→ history_id
product_cost_history
→ cost_record_id
Where a stable ID cannot be guaranteed, use a documented composite unique key.
21

30. UPSERT POLICY
Do not automatically overwrite MySQL historical records simply because a matching source key exists.
Default behavior:
Source row
↓
Does key exist?
│
├── NO → INSERT
│
└── YES
↓
Compare row
│
├── SAME → SKIP
│
└── DIFFERENT → LOG CHANGE
For historical transactional data, the default should be:
Do not silently overwrite.
If a source record differs from the MySQL version, the engine should flag it for reconciliation.
This protects historical integrity.
31. WHY NOT SIMPLE INSERT IGNORE?
Avoid relying on:
INSERT IGNORE
as the entire deduplication strategy.
It can hide data-quality problems.
The engine should know whether a row was:
• inserted
22

• already present and identical
• already present but different
• invalid
• failed
Every result should be measurable.
32. BATCH PROCESSING
The engine must process records in batches.
Example:
Read 500 rows
↓
Validate
↓
Transform
↓
Insert transaction
↓
Verify
↓
Next 500
The batch size must be configurable.
Suggested initial value:
500
The existing operational archive engine already uses a configurable batch size of 500.
The MySQL engine may use a different value after performance testing.
33. TRANSACTION SAFETY
Each MySQL batch should use a database transaction:
23

BEGIN
INSERT batch
VALIDATE
COMMIT
If the batch fails:
ROLLBACK
No partially inserted batch should be treated as successful.
34. INCREMENTAL ARCHIVING
The engine must support incremental operation.
Preferred conceptual logic:
Archive DB
↓
Read records
↓
Compare against MySQL
↓
Find missing records
↓
Insert missing
The system should not require the entire archive workbook to be reprocessed indefinitely.
A migration checkpoint should be maintained.
35. CHECKPOINT
Create a dedicated MySQL control table, for example:
archive_sync_control
It should track at minimum:
24

sync_id
source_table
last_successful_sync
last_source_row_count
last_processed_key
last_run_datetime
last_success_datetime
last_status
last_error
rows_read
rows_inserted
rows_skipped
rows_changed
rows_failed
The exact schema may be refined by the developer.
36. EXECUTION LOG
Create a dedicated MySQL table:
archive_sync_log
Suggested fields:
execution_id
started_at
finished_at
status
source_database
source_table
rows_read
rows_inserted
rows_skipped
rows_changed
rows_failed
duration_seconds
error_message
This is separate from the existing OMS job_execution_log .
25

The existing archive workbook contains job_execution_log , but the MySQL archival process needs its
own migration-level execution record.
37. DRY RUN
The developer must provide:
DRY RUN = TRUE
capability.
Dry run must:
• read source
• validate schema
• validate data
• identify duplicates
• identify missing MySQL rows
• identify changed rows
• calculate expected inserts
but:
must not modify MySQL.
Example output:
TABLE: orders
Source rows: 25,000
Already in MySQL: 24,800
New rows: 190
Changed rows: 10
Invalid rows: 0
Expected inserts: 190
38. SCHEMA VALIDATION
Before processing a table:
26

Check source sheet exists
↓
Check header row exists
↓
Check required columns exist
↓
Check duplicate column names
↓
Check MySQL table exists
↓
Check MySQL schema compatibility
If a required column is missing:
FAIL TABLE
Do not attempt positional guessing.
39. DATA VALIDATION
At minimum validate:
IDs
• non-null where required
• correct type
• uniqueness where expected
Dates
• valid date
• no impossible conversion
Numeric
• valid numeric values
• monetary precision preserved
References
• parent references checked where applicable
27

Required fields
• required fields cannot be blank
40. REFERENTIAL INTEGRITY
The engine should validate major relationships.
Example:
orders
│
├── order_lines
├── reservations
├── packing_events
├── turnover_lines
├── wallet_transactions
├── returns
└── oms_status_history
A child record referring to an order that does not exist in MySQL should be flagged.
However, because archive transfer may occur table-by-table, the engine should use dependency-aware load
ordering.
41. RECOMMENDED LOAD ORDER
Use the following sequence for the initial load:
1. warehouses
2. suppliers
3. users
4. couriers
5. packing_stations
6. products
7. sku_derivative_rules
8. promo_pack_components
9. oms_status_mapping
10. system/reference tables
11. orders
28

12. order_lines
13. reservations
14. inventory_ledger
15. inventory_balance
16. packing_events
17. turnover_lines
18. oms_status_history
19. returns
20. wallet_transactions
21. wallet_transactions_lines
22. product_cost_history
23. job_execution_log
24. missing_data
Configuration and optional dashboard tables can be loaded separately.
The developer may adjust the order if MySQL constraints are designed differently, but referential integrity
must remain intact.
42. ARCHIVE SNAPSHOT CONSIDERATION
The current Archive Database is not necessarily immutable.
The existing archive maintenance process can perform cleanup and duplicate/orphan handling.
Therefore MySQL should be treated as the permanent historical store, while Google Sheets Archive
remains the intermediate archive layer.
The system should not assume:
Archive Google Sheets = immutable
Instead:
Archive Google Sheets
↓
Historical source
↓
MySQL
29

↓
Permanent historical storage
43. SOURCE CHANGES AFTER MYSQL LOAD
If a source row is later modified:
Google Sheets Archive
↓
Existing MySQL row
the engine must detect the difference.
Do not silently overwrite.
Instead record:
source_changed = TRUE
and log:
table
primary_key
source_value
mysql_value
detected_at
This can later become a formal reconciliation process.
44. FAILURE RECOVERY
If the script fails halfway through:
Example:
10,000 rows
↓
8,000 inserted
30

↓
failure
the next run must safely resume.
It must not create:
8,000 duplicates
The combination of:
• stable unique keys
• transactions
• checkpoints
• idempotent inserts
must make recovery automatic.
45. MYSQL CONNECTION
The developer should isolate database credentials from business logic.
Do not place credentials directly inside archive functions.
Use secure configuration such as:
environment variables
secret manager
secure Apps Script properties
depending on the actual deployment architecture.
The MySQL password must never be stored in the source code.
46. ARCHIVE ENGINE STRUCTURE
Recommended logical structure:
31

ArchiveToMySQL
│
├── Config
│
├── MySQL Connection
│
├── Schema Validator
│
├── Source Reader
│
├── Data Transformer
│
├── Key Resolver
│
├── Batch Writer
│
├── Duplicate Detector
│
├── Integrity Validator
│
├── Checkpoint Manager
│
├── Execution Logger
│
└── Reconciliation Reporter
47. MAIN ENTRY POINTS
Recommended functions:
runArchiveToMySQL()
Production execution.
runArchiveToMySQLDryRun()
Validation without writing.
runArchiveToMySQLTable(tableName)
32

Process one table.
validateArchiveToMySQLSchema()
Validate source and destination schemas.
reconcileArchiveToMySQL()
Compare source and destination.
getArchiveToMySQLStatus()
Return migration status.
retryFailedArchiveToMySQL()
Retry failed batches/tables.
48. INITIAL DEPLOYMENT STRATEGY
Do not immediately enable the recurring production trigger.
Use:
STEP 1
Create MySQL schema
↓
STEP 2
Run source schema validation
↓
STEP 3
Dry run
↓
33

STEP 4
Load one small table
↓
STEP 5
Validate
↓
STEP 6
Load one transactional table
↓
STEP 7
Validate
↓
STEP 8
Full historical load
↓
STEP 9
Reconciliation
↓
STEP 10
Enable incremental trigger
49. PILOT TABLE
Recommended first pilot:
orders
because it is the central historical entity.
Then:
34

order_lines
Then:
inventory_ledger
Then:
wallet_transactions
Then remaining tables.
50. SUCCESS CRITERIA
The build is successful only when:
Schema
• all required MySQL tables exist
• all required columns exist
• data types are certified
Data
• source rows are accounted for
• MySQL rows are accounted for
• duplicates are detected
• invalid records are reported
Integrity
• parent/child relationships are valid
• primary keys are unique
• no silent truncation occurs
• monetary values are preserved
• dates are preserved
Reliability
• rerunning does not duplicate data
• failed batches can resume
• transactions roll back correctly
35

Observability
Every run reports:
start
end
duration
tables processed
rows read
rows inserted
rows skipped
rows changed
rows failed
errors
51. FINAL ARCHITECTURAL RULE
The developer must preserve this distinction:
OPERATIONS
Google Sheets
↓
Archive Engine #1
↓
ARCHIVE
Google Sheets
↓
Archive Engine #2
↓
HISTORICAL STORAGE
MySQL
The MySQL archive is not another operational database.
It does not become the place where the OMS runs its business logic.
It is the permanent historical storage layer.
36

52. DEFINITION OF DONE
Archive Layer 2 is considered complete when:
• [ ] MySQL database created
• [ ] MySQL archive schema certified
• [ ] Source schema validator completed
• [ ] Source-to-MySQL mappings completed
• [ ] Data-type conversion completed
• [ ] Initial migration completed
• [ ] Existing July archive data reconciled
• [ ] Duplicate detection certified
• [ ] Idempotency certified
• [ ] Batch transactions certified
• [ ] Failure recovery certified
• [ ] Checkpoint system completed
• [ ] Execution logging completed
• [ ] Dry-run completed
• [ ] Full reconciliation completed
• [ ] Referential-integrity audit completed
• [ ] Incremental migration tested
• [ ] Sensitive API credentials excluded/protected
• [ ] Production trigger enabled
• [ ] First recurring production run verified
53. FROZEN SCOPE
This project does not include redesigning the OMS.
It does not include moving live operations to MySQL.
It does not include changing the existing Operational → Archive engine.
It does not include rebuilding business logic.
It is specifically:
Build a reliable, idempotent, auditable, end-to-end pipeline that takes the existing
Neulight OMS Archive Google Database and stores it permanently in MySQL.
The existing Archive Engine remains Layer 1 of the archival process. The new Archive-to-MySQL engine
becomes Layer 2.
37

---

## Developer delivery estimate (project planning addendum)

**Not part of the original frozen specification.** Added for implementation planning.

| Item | Estimate |
|------|----------|
| **Target delivery** | **~2–3 weeks — 10–18 working days (Monday–Saturday; Sunday excluded) @ 4 hrs/day** |
| **Scope** | Full specification per Section 52 (Definition of Done) |
| **Effort** | Approximately 40–70 developer hours with AI-assisted tooling |
| **Approach** | Generic ETL pipeline first; remaining 33 tables rolled out via configuration |

**Suggested schedule @ 4 hrs/day:**

| Days | Focus |
|------|-------|
| 1–3 | Core pipeline, pilot tables (`orders`, `order_lines`), dry-run |
| 4–8 | Roll out remaining archive tables |
| 9–12 | Reconciliation, incremental sync, production trigger, handoff |