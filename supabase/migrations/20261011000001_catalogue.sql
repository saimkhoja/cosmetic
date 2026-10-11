-- SIM update 2 (part 1): categories made by the Admin, half-dozen unit, optional carton price,
-- deleting (archiving) items, hot-item ranking, the till printing approved orders.
-- Safe to run more than once.

-- ---------- categories ----------
create table if not exists public.categories (
  id            uuid primary key default gen_random_uuid(),
  name          text not null check (length(btrim(name)) between 1 and 30),
  seasonal      boolean not null default false,
  season_months int[] not null default '{}',             -- 1..12, the months a seasonal category sells
  created_at    timestamptz not null default now()
);
create unique index if not exists categories_name_key on public.categories (lower(name));
-- categories already used by items are kept, so nothing breaks; the built-in list is gone
insert into public.categories (name) select distinct category from public.products
  where not exists (select 1 from public.categories c where lower(c.name) = lower(products.category));
alter table public.categories enable row level security;
revoke all on public.categories from anon, authenticated;
grant select on public.categories to authenticated;
drop policy if exists read_categories on public.categories;
create policy read_categories on public.categories for select to authenticated using (app.my_role() is not null);

-- ---------- products: half dozen, archive ----------
alter table public.products add column if not exists half_dozen_usd numeric(12,4) not null default 0;
alter table public.products add column if not exists archived_at timestamptz;
drop index if exists products_name_key;
create unique index if not exists products_active_name_key on public.products (lower(name)) where active;

