-- Maintenance tools for the archive. Run once in the Supabase SQL Editor, after
-- 20261012000000_archive_transfer_rpc.sql. Safe to run again.
--
-- Adds
--   * archive.archive_header_map: sheet header -> table column, per sheet.
--     target_column null means "ignore this sheet column".
--   * archive.prepare_archive_table(name): bookkeeping columns + lockdown for a new table.
--   * archive.apply_accepted_changes(sheet): copies ACCEPTED rows from archive_row_changes
--     into the archive table.
--   * Blank cells no longer count toward _row_hash, so adding an empty column to a sheet
--     does not mark every stored row as changed.

-- ---------------------------------------------------------------------------
-- Header map
-- ---------------------------------------------------------------------------

create table if not exists archive.archive_header_map (
  source_table   text not null,
  source_header  text not null,
  target_column  text,
  note           text,
  created_at     timestamptz not null default now(),
  primary key (source_table, source_header)
);

insert into archive.archive_header_map (source_table, source_header, target_column, note) values
  ('products',               'BRAND',    'brand',    'Original header is upper case'),
  ('missing_data',           'P60 days', 'p60_days', 'Original header has a space'),
  ('warehouse_admin_bucket', 'Emoji',    'emoji',    'Original header is capitalised')
on conflict (source_table, source_header) do nothing;

alter table archive.archive_header_map enable row level security;
revoke all on archive.archive_header_map from public, anon, authenticated;

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
  v_renames jsonb;
  v_ignored jsonb;
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

  select coalesce(jsonb_object_agg(source_header, target_column) filter (where target_column is not null), '{}'::jsonb),
         coalesce(jsonb_agg(source_header) filter (where target_column is null), '[]'::jsonb)
  into v_renames, v_ignored
  from archive.archive_header_map
  where source_table = v_ctrl.source_table;

  return jsonb_build_object(
    'source_table', v_ctrl.source_table,
    'target_table', v_ctrl.target_table,
    'enabled', v_ctrl.enabled,
    'load_order', v_ctrl.load_order,
    'key_mode', v_ctrl.key_mode,
    'key_columns', to_jsonb(v_ctrl.key_columns),
    'columns', v_columns,
    'header_renames', v_renames,
    'ignored_headers', v_ignored,
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

revoke all on function public.archive_sheet_contract(text) from public, anon, authenticated;
grant execute on function public.archive_sheet_contract(text) to service_role;

-- ---------------------------------------------------------------------------
-- Blank cells are left out of the normalized row (and so out of _row_hash)
-- ---------------------------------------------------------------------------

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
  v_bool boolean;
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

    if v_val is null or jsonb_typeof(v_val) = 'null' then
      continue;
    end if;

    v_text := btrim(v_val #>> '{}');
    if v_text = '' or lower(v_text) = 'null' then
      continue;
    end if;

    if v_type = 'boolean' then
      v_bool := case lower(v_text)
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
      end;
      if v_bool is null then
        raise exception 'Column % expects true/false, got "%"', v_key, v_text;
      end if;
      v_out := v_out || jsonb_build_object(v_key, v_bool);
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

-- ---------------------------------------------------------------------------
-- New table helper
-- ---------------------------------------------------------------------------

-- Use on a new, empty archive table right after create table.
create or replace function archive.prepare_archive_table(p_table text)
returns void
language plpgsql
set search_path = archive, public
as $$
begin
  execute format(
    'alter table archive.%I
       add column if not exists _row_hash text not null,
       add column if not exists _source_file text,
       add column if not exists _execution_id bigint references archive.archive_sync_log (execution_id),
       add column if not exists _loaded_at timestamptz not null default now(),
       add column if not exists _last_seen_at timestamptz', p_table);
  execute format('alter table archive.%I enable row level security', p_table);
  execute format('revoke all on archive.%I from public, anon, authenticated', p_table);
end;
$$;

revoke all on function archive.prepare_archive_table(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Apply accepted changes
-- ---------------------------------------------------------------------------

alter table archive.archive_row_changes
  add column if not exists applied_at timestamptz;

-- Copies each ACCEPTED, not-yet-applied change into the archive table.
-- Only columns present in the incoming row are written, so accepting never erases a
-- stored value. A change is skipped as stale if the stored row moved on since it was logged.
create or replace function archive.apply_accepted_changes(p_source_table text)
returns jsonb
language plpgsql
set search_path = archive, public
as $$
declare
  v_ctrl archive.archive_sync_control%rowtype;
  v_chg archive.archive_row_changes%rowtype;
  v_set text;
  v_where text;
  v_count integer;
  v_applied integer := 0;
  v_stale integer := 0;
begin
  select * into v_ctrl
  from archive.archive_sync_control
  where source_table = p_source_table;

  if not found then
    raise exception 'Unknown archive sheet: %', p_source_table;
  end if;

  if v_ctrl.key_mode = 'hash' then
    raise exception 'Sheet % is matched by row content and has no change queue', p_source_table;
  end if;

  select string_agg(
           format('%I = case when $1 ? %L then r.%I else t.%I end',
                  column_name, column_name, column_name, column_name),
           ', ' order by ordinal_position)
  into v_set
  from information_schema.columns
  where table_schema = 'archive'
    and table_name = v_ctrl.target_table
    and coalesce(is_identity, 'NO') = 'NO'
    and column_name not in ('_row_hash', '_source_file', '_execution_id', '_loaded_at', '_last_seen_at')
    and column_name <> all (v_ctrl.key_columns);

  v_set := coalesce(v_set || ', ', '');

  select string_agg(format('t.%I = r.%I', k, k), ' and ')
  into v_where
  from unnest(v_ctrl.key_columns) as k;

  for v_chg in
    select *
    from archive.archive_row_changes
    where source_table = p_source_table
      and resolution = 'ACCEPTED'
      and applied_at is null
    order by detected_at, change_id
  loop
    execute format(
      'update archive.%I as t
          set %s_row_hash = $2, _last_seen_at = now()
         from jsonb_populate_record(null::archive.%I, $1) as r
        where %s and t._row_hash = $3',
      v_ctrl.target_table, v_set, v_ctrl.target_table, v_where
    ) using v_chg.incoming_row, v_chg.incoming_hash, v_chg.existing_hash;

    get diagnostics v_count = row_count;

    if v_count = 1 then
      update archive.archive_row_changes
      set applied_at = now()
      where change_id = v_chg.change_id;
      v_applied := v_applied + 1;
    else
      v_stale := v_stale + 1;
    end if;
  end loop;

  return jsonb_build_object('applied', v_applied, 'stale', v_stale);
end;
$$;

revoke all on function archive.apply_accepted_changes(text) from public, anon, authenticated;

notify pgrst, 'reload schema';
