-- Every change in SIM goes through one of these functions. Each runs in one transaction,
-- checks the caller's role first, and writes the activity log.

-- ---------- helpers ----------
create or replace function app.req(variadic roles public.app_role[]) returns public.profiles
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare u public.profiles;
begin
  select * into u from public.profiles where id = auth.uid() and active;
  if u.id is null or not (u.role = any(roles)) then
    raise exception 'You do not have permission for this action' using errcode = '42501';
  end if;
  return u;
end $$;

create or replace function app.log(u public.profiles, action text) returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into public.audit_log (user_id, username, action) values (u.id, coalesce(u.username, 'system'), action)
$$;

create or replace function app.num(t text) returns numeric
language plpgsql immutable as $$
begin
  if t is null or btrim(t) = '' then return null; end if;
  return btrim(t)::numeric;
exception when others then return null;
end $$;

-- shop price in Francs: USD x rate, rounded to the nearest 10 FC
create or replace function app.to_cdf(usd numeric, r numeric) returns bigint
language sql immutable as $$ select (round(usd * r / 10) * 10)::bigint $$;

create or replace function app.fc(n bigint) returns text
language sql immutable as $$ select replace(to_char(n, 'FM999,999,999,999,990'), ',', ' ') || ' FC' $$;

create or replace function app.usd(n numeric) returns text
language sql immutable as $$ select '$' || to_char(n, 'FM999,999,999,990.00') $$;

-- validated, normalised item fields; raises a readable message on bad input (same rules as the item form)
create or replace function app.product_fields(p jsonb) returns jsonb
language plpgsql immutable as $$
declare
  name text := btrim(regexp_replace(coalesce(p->>'name',''), '\s+', ' ', 'g'));
  category text := btrim(coalesce(p->>'category',''));
  b boolean := coalesce((p->>'is_bundle')::boolean, false);
  cc numeric; per numeric; pc numeric; dz numeric; ctn numeric; cpc numeric;
  sc numeric; sp numeric; pcs numeric; pp numeric;
begin
  if name = '' then raise exception 'Enter the item name'; end if;
  if length(name) > 60 then raise exception 'Item name is too long (60 characters at most)'; end if;
  if category = '' then raise exception 'Enter the category'; end if;
  if length(category) > 30 then raise exception 'Category is too long (30 characters at most)'; end if;
  if b then
    sc := app.num(p->>'set_cost'); sp := app.num(p->>'set_price'); pcs := app.num(p->>'pcs'); pp := app.num(p->>'piece');
    if sc is null or sc < 0 or sp is null or sp <= 0 then raise exception 'Enter the cost and selling price of one set'; end if;
    if sp < sc then raise exception 'Set price cannot be below its cost'; end if;
    if pcs is null or pcs < 2 or pcs <> trunc(pcs) or pp is null or pp <= 0 then
      raise exception 'For a mixed set, enter the pieces per set and the last price for one piece';
    end if;
    return jsonb_build_object('name',name,'category',category,'stock_unit','set','is_bundle',true,
      'per_carton',0,'pieces_per_set',pcs::int,'price_usd',sp,'dozen_usd',0,'carton_usd',0,'piece_usd',pp,
      'carton_cost_usd',0,'cost_usd',sc);
  end if;
  cc := app.num(p->>'carton_cost'); per := app.num(p->>'per_carton'); pc := app.num(p->>'pc');
  dz := coalesce(app.num(p->>'dzn'), 0); ctn := app.num(p->>'ctn');
  if cc is null or cc < 0 then raise exception 'Enter the cost of one carton'; end if;
  if per is null or per < 2 or per <> trunc(per) then raise exception 'Enter how many pcs are in one carton (2 or more)'; end if;
  if pc is null or pc <= 0 then raise exception 'Enter the selling price per pc'; end if;
  if ctn is null or ctn <= 0 then raise exception 'Enter the selling price per carton'; end if;
  if dz < 0 then raise exception 'Price per dozen cannot be negative'; end if;
  cpc := cc / per;
  if per = 12 then dz := 0; end if;
  if pc < cpc - 0.000000001 then raise exception 'Price per pc is below the cost of one pc (%)', app.usd(cpc); end if;
  if dz > 0 and dz < cpc * 12 - 0.000000001 then raise exception 'Price per dozen is below the cost of 12 pcs (%)', app.usd(cpc * 12); end if;
  if ctn < cc then raise exception 'Price per carton cannot be below the carton cost'; end if;
  return jsonb_build_object('name',name,'category',category,'stock_unit','pcs','is_bundle',false,
    'per_carton',per::int,'pieces_per_set',0,'price_usd',pc,'dozen_usd',dz,'carton_usd',ctn,'piece_usd',0,
    'carton_cost_usd',cc,'cost_usd',cpc);