create or replace function app.product_fields(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  name text := btrim(regexp_replace(coalesce(p->>'name',''), '\s+', ' ', 'g'));
  cat text := btrim(coalesce(p->>'category',''));
  b boolean := coalesce((p->>'is_bundle')::boolean, false);
  cc numeric; per numeric; pc numeric; dz numeric; hz numeric; ctn numeric; cpc numeric;
  sc numeric; sp numeric; pcs numeric; pp numeric;
begin
  if name = '' then raise exception 'Enter the item name'; end if;
  if length(name) > 60 then raise exception 'Item name is too long (60 characters at most)'; end if;
  if cat = '' then raise exception 'Choose the category'; end if;
  select c.name into cat from categories c where lower(c.name) = lower(cat);
  if cat is null then raise exception 'Category "%" does not exist. The Admin creates categories first', btrim(p->>'category'); end if;
  if b then
    sc := app.num(p->>'set_cost'); sp := app.num(p->>'set_price'); pcs := app.num(p->>'pcs'); pp := app.num(p->>'piece');
    if sc is null or sc < 0 or sp is null or sp <= 0 then raise exception 'Enter the cost and selling price of one set'; end if;
    if sp < sc then raise exception 'Set price cannot be below its cost'; end if;
    if pcs is null or pcs < 2 or pcs <> trunc(pcs) or pp is null or pp <= 0 then
      raise exception 'For a mixed set, enter the pieces per set and the last price for one piece';
    end if;
    return jsonb_build_object('name',name,'category',cat,'stock_unit','set','is_bundle',true,
      'per_carton',0,'pieces_per_set',pcs::int,'price_usd',sp,'dozen_usd',0,'half_dozen_usd',0,'carton_usd',0,'piece_usd',pp,
      'carton_cost_usd',0,'cost_usd',sc);
  end if;
  cc := app.num(p->>'carton_cost'); per := app.num(p->>'per_carton'); pc := app.num(p->>'pc');
  dz := coalesce(app.num(p->>'dzn'), 0); hz := coalesce(app.num(p->>'half'), 0); ctn := coalesce(app.num(p->>'ctn'), 0);
  if cc is null or cc < 0 then raise exception 'Enter the cost of one carton'; end if;
  if per is null or per < 2 or per <> trunc(per) then raise exception 'Enter how many pcs are in one carton (2 or more)'; end if;
  if pc is null or pc <= 0 then raise exception 'Enter the selling price per pc'; end if;
  if dz < 0 or hz < 0 or ctn < 0 then raise exception 'Prices cannot be negative'; end if;
  cpc := cc / per;
  if per = 12 then dz := 0; end if;
  if per = 6 then hz := 0; end if;
  if pc < cpc - 0.000000001 then raise exception 'Price per pc is below the cost of one pc (%)', app.usd(cpc); end if;
  if hz > 0 and hz < cpc * 6 - 0.000000001 then raise exception 'Price per half dozen is below the cost of 6 pcs (%)', app.usd(cpc * 6); end if;
  if dz > 0 and dz < cpc * 12 - 0.000000001 then raise exception 'Price per dozen is below the cost of 12 pcs (%)', app.usd(cpc * 12); end if;
  if ctn > 0 and ctn < cc then raise exception 'Price per carton cannot be below the carton cost'; end if;
  return jsonb_build_object('name',name,'category',cat,'stock_unit','pcs','is_bundle',false,
    'per_carton',per::int,'pieces_per_set',0,'price_usd',pc,'dozen_usd',dz,'half_dozen_usd',hz,'carton_usd',ctn,'piece_usd',0,
    'carton_cost_usd',cc,'cost_usd',cpc);
end $$;

create or replace function app.units_text(p public.products) returns text
language sql immutable as $$
  select case when p.is_bundle then 'set ' || app.usd(p.price_usd) || ', piece ' || app.usd(p.piece_usd)
    else 'pcs ' || app.usd(p.price_usd) || case when p.half_dozen_usd > 0 then ', half dzn ' || app.usd(p.half_dozen_usd) else '' end
         || case when p.dozen_usd > 0 then ', dzn ' || app.usd(p.dozen_usd) else '' end
         || case when p.carton_usd > 0 then ', carton ' || app.usd(p.carton_usd) else '' end end
$$;

-- the unit a line is sold in, checked against the item
create or replace function app.unit_of(pr public.products, mult int, piece boolean) returns text
language plpgsql stable as $$
begin
  if piece then
    if not pr.is_bundle then raise exception '% is not sold by piece', pr.name; end if;
    return 'piece';
  elsif pr.is_bundle then
    if mult <> 1 then raise exception 'Unit not valid for %', pr.name; end if;
    return 'set';
  elsif mult = 1 then return 'pcs';
  elsif mult = 6 and pr.half_dozen_usd > 0 and pr.per_carton <> 6 then return 'half dzn';
  elsif mult = 12 and pr.dozen_usd > 0 and pr.per_carton <> 12 then return 'dzn';
  elsif mult = pr.per_carton and pr.carton_usd > 0 then return 'carton';
  end if;
  raise exception 'Unit not valid for %', pr.name;
end $$;

-- shop price of one unit, in FC
create or replace function app.unit_price(pr public.products, unit text, r numeric) returns bigint
language sql immutable as $$
  select app.to_cdf(case unit when 'piece' then pr.piece_usd when 'half dzn' then pr.half_dozen_usd when 'dzn' then pr.dozen_usd
    when 'carton' then pr.carton_usd else pr.price_usd end, r)
$$;

create or replace function app.insert_product(f jsonb, sku text, qty int, reorder int, supplier text, u public.profiles)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare pid uuid; s text := nullif(btrim(coalesce(sku,'')), '');
begin
  if exists (select 1 from products where active and lower(name) = lower(f->>'name')) then
    raise exception 'An item called "%" already exists', f->>'name';
  end if;
  if s is not null and exists (select 1 from products where lower(products.sku) = lower(s)) then
    raise exception 'The code % is already used', s;
  end if;
  if s is null then
    loop s := 'SK-' || nextval('sku_seq'); exit when not exists (select 1 from products where products.sku = s); end loop;
  end if;
  insert into products (sku, name, category, stock_unit, is_bundle, per_carton, pieces_per_set, price_usd, dozen_usd, half_dozen_usd, carton_usd, piece_usd, reorder, wh_qty)
  values (s, f->>'name', f->>'category', f->>'stock_unit', (f->>'is_bundle')::boolean, (f->>'per_carton')::int, (f->>'pieces_per_set')::int,
    (f->>'price_usd')::numeric, (f->>'dozen_usd')::numeric, (f->>'half_dozen_usd')::numeric, (f->>'carton_usd')::numeric, (f->>'piece_usd')::numeric, reorder, qty)
  returning id into pid;
  insert into product_costs values (pid, (f->>'carton_cost_usd')::numeric, (f->>'cost_usd')::numeric);
  insert into shop_stock (shop_id, product_id) select id, pid from shops;
  if qty > 0 then insert into purchases (product_id, qty, supplier, by_id, by_name) values (pid, qty, coalesce(supplier,''), u.id, u.name); end if;
  return pid;
end $$;

-- item form. Stock is no longer received here (that goes through "Receive from supplier"), except
-- the opening stock of a brand-new item.
create or replace function public.save_product(p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); f jsonb := app.product_fields(p); pid uuid := (p->>'id')::uuid;
  old public.products; nw public.products; v_qty int; v_reorder int := app.int_or_raise(p->>'reorder', 'Reorder level');
begin
  if pid is null then
    v_qty := case when (f->>'is_bundle')::boolean then 0 else app.int_or_raise(p->>'qty_cartons', 'Cartons') * (f->>'per_carton')::int end
           + app.int_or_raise(p->>'qty_loose', 'Quantity');
    pid := app.insert_product(f, p->>'sku', v_qty, v_reorder, 'Opening stock', u);
    perform app.log(u, format('Added item %s%s', f->>'name', case when v_qty > 0 then format(', opening stock %s %s', v_qty, f->>'stock_unit') else '' end));
    perform app.after_opening_stock(pid, v_qty, u);
    return pid;
  end if;
  select * into old from products where id = pid and active for update;
  if not found then raise exception 'Item not found'; end if;
  if exists (select 1 from products where active and lower(name) = lower(f->>'name') and id <> pid) then
    raise exception 'An item called "%" already exists', f->>'name';
  end if;
  update products set name = f->>'name', category = f->>'category', stock_unit = f->>'stock_unit', is_bundle = (f->>'is_bundle')::boolean,
    per_carton = (f->>'per_carton')::int, pieces_per_set = (f->>'pieces_per_set')::int, price_usd = (f->>'price_usd')::numeric,
    dozen_usd = (f->>'dozen_usd')::numeric, half_dozen_usd = (f->>'half_dozen_usd')::numeric, carton_usd = (f->>'carton_usd')::numeric,
    piece_usd = (f->>'piece_usd')::numeric, reorder = v_reorder, updated_at = now()
  where id = pid returning * into nw;
  insert into product_costs values (pid, (f->>'carton_cost_usd')::numeric, (f->>'cost_usd')::numeric)
  on conflict (product_id) do update set carton_cost_usd = excluded.carton_cost_usd, cost_usd = excluded.cost_usd;
  if app.units_text(old) <> app.units_text(nw) then
    perform app.log(u, format('Prices changed for %s: %s to %s', nw.name, app.units_text(old), app.units_text(nw)));
  end if;
  perform app.log(u, 'Updated item ' || nw.name);
  return pid;
end $$;

-- hook for the accounts part: opening stock of a new item (replaced by the accounts migration)
create or replace function app.after_opening_stock(p_product uuid, p_qty int, u public.profiles) returns void
language plpgsql security definer set search_path = public, pg_temp as $$ begin null; end $$;

create or replace function public.import_products(p_rows jsonb, p_file text default '') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); r jsonb; f jsonb; ok jsonb := '[]'; skipped jsonb := '[]'; errs text[] := '{}';
  names text[] := '{}'; skus text[] := '{}'; n int := 0; stock int := 0; q int; s text; pid uuid; newcats int := 0; c text;
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
      if exists (select 1 from products where active and lower(name) = lower(f->>'name')) or lower(f->>'name') = any(names) then
        skipped := skipped || jsonb_build_object('row', r->>'row', 'name', f->>'name', 'reason', 'Name already exists'); continue;
      end if;
      if s is not null and (exists (select 1 from products where lower(sku) = lower(s)) or lower(s) = any(skus)) then
        skipped := skipped || jsonb_build_object('row', r->>'row', 'name', f->>'name', 'reason', 'Code already exists'); continue;
      end if;
      q := case when (f->>'is_bundle')::boolean then 0 else app.int_or_raise(r->>'open_cartons','Opening cartons') * (f->>'per_carton')::int end
           + app.int_or_raise(r->>'open_pcs','Opening pcs');
      names := names || lower(f->>'name'); if s is not null then skus := skus || lower(s); end if;
      ok := ok || jsonb_build_object('f', f, 'sku', s, 'qty', q,
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
    perform app.after_opening_stock(pid, (r->>'qty')::int, u);
    n := n + 1; stock := stock + (r->>'qty')::int;
  end loop;
  perform app.log(u, format('Imported %s new items from Excel%s%s%s', n, case when stock > 0 then format(', %s pcs opening stock', stock) else '' end,
    case when newcats > 0 then format(', %s new categories', newcats) else '' end,
    case when coalesce(p_file,'') <> '' then ' (' || left(p_file, 60) || ')' else '' end));
  return jsonb_build_object('imported', n, 'skipped', skipped, 'new_categories', newcats);
end $$;

create or replace function public.save_category(p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); cid uuid := (p->>'id')::uuid; n text := btrim(regexp_replace(coalesce(p->>'name',''), '\s+', ' ', 'g'));
  old text; seas boolean := coalesce((p->>'seasonal')::boolean, false); months int[];
begin
  if n = '' then raise exception 'Enter the category name'; end if;
  if length(n) > 30 then raise exception 'Category name is too long (30 characters at most)'; end if;
  select coalesce(array_agg(distinct m::int order by m::int), '{}') into months from jsonb_array_elements_text(coalesce(p->'season_months','[]')) m;
  if exists (select 1 from unnest(months) m where m < 1 or m > 12) then raise exception 'Months must be 1 to 12'; end if;
  if seas and coalesce(array_length(months,1),0) = 0 then raise exception 'Pick the months when this seasonal category sells'; end if;
  if exists (select 1 from categories where lower(name) = lower(n) and id is distinct from cid) then raise exception 'Category "%" already exists', n; end if;
  if cid is null then
    insert into categories (name, seasonal, season_months) values (n, seas, case when seas then months else '{}' end) returning id into cid;
    perform app.log(u, 'Added category ' || n);
  else
    select name into old from categories where id = cid for update;
    if old is null then raise exception 'Category not found'; end if;
    update categories set name = n, seasonal = seas, season_months = case when seas then months else '{}' end where id = cid;
    if old <> n then update products set category = n where category = old; end if;
    perform app.log(u, case when old <> n then format('Renamed category %s to %s', old, n) else 'Updated category ' || n end);
  end if;
  return cid;
end $$;

create or replace function public.delete_category(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); c public.categories; k int;
begin
  select * into c from categories where id = p_id;
  if not found then raise exception 'Category not found'; end if;
  select count(*) into k from products where active and category = c.name;
  if k > 0 then raise exception 'Move the % item(s) in "%" to another category first', k, c.name; end if;
  delete from categories where id = p_id;
  perform app.log(u, 'Deleted category ' || c.name);
end $$;

-- delete an item: only with no stock anywhere. If it was ever used, it is archived so its history stays.
create or replace function public.delete_product(p_id uuid) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); pr public.products; shops_left text; used boolean;
begin
  select * into pr from products where id = p_id and active for update;
  if not found then raise exception 'Item not found'; end if;
  if pr.wh_qty <> 0 then raise exception '% still has % % in the central store. Adjust the stock to 0 first', pr.name, pr.wh_qty, pr.stock_unit; end if;
  select string_agg(s.name || ' (' || st.qty || ')', ', ') into shops_left from shop_stock st join shops s on s.id = st.shop_id
    where st.product_id = p_id and (st.qty <> 0 or st.open_pieces <> 0);
  if shops_left is not null then raise exception '% still has stock in: %. Return or sell it first', pr.name, shops_left; end if;
  if exists (select 1 from delivery_items i join deliveries d on d.id = i.delivery_id where i.product_id = p_id and d.status = 'pending') then
    raise exception '% is on a delivery that is not received yet', pr.name;
  end if;
  used := exists (select 1 from invoice_items where product_id = p_id) or exists (select 1 from delivery_items where product_id = p_id)
       or exists (select 1 from purchases where product_id = p_id) or app.item_used_elsewhere(p_id);
  if used then
    update products set active = false, archived_at = now(), updated_at = now() where id = p_id;
    perform app.log(u, 'Archived item ' || pr.name || ' (it has sales or stock history)');
    return 'archived';
  end if;
  delete from products where id = p_id;
  perform app.log(u, 'Deleted item ' || pr.name);
  return 'deleted';
