-- Lets Google Apps Script copy the Archive spreadsheet into schema "archive".
-- Run this once in the Supabase SQL Editor, after the archive tables already exist.
--
-- The sheet never talks to the tables directly. It calls the public functions below
-- with the service_role key. anon and authenticated cannot call them.
-- The archive schema stays off the Data API.

create extension if not exists pgcrypto with schema extensions;

alter table archive.archive_sync_control
  add column if not exists key_mode text,
  add column if not exists key_columns text[] not null default '{}';

update archive.archive_sync_control as c
set key_mode = v.key_mode,
    key_columns = v.key_columns
from (
  values
    ('products',                        'pk',        array['sku_code']),
    ('suppliers',                       'pk',        array['supplier_code']),
    ('warehouses',                      'pk',        array['warehouse_code']),
    ('couriers',                        'pk',        array['courier_code']),
    ('users',                           'pk',        array['user_id']),
    ('packing_stations',                'pk',        array['station_id']),
    ('promo_pack_components',           'composite', array['promo_sku', 'component_sku']),
    ('sku_derivative_rules',            'pk',        array['suffix']),
    ('oms_status_mapping',              'pk',        array['platform_status']),
    ('forecast_baseline',               'pk',        array['sku_code']),
    ('inventory_balance',               'pk',        array['inventory_balance_id']),
    ('orders',                          'pk',        array['platform_order_id']),
    ('order_lines',                     'pk',        array['order_line_id']),
    ('reservations',                    'pk',        array['reservation_id']),
    ('inventory_ledger',                'pk',        array['ledger_id']),
    ('packing_events',                  'pk',        array['packing_event_id']),
    ('turnover_lines',                  'pk',        array['turnover_line_id']),
    ('oms_status_history',              'pk',        array['history_id']),
    ('wallet_statements',               'pk',        array['statement_id']),
    ('wallet_transactions',             'wallet',    array['wallet_txn_id']),
    ('wallet_transactions_lines',       'pk',        array['wallet_transaction_line_id']),
    ('returns',                         'pk',        array['return_id']),
    ('return_lines',                    'pk',        array['return_line_id']),
    ('product_cost_history',            'pk',        array['cost_record_id']),
    ('goods_receipts',                  'pk',        array['gr_id']),
    ('goods_receipt_lines',             'pk',        array['gr_line_id']),
    ('supply_purchases',                'pk',        array['purchase_id']),
    ('supply_counts',                   'pk',        array['count_id']),
    ('missing_data',                    'hash',      array[]::text[]),
    ('job_execution_log',               'pk',        array['job_execution_id']),
    ('device_settings',                 'pk',        array['device_name']),
    ('financial_settings',              'pk',        array['setting_key']),
    ('platform_settings',               'pk',        array['platform']),
    ('system_settings',                 'pk',        array['setting_name']),
    ('system_messages',                 'pk',        array['message_id']),
    ('warehouse_admin_bucket',          'hash',      array[]::text[]),
    ('warehouse_dashboard',             'hash',      array[]::text[]),
    ('warehouse_dashboard_work',        'hash',      array[]::text[]),
    ('reservations_historical_recover', 'pk',        array['reservation_id']),
    ('api_tokens',                      'composite', array['platform', 'store_id', 'shop_id'])
) as v(source_table, key_mode, key_columns)
where c.source_table = v.source_table;

alter table archive.archive_sync_control
  alter column key_mode set not null;

alter table archive.archive_sync_control
  drop constraint if exists archive_sync_control_key_mode_chk;

alter table archive.archive_sync_control
  add constraint archive_sync_control_key_mode_chk
  check (key_mode in ('pk', 'composite', 'hash', 'wallet'));

-- Turn a sheet payload into typed jsonb. Unknown keys and bookkeeping keys are dropped.
-- Hash this result so two runs of the same sheet row produce the same _row_hash.
create or replace function archive.normalize_payload(p_payload jsonb, p_types jsonb)
returns jsonb
language plpgsql
stable
set search_path = archive, public, extensions
as $$
declare
  v_key text;
  v_val jsonb;
  v_type text;
  v_text text;
  v_out jsonb := '{}'::jsonb;