end $$;

create or replace function app.units_text(p public.products) returns text
language sql immutable as $$
  select case when p.is_bundle then 'set ' || app.usd(p.price_usd) || ', piece ' || app.usd(p.piece_usd)
    else 'pcs ' || app.usd(p.price_usd) || case when p.dozen_usd > 0 then ', dzn ' || app.usd(p.dozen_usd) else '' end
         || ', carton ' || app.usd(p.carton_usd) end
$$;

create or replace function app.int_or_raise(t text, what text) returns int
language plpgsql immutable as $$
begin
  if t is null or btrim(t) = '' then return 0; end if;
  if btrim(t) !~ '^\d{1,7}$' then raise exception '% must be a whole number of 0 or more', what; end if;
  return btrim(t)::int;
end $$;

create or replace function app.insert_product(f jsonb, sku text, qty int, reorder int, supplier text, u public.profiles)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare pid uuid; s text := nullif(btrim(coalesce(sku,'')), '');
begin
  if exists (select 1 from products where lower(name) = lower(f->>'name')) then
    raise exception 'An item called "%" already exists', f->>'name';
  end if;
  if s is not null and exists (select 1 from products where lower(products.sku) = lower(s)) then
    raise exception 'The code % is already used', s;
  end if;
  if s is null then
    loop s := 'SK-' || nextval('sku_seq'); exit when not exists (select 1 from products where products.sku = s); end loop;
  end if;
  insert into products (sku, name, category, stock_unit, is_bundle, per_carton, pieces_per_set, price_usd, dozen_usd, carton_usd, piece_usd, reorder, wh_qty)
  values (s, f->>'name', f->>'category', f->>'stock_unit', (f->>'is_bundle')::boolean, (f->>'per_carton')::int, (f->>'pieces_per_set')::int,
    (f->>'price_usd')::numeric, (f->>'dozen_usd')::numeric, (f->>'carton_usd')::numeric, (f->>'piece_usd')::numeric, reorder, qty)
  returning id into pid;
  insert into product_costs values (pid, (f->>'carton_cost_usd')::numeric, (f->>'cost_usd')::numeric);
  insert into shop_stock (shop_id, product_id) select id, pid from shops;
  if qty > 0 then insert into purchases (product_id, qty, supplier, by_id, by_name) values (pid, qty, coalesce(supplier,''), u.id, u.name); end if;
  return pid;
end $$;

create or replace function app.lines(p jsonb) returns table (product_id uuid, qty int)
language plpgsql immutable as $$
begin
  if p is null or jsonb_typeof(p) <> 'array' then raise exception 'Enter a quantity for at least one item'; end if;
  if exists (select 1 from jsonb_array_elements(p) e where coalesce(e->>'qty','') !~ '^\d{1,7}$') then
    raise exception 'Quantities must be whole numbers';
  end if;
  return query select (e->>'product_id')::uuid, sum((e->>'qty')::int)::int
    from jsonb_array_elements(p) e where (e->>'qty')::int > 0 group by 1;
end $$;

-- stock out of a shop for one sold line; pieces of a mixed set open a set when needed
create or replace function app.take(p_shop uuid, p_product uuid, p_qty int, p_mult int, p_piece boolean, p_per int)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare per int := greatest(coalesce(p_per,1),1);
begin
  insert into shop_stock (shop_id, product_id) values (p_shop, p_product) on conflict do nothing;
  if p_piece then
    update shop_stock set qty = qty - (open_pieces + p_qty) / per, open_pieces = (open_pieces + p_qty) % per
     where shop_id = p_shop and product_id = p_product;
  else
    update shop_stock set qty = qty - p_qty * p_mult where shop_id = p_shop and product_id = p_product;
  end if;
end $$;

create or replace function app.give_back(p_shop uuid, p_product uuid, p_qty int, p_mult int, p_piece boolean, p_per int)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare per int := greatest(coalesce(p_per,1),1);
begin
  insert into shop_stock (shop_id, product_id) values (p_shop, p_product) on conflict do nothing;
  if p_piece then
    update shop_stock set
      qty = qty + case when open_pieces - p_qty >= 0 then 0 else ceil((p_qty - open_pieces)::numeric / per)::int end,
      open_pieces = case when open_pieces - p_qty >= 0 then open_pieces - p_qty
                         else open_pieces - p_qty + ceil((p_qty - open_pieces)::numeric / per)::int * per end
     where shop_id = p_shop and product_id = p_product;
  else
    update shop_stock set qty = qty + p_qty * p_mult where shop_id = p_shop and product_id = p_product;
  end if;
