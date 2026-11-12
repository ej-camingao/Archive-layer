-- Neulight OMS Archive Layer 2: historical archive schema (PostgreSQL / Supabase)
-- Source contract: Neulight_OMS_Archive.xlsx headers as of 2026-10-07.
--
-- Conventions
--   * Everything lives in schema "archive", which is not exposed through the Supabase
--     Data API. Only the postgres / service role (the archive engine) can read or write.
--   * IDs are text: the sheets mix numeric and text IDs, and numeric IDs above 15 digits
--     lose precision if treated as numbers.
--   * Money and quantities are numeric(18,4), never float.
--   * Datetimes are timestamptz. Sheet values have no zone; the engine must read them as
--     Asia/Manila so they are stored as the correct instant.
--   * Blank cells are NULL, not ''.
--   * No foreign keys between archive tables. History can arrive out of order or contain
--     orphans; referential checks are done by the engine and reported, not enforced.
--   * Header renames (source -> column): products."BRAND" -> brand,
--     missing_data."P60 days" -> p60_days, warehouse_admin_bucket."Emoji" -> emoji,
--     wallet_transactions unnamed columns AB/AC -> unnamed_col_ab / unnamed_col_ac.
--   * api_tokens secrets are never archived; only metadata (spec section 12).

create schema if not exists archive;

revoke all on schema archive from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Control tables
-- ---------------------------------------------------------------------------

create table archive.archive_sync_log (
  execution_id      bigint generated always as identity primary key,
  run_mode          text not null check (run_mode in ('DRY_RUN', 'INITIAL', 'INCREMENTAL', 'BACKFILL')),
  source_database   text not null,
  source_table      text not null,
  started_at        timestamptz not null default now(),
  finished_at       timestamptz,
  status            text not null default 'RUNNING'
                    check (status in ('RUNNING', 'SUCCESS', 'PARTIAL', 'FAILED')),
  rows_read         integer not null default 0,
  rows_inserted     integer not null default 0,
  rows_skipped      integer not null default 0,
  rows_changed      integer not null default 0,
  rows_failed       integer not null default 0,
  duration_seconds  numeric(12,3),
  error_message     text
);

create index archive_sync_log_table_started_idx
  on archive.archive_sync_log (source_table, started_at desc);

create table archive.archive_sync_control (
  sync_id                bigint generated always as identity primary key,
  source_table           text not null unique,
  target_table           text not null,
  table_group            text not null check (table_group in ('A', 'B', 'C', 'D', 'X', 'SECURITY')),
  load_order             integer not null,
  enabled                boolean not null default true,
  last_successful_sync   timestamptz,
  last_source_row_count  integer,
  last_processed_key     text,
  last_run_datetime      timestamptz,
  last_success_datetime  timestamptz,
  last_status            text,
  last_error             text,
  rows_read              integer not null default 0,
  rows_inserted          integer not null default 0,
  rows_skipped           integer not null default 0,
  rows_changed           integer not null default 0,
  rows_failed            integer not null default 0
);

-- Rows whose key already exists with different content. Never applied automatically.
create table archive.archive_row_changes (
  change_id       bigint generated always as identity primary key,
  execution_id    bigint references archive.archive_sync_log (execution_id),
  source_table    text not null,
  row_key         text not null,
  existing_hash   text not null,
  incoming_hash   text not null,
  incoming_row    jsonb not null,
  detected_at     timestamptz not null default now(),
  resolution      text not null default 'PENDING'
                  check (resolution in ('PENDING', 'ACCEPTED', 'REJECTED')),
  resolved_at     timestamptz,
  resolved_by     text,
  unique (source_table, row_key, incoming_hash)
);

create table archive.archive_row_failures (
  failure_id        bigint generated always as identity primary key,
  execution_id      bigint references archive.archive_sync_log (execution_id),
  source_table      text not null,
  source_row_number integer,
  row_key           text,
  failure_reason    text not null,
  raw_row           jsonb,
  detected_at       timestamptz not null default now()
);

