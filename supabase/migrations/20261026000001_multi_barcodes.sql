-- SIM: barcodes are a standard feature (no switch any more) and an item can have several barcodes, for example a
-- new pack design or another supplier's code for the same article. Each barcode still belongs to one item only.
-- products.barcodes holds them all; products.barcode keeps the first one, so a till still on the older app finds it.
-- Also fixes the Admin's values of returns to suppliers (they showed "-").
-- Already running SIM? Run this file once, after 20261025000001_one_per_carton.sql; it keeps your data.

alter table public.products add column if not exists barcodes text[] not null default '{}';
update public.products set barcodes = array[barcode] where barcode is not null and cardinality(barcodes) = 0;
create index if not exists products_barcodes_idx on public.products using gin (barcodes);

-- barcodes as typed, scanned or imported: separated by , ; | or new lines; blanks and repeats dropped, at most 10
create or replace function app.barcode_list(v text) returns text[]
language plpgsql immutable as $$
declare part text; b text; res text[] := '{}';
begin
  foreach part in array regexp_split_to_array(coalesce(v, ''), '[,;|\n\r]+') loop
    b := app.barcode_of(part);
    if b is not null and not b = any(res) then res := res || b; end if;
  end loop;
  if cardinality(res) > 10 then raise exception 'An item can have at most 10 barcodes'; end if;
  return res;
end $$;

-- an item's barcodes (the whole list replaces the old one); none of them may belong to another item
create or replace function app.set_barcode(pid uuid, v text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare l text[] := app.barcode_list(v); dup text; other text;
begin
  select x, p.name into dup, other from products p, unnest(l) x where p.id <> pid and (x = any(p.barcodes) or x = p.barcode) limit 1;
  if dup is not null then raise exception 'Barcode % is already used by %', dup, other; end if;
  update products set barcodes = l, barcode = l[1] where id = pid and (barcodes is distinct from l or barcode is distinct from l[1]);
end $$;

-- ---------- Excel import: a Barcode cell may hold several barcodes, separated by ; or , ----------
create or replace function public.import_products(p_rows jsonb, p_file text default '') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); r jsonb; f jsonb; ok jsonb := '[]'; skipped jsonb := '[]'; errs text[] := '{}';
  names text[] := '{}'; skus text[] := '{}'; codes text[] := '{}'; b text[]; n int := 0; stock int := 0; q int; s text; pid uuid; newcats int := 0; c text;
begin
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'There are no rows to import'; end if;
  if jsonb_array_length(p_rows) > 5000 then raise exception 'Import at most 5000 items at a time'; end if;
  -- categories named in the sheet are created if they don't exist yet
  for c in select distinct btrim(e->>'category') from jsonb_array_elements(p_rows) e where btrim(coalesce(e->>'category','')) <> '' loop
    if length(c) <= 30 and not exists (select 1 from categories where lower(name) = lower(c)) then
      insert into categories (name) values (c); newcats := newcats + 1;
    end if;
  end loop;
  for r in select * from jsonb_array_elements(p_rows) loop
    begin
      f := app.product_fields(r);
      s := nullif(btrim(coalesce(r->>'sku','')), '');
      b := app.barcode_list(r->>'barcode');
      if exists (select 1 from products where active and lower(name) = lower(f->>'name')) or lower(f->>'name') = any(names) then
        skipped := skipped || jsonb_build_object('row', r->>'row', 'name', f->>'name', 'reason', 'Name already exists'); continue;
      end if;
      if s is not null and (exists (select 1 from products where lower(sku) = lower(s)) or lower(s) = any(skus)) then
        skipped := skipped || jsonb_build_object('row', r->>'row', 'name', f->>'name', 'reason', 'Code already exists'); continue;
      end if;
      if cardinality(b) > 0 and (exists (select 1 from products where barcodes && b) or b && codes) then
        skipped := skipped || jsonb_build_object('row', r->>'row', 'name', f->>'name', 'reason', 'Barcode already exists'); continue;
      end if;
      q := case when (f->>'is_bundle')::boolean then 0 else app.int_or_raise(r->>'open_cartons','Opening cartons') * (f->>'per_carton')::int end
           + app.int_or_raise(r->>'open_pcs','Opening pcs');
      names := names || lower(f->>'name'); if s is not null then skus := skus || lower(s); end if; codes := codes || b;
      ok := ok || jsonb_build_object('f', f, 'sku', s, 'barcode', array_to_string(b, ';'), 'qty', q,
        'reorder', case when coalesce(r->>'reorder','') = '' then (f->>'per_carton')::int else app.int_or_raise(r->>'reorder','Reorder') end);
    exception when raise_exception then
      errs := errs || format('row %s: %s', coalesce(r->>'row','?'), sqlerrm);
    end;
  end loop;
  if array_length(errs, 1) > 0 then
    raise exception 'Nothing was imported. Fix these rows first: %', array_to_string(errs[1:8], '; ');
  end if;
  for r in select * from jsonb_array_elements(ok) loop
    pid := app.insert_product(r->'f', r->>'sku', (r->>'qty')::int, (r->>'reorder')::int, 'Excel import', u);
    perform app.set_barcode(pid, r->>'barcode');
    perform app.after_opening_stock(pid, (r->>'qty')::int, u);
    n := n + 1; stock := stock + (r->>'qty')::int;
  end loop;
  perform app.log(u, format('Imported %s new items from Excel%s%s%s', n, case when stock > 0 then format(', %s pcs opening stock', stock) else '' end,
    case when newcats > 0 then format(', %s new categories', newcats) else '' end,
    case when coalesce(p_file,'') <> '' then ' (' || left(p_file, 60) || ')' else '' end));
  return jsonb_build_object('imported', n, 'skipped', skipped, 'new_categories', newcats);
end $$;

-- ---------- fix: the Admin's view of what returns to suppliers are worth ----------
-- (the earlier version tested the Admin's profile with "is not null", which is false when any field, such as the
-- shop, is empty, so it always returned an empty list)
create or replace function public.supplier_return_values() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform app.req('admin');
  return (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'value_usd', r.value_usd, 'amount_usd', r.amount_usd,
    'bill_no', (select v.no || coalesce(' · ' || nullif(v.ref, ''), '') from vouchers v where v.id = r.bill_id))), '[]'::jsonb)
    from supplier_returns r);
end $$;

-- ---------- who may call what ----------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.save_product(jsonb), public.import_products(jsonb, text), public.supplier_return_values() to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