end $$;
-- hook for the accounts part (supplier receipts and returns also count as history)
create or replace function app.item_used_elsewhere(p_id uuid) returns boolean
language sql stable as $$ select false $$;

create or replace function public.restore_product(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); pr public.products;
begin
  select * into pr from products where id = p_id and not active for update;
  if not found then raise exception 'Archived item not found'; end if;
  if exists (select 1 from products where active and lower(name) = lower(pr.name)) then raise exception 'An active item is already called "%". Rename one first', pr.name; end if;
  update products set active = true, archived_at = null, updated_at = now() where id = p_id;
  perform app.log(u, 'Restored item ' || pr.name);
end $$;

-- ---------- hot items first: units sold in the last 30 days; seasonal items out of season last ----------
create or replace function public.item_ranks(p_shop uuid default null) returns table (product_id uuid, sold_30 numeric, in_season boolean)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin','whop','shopadmin','till'); sid uuid := case when u.role in ('shopadmin','till') then u.shop_id else p_shop end;
  m int := extract(month from now() at time zone (select tz from settings where id = 1))::int;
begin
  return query
  select p.id,
    coalesce((select sum(case when ii.piece then ii.qty::numeric / greatest(p.pieces_per_set,1) else ii.qty * greatest(ii.mult,1) end)
      from invoice_items ii join invoices i on i.id = ii.invoice_id
      where ii.product_id = p.id and i.t > now() - interval '30 days' and (sid is null or i.shop_id = sid)), 0),
    coalesce((select not c.seasonal or m = any(c.season_months) from categories c where c.name = p.category), true)
  from products p where p.active;