create index archive_row_failures_table_idx
  on archive.archive_row_failures (source_table, detected_at desc);

-- ---------------------------------------------------------------------------
-- Group A: historical transaction data
-- ---------------------------------------------------------------------------

create table archive.orders (
  platform_order_id          text primary key,
  platform                   text,
  tracking_number            text,
  order_date                 timestamptz,
  platform_courier           text,
  platform_status            text,
  shipping_status            text,
  paid_date                  timestamptz,
  grand_total                numeric(18,4),
  import_batch_id            text,
  created_datetime           timestamptz,
  store_code                 text,
  wh_status                  text,
  picked_at                  timestamptz,
  packed_at                  timestamptz,
  packing_photo_temp         text,
  items_verified_temp        boolean,
  photo_taken_datetime_temp  timestamptz,
  packing_station_temp       text,
  oms_status                 text,
  dispatch_datetime          timestamptz,
  turnover_id                text,
  repack_count               integer,
  package_id                 text,
  cancel_reason              text,
  cancelled_by               text,
  courier                    text,
  packing_duration_seconds   numeric(18,4),
  packing_labor_cost         numeric(18,4),
  warehouse_signature        text,
  work_bucket                text,
  payment_status             text,
  net_settlement             numeric(18,4),
  return_amount              numeric(18,4),
  shipment_batch_id          text,
  shipment_package_id        text
);

create table archive.order_lines (
  order_line_id          text primary key,
  platform_order_id      text,
  sku_code               text,
  quantity_pcs           numeric(18,4),
  product_name           text,
  store_code             text,
  import_batch_id        text,
  reservation_status     text,
  platform_sku           text,
  marketplace_item_id    text,
  sku_resolution_status  text,
  platform_parent_sku    text,
  platform_model_sku     text,
  platform_line_id       text,
  sale_price             numeric(18,4),
  original_price         numeric(18,4),
  cogs                   numeric(18,4),
  variant                text
);

create table archive.reservations (
  reservation_id    text primary key,
  platform_order    text,
  original_sku      text,
  original_qty      numeric(18,4),
  resolved_sku      text,
  reserved_qty      numeric(18,4),
  status            text,
  created_datetime  timestamptz,
  reservation_type  text,
  repack_count      integer,
  hold_reason       text
);

create table archive.inventory_ledger (
  ledger_id       text primary key,
  txn_datetime    timestamptz,
  sku_code        text,
  warehouse_code  text,
  movement_type   text,
  quantity_pcs    numeric(18,4),
  reference_type  text,
  reference_id    text,
  order_id        text,
  created_by      text,
  related_id      text
);

-- wallet_txn_id is blank on some source rows, so it cannot be the primary key.
create table archive.wallet_transactions (
  archive_row_id        bigint generated always as identity primary key,
  wallet_txn_id         text,
  platform              text,
  store_code            text,
  statement_id          text,
  txn_datetime          timestamptz,
  platform_order_id     text,
  transaction_id        text,
  txn_type              text,
  wallet_type           text,
  gross_sales           numeric(18,4),
  seller_discount       numeric(18,4),
  platform_discount     numeric(18,4),
  affiliate_commission  numeric(18,4),
  platform_fee          numeric(18,4),
  shipping_fee          numeric(18,4),
  shipping_subsidy      numeric(18,4),
  adjustment_amount     numeric(18,4),
  tax_withheld          numeric(18,4),
  net_settlement        numeric(18,4),
  currency              text,
  matched               boolean,
  order_id              text,
  created_at            timestamptz,
  raw_json              jsonb,
  raw_json_text         text,
  campaign_fee          numeric(18,4),
  reverse_shipping_fee  numeric(18,4),
  escrow_downloaded     boolean,
  unnamed_col_ab        numeric(18,4),
  unnamed_col_ac        numeric(18,4)
);

