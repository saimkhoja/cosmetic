-- SIM for a supermarket: two switches the Admin turns on in Settings (both off by default, so nothing
-- changes for an installation that does not use them):
--   customer_optional: a sale or an order can be made without the customer name (walk-in customers)
--   barcode:           items carry a barcode; scanning it at the till adds the item
-- Already running SIM? Run this file once; it keeps your data.

alter table public.settings add column if not exists features jsonb not null default '{}'::jsonb;

alter table public.products add column if not exists barcode text check (barcode ~ '^[A-Za-z0-9-]{3,32}$');
create unique index if not exists products_barcode_key on public.products (barcode) where barcode is not null;

-- orders may now be saved without a customer name (only when the switch is on, see app.check_customer)
alter table public.sale_orders drop constraint if exists sale_orders_customer_check;
alter table public.sale_orders add constraint sale_orders_customer_check check (length(customer) <= 60);

create or replace function app.feature(k text) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select (features->>k)::boolean from settings where id = 1), false)
$$;

create or replace function app.check_customer(cust text) returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if coalesce(cust, '') = '' and not app.feature('customer_optional') then raise exception 'Enter the customer name'; end if;
  if length(cust) > 60 then raise exception 'Customer name is too long'; end if;
end $$;

-- a barcode as typed or scanned: blank means none
create or replace function app.barcode_of(v text) returns text
language plpgsql immutable as $$
declare b text := nullif(regexp_replace(coalesce(v, ''), '\s+', '', 'g'), '');
begin
  if b is not null and b !~ '^[A-Za-z0-9-]{3,32}$' then raise exception 'Barcode "%" is not valid (3 to 32 letters or digits)', left(b, 40); end if;
  return b;
end $$;

create or replace function app.set_barcode(pid uuid, v text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare b text := app.barcode_of(v); other text;
begin
  if b is not null then
    select name into other from products where barcode = b and id <> pid;
    if found then raise exception 'Barcode % is already used by %', b, other; end if;
  end if;
  update products set barcode = b where id = pid and barcode is distinct from b;
end $$;

-- ---------- settings: the two switches ----------
create or replace function public.save_settings(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); r numeric := app.num(p->>'rate'); v numeric := app.num(p->>'vat'); old numeric; c jsonb := '{}'; k text;
  fe jsonb := '{}';
begin
  if r is null or r <= 0 then raise exception 'Enter a valid exchange rate'; end if;
  if v is null or v < 0 or v > 30 then raise exception 'VAT must be between 0 and 30'; end if;
  foreach k in array array['name','address','phone','email','rccm','idnat','nif','footer'] loop
    c := c || jsonb_build_object(k, left(btrim(coalesce(p->'company'->>k, '')), 80));
  end loop;
  foreach k in array array['customer_optional','barcode'] loop
    fe := fe || jsonb_build_object(k, coalesce((p->'features'->>k)::boolean, false));
  end loop;
  select rate into old from settings where id = 1 for update;
  update settings set rate = r, vat = v, company = c, features = fe, updated_at = now() where id = 1;
  perform app.log(u, case when old <> r then format('Exchange rate changed %s to %s', old, r) else 'Settings updated' end);
end $$;


-- ---------- items: barcode in the item form and the Excel import ----------
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
    perform app.set_barcode(pid, p->>'barcode');
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
  perform app.set_barcode(pid, p->>'barcode');
  perform app.log(u, 'Updated item ' || nw.name);
  return pid;
end $$;


create or replace function public.import_products(p_rows jsonb, p_file text default '') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); r jsonb; f jsonb; ok jsonb := '[]'; skipped jsonb := '[]'; errs text[] := '{}';
  names text[] := '{}'; skus text[] := '{}'; codes text[] := '{}'; b text; n int := 0; stock int := 0; q int; s text; pid uuid; newcats int := 0; c text;
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
      b := app.barcode_of(r->>'barcode');
      if exists (select 1 from products where active and lower(name) = lower(f->>'name')) or lower(f->>'name') = any(names) then
        skipped := skipped || jsonb_build_object('row', r->>'row', 'name', f->>'name', 'reason', 'Name already exists'); continue;
      end if;
      if s is not null and (exists (select 1 from products where lower(sku) = lower(s)) or lower(s) = any(skus)) then
        skipped := skipped || jsonb_build_object('row', r->>'row', 'name', f->>'name', 'reason', 'Code already exists'); continue;
      end if;
      if b is not null and (exists (select 1 from products where barcode = b) or b = any(codes)) then
        skipped := skipped || jsonb_build_object('row', r->>'row', 'name', f->>'name', 'reason', 'Barcode already exists'); continue;
      end if;
      q := case when (f->>'is_bundle')::boolean then 0 else app.int_or_raise(r->>'open_cartons','Opening cartons') * (f->>'per_carton')::int end
           + app.int_or_raise(r->>'open_pcs','Opening pcs');
      names := names || lower(f->>'name'); if s is not null then skus := skus || lower(s); end if; if b is not null then codes := codes || b; end if;
      ok := ok || jsonb_build_object('f', f, 'sku', s, 'barcode', b, 'qty', q,
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


-- ---------- the customer name is optional when the switch is on ----------
create or replace function public.submit_order(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('till','shopadmin'); oid uuid := (p->>'id')::uuid; ex public.sale_orders; cust text := btrim(coalesce(p->>'customer',''));
  it jsonb; pr public.products; items jsonb := '[]'; q int; n int := 0;
begin
  if oid is null then raise exception 'Order id is missing'; end if;
  select * into ex from sale_orders where id = oid;
  if found then
    if ex.shop_id <> u.shop_id then raise exception 'Order id already used'; end if;
    return jsonb_build_object('status', 'duplicate');
  end if;
  perform app.check_customer(cust);
  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'The order has no items'; end if;
  for it in select * from jsonb_array_elements(p->'items') loop
    select * into pr from products where id = (it->>'product_id')::uuid;
    if not found then raise exception 'Unknown item in the order'; end if;
    q := app.int_or_raise(it->>'qty', 'Quantity'); if q < 1 then raise exception 'Quantity must be 1 or more'; end if;
    perform app.unit_of(pr, coalesce(app.num(it->>'mult'), 1)::int, coalesce((it->>'piece')::boolean, false));
    items := items || jsonb_build_object('product_id', pr.id, 'mult', coalesce(app.num(it->>'mult'), 1)::int, 'piece', coalesce((it->>'piece')::boolean, false), 'qty', q);
    n := n + q;
  end loop;
  insert into sale_orders (id, shop_id, customer, items, created_by, created_by_name, created_at)
    values (oid, u.shop_id, cust, items, u.id, u.name, least(coalesce((p->>'t')::timestamptz, now()), now()));
  perform app.log(u, format('Order for %s sent for approval, %s items', coalesce(nullif(cust, ''), 'walk-in'), n));
  return jsonb_build_object('status', 'ok');
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
  perform app.check_customer(cust);
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
  perform app.log(u, format('Invoice %s for %s, cash, %s%s%s', p->>'no', coalesce(nullif(cust, ''), 'walk-in'), app.fc(v_total), case when dp > 0 then format(', discount %s%%', dp) else '' end,
    case when oid is not null then ' (order from ' || o.created_by_name || ' approved)' else '' end));
  return jsonb_build_object('status', 'ok', 'no', p->>'no', 'total', v_total, 'price_flag', flag);
end $$;


-- ---------- who may call what ----------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.save_settings(jsonb), public.save_product(jsonb), public.import_products(jsonb, text),
  public.submit_order(jsonb), public.submit_invoice(jsonb) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