end $$;

-- ---------- setup and settings ----------
create or replace function public.setup_needed() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select not exists (select 1 from public.profiles)
$$;

-- called only by the setup Edge Function (service role) right after it created the Admin login
create or replace function public.app_setup(p_user uuid, p_username text, p_name text, p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles; s jsonb;
begin
  if exists (select 1 from profiles) then raise exception 'SIM is already set up'; end if;
  perform pg_advisory_xact_lock(4242);
  if exists (select 1 from profiles) then raise exception 'SIM is already set up'; end if;
  insert into profiles (id, username, name, role, must_change_password) values (p_user, lower(p_username), btrim(p_name), 'admin', false)
  returning * into u;
  update settings set rate = coalesce(app.num(p->>'rate'), rate), vat = coalesce(app.num(p->>'vat'), vat),
    company = coalesce(p->'company', '{}'::jsonb), updated_at = now() where id = 1;
  for s in select * from jsonb_array_elements(coalesce(p->'shops','[]'::jsonb)) loop
    insert into shops (code, name, address) values (upper(btrim(s->>'code')), btrim(s->>'name'), btrim(coalesce(s->>'address','')));
  end loop;
  perform app.log(u, 'SIM set up, Admin account created');
end $$;

create or replace function public.save_settings(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); r numeric := app.num(p->>'rate'); v numeric := app.num(p->>'vat'); old numeric; c jsonb := '{}'; k text;
begin
  if r is null or r <= 0 then raise exception 'Enter a valid exchange rate'; end if;
  if v is null or v < 0 or v > 30 then raise exception 'VAT must be between 0 and 30'; end if;
  foreach k in array array['name','address','phone','email','rccm','idnat','nif','footer'] loop
    c := c || jsonb_build_object(k, left(btrim(coalesce(p->'company'->>k, '')), 80));
  end loop;
  select rate into old from settings where id = 1 for update;
  update settings set rate = r, vat = v, company = c, updated_at = now() where id = 1;
  perform app.log(u, case when old <> r then format('Exchange rate changed %s to %s', old, r) else 'Settings updated' end);
end $$;

create or replace function public.save_shop(p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); sid uuid := (p->>'id')::uuid; c text := upper(btrim(coalesce(p->>'code','')));
  n text := btrim(coalesce(p->>'name','')); a text := btrim(coalesce(p->>'address',''));
begin
  if length(n) < 2 then raise exception 'Enter the shop name'; end if;
  if sid is null then
    if c !~ '^[A-Z]{3}$' then raise exception 'Enter a 3-letter shop code'; end if;
    if exists (select 1 from shops where code = c) then raise exception 'That code is already used'; end if;
    insert into shops (code, name, address) values (c, n, a) returning id into sid;
    insert into shop_stock (shop_id, product_id) select sid, id from products;
    perform app.log(u, 'Added shop ' || n);
  else
    update shops set name = n, address = a, active = coalesce((p->>'active')::boolean, active) where id = sid;
    if not found then raise exception 'Shop not found'; end if;
    perform app.log(u, 'Updated shop ' || n);
  end if;
  return sid;
end $$;

create or replace function public.mark_password_changed() returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin','whop','shopadmin','till');
begin
  update profiles set must_change_password = false where id = u.id;
  perform app.log(u, 'Changed own password');
end $$;

-- ---------- catalogue ----------
create or replace function public.save_product(p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); f jsonb := app.product_fields(p); pid uuid := (p->>'id')::uuid;
  old public.products; nw public.products; v_qty int; v_reorder int := app.int_or_raise(p->>'reorder', 'Reorder level');
begin
  v_qty := case when (f->>'is_bundle')::boolean then 0 else app.int_or_raise(p->>'qty_cartons', 'Cartons') * (f->>'per_carton')::int end
         + app.int_or_raise(p->>'qty_loose', 'Quantity');
  if pid is null then
    pid := app.insert_product(f, p->>'sku', v_qty, v_reorder, p->>'supplier', u);
    perform app.log(u, format('Added item %s%s', f->>'name', case when v_qty > 0 then format(', received %s %s', v_qty, f->>'stock_unit') else '' end));
    return pid;
  end if;
  select * into old from products where id = pid for update;
  if not found then raise exception 'Item not found'; end if;
  if exists (select 1 from products where lower(name) = lower(f->>'name') and id <> pid) then
    raise exception 'An item called "%" already exists', f->>'name';
  end if;
  update products set name = f->>'name', category = f->>'category', stock_unit = f->>'stock_unit', is_bundle = (f->>'is_bundle')::boolean,
    per_carton = (f->>'per_carton')::int, pieces_per_set = (f->>'pieces_per_set')::int, price_usd = (f->>'price_usd')::numeric,
    dozen_usd = (f->>'dozen_usd')::numeric, carton_usd = (f->>'carton_usd')::numeric, piece_usd = (f->>'piece_usd')::numeric,
    reorder = v_reorder, wh_qty = wh_qty + v_qty, updated_at = now()
  where id = pid returning * into nw;
  insert into product_costs values (pid, (f->>'carton_cost_usd')::numeric, (f->>'cost_usd')::numeric)
  on conflict (product_id) do update set carton_cost_usd = excluded.carton_cost_usd, cost_usd = excluded.cost_usd;
  if v_qty > 0 then insert into purchases (product_id, qty, supplier, by_id, by_name) values (pid, v_qty, coalesce(p->>'supplier',''), u.id, u.name); end if;
  if app.units_text(old) <> app.units_text(nw) then
    perform app.log(u, format('Prices changed for %s: %s to %s', nw.name, app.units_text(old), app.units_text(nw)));
  end if;
  perform app.log(u, format('Updated item %s%s', nw.name, case when v_qty > 0 then format(', received %s %s', v_qty, nw.stock_unit) else '' end));
  return pid;
end $$;

create or replace function public.receive_stock(p_product uuid, p_cartons int, p_loose int, p_supplier text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin','whop'); p public.products; q int;
begin
  select * into p from products where id = p_product for update;
  if not found then raise exception 'Item not found'; end if;
  if coalesce(p_cartons,0) < 0 or coalesce(p_loose,0) < 0 then raise exception 'Quantity cannot be negative'; end if;
  q := case when p.is_bundle then 0 else coalesce(p_cartons,0) * p.per_carton end + coalesce(p_loose,0);
  if q < 1 then raise exception 'Enter a quantity of 1 or more'; end if;
  update products set wh_qty = wh_qty + q, updated_at = now() where id = p_product;
  insert into purchases (product_id, qty, supplier, by_id, by_name) values (p_product, q, left(coalesce(p_supplier,''), 60), u.id, u.name);
  perform app.log(u, format('Received %s %s of %s', q, p.stock_unit, p.name));
end $$;

-- new items from an Excel sheet; duplicates are skipped, any invalid row stops the whole import
create or replace function public.import_products(p_rows jsonb, p_file text default '') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); r jsonb; f jsonb; ok jsonb := '[]'; skipped jsonb := '[]'; errs text[] := '{}';
  names text[] := '{}'; skus text[] := '{}'; n int := 0; stock int := 0; q int; s text;
begin
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'There are no rows to import'; end if;
  if jsonb_array_length(p_rows) > 5000 then raise exception 'Import at most 5000 items at a time'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    begin
      f := app.product_fields(r);
      s := nullif(btrim(coalesce(r->>'sku','')), '');
      if exists (select 1 from products where lower(name) = lower(f->>'name')) or lower(f->>'name') = any(names) then
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
    perform app.insert_product(r->'f', r->>'sku', (r->>'qty')::int, (r->>'reorder')::int, 'Excel import', u);
    n := n + 1; stock := stock + (r->>'qty')::int;
  end loop;
  perform app.log(u, format('Imported %s new items from Excel%s%s', n, case when stock > 0 then format(', %s pcs opening stock', stock) else '' end,
    case when coalesce(p_file,'') <> '' then ' (' || left(p_file, 60) || ')' else '' end));
  return jsonb_build_object('imported', n, 'skipped', skipped);
end $$;

-- ---------- deliveries: the store sends stock straight to the shops ----------
create or replace function public.create_deliveries(p_shops uuid[], p_lines jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin','whop'); k int; short text; sid uuid; did uuid; dno text; out jsonb := '[]'; r numeric; msg text := '';
begin
  -- keep the order the outlets were picked in, drop repeats
  select array_agg(x order by o) into p_shops from (select x, min(o) o from unnest(p_shops) with ordinality as u(x, o) group by x) d;
  k := coalesce(array_length(p_shops, 1), 0);
  if k = 0 then raise exception 'Pick at least one outlet'; end if;
  if (select count(*) from shops where id = any(p_shops) and active) <> k then raise exception 'One of the outlets was not found'; end if;
  if not exists (select 1 from app.lines(p_lines)) then raise exception 'Enter a quantity for at least one item'; end if;
  perform 1 from products where id in (select product_id from app.lines(p_lines)) order by id for update;
  if (select count(*) from products where id in (select product_id from app.lines(p_lines))) <> (select count(*) from app.lines(p_lines)) then
    raise exception 'One of the items was not found';
  end if;
  select string_agg(p.name, ', ' order by p.name) into short from products p join app.lines(p_lines) l on l.product_id = p.id where p.wh_qty < l.qty * k;
  if short is not null then raise exception 'Not enough in the store: %', short; end if;
  select rate into r from settings where id = 1;
  foreach sid in array p_shops loop
    dno := 'DEL-' || lpad(nextval('delivery_seq')::text, 4, '0');
    insert into deliveries (no, shop_id, rate, created_by, created_by_name) values (dno, sid, r, u.id, u.name) returning id into did;
    insert into delivery_items (delivery_id, product_id, qty, price_usd)
      select did, l.product_id, l.qty, p.price_usd from app.lines(p_lines) l join products p on p.id = l.product_id;
    update products p set wh_qty = p.wh_qty - l.qty, updated_at = now() from app.lines(p_lines) l where p.id = l.product_id;
    insert into shop_stock (shop_id, product_id, qty) select sid, l.product_id, l.qty from app.lines(p_lines) l
      on conflict (shop_id, product_id) do update set qty = shop_stock.qty + excluded.qty;
    out := out || jsonb_build_object('id', did, 'no', dno, 'shop_id', sid);
    msg := msg || case when msg = '' then '' else ', ' end || dno || ' to ' || (select name from shops where id = sid);
  end loop;
  perform app.log(u, 'Sent ' || msg);
  return out;
end $$;

create or replace function public.edit_delivery(p_id uuid, p_shop uuid, p_lines jsonb, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin','whop'); d public.deliveries; old_prices jsonb; old_qty int; new_qty int; short text; neg int;
begin
  if length(btrim(coalesce(p_reason,''))) < 4 then raise exception 'Write a short reason for the change'; end if;
  select * into d from deliveries where id = p_id for update;
  if not found then raise exception 'Delivery not found'; end if;
  if not exists (select 1 from shops where id = p_shop and active) then raise exception 'Outlet not found'; end if;
  if not exists (select 1 from app.lines(p_lines)) then raise exception 'Enter a quantity for at least one item'; end if;
  perform 1 from products where id in (select product_id from delivery_items where delivery_id = p_id union select product_id from app.lines(p_lines)) order by id for update;
  select coalesce(jsonb_object_agg(product_id, price_usd), '{}'), coalesce(sum(qty),0) into old_prices, old_qty from delivery_items where delivery_id = p_id;
  -- undo the old delivery
  update products p set wh_qty = p.wh_qty + i.qty from delivery_items i where i.delivery_id = p_id and p.id = i.product_id;
  update shop_stock s set qty = s.qty - i.qty from delivery_items i where i.delivery_id = p_id and s.shop_id = d.shop_id and s.product_id = i.product_id;
  select string_agg(p.name, ', ' order by p.name) into short from products p join app.lines(p_lines) l on l.product_id = p.id where p.wh_qty < l.qty;
  if short is not null then raise exception 'Not enough in the store: %', short; end if;
  -- apply the corrected one, keeping the price frozen at the first dispatch
  delete from delivery_items where delivery_id = p_id;
  insert into delivery_items (delivery_id, product_id, qty, price_usd)
    select p_id, l.product_id, l.qty, coalesce((old_prices->>l.product_id::text)::numeric, p.price_usd) from app.lines(p_lines) l join products p on p.id = l.product_id;
  update products p set wh_qty = p.wh_qty - l.qty, updated_at = now() from app.lines(p_lines) l where p.id = l.product_id;
  insert into shop_stock (shop_id, product_id, qty) select p_shop, l.product_id, l.qty from app.lines(p_lines) l
    on conflict (shop_id, product_id) do update set qty = shop_stock.qty + excluded.qty;
  select sum(qty) into new_qty from delivery_items where delivery_id = p_id;
  update deliveries set shop_id = p_shop, edited_at = now() where id = p_id;
  insert into delivery_edits (delivery_id, by_name, reason, from_shop, from_qty, to_qty) values (p_id, u.name, btrim(p_reason), d.shop_id, old_qty, new_qty);
  select count(*) into neg from shop_stock where shop_id = d.shop_id and qty < 0 and old_prices ? product_id::text;
  perform app.log(u, format('Delivery %s edited by %s%s: %s to %s units, %s', d.no, u.name,
    case when d.shop_id <> p_shop then format(', moved from %s to %s', (select name from shops where id = d.shop_id), (select name from shops where id = p_shop)) else '' end,
    old_qty, new_qty, btrim(p_reason)));
  return jsonb_build_object('negative', neg, 'from_shop', d.shop_id);
end $$;

-- ---------- tills and sales ----------
create or replace function public.register_device(p_device uuid default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('till','shopadmin'); dv public.devices; s public.shops; n int;
begin
  select * into s from shops where id = u.shop_id;
  if p_device is not null then
    select * into dv from devices where id = p_device and shop_id = u.shop_id;
  end if;
  if dv.id is null then
    perform 1 from shops where id = u.shop_id for update;
    select coalesce(max(substring(code from 2)::int), 0) + 1 into n from devices where shop_id = u.shop_id;
    insert into devices (shop_id, code, registered_by) values (u.shop_id, 'T' || n, u.name) returning * into dv;
    perform app.log(u, format('Till %s registered for %s', dv.code, s.name));
  end if;
  return jsonb_build_object('id', dv.id, 'code', dv.code, 'last_seq', dv.last_seq, 'shop_code', s.code);
end $$;

-- a sale from a till, sent once online (possibly long after it was printed offline)
create or replace function public.submit_invoice(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('till','shopadmin'); iid uuid := (p->>'id')::uuid; ex public.invoices; dv public.devices; s public.shops;
  cashier public.profiles; seq int; r numeric := app.num(p->>'rate'); vr numeric := app.num(p->>'vat_rate'); dp int; t timestamptz;
  it jsonb; pr public.products; pc public.product_costs; ln int := 0; q int; mult int; piece boolean; price bigint; cur bigint; unit text; cost numeric;
  v_gross bigint := 0; v_disc bigint; v_total bigint; v_vat bigint; tend bigint; flag boolean := false;
begin
  if iid is null then raise exception 'Invoice id is missing'; end if;
  select * into ex from invoices where id = iid;
  if found then
    if ex.shop_id <> u.shop_id then raise exception 'Invoice id already used'; end if;
    return jsonb_build_object('status', 'duplicate', 'no', ex.no);
  end if;
  select * into dv from devices where id = (p->>'device_id')::uuid and shop_id = u.shop_id for update;
  if not found then raise exception 'This till is not registered for your shop'; end if;
  select * into s from shops where id = u.shop_id;
  if coalesce(p->>'no','') !~ ('^' || s.code || '-' || dv.code || '-\d{6}$') then raise exception 'Invoice number does not match this till'; end if;
  seq := right(p->>'no', 6)::int;
  -- the cashier who made the sale, if another user of this shop is sending it later
  select * into cashier from profiles where id = coalesce((p->>'cashier_id')::uuid, u.id) and shop_id = u.shop_id and role in ('till','shopadmin');
  if cashier.id is null then cashier := u; end if;
  if r is null or r <= 0 then raise exception 'Exchange rate is missing'; end if;
  if vr is null or vr < 0 or vr > 30 then raise exception 'VAT rate is not valid'; end if;
  dp := coalesce(app.num(p->>'disc_pct'), 0)::int;
  if dp < 0 or dp > 30 then raise exception 'Discount must be between 0%% and 30%%'; end if;
  if dp > 0 and cashier.role <> 'shopadmin' then raise exception 'Only the shop admin can give a discount'; end if;
  t := coalesce((p->>'t')::timestamptz, now());
  if t > now() + interval '10 minutes' then t := now(); end if;
  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'The sale has no items'; end if;
  insert into invoices (id, no, shop_id, device_id, cashier_id, cashier_name, t, rate, vat_rate, gross, disc_pct, disc, total, vat, ht, tendered)
    values (iid, p->>'no', s.id, dv.id, cashier.id, cashier.name, t, r, vr, 0, dp, 0, 0, 0, 0, 0);
  for it in select * from jsonb_array_elements(p->'items') loop
    ln := ln + 1;
    select * into pr from products where id = (it->>'product_id')::uuid;
    if not found then raise exception 'Unknown item on line %', ln; end if;
    select * into pc from product_costs where product_id = pr.id;
    q := app.int_or_raise(it->>'qty', 'Quantity'); if q < 1 then raise exception 'Quantity must be 1 or more'; end if;
    price := app.num(it->>'price')::bigint; if price is null or price <= 0 then raise exception 'Price missing on line %', ln; end if;
    piece := coalesce((it->>'piece')::boolean, false); mult := coalesce(app.num(it->>'mult'), 1)::int;
    if piece then
      if not pr.is_bundle then raise exception '% is not sold by piece', pr.name; end if;
      unit := 'piece'; mult := 0; cur := app.to_cdf(pr.piece_usd, r); cost := coalesce(pc.cost_usd,0) / greatest(pr.pieces_per_set,1);
    elsif pr.is_bundle then
      unit := 'set'; mult := 1; cur := app.to_cdf(pr.price_usd, r); cost := coalesce(pc.cost_usd,0);
    elsif mult = 1 then unit := 'pcs'; cur := app.to_cdf(pr.price_usd, r); cost := coalesce(pc.cost_usd,0);
    elsif mult = 12 and pr.dozen_usd > 0 and pr.per_carton <> 12 then unit := 'dzn'; cur := app.to_cdf(pr.dozen_usd, r); cost := coalesce(pc.cost_usd,0) * 12;
    elsif mult = pr.per_carton then unit := 'carton'; cur := app.to_cdf(pr.carton_usd, r); cost := coalesce(pc.cost_usd,0) * mult;
    else raise exception 'Unit not valid for %', pr.name;
    end if;
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
  perform app.log(u, format('Invoice %s, cash, %s%s%s', p->>'no', app.fc(v_total), case when dp > 0 then format(', discount %s%%', dp) else '' end,
    case when cashier.id <> u.id then ' (sold by ' || cashier.name || ')' else '' end));
  return jsonb_build_object('status', 'ok', 'no', p->>'no', 'total', v_total, 'price_flag', flag);
end $$;

-- the shop admin corrects a confirmed sale; stock is put right and the change is logged
create or replace function public.edit_invoice(p_id uuid, p_lines jsonb, p_disc int, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); inv public.invoices; it record; v_gross bigint; v_disc bigint; v_total bigint; v_vat bigint;
begin
  select * into inv from invoices where id = p_id and shop_id = u.shop_id for update;
  if not found then raise exception 'Invoice not found'; end if;
  if length(btrim(coalesce(p_reason,''))) < 4 then raise exception 'Write a short reason for the change'; end if;
  if coalesce(p_disc,0) < 0 or coalesce(p_disc,0) > 30 then raise exception 'Discount must be between 0%% and 30%%'; end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p_lines,'[]')) e where coalesce(e->>'qty','') !~ '^\d{1,7}$') then
    raise exception 'Quantities must be whole numbers';
  end if;
  for it in select i.*, pr.pieces_per_set from invoice_items i join products pr on pr.id = i.product_id where i.invoice_id = p_id loop
    perform app.give_back(inv.shop_id, it.product_id, it.qty, it.mult, it.piece, it.pieces_per_set);
  end loop;
  update invoice_items i set qty = (e->>'qty')::int, line = i.price * (e->>'qty')::int
    from jsonb_array_elements(p_lines) e where i.invoice_id = p_id and i.line_no = (e->>'line_no')::int and (e->>'qty')::int > 0;
  delete from invoice_items i where i.invoice_id = p_id and not exists
    (select 1 from jsonb_array_elements(p_lines) e where (e->>'line_no')::int = i.line_no and (e->>'qty')::int > 0);
  if not exists (select 1 from invoice_items where invoice_id = p_id) then raise exception 'Keep at least one line on the invoice'; end if;
  for it in select i.*, pr.pieces_per_set from invoice_items i join products pr on pr.id = i.product_id where i.invoice_id = p_id loop
    perform app.take(inv.shop_id, it.product_id, it.qty, it.mult, it.piece, it.pieces_per_set);
  end loop;
  select sum(line) into v_gross from invoice_items where invoice_id = p_id;
  v_disc := (round(v_gross * coalesce(p_disc,0) / 1000.0) * 10)::bigint; v_total := v_gross - v_disc; v_vat := round(v_total * inv.vat_rate / (100 + inv.vat_rate))::bigint;
  update invoices set gross = v_gross, disc_pct = coalesce(p_disc,0), disc = v_disc, total = v_total,
    vat = v_vat, ht = v_total - v_vat, tendered = v_total, change = 0 where id = p_id;
  insert into invoice_edits (invoice_id, by_id, by_name, reason, from_total, to_total) values (p_id, u.id, u.name, btrim(p_reason), inv.total, v_total);
  perform app.log(u, format('Invoice %s edited by %s: %s to %s, %s', inv.no, u.name, app.fc(inv.total), app.fc(v_total), btrim(p_reason)));
  return jsonb_build_object('from_total', inv.total, 'to_total', v_total);
end $$;

create or replace function public.record_reprint(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); n text;
begin
  update invoices set printed = printed + 1 where id = p_id and shop_id = u.shop_id returning no into n;
  if n is null then raise exception 'Invoice not found'; end if;
  perform app.log(u, 'Duplicate printed for ' || n);
end $$;

-- ---------- upkeep ----------
create or replace function public.add_upkeep(p_date date, p_category text, p_desc text, p_amount numeric) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin');
begin
  if p_date is null or p_date > current_date + 1 then raise exception 'Choose a date'; end if;
  if length(btrim(coalesce(p_desc,''))) = 0 then raise exception 'Describe the expense'; end if;
  if coalesce(p_amount,0) <= 0 then raise exception 'Enter an amount above zero'; end if;
  insert into upkeep (date, category, description, amount_usd, by_name) values (p_date, left(btrim(p_category),40), left(btrim(p_desc),80), p_amount, u.name);
  perform app.log(u, format('Expense %s: %s', btrim(p_category), app.usd(p_amount)));
end $$;

-- ---------- reports ----------
create or replace function public.sales_report(p_from date, p_to date, p_shop uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin','shopadmin'); sid uuid; tz text; res jsonb;
begin
  if p_from is null or p_to is null then raise exception 'Choose the dates'; end if;
  if p_from > p_to then select p_to, p_from into p_from, p_to; end if;
  sid := case when u.role = 'shopadmin' then u.shop_id else p_shop end;
  select settings.tz into tz from settings where id = 1;
  with inv as (
    select i.*, (i.t at time zone tz)::date as day,
      (select coalesce(sum(qty),0) from invoice_items where invoice_id = i.id) as q,
      (select coalesce(sum(cost_usd * qty),0) from invoice_items where invoice_id = i.id) as cogs,
      coalesce((select e.from_total from invoice_edits e where e.invoice_id = i.id order by e.at, e.id limit 1), i.total)
        + (select coalesce(sum(greatest(0, to_total - from_total)),0) from invoice_edits where invoice_id = i.id) as col,
      (select coalesce(sum(greatest(0, from_total - to_total)),0) from invoice_edits where invoice_id = i.id) as ret,
      exists (select 1 from invoice_edits where invoice_id = i.id) as edited
    from invoices i
    where (sid is null or i.shop_id = sid) and (i.t at time zone tz)::date between p_from and p_to
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'shop_id', sid,
    'n', (select count(*) from inv),
    'total', (select coalesce(sum(total),0) from inv),
    'total_usd', (select coalesce(sum(total / rate),0) from inv),
    'disc', (select coalesce(sum(disc),0) from inv),
    'vat', (select coalesce(sum(vat),0) from inv),
    'items', (select coalesce(sum(q),0) from inv),
    'edited', (select count(*) from inv where edited),
    'profit_usd', case when u.role = 'admin' then (select coalesce(sum(ht / rate - cogs),0) from inv) end,
    'by_day', (select coalesce(jsonb_agg(d order by d.day), '[]') from (select day, count(*) n, sum(q) q, sum(disc) d, sum(total) v from inv group by day) d),
    'top', (select coalesce(jsonb_agg(x order by x.val desc), '[]') from (
        select ii.name, sum(ii.qty) qty, sum(ii.line) val from invoice_items ii join inv on inv.id = ii.invoice_id group by ii.product_id, ii.name order by 3 desc limit 15) x),
    'by_cashier', (select coalesce(jsonb_agg(c order by c.v desc), '[]') from (select cashier_name as name, sum(total) v from inv group by cashier_name) c),
    'slips', (select coalesce(jsonb_agg(sl order by sl.shop_name), '[]') from (
        select s.id as shop_id, s.name as shop_name, s.code, count(inv.id) n, coalesce(sum(inv.total),0) value_fc, coalesce(sum(inv.total / inv.rate),0) value_usd,
          coalesce(sum(inv.col),0) collected, coalesce(sum(inv.ret),0) returned
        from shops s left join inv on inv.shop_id = s.id
        where (sid is null and s.active) or s.id = sid group by s.id, s.name, s.code) sl),
    'invoices', (select coalesce(jsonb_agg(v order by v.t desc), '[]') from (
        select id, no, t, shop_id, cashier_name, q as items, disc, total, edited from inv order by t desc limit 300) v)
  ) into res;
  return res;
end $$;

-- ---------- who may call what ----------
revoke execute on all functions in schema public from public, anon, authenticated;
revoke execute on all functions in schema app from public, anon, authenticated;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.app_setup(uuid, text, text, jsonb) to service_role;
grant execute on function public.save_settings(jsonb), public.save_shop(jsonb), public.mark_password_changed(),
  public.save_product(jsonb), public.receive_stock(uuid, int, int, text), public.import_products(jsonb, text),
  public.create_deliveries(uuid[], jsonb), public.edit_delivery(uuid, uuid, jsonb, text),
  public.register_device(uuid), public.submit_invoice(jsonb), public.edit_invoice(uuid, jsonb, int, text),
  public.record_reprint(uuid), public.add_upkeep(date, text, text, numeric), public.sales_report(date, date, uuid)
  to authenticated;
grant execute on function app.me(), app.my_role(), app.my_shop() to authenticated, service_role;