create unique index wallet_transactions_wallet_txn_id_key
  on archive.wallet_transactions (wallet_txn_id)
  where wallet_txn_id is not null;

create table archive.wallet_transactions_lines (
  wallet_transaction_line_id  text primary key,
  platform                    text,
  store_code                  text,
  transaction_id              text,
  statement_id                text,
  platform_order_id           text,
  platform_order_line_id      text,
  txn_datetime                timestamptz,
  txn_type                    text,
  fee_name                    text,
  fee_type                    text,
  amount                      numeric(18,4),
  currency                    text,
  raw_json                    jsonb,
  raw_json_text               text,
  created_at                  timestamptz,
  import_batch_id             text
);

create table archive.wallet_statements (
  statement_id            text primary key,
  platform                text,
  store_code              text,
  statement_date          timestamptz,
  payment_status          text,
  payment_id              text,
  settlement_amount       numeric(18,4),
  revenue_amount          numeric(18,4),
  fee_amount              numeric(18,4),
  adjustment_amount       numeric(18,4),
  shipping_cost_amount    numeric(18,4),
  currency                text,
  payment_time            timestamptz,
  imported_at             timestamptz,
  transactions_imported   boolean,
  transactions_last_sync  timestamptz
);

create table archive.returns (
  return_id                  text primary key,
  platform                   text,
  platform_order_id          text,
  tracking_number            text,
  return_type                text,
  return_status              text,
  return_reason_code         text,
  return_reason_text         text,
  refund_reason_code         text,
  refund_reason_text         text,
  refund_amount              numeric(18,4),
  request_datetime           timestamptz,
  approved_datetime          timestamptz,
  closed_datetime            timestamptz,
  initiator                  text,
  store_code                 text,
  return_received            boolean,
  unpack_required            boolean,
  unpacked                   boolean,
  unpacked_datetime          timestamptz,
  photo_unopened_parcel      text,
  received_photo             text,
  opened_photo               text,
  inspection_photo_datetime  timestamptz,
  inspection_datetime        timestamptz,
  packing_station            text,
  inventory_processed        boolean,
  inspection_completed       boolean,
  inventory_released         boolean
);

create table archive.return_lines (
  return_line_id           text primary key,
  return_id                text,
  platform_order_line_id   text,
  platform_return_line_id  text,
  sku_code                 text,
  product_name             text,
  qty_returned             numeric(18,4),
  good_qty                 numeric(18,4),
  bad_qty                  numeric(18,4),
  inspection_result        text,
  inventory_action         text,
  inventory_processed      boolean,
  processed_datetime       timestamptz,
  processed_qty            numeric(18,4),
  damage_reason            text,
  inspection_completed     boolean,
  inspection_datetime      timestamptz,
  inspected_by             text,
  resolved_sku             text,
  resolved_product_name    text,
  resolved_qty             numeric(18,4),
  sku_resolution_status    text
);

create table archive.packing_events (
  packing_event_id            text primary key,
  platform_order_id           text,
  packing_station             text,
  packed_by                   text,
  packed_datetime             timestamptz,
  items_verified              boolean,
  packing_photo               text,
  prepack_photo_datetime      timestamptz,
  packing_duration_seconds    numeric(18,4),
  tracking_number             text,
  event_source                text,
  original_platform_order_id  text
);

create table archive.turnover_lines (
  turnover_line_id   text primary key,
  turnover_id        text,
  platform_order_id  text,
  tracking_number    text,
  scan_datetime      timestamptz,
  scan_user          text,
  exception_type     text,
  override_reason    text,
  wh_status_at_scan  text
);

create table archive.oms_status_history (
  history_id         text primary key,
  platform_order_id  text,
  old_oms_status     text,
  new_oms_status     text,
  status_datetime    timestamptz,
  updated_by         text,
  remarks            text
);

create table archive.product_cost_history (
  cost_record_id    text primary key,
  sku_code          text,
  effective_date    timestamptz,
  cost_basis        text,
  cost_value        numeric(18,4),
  remarks           text,
  created_by        text,
  created_datetime  timestamptz
);

