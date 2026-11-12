-- Registers the two historical-reservation tabs. Both stay off (enabled = false)
-- until you turn them on in archive_sync_control.
--
-- reservations_historical_recover  — table already exists.
-- reservations_historical_recovery — new tab (name ends in y). Same columns as recover.
-- Safe to run again.

create table if not exists archive.reservations_historical_recovery (
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

select archive.prepare_archive_table('reservations_historical_recovery');

create index if not exists reservations_historical_recovery_platform_order_idx
  on archive.reservations_historical_recovery (platform_order);

insert into archive.archive_sync_control
  (source_table, target_table, table_group, load_order, enabled, key_mode, key_columns)
values
  (
    'reservations_historical_recovery',
    'reservations_historical_recovery',
    'X',
    91,
    false,
    'pk',
    array['reservation_id']
  )
on conflict (source_table) do update
set target_table = excluded.target_table,
    table_group  = excluded.table_group,
    load_order   = excluded.load_order,
    enabled      = false,
    key_mode     = excluded.key_mode,
    key_columns  = excluded.key_columns;

update archive.archive_sync_control
set enabled = false
where source_table in (
  'reservations_historical_recover',
  'reservations_historical_recovery'
);

notify pgrst, 'reload schema';