begin
  for v_key, v_val in select key, value from jsonb_each(p_payload)
  loop
    if v_key like '\_%' escape '\' then
      continue;
    end if;

    v_type := p_types ->> v_key;
    if v_type is null then
      continue;
    end if;

    if v_val is null or v_val = 'null'::jsonb or jsonb_typeof(v_val) = 'null' then
      v_out := v_out || jsonb_build_object(v_key, null);
      continue;
    end if;

    v_text := btrim(v_val #>> '{}');
    if v_text = '' or lower(v_text) = 'null' then
      v_out := v_out || jsonb_build_object(v_key, null);
      continue;
    end if;

    if v_type = 'boolean' then
      v_out := v_out || jsonb_build_object(
        v_key,
        case lower(v_text)
          when 'true' then true
          when 't' then true
          when 'y' then true
          when 'yes' then true
          when '1' then true
          when 'false' then false
          when 'f' then false
          when 'n' then false
          when 'no' then false
          when '0' then false
          else null
        end
      );
    elsif v_type in ('integer', 'bigint', 'smallint') then
      v_out := v_out || jsonb_build_object(v_key, trunc(v_text::numeric)::bigint);
    elsif v_type = 'numeric' then
      v_out := v_out || jsonb_build_object(v_key, v_text::numeric);
    elsif v_type = 'timestamp with time zone' then
      v_out := v_out || jsonb_build_object(v_key, v_text::timestamptz);
    elsif v_type = 'jsonb' then
      if jsonb_typeof(v_val) = 'string' then
        v_out := v_out || jsonb_build_object(v_key, v_text::jsonb);
      else
        v_out := v_out || jsonb_build_object(v_key, v_val);
      end if;
    else
      v_out := v_out || jsonb_build_object(v_key, v_text);
    end if;
  end loop;

  return v_out;
end;
$$;

revoke all on function archive.normalize_payload(jsonb, jsonb) from public, anon, authenticated;

create or replace function public.archive_list_sheets(p_include_disabled boolean default false)
returns jsonb
language sql
stable
security definer
set search_path = archive, public
as $$
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'source_table', source_table,
      'target_table', target_table,
      'table_group', table_group,
      'load_order', load_order,
      'enabled', enabled,
      'key_mode', key_mode,
      'key_columns', to_jsonb(key_columns)
    )
    order by load_order
  ), '[]'::jsonb)
  from archive.archive_sync_control
  where p_include_disabled or enabled;
$$;

create or replace function public.archive_sheet_contract(p_source_table text)
returns jsonb
language plpgsql
stable
security definer
set search_path = archive, public
as $$
declare
  v_ctrl archive.archive_sync_control%rowtype;
  v_columns jsonb;
begin
  select * into v_ctrl
  from archive.archive_sync_control
  where source_table = p_source_table;

  if not found then
    raise exception 'Unknown archive sheet: %', p_source_table;
  end if;

  select coalesce(jsonb_agg(
    jsonb_build_object('name', column_name, 'data_type', data_type)
    order by ordinal_position
  ), '[]'::jsonb)
  into v_columns
  from information_schema.columns
  where table_schema = 'archive'
    and table_name = v_ctrl.target_table
    and coalesce(is_identity, 'NO') = 'NO'
    and column_name not in ('_row_hash', '_source_file', '_execution_id', '_loaded_at', '_last_seen_at');

  return jsonb_build_object(
    'source_table', v_ctrl.source_table,
    'target_table', v_ctrl.target_table,
    'enabled', v_ctrl.enabled,
    'load_order', v_ctrl.load_order,
    'key_mode', v_ctrl.key_mode,
    'key_columns', to_jsonb(v_ctrl.key_columns),
    'columns', v_columns,
    'header_renames', jsonb_build_object(
      'BRAND', 'brand',
      'P60 days', 'p60_days',
      'Emoji', 'emoji'
    ),
    'secret_headers', jsonb_build_array(
      'access_token', 'refresh_token', 'app_key', 'app_secret', 'shop_cipher', 'main_account_id'
    ),
    'unnamed_headers', case
      when v_ctrl.source_table = 'wallet_transactions'
        then jsonb_build_array('unnamed_col_ab', 'unnamed_col_ac')
      else '[]'::jsonb
    end
  );
end;
$$;