create table archive.job_execution_log (
  job_execution_id  text primary key,
  job_name          text,
  start_datetime    timestamptz,
  end_datetime      timestamptz,
  duration_seconds  numeric(18,4),
  status            text,
  rows_processed    integer,
  error_message     text,
  urlfetch_count    integer
);

create table archive.missing_data (
  archive_row_id     bigint generated always as identity primary key,
  platform           text,
  store_code         text,
  platform_order_id  text,
  date               timestamptz,
  status             text,
  remarks            text,
  p60_days           text
);

create table archive.goods_receipts (
  gr_id             text primary key,
  gr_number         text,
  po_id             text,
  supplier_code     text,
  receipt_date      timestamptz,
  received_by       text,
  posted_by         text,
  posted_datetime   timestamptz,
  remarks           text,
  status            text,
  created_by        text,
  created_datetime  timestamptz
);

create table archive.goods_receipt_lines (
  gr_line_id        text primary key,
  gr_id             text,
  po_line_id        text,
  sku_code          text,
  ordered_cases     numeric(18,4),
  received_cases    numeric(18,4),
  status            text,
  po_unit_cost      numeric(18,4),
  actual_unit_cost  numeric(18,4),
  line_total        numeric(18,4),
  remarks           text
);

create table archive.supply_counts (
  count_id           text primary key,
  count_datetime     timestamptz,
  supply_id          text,
  physical_quantity  numeric(18,4),
  created_at         timestamptz
);

create table archive.supply_purchases (
  purchase_id        text primary key,
  purchase_datetime  timestamptz,
  supply_id          text,
  quantity           numeric(18,4),
  total_cost         numeric(18,4),
  unit_cost          numeric(18,4)
);

-- ---------------------------------------------------------------------------
-- Group B: master / reference data
-- ---------------------------------------------------------------------------

create table archive.products (
  sku_code               text primary key,
  barcode                text,
  category               text,
  sku_type               text,
  base_sku_code          text,
  supplier_code          text,
  brand                  text,
  product_name           text,
  variant_name           text,
  display_name           text,
  units_per_case         numeric(18,4),
  target_margin_pct      numeric(18,4),
  active                 text,
  sourcing_type          text,
  piece_barcode          text,
  case_barcode           text,
  product_weight_g       numeric(18,4),
  product_length_cm      numeric(18,4),
  product_width_cm       numeric(18,4),
  product_height_cm      numeric(18,4),
  replenishment_enabled  boolean
);

create table archive.suppliers (
  supplier_code   text primary key,
  supplier_name   text,
  active_flag     text,
  lead_time_days  numeric(18,4)
);

create table archive.warehouses (
  warehouse_code  text primary key,
  warehouse_name  text,
  warehouse_type  text,
  active_flag     text
);

create table archive.couriers (
  courier_code      text primary key,
  courier_name      text,
  active_flag       text,
  platform_courier  text
);

create table archive.users (
  user_id      text primary key,
  user_name    text,
  email        text,
  role         text,
  active_flag  text
);

create table archive.packing_stations (
  station_id     text primary key,
  station_name   text,
  active_flag    text,
  assigned_user  text
);

create table archive.promo_pack_components (
  promo_sku           text not null,
  component_sku       text not null,
  promo_name          text,
  promo_type          text,
  qty_required        numeric(18,4),
  component_sequence  integer,
  active              text,
  primary key (promo_sku, component_sku)
);

create table archive.sku_derivative_rules (
  suffix      text primary key,
  multiplier  numeric(18,4)
);

create table archive.oms_status_mapping (
  platform_status  text primary key,
  oms_status       text
);

create table archive.forecast_baseline (
  sku_code    text primary key,
  ads_pieces  numeric(18,4),
  ads_cases   numeric(18,4)
);