end $$;

-- ---------- sales with half dozen; the till prints the invoices of its approved orders ----------
alter table public.invoices add column if not exists till_printed_at timestamptz;

drop policy if exists read_invoices on public.invoices;
create policy read_invoices on public.invoices for select to authenticated
  using (app.my_role() = 'admin' or (app.my_role() = 'shopadmin' and shop_id = app.my_shop())
    or (app.my_role() = 'till' and order_id in (select o.id from sale_orders o where o.created_by = auth.uid())));

create or replace function public.record_till_print(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('till','shopadmin'); inv public.invoices;
begin
  select i.* into inv from invoices i join sale_orders o on o.id = i.order_id where i.id = p_id and i.shop_id = u.shop_id for update of i;
  if not found then raise exception 'Invoice not found'; end if;
  if u.role = 'till' and inv.till_printed_at is not null then raise exception 'Already printed. Ask the shop admin for a duplicate'; end if;
  update invoices set till_printed_at = coalesce(till_printed_at, now()) where id = p_id;
  perform app.log(u, format('Invoice %s for %s printed at the till', inv.no, inv.customer));
end $$;

create or replace function public.submit_invoice(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); iid uuid := (p->>'id')::uuid; ex public.invoices; dv public.devices; s public.shops;
  cashier public.profiles; seq int; r numeric := app.num(p->>'rate'); vr numeric := app.num(p->>'vat_rate'); dp int; t timestamptz;
  it jsonb; pr public.products; pc public.product_costs; ln int := 0; q int; mult int; piece boolean; price bigint; cur bigint; unit text; cost numeric;
  v_gross bigint := 0; v_disc bigint; v_total bigint; v_vat bigint; tend bigint; flag boolean := false;
  cust text := btrim(coalesce(p->>'customer','')); o public.sale_orders; oid uuid := (p->>'order_id')::uuid;
begin
  if iid is null then raise exception 'Invoice id is missing'; end if;
  select * into ex from invoices where id = iid;
  if found then
    if ex.shop_id <> u.shop_id then raise exception 'Invoice id already used'; end if;
    return jsonb_build_object('status', 'duplicate', 'no', ex.no);
  end if;
  if cust = '' then raise exception 'Enter the customer name'; end if;
  if length(cust) > 60 then raise exception 'Customer name is too long'; end if;
  select * into dv from devices where id = (p->>'device_id')::uuid and shop_id = u.shop_id for update;
  if not found then raise exception 'This till is not registered for your shop'; end if;
  select * into s from shops where id = u.shop_id;
  if coalesce(p->>'no','') !~ ('^' || s.code || '-' || dv.code || '-\d{6}$') then raise exception 'Invoice number does not match this till'; end if;
  seq := right(p->>'no', 6)::int;
  if oid is not null then
    select * into o from sale_orders where id = oid and shop_id = u.shop_id for update;
    if not found then raise exception 'The order being approved was not found'; end if;
    if o.status <> 'pending' then raise exception 'The order for % was already %', o.customer, o.status; end if;
  end if;
  select * into cashier from profiles where id = coalesce((p->>'cashier_id')::uuid, u.id) and shop_id = u.shop_id and role = 'shopadmin';
  if cashier.id is null then cashier := u; end if;
  if r is null or r <= 0 then raise exception 'Exchange rate is missing'; end if;
  if vr is null or vr < 0 or vr > 30 then raise exception 'VAT rate is not valid'; end if;
  dp := coalesce(app.num(p->>'disc_pct'), 0)::int;
  if dp < 0 or dp > 30 then raise exception 'Discount must be between 0%% and 30%%'; end if;
  t := coalesce((p->>'t')::timestamptz, now());
  if t > now() + interval '10 minutes' then t := now(); end if;
  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'The sale has no items'; end if;
  insert into invoices (id, no, shop_id, device_id, cashier_id, cashier_name, t, rate, vat_rate, gross, disc_pct, disc, total, vat, ht, tendered, customer, order_id, prepared_by_name)
    values (iid, p->>'no', s.id, dv.id, cashier.id, cashier.name, t, r, vr, 0, dp, 0, 0, 0, 0, 0, cust, oid, o.created_by_name);
  for it in select * from jsonb_array_elements(p->'items') loop
    ln := ln + 1;
    select * into pr from products where id = (it->>'product_id')::uuid;
    if not found then raise exception 'Unknown item on line %', ln; end if;
    select * into pc from product_costs where product_id = pr.id;
    q := app.int_or_raise(it->>'qty', 'Quantity'); if q < 1 then raise exception 'Quantity must be 1 or more'; end if;
    price := app.num(it->>'price')::bigint; if price is null or price <= 0 then raise exception 'Price missing on line %', ln; end if;
    piece := coalesce((it->>'piece')::boolean, false); mult := coalesce(app.num(it->>'mult'), 1)::int;
    unit := app.unit_of(pr, mult, piece);
    if piece then mult := 0; cost := coalesce(pc.cost_usd,0) / greatest(pr.pieces_per_set,1);
    else cost := coalesce(pc.cost_usd,0) * mult; end if;
    cur := app.unit_price(pr, unit, r);
    if price <> cur then flag := true; end if;
    insert into invoice_items (invoice_id, line_no, product_id, name, unit, mult, piece, qty, price, line, cost_usd)
      values (iid, ln, pr.id, pr.name, unit, mult, piece, q, price, price * q, cost);
    v_gross := v_gross + price * q;
    perform app.take(s.id, pr.id, q, mult, piece, pr.pieces_per_set);
  end loop;
  v_disc := (round(v_gross * dp / 1000.0) * 10)::bigint; v_total := v_gross - v_disc; v_vat := round(v_total * vr / (100 + vr))::bigint;
  tend := coalesce(app.num(p->>'tendered')::bigint, v_total);
  if tend < v_total then raise exception 'Cash received is less than the total'; end if;
  update invoices set gross = v_gross, disc = v_disc, total = v_total, vat = v_vat, ht = v_total - v_vat, tendered = tend, change = tend - v_total, price_flag = flag
    where id = iid;
  update devices set last_seq = greatest(last_seq, seq) where id = dv.id;
  if oid is not null then
    update sale_orders set status = 'approved', reviewed_by_name = cashier.name, reviewed_at = now(), invoice_id = iid where id = oid;
  end if;
  perform app.log(u, format('Invoice %s for %s, cash, %s%s%s', p->>'no', cust, app.fc(v_total), case when dp > 0 then format(', discount %s%%', dp) else '' end,
    case when oid is not null then ' (order from ' || o.created_by_name || ' approved)' else '' end));
  return jsonb_build_object('status', 'ok', 'no', p->>'no', 'total', v_total, 'price_flag', flag);
end $$;

-- ---------- who may call what ----------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.save_category(jsonb), public.delete_category(uuid), public.delete_product(uuid), public.restore_product(uuid),
  public.item_ranks(uuid), public.record_till_print(uuid), public.submit_invoice(jsonb), public.save_product(jsonb), public.import_products(jsonb, text)
  to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
