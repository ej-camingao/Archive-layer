-- inventory_ledger sheet gained a related_id column.
-- Run once in the SQL Editor, then transfer inventory_ledger again.

alter table archive.inventory_ledger
  add column if not exists related_id text;

notify pgrst, 'reload schema';