-- Balance snapshot only; movement history is inventory_ledger.
create table archive.inventory_balance (
  inventory_balance_id  text primary key,
  warehouse_code        text,
  sku_code              text,
  on_hand_pcs           numeric(18,4),
  reserved_pcs          numeric(18,4),
  for_turnover_qty      numeric(18,4),
  on_hold_qty           numeric(18,4),
  available_pcs         numeric(18,4),
  last_updated          timestamptz,
  return_hold_qty       numeric(18,4)
);

-- ---------------------------------------------------------------------------
-- Group C: configuration snapshots (never read back by the OMS)
-- ---------------------------------------------------------------------------

create table archive.device_settings (
  device_name         text primary key,
  packing_station     text,
  device_role         text,
  active_turnover_id  text
);

create table archive.financial_settings (
  setting_key    text primary key,
  setting_value  numeric(18,4),
  remarks        text
);

create table archive.platform_settings (
  platform              text primary key,
  shipping_enabled      boolean,
  waybill_enabled       boolean,
  active_flag           boolean,
  api_enabled           boolean,
  polling_minutes       integer,
  rate_limit_remaining  integer,
  last_sync_datetime    timestamptz
);

-- setting_value mixes booleans, numbers, dates and text in the source.
create table archive.system_settings (
  setting_name   text primary key,
  setting_value  text,
  remarks        text,
  current_store  text
);

create table archive.system_messages (
  message_id          text primary key,
  title               text,
  message             text,
  action_required     text,
  return_turnover_id  text
);

-- ---------------------------------------------------------------------------
-- Group D: dashboard snapshots (optional, never block Group A)
-- ---------------------------------------------------------------------------

create table archive.warehouse_admin_bucket (
  archive_row_id  bigint generated always as identity primary key,
  sequence        integer,
  queue_id        text,
  work_area       text,
  work_bucket     text,
  wh_status       text,
  parcel_count    text,
  emoji           text
);

create table archive.warehouse_dashboard (
  archive_row_id              bigint generated always as identity primary key,
  to_pick_overdue             numeric(18,4),
  to_pick_today               numeric(18,4),
  to_pick_tomorrow            numeric(18,4),
  to_pack_overdue             numeric(18,4),
  to_pack_today               numeric(18,4),
  to_pack_tomorrow            numeric(18,4),
  for_turnover_overdue        numeric(18,4),
  for_turnover_today          numeric(18,4),
  for_turnover_tomorrow       numeric(18,4),
  today_total                 numeric(18,4),
  warehouse_dispatched_today  numeric(18,4),
  platform_dispatched_today   numeric(18,4),
  warehouse_pending_platform  numeric(18,4),
  warehouse_remaining         numeric(18,4),
  progress_platform_pct       numeric(18,4),
  progress_warehouse_pct      numeric(18,4),
  last_refresh                timestamptz,
  notesforwh                  text,
  hold_returns_parcels        numeric(18,4),
  hold_cancelled_parcels      numeric(18,4)
);

create table archive.warehouse_dashboard_work (
  archive_row_id  bigint generated always as identity primary key,
  dashboard_id    text,
  sequence        integer,
  work_area       text,
  overdue         numeric(18,4),
  today           numeric(18,4),
  tomorrow        numeric(18,4),
  late_unscanned  numeric(18,4)
);

-- ---------------------------------------------------------------------------
-- Extra sheets and security-sensitive metadata
-- ---------------------------------------------------------------------------

create table archive.reservations_historical_recover (
  reservation_id    text primary key,
  order_line_id     text,
  platform_order    text,
  original_sku      text,
  original_qty      numeric(18,4),
  resolved_sku      text,
  reserved_qty      numeric(18,4),
  status            text,
  created_datetime  timestamptz,
  reservation_type  text
);

