-- Skip identical extra rows in a hash-mode batch (oms_status_mapping duplicates).
-- The previous change only switched the key mode; the transfer still failed those rows.
-- Run this in the SQL Editor, then Transfer all again.

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

grant execute on function public.archive_apply_batch(text, bigint, jsonb, text, boolean) to service_role;
notify pgrst, 'reload schema';
