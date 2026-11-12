-- oms_status_mapping: platform_status is not unique in the sheet
-- (UNPAID, IN_TRANSIT, CANCELLED each appear twice with the same oms_status).
-- Switch to hash matching so a second identical row is skipped, not failed.
-- Same platform_status with a different oms_status still stores as a second row.
-- Run once in the SQL Editor.

alter table archive.oms_status_mapping
  drop constraint if exists oms_status_mapping_pkey;

alter table archive.oms_status_mapping
  add column if not exists archive_row_id bigint generated always as identity;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'archive.oms_status_mapping'::regclass
      and contype = 'p'
  ) then
    alter table archive.oms_status_mapping
      add primary key (archive_row_id);
  end if;
end $$;

create unique index if not exists oms_status_mapping_row_hash_key
  on archive.oms_status_mapping (_row_hash);

update archive.archive_sync_control
set key_mode = 'hash',
    key_columns = array[]::text[]
where source_table = 'oms_status_mapping';

notify pgrst, 'reload schema';