-- Metadata only. access_token, refresh_token, app_key, app_secret, shop_cipher and
-- main_account_id are deliberately absent.
create table archive.api_tokens_metadata (
  platform              text not null,
  store_id              text not null,
  shop_id               text not null,
  expire_at             timestamptz,
  updated_at            timestamptz,
  authorization_expiry  timestamptz,
  primary key (platform, store_id, shop_id)
);

-- ---------------------------------------------------------------------------
-- Archive bookkeeping columns on every data table
--   _row_hash       hash of the normalized source row, used for SAME / DIFFERENT checks
--   _source_file    workbook or spreadsheet the row came from
--   _execution_id   archive_sync_log run that first inserted the row
--   _loaded_at      when the row was first inserted
--   _last_seen_at   last run that saw the identical row in the source
-- ---------------------------------------------------------------------------

do $$
declare
  t text;
begin
  foreach t in array array[
    'orders', 'order_lines', 'reservations', 'inventory_ledger',
    'wallet_transactions', 'wallet_transactions_lines', 'wallet_statements',
    'returns', 'return_lines', 'packing_events', 'turnover_lines',
    'oms_status_history', 'product_cost_history', 'job_execution_log', 'missing_data',
    'goods_receipts', 'goods_receipt_lines', 'supply_counts', 'supply_purchases',
    'products', 'suppliers', 'warehouses', 'couriers', 'users', 'packing_stations',
    'promo_pack_components', 'sku_derivative_rules', 'oms_status_mapping',
    'forecast_baseline', 'inventory_balance',
    'device_settings', 'financial_settings', 'platform_settings',
    'system_settings', 'system_messages',
    'warehouse_admin_bucket', 'warehouse_dashboard', 'warehouse_dashboard_work',
    'reservations_historical_recover', 'api_tokens_metadata'
  ]
  loop
    execute format(
      'alter table archive.%I
         add column _row_hash text not null,
         add column _source_file text,
         add column _execution_id bigint references archive.archive_sync_log (execution_id),
         add column _loaded_at timestamptz not null default now(),
         add column _last_seen_at timestamptz', t);
  end loop;
end $$;

-- Tables without a stable source ID deduplicate on the full row content.
create unique index missing_data_row_hash_key on archive.missing_data (_row_hash);
create unique index warehouse_admin_bucket_row_hash_key on archive.warehouse_admin_bucket (_row_hash);
create unique index warehouse_dashboard_row_hash_key on archive.warehouse_dashboard (_row_hash);
create unique index warehouse_dashboard_work_row_hash_key on archive.warehouse_dashboard_work (_row_hash);
create unique index wallet_transactions_no_id_row_hash_key
  on archive.wallet_transactions (_row_hash)
  where wallet_txn_id is null;

-- ---------------------------------------------------------------------------
-- Lookup indexes for historical queries
-- ---------------------------------------------------------------------------

create index orders_order_date_idx on archive.orders (order_date);
create index orders_tracking_number_idx on archive.orders (tracking_number);
create index orders_store_platform_idx on archive.orders (store_code, platform);
create index order_lines_platform_order_id_idx on archive.order_lines (platform_order_id);
create index order_lines_sku_code_idx on archive.order_lines (sku_code);
create index reservations_platform_order_idx on archive.reservations (platform_order);
create index inventory_ledger_sku_txn_idx on archive.inventory_ledger (sku_code, txn_datetime);
create index wallet_transactions_platform_order_id_idx on archive.wallet_transactions (platform_order_id);
create index wallet_transactions_txn_datetime_idx on archive.wallet_transactions (txn_datetime);
create index wallet_transactions_transaction_id_idx on archive.wallet_transactions (transaction_id);
create index wallet_transactions_lines_platform_order_id_idx on archive.wallet_transactions_lines (platform_order_id);
create index returns_platform_order_id_idx on archive.returns (platform_order_id);
create index return_lines_return_id_idx on archive.return_lines (return_id);
create index packing_events_platform_order_id_idx on archive.packing_events (platform_order_id);
create index turnover_lines_platform_order_id_idx on archive.turnover_lines (platform_order_id);
create index oms_status_history_platform_order_id_idx on archive.oms_status_history (platform_order_id, status_datetime);
create index product_cost_history_sku_date_idx on archive.product_cost_history (sku_code, effective_date);
create index goods_receipt_lines_gr_id_idx on archive.goods_receipt_lines (gr_id);

-- ---------------------------------------------------------------------------
-- Sync registry: one row per source sheet, in recommended load order
-- ---------------------------------------------------------------------------

insert into archive.archive_sync_control (source_table, target_table, table_group, load_order, enabled) values
  ('products',                        'products',                        'B',         10, true),
  ('suppliers',                       'suppliers',                       'B',         11, true),
  ('warehouses',                      'warehouses',                      'B',         12, true),
  ('couriers',                        'couriers',                        'B',         13, true),
  ('users',                           'users',                           'B',         14, true),
  ('packing_stations',                'packing_stations',                'B',         15, true),
  ('promo_pack_components',           'promo_pack_components',           'B',         16, true),
  ('sku_derivative_rules',            'sku_derivative_rules',            'B',         17, true),
  ('oms_status_mapping',              'oms_status_mapping',              'B',         18, true),
  ('forecast_baseline',               'forecast_baseline',               'B',         19, true),
  ('inventory_balance',               'inventory_balance',               'B',         20, true),
  ('orders',                          'orders',                          'A',         30, true),
  ('order_lines',                     'order_lines',                     'A',         31, true),
  ('reservations',                    'reservations',                    'A',         32, true),
  ('inventory_ledger',                'inventory_ledger',                'A',         33, true),
  ('packing_events',                  'packing_events',                  'A',         34, true),
  ('turnover_lines',                  'turnover_lines',                  'A',         35, true),
  ('oms_status_history',              'oms_status_history',              'A',         36, true),
  ('wallet_statements',               'wallet_statements',               'A',         40, true),
  ('wallet_transactions',             'wallet_transactions',             'A',         41, true),
  ('wallet_transactions_lines',       'wallet_transactions_lines',       'A',         42, true),
  ('returns',                         'returns',                         'A',         50, true),
  ('return_lines',                    'return_lines',                    'A',         51, true),
  ('product_cost_history',            'product_cost_history',            'A',         60, true),
  ('goods_receipts',                  'goods_receipts',                  'A',         61, true),
  ('goods_receipt_lines',             'goods_receipt_lines',             'A',         62, true),
  ('supply_purchases',                'supply_purchases',                'A',         63, true),
  ('supply_counts',                   'supply_counts',                   'A',         64, true),
  ('missing_data',                    'missing_data',                    'A',         65, true),
  ('job_execution_log',               'job_execution_log',               'A',         66, true),
  ('device_settings',                 'device_settings',                 'C',         70, true),
  ('financial_settings',              'financial_settings',              'C',         71, true),
  ('platform_settings',               'platform_settings',               'C',         72, true),
  ('system_settings',                 'system_settings',                 'C',         73, true),
  ('system_messages',                 'system_messages',                 'C',         74, true),
  ('warehouse_admin_bucket',          'warehouse_admin_bucket',          'D',         80, false),
  ('warehouse_dashboard',             'warehouse_dashboard',             'D',         81, false),
  ('warehouse_dashboard_work',        'warehouse_dashboard_work',        'D',         82, false),
  ('reservations_historical_recover', 'reservations_historical_recover', 'X',         90, false),
  ('api_tokens',                      'api_tokens_metadata',             'SECURITY',  99, false);

-- ---------------------------------------------------------------------------
-- Lock down: RLS on with no policies, no grants to API roles
-- ---------------------------------------------------------------------------

do $$
declare
  t record;
begin
  for t in select tablename from pg_tables where schemaname = 'archive'
  loop
    execute format('alter table archive.%I enable row level security', t.tablename);
    execute format('revoke all on archive.%I from public, anon, authenticated', t.tablename);
  end loop;
end $$;
