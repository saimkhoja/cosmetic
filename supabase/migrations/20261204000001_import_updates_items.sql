-- QuickSales: Inventory → Import from Excel also updates the items already in the catalogue.
-- A row matching an item already there (by its code, else its name, else one of its barcodes) no longer is skipped:
-- the item takes the row's category, units, prices and costs (a new cost revalues the stock held, as in the item form),
-- its barcodes get the row's new ones, and the row's cartons and pcs are added to the central store, booked at cost as
-- opening stock. Its name and code stay. New rows make new items, as before; categories not there yet are made.
-- A mixed set (sold by the set and the piece) is not changed from the file: its row is refused, to change in the item form.
-- Already running QuickSales? Run this file once, after 20261203000001_credit_at_internal_rate.sql. It changes no data.

-- stop at once if the update before this one was not run
do $$ begin
  if not exists (select 1 from pg_proc where proname = 'post_invoice' and pg_get_functiondef(oid) like '%Exchange on goods on credit%') then
    raise exception 'Run supabase/migrations/20261203000001_credit_at_internal_rate.sql (and every earlier file) first, then this file. supabase/scripts/check_migrations.sql shows what is missing';
  end if;
end $$;

create or replace function public.import_products(p_rows jsonb, p_file text default '') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); r jsonb; f jsonb; ok jsonb := '[]'; upd jsonb := '[]'; errs text[] := '{}';
  names text[] := '{}'; skus text[] := '{}'; codes text[] := '{}'; seen uuid[] := '{}'; b text[]; n int := 0; nu int := 0; stock int := 0; q int; s text;
  pid uuid; newcats int := 0; c text; ex public.products; old public.products; nw public.products; oc public.product_costs; nc public.product_costs; changed int := 0;
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
      q := case when (f->>'is_bundle')::boolean then 0 else app.int_or_raise(r->>'open_cartons','Opening cartons') * (f->>'per_carton')::int end
           + app.int_or_raise(r->>'open_pcs','Opening pcs');
      -- an item already in the catalogue: by its code, else its name, else one of its barcodes
      ex := null;
      if s is not null then select * into ex from products where active and lower(sku) = lower(s); end if;
      if ex.id is null then select * into ex from products where active and lower(name) = lower(f->>'name'); end if;
      if ex.id is null and cardinality(b) > 0 then select * into ex from products where active and barcodes && b order by name limit 1; end if;
      if ex.id is not null then
        if ex.is_bundle then raise exception '% is a mixed set: change it in the item form', ex.name; end if;
        if ex.id = any(seen) then raise exception '% is on more than one row', ex.name; end if;
        -- the row's barcodes may not belong to another item
        if cardinality(b) > 0 and exists (select 1 from products where barcodes && b and id <> ex.id) then
          raise exception 'a barcode of % belongs to another item', ex.name;
        end if;
        seen := seen || ex.id;
        upd := upd || jsonb_build_object('id', ex.id, 'f', f, 'barcode', array_to_string(b, ';'), 'qty', q,
          'reorder', case when coalesce(r->>'reorder','') = '' then ex.reorder else app.int_or_raise(r->>'reorder','Reorder') end);
        continue;
      end if;
      if lower(f->>'name') = any(names) then raise exception '% is on more than one row', f->>'name'; end if;
      if s is not null and lower(s) = any(skus) then raise exception 'code % is on more than one row', s; end if;
      if cardinality(b) > 0 and b && codes then raise exception 'a barcode of % is on another row', f->>'name'; end if;
      if s is not null and exists (select 1 from products where lower(sku) = lower(s)) then raise exception 'code % belongs to an archived item', s; end if;
      if cardinality(b) > 0 and exists (select 1 from products where barcodes && b) then raise exception 'a barcode of % belongs to an archived item', f->>'name'; end if;
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
  -- new items
  for r in select * from jsonb_array_elements(ok) loop
    pid := app.insert_product(r->'f', r->>'sku', (r->>'qty')::int, (r->>'reorder')::int, 'Excel import', u);
    perform app.set_barcode(pid, r->>'barcode');
    perform app.after_opening_stock(pid, (r->>'qty')::int, u);
    n := n + 1; stock := stock + (r->>'qty')::int;
  end loop;
  -- items already in the catalogue: the row's details (not the name or code), new barcodes added, the stock added
  for r in select * from jsonb_array_elements(upd) loop
    pid := (r->>'id')::uuid; f := r->'f';
    select * into old from products where id = pid for update;
    update products set category = f->>'category', stock_unit = f->>'stock_unit', per_carton = (f->>'per_carton')::int,
      price_usd = (f->>'price_usd')::numeric, dozen_usd = (f->>'dozen_usd')::numeric, half_dozen_usd = (f->>'half_dozen_usd')::numeric,
      carton_usd = (f->>'carton_usd')::numeric, reorder = (r->>'reorder')::int, updated_at = now()
    where id = pid returning * into nw;
    select * into oc from product_costs where product_id = pid;
    -- a new cost revalues the stock already held (the cost_books trigger), before the new stock comes in at it
    insert into product_costs (product_id, carton_cost_usd, net_cost_usd, cost_usd)
    values (pid, (f->>'carton_cost_usd')::numeric, (f->>'net_cost_usd')::numeric, (f->>'cost_usd')::numeric)
    on conflict (product_id) do update set carton_cost_usd = excluded.carton_cost_usd, net_cost_usd = excluded.net_cost_usd, cost_usd = excluded.cost_usd
    returning * into nc;
    if coalesce(r->>'barcode', '') <> '' then
      perform app.set_barcode(pid, array_to_string(array(select distinct x from unnest(coalesce(old.barcodes, '{}') || string_to_array(r->>'barcode', ';')) x where x <> ''), ';'));
    end if;
    if (r->>'qty')::int > 0 then
      update products set wh_qty = wh_qty + (r->>'qty')::int where id = pid;
      insert into purchases (product_id, qty, supplier, by_id, by_name) values (pid, (r->>'qty')::int, 'Excel import', u.id, u.name);
      perform app.after_opening_stock(pid, (r->>'qty')::int, u);
      stock := stock + (r->>'qty')::int;
    end if;
    if app.units_text(old) <> app.units_text(nw) or oc.cost_usd is distinct from nc.cost_usd or old.category <> nw.category then
      changed := changed + 1;
      perform app.log(u, format('Updated from Excel: %s%s%s', nw.name,
        case when app.units_text(old) <> app.units_text(nw) then format(', prices %s to %s', app.units_text(old), app.units_text(nw)) else '' end,
        case when oc.cost_usd is distinct from nc.cost_usd then format(', cost per pc %s to %s', app.usd(coalesce(oc.cost_usd, 0)), app.usd(nc.cost_usd)) else '' end));
    end if;
    nu := nu + 1;
  end loop;
  perform app.log(u, format('Imported from Excel: %s new items, %s items updated%s%s%s', n, nu, case when stock > 0 then format(', %s pcs of stock added', stock) else '' end,
    case when newcats > 0 then format(', %s new categories', newcats) else '' end,
    case when coalesce(p_file,'') <> '' then ' (' || left(p_file, 60) || ')' else '' end));
  return jsonb_build_object('imported', n, 'updated', nu, 'changed', changed, 'stock', stock, 'skipped', '[]'::jsonb, 'new_categories', newcats);
end $$;

revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.import_products(jsonb, text) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
