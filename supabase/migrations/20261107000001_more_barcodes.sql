-- QuickSales: an item can have up to 60 barcodes instead of 10 (in the item form and in an Excel import).
-- Already running QuickSales? Run this file once, after 20261026000001_multi_barcodes.sql, BEFORE the new app goes
-- live. It only changes the limit; it keeps your data and is safe to run again.

-- stop at once if the update that brought several barcodes per item was not run
do $$ begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'products' and column_name = 'barcodes') then
    raise exception 'Run supabase/migrations/20261026000001_multi_barcodes.sql (and every earlier file) first, then this file. supabase/scripts/check_migrations.sql shows what is missing';
  end if;
end $$;

-- barcodes as typed, scanned or imported: separated by , ; | or new lines; blanks and repeats dropped, at most 60
create or replace function app.barcode_list(v text) returns text[]
language plpgsql immutable as $$
declare part text; b text; res text[] := '{}';
begin
  foreach part in array regexp_split_to_array(coalesce(v, ''), '[,;|\n\r]+') loop
    b := app.barcode_of(part);
    if b is not null and not b = any(res) then res := res || b; end if;
  end loop;
  if cardinality(res) > 60 then raise exception 'An item can have at most 60 barcodes'; end if;
  return res;
end $$;

revoke execute on function app.barcode_list(text) from public, anon;