create or replace function public.archive_begin_run(
  p_source_table text,
  p_run_mode text,
  p_source_database text,
  p_force boolean default false
)
returns bigint
language plpgsql
security definer
set search_path = archive, public
as $$
declare
  v_enabled boolean;
  v_id bigint;
begin
  if p_run_mode not in ('DRY_RUN', 'INITIAL', 'INCREMENTAL', 'BACKFILL') then
    raise exception 'Unsupported run mode: %', p_run_mode;
  end if;

  select enabled into v_enabled
  from archive.archive_sync_control
  where source_table = p_source_table;

  if not found then
    raise exception 'Unknown archive sheet: %', p_source_table;
  end if;

  if not v_enabled and not p_force then
    raise exception 'Sheet % is turned off in archive_sync_control', p_source_table;
  end if;

  insert into archive.archive_sync_log (run_mode, source_database, source_table, status)
  values (p_run_mode, p_source_database, p_source_table, 'RUNNING')
  returning execution_id into v_id;

  update archive.archive_sync_control
  set last_run_datetime = now(),
      last_status = 'RUNNING',
      last_error = null
  where source_table = p_source_table;

  return v_id;
end;
$$;

create or replace function public.archive_apply_batch(
  p_source_table text,
  p_execution_id bigint,
  p_rows jsonb,
  p_source_file text,
  p_dry_run boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = archive, public, extensions
as $$
declare
  v_ctrl archive.archive_sync_control%rowtype;
  v_types jsonb;
  v_cols text[];
  v_col_sql text;
  v_sel_sql text;
  v_item jsonb;
  v_norm jsonb;
  v_full jsonb;
  v_hash text;
  v_key text;
  v_existing text;
  v_seen jsonb := '{}'::jsonb;
  v_read integer := 0;
  v_inserted integer := 0;
  v_skipped integer := 0;
  v_changed integer := 0;
  v_failed integer := 0;
  v_reason text;
  v_skip_identical boolean;
  v_ord integer := 0;
  v_part text;
  v_col text;
begin
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'p_rows must be a json array';
  end if;

  select * into v_ctrl
  from archive.archive_sync_control
  where source_table = p_source_table;

  if not found then
    raise exception 'Unknown archive sheet: %', p_source_table;
  end if;

  if not exists (
    select 1 from archive.archive_sync_log
    where execution_id = p_execution_id
      and source_table = p_source_table
      and status = 'RUNNING'
  ) then
    raise exception 'Run % is not an open run for %', p_execution_id, p_source_table;
  end if;

  select jsonb_object_agg(column_name, data_type)
  into v_types
  from information_schema.columns
  where table_schema = 'archive'
    and table_name = v_ctrl.target_table
    and coalesce(is_identity, 'NO') = 'NO'
    and column_name not in ('_row_hash', '_source_file', '_execution_id', '_loaded_at', '_last_seen_at');

  select array_agg(column_name order by ordinal_position)
  into v_cols
  from information_schema.columns
  where table_schema = 'archive'
    and table_name = v_ctrl.target_table
    and coalesce(is_identity, 'NO') = 'NO';

  select string_agg(format('%I', col), ', '),
         string_agg(format('r.%I', col), ', ')
  into v_col_sql, v_sel_sql
  from unnest(v_cols) as col;

  for v_item in select value from jsonb_array_elements(p_rows)
  loop
    v_ord := v_ord + 1;
    v_read := v_read + 1;
    v_reason := null;
    v_skip_identical := false;
    v_key := null;
    v_existing := null;

    begin
      v_norm := archive.normalize_payload(v_item, v_types);
      v_hash := encode(extensions.digest(convert_to(v_norm::text, 'UTF8'), 'sha256'), 'hex');

      if v_ctrl.key_mode = 'hash' then
        v_key := v_hash;
      elsif v_ctrl.key_mode in ('pk', 'wallet') then
        v_key := v_norm ->> v_ctrl.key_columns[1];
      else
        foreach v_col in array v_ctrl.key_columns
        loop
          v_part := v_norm ->> v_col;
          if v_part is null or v_part = '' then
            v_key := null;
            exit;
          end if;
          v_key := concat_ws('|', v_key, v_part);
        end loop;
      end if;

      if v_ctrl.key_mode <> 'hash' and v_ctrl.key_mode <> 'wallet' and (v_key is null or v_key = '') then
        v_reason := 'missing key';
      elsif v_seen ? coalesce(v_key, v_hash) then
        if v_ctrl.key_mode = 'hash' then
          v_skip_identical := true;
        else
          v_reason := 'duplicate key in this batch';
        end if;
      end if;

      if v_reason is null and not v_skip_identical then
        v_seen := v_seen || jsonb_build_object(coalesce(v_key, v_hash), true);

        if v_ctrl.key_mode = 'hash' then
          execute format('select _row_hash from archive.%I where _row_hash = $1 limit 1', v_ctrl.target_table)
            into v_existing using v_hash;
        elsif v_ctrl.key_mode = 'wallet' and (v_key is null or v_key = '') then
          execute format(
            'select _row_hash from archive.%I where wallet_txn_id is null and _row_hash = $1 limit 1',
            v_ctrl.target_table
          ) into v_existing using v_hash;
          v_key := v_hash;
        elsif v_ctrl.key_mode = 'wallet' then
          execute format(
            'select _row_hash from archive.%I where wallet_txn_id = $1 limit 1',
            v_ctrl.target_table
          ) into v_existing using v_key;
        elsif v_ctrl.key_mode = 'pk' then
          execute format(
            'select _row_hash from archive.%I where %I = $1 limit 1',
            v_ctrl.target_table, v_ctrl.key_columns[1]
          ) into v_existing using v_key;
        elsif array_length(v_ctrl.key_columns, 1) = 2 then
          execute format(
            'select _row_hash from archive.%I where %I = $1 and %I = $2 limit 1',
            v_ctrl.target_table, v_ctrl.key_columns[1], v_ctrl.key_columns[2]
          ) into v_existing using v_norm ->> v_ctrl.key_columns[1], v_norm ->> v_ctrl.key_columns[2];
        elsif array_length(v_ctrl.key_columns, 1) = 3 then
          execute format(
            'select _row_hash from archive.%I where %I = $1 and %I = $2 and %I = $3 limit 1',
            v_ctrl.target_table, v_ctrl.key_columns[1], v_ctrl.key_columns[2], v_ctrl.key_columns[3]
          ) into v_existing
            using v_norm ->> v_ctrl.key_columns[1],
                  v_norm ->> v_ctrl.key_columns[2],
                  v_norm ->> v_ctrl.key_columns[3];
        else
          v_reason := 'unsupported key shape';
        end if;
      end if;

      if v_skip_identical then
        v_skipped := v_skipped + 1;
      elsif v_reason is not null then
        if not p_dry_run then
          insert into archive.archive_row_failures (
            execution_id, source_table, source_row_number, row_key, failure_reason, raw_row
          ) values (
            p_execution_id, p_source_table, v_ord, v_key, v_reason, v_item
          );
        end if;
        v_failed := v_failed + 1;
      elsif v_existing is null then
        if not p_dry_run then
          v_full := v_norm || jsonb_build_object(
            '_row_hash', v_hash,
            '_source_file', p_source_file,
            '_execution_id', p_execution_id,
            '_loaded_at', now(),
            '_last_seen_at', now()
          );
          execute format(
            'insert into archive.%I (%s) select %s from jsonb_populate_record(null::archive.%I, $1) as r',
            v_ctrl.target_table, v_col_sql, v_sel_sql, v_ctrl.target_table
          ) using v_full;
        end if;
        v_inserted := v_inserted + 1;
      elsif v_existing = v_hash then
        if not p_dry_run then
          if v_ctrl.key_mode = 'hash' or (v_ctrl.key_mode = 'wallet' and v_key = v_hash) then
            execute format(
              'update archive.%I set _last_seen_at = now() where _row_hash = $1',
              v_ctrl.target_table
            ) using v_hash;
          elsif v_ctrl.key_mode in ('pk', 'wallet') then
            execute format(
              'update archive.%I set _last_seen_at = now() where %I = $1',
              v_ctrl.target_table, v_ctrl.key_columns[1]
            ) using v_key;
          elsif array_length(v_ctrl.key_columns, 1) = 2 then
            execute format(
              'update archive.%I set _last_seen_at = now() where %I = $1 and %I = $2',
              v_ctrl.target_table, v_ctrl.key_columns[1], v_ctrl.key_columns[2]
            ) using v_norm ->> v_ctrl.key_columns[1], v_norm ->> v_ctrl.key_columns[2];
          else
            execute format(
              'update archive.%I set _last_seen_at = now() where %I = $1 and %I = $2 and %I = $3',
              v_ctrl.target_table, v_ctrl.key_columns[1], v_ctrl.key_columns[2], v_ctrl.key_columns[3]
            ) using v_norm ->> v_ctrl.key_columns[1],
                    v_norm ->> v_ctrl.key_columns[2],
                    v_norm ->> v_ctrl.key_columns[3];
          end if;
        end if;
        v_skipped := v_skipped + 1;
      else
        if not p_dry_run then
          insert into archive.archive_row_changes (
            execution_id, source_table, row_key, existing_hash, incoming_hash, incoming_row
          ) values (
            p_execution_id, p_source_table, coalesce(v_key, v_hash), v_existing, v_hash, v_norm
          )
          on conflict (source_table, row_key, incoming_hash) do nothing;
        end if;
        v_changed := v_changed + 1;
      end if;
    exception
      when others then
        v_failed := v_failed + 1;
        if not p_dry_run then
          insert into archive.archive_row_failures (
            execution_id, source_table, source_row_number, row_key, failure_reason, raw_row
          ) values (
            p_execution_id, p_source_table, v_ord, v_key, sqlerrm, v_item
          );
        end if;
    end;
  end loop;

  update archive.archive_sync_log
  set rows_read = rows_read + v_read,
      rows_inserted = rows_inserted + v_inserted,
      rows_skipped = rows_skipped + v_skipped,
      rows_changed = rows_changed + v_changed,
      rows_failed = rows_failed + v_failed
  where execution_id = p_execution_id;

  return jsonb_build_object(
    'read', v_read,
    'inserted', v_inserted,
    'skipped', v_skipped,
    'changed', v_changed,
    'failed', v_failed
  );
end;
$$;

create or replace function public.archive_finish_run(
  p_execution_id bigint,
  p_status text,
  p_error text default null
)
returns void
language plpgsql
security definer
set search_path = archive, public
as $$
declare
  v_log archive.archive_sync_log%rowtype;
begin
  if p_status not in ('SUCCESS', 'PARTIAL', 'FAILED') then
    raise exception 'Unsupported finish status: %', p_status;
  end if;

  update archive.archive_sync_log
  set finished_at = now(),
      status = p_status,
      duration_seconds = round(extract(epoch from (now() - started_at))::numeric, 3),
      error_message = p_error
  where execution_id = p_execution_id
    and status = 'RUNNING'
  returning * into v_log;

  if not found then
    raise exception 'Run % is not open', p_execution_id;
  end if;

  update archive.archive_sync_control
  set last_status = p_status,
      last_error = p_error,
      last_source_row_count = v_log.rows_read,
      last_run_datetime = now(),
      last_success_datetime = case
        when p_status in ('SUCCESS', 'PARTIAL') then now()
        else last_success_datetime
      end,
      last_successful_sync = case
        when p_status = 'SUCCESS' then now()
        else last_successful_sync
      end,
      rows_read = v_log.rows_read,
      rows_inserted = v_log.rows_inserted,
      rows_skipped = v_log.rows_skipped,
      rows_changed = v_log.rows_changed,
      rows_failed = v_log.rows_failed
  where source_table = v_log.source_table;
end;
$$;

revoke all on function public.archive_list_sheets(boolean) from public, anon, authenticated;
revoke all on function public.archive_sheet_contract(text) from public, anon, authenticated;
revoke all on function public.archive_begin_run(text, text, text, boolean) from public, anon, authenticated;
revoke all on function public.archive_apply_batch(text, bigint, jsonb, text, boolean) from public, anon, authenticated;
revoke all on function public.archive_finish_run(bigint, text, text) from public, anon, authenticated;

grant execute on function public.archive_list_sheets(boolean) to service_role;
grant execute on function public.archive_sheet_contract(text) to service_role;
grant execute on function public.archive_begin_run(text, text, text, boolean) to service_role;
grant execute on function public.archive_apply_batch(text, bigint, jsonb, text, boolean) to service_role;
grant execute on function public.archive_finish_run(bigint, text, text) to service_role;

notify pgrst, 'reload schema';
