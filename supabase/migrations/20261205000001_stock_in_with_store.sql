-- QuickSales: Shop stock → Add stock to shops also works with a central store.
-- The Admin adds stock straight into the shops ticked, typed or from the item Excel template (items not in the
-- catalogue are made from the file), booked at cost as opening stock, and the Shop Admin is told, as without a central
-- store. With a central store the usual way stays a delivery from the store; this is for stock that does not pass
-- through it.
-- Already running QuickSales? Run this file once, after 20261204000001_import_updates_items.sql. It changes no data.

-- stop at once if the update before this one was not run
do $$ begin
  if not exists (select 1 from pg_proc where proname = 'import_products' and pg_get_functiondef(oid) like '%items updated%') then
    raise exception 'Run supabase/migrations/20261204000001_import_updates_items.sql (and every earlier file) first, then this file. supabase/scripts/check_migrations.sql shows what is missing';
  end if;
end $$;

create or replace function public.stock_in_shops(p_shops uuid[], p_lines jsonb, p_new jsonb default '[]', p_file text default '', p_note text default '')
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); r jsonb; f jsonb; s text; b text[]; pid uuid; q int; errs text[] := '{}';
  names text[] := '{}'; skus text[] := '{}'; codes text[] := '{}'; created int := 0; newcats int := 0; c text;
  sh public.shops; v numeric; n int; units int; tz text; what text;
begin
  -- with a central store too: stock bought for a shop goes straight in, without passing through the store
  if p_shops is null or cardinality(p_shops) = 0 then raise exception 'Tick at least one shop'; end if;
  if (select count(*) from shops where active and id = any(p_shops)) <> cardinality(array(select distinct x from unnest(p_shops) x)) then
    raise exception 'One of the shops was not found';
  end if;
  if p_new is null or jsonb_typeof(p_new) <> 'array' then p_new := '[]'; end if;
  if jsonb_array_length(p_new) > 5000 then raise exception 'Import at most 5000 new items at a time'; end if;
  create temp table if not exists stock_in_lines (product_id uuid, qty int) on commit drop;
  delete from stock_in_lines where true;   -- the Supabase API refuses a DELETE without WHERE
  -- items already in the catalogue
  insert into stock_in_lines select l.product_id, l.qty from app.lines(coalesce(p_lines, '[]')) l;
  if exists (select 1 from stock_in_lines l where not exists (select 1 from products p where p.id = l.product_id and p.active)) then
    raise exception 'One of the items was not found';
  end if;
  -- categories named in the file are made if they do not exist yet
  for c in select distinct btrim(e->>'category') from jsonb_array_elements(p_new) e where btrim(coalesce(e->>'category', '')) <> '' loop
    if length(c) <= 30 and not exists (select 1 from categories where lower(name) = lower(c)) then
      insert into categories (name) values (c); newcats := newcats + 1;
    end if;
  end loop;
  -- items not in the catalogue: checked like the item import, then made
  for r in select * from jsonb_array_elements(p_new) loop
    begin
      f := app.product_fields(r);
      s := nullif(btrim(coalesce(r->>'sku', '')), '');
      b := app.barcode_list(r->>'barcode');
      if exists (select 1 from products where active and lower(name) = lower(f->>'name')) or lower(f->>'name') = any(names) then
        raise exception 'an item called "%" already exists', f->>'name';
      end if;
      if s is not null and (exists (select 1 from products where lower(sku) = lower(s)) or lower(s) = any(skus)) then raise exception 'the code % is already used', s; end if;
      if cardinality(b) > 0 and (exists (select 1 from products where barcodes && b) or b && codes) then raise exception 'one of its barcodes is already used'; end if;
      q := case when (f->>'is_bundle')::boolean then 0 else app.int_or_raise(r->>'open_cartons', 'Cartons') * (f->>'per_carton')::int end
           + app.int_or_raise(r->>'open_pcs', 'Pcs');
      names := names || lower(f->>'name'); if s is not null then skus := skus || lower(s); end if; codes := codes || b;
      pid := app.insert_product(f, s, 0, case when coalesce(r->>'reorder', '') = '' then (f->>'per_carton')::int else app.int_or_raise(r->>'reorder', 'Reorder') end,
        '', u);
      perform app.set_barcode(pid, array_to_string(b, ';'));
      created := created + 1;
      if q > 0 then insert into stock_in_lines values (pid, q); end if;
    exception when raise_exception then
      errs := errs || format('row %s: %s', coalesce(r->>'row', '?'), sqlerrm);
    end;
  end loop;
  if array_length(errs, 1) > 0 then
    raise exception 'Nothing was added. Fix these rows first: %', array_to_string(errs[1:8], '; ');
  end if;
  select count(distinct product_id), coalesce(sum(qty), 0) into n, units from stock_in_lines;
  if units = 0 and created = 0 then raise exception 'Enter a quantity for at least one item'; end if;
  select settings.tz into tz from settings where id = 1;
  what := coalesce(nullif(btrim(p_file), ''), 'by hand');
  -- into each shop ticked, booked at cost as opening stock
  for sh in select * from shops where id = any(p_shops) order by name loop
    insert into shop_stock (shop_id, product_id, qty) select sh.id, l.product_id, sum(l.qty) from stock_in_lines l group by l.product_id
      on conflict (shop_id, product_id) do update set qty = shop_stock.qty + excluded.qty;
    insert into purchases (product_id, qty, supplier, by_id, by_name)
      select l.product_id, sum(l.qty), left('Stock added to ' || sh.name || ' (' || what || ')', 120), u.id, u.name from stock_in_lines l group by l.product_id;
    select coalesce(sum(l.qty * coalesce(c.cost_usd, 0)), 0) into v from stock_in_lines l left join product_costs c on c.product_id = l.product_id;
    perform app.post('opening', (now() at time zone tz)::date, left(format('Stock added to %s (%s)%s', sh.name, what, coalesce(': ' || nullif(btrim(p_note), ''), '')), 200),
      sh.code, null, null,
      jsonb_build_array(jsonb_build_object('account', app.shop_acc('INV_SHOP', sh.id), 'side', 'Dr', 'amount', round(v, 2)),
                        jsonb_build_object('code', 'OPENING', 'side', 'Cr', 'amount', round(v, 2))), u.name);
    -- the shop admin is told what came in
    perform app.stock_arrived(sh.id, 'stock_in', what, p_note, u.name,
      (select jsonb_agg(jsonb_build_object('product_id', l.product_id, 'qty', l.qty)) from (select product_id, sum(qty) qty from stock_in_lines group by product_id) l where l.qty > 0));
  end loop;
  perform app.log(u, format('Stock added to %s (%s): %s items, %s units each%s%s',
    (select string_agg(name, ', ' order by name) from shops where id = any(p_shops)), what, n, units,
    case when created > 0 then format(', %s new items made', created) else '' end,
    case when newcats > 0 then format(', %s new categories', newcats) else '' end));
  return jsonb_build_object('created', created, 'items', n, 'units', units, 'shops', cardinality(p_shops), 'new_categories', newcats);
end $$;

revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
