-- SIM update 1: sales prepared by the till operator and approved by the shop admin,
-- customer names on invoices, and deliveries that the shop admin receives before stock moves.
-- Safe to run on an installation that already has the first three files.

-- ---------- customer names and orders for review ----------
alter table public.invoices add column if not exists customer text not null default '';
alter table public.invoices add column if not exists prepared_by_name text;
alter table public.invoices add column if not exists order_id uuid;

create table if not exists public.sale_orders (
  id               uuid primary key,                       -- made on the till, so a re-sent order is saved once
  shop_id          uuid not null references public.shops(id),
  customer         text not null check (length(customer) between 1 and 60),
  items            jsonb not null,                          -- [{product_id, mult, piece, qty}], priced when approved
  status           text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_by       uuid not null,
  created_by_name  text not null,
  created_at       timestamptz not null default now(),
  reviewed_by_name text,
  reviewed_at      timestamptz,
  reason           text,
  invoice_id       uuid
);
create index if not exists sale_orders_shop_status on public.sale_orders (shop_id, status, created_at);
alter table public.sale_orders enable row level security;
revoke all on public.sale_orders from anon, authenticated;
grant select on public.sale_orders to authenticated;
drop policy if exists read_orders on public.sale_orders;
-- the shop admin sees the shop's orders; a till operator sees only the orders they sent
create policy read_orders on public.sale_orders for select to authenticated
  using (app.my_role() = 'admin' or (app.my_role() = 'shopadmin' and shop_id = app.my_shop()) or (app.my_role() = 'till' and created_by = auth.uid()));

-- ---------- deliveries wait for the shop admin ----------
alter table public.deliveries add column if not exists status text not null default 'received';
alter table public.deliveries drop constraint if exists deliveries_status_check;
alter table public.deliveries add constraint deliveries_status_check check (status in ('pending','received','cancelled'));
alter table public.deliveries add column if not exists received_at timestamptz;
alter table public.deliveries add column if not exists received_by_name text;
alter table public.deliveries add column if not exists received_note text;
alter table public.delivery_items add column if not exists received_qty int;
update public.delivery_items set received_qty = qty where received_qty is null
  and delivery_id in (select id from public.deliveries where status = 'received');

-- the unit a line is sold in, checked against the item; returns the unit name, or raises
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
  elsif mult = 12 and pr.dozen_usd > 0 and pr.per_carton <> 12 then return 'dzn';
  elsif mult = pr.per_carton then return 'carton';
  end if;
  raise exception 'Unit not valid for %', pr.name;
end $$;

-- store stock not yet promised to a delivery waiting at a shop
create or replace function app.available(p_product uuid, p_except uuid default null) returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select p.wh_qty - coalesce((select sum(i.qty) from delivery_items i join deliveries d on d.id = i.delivery_id
    where d.status = 'pending' and i.product_id = p.id and d.id is distinct from p_except), 0)::int
  from products p where p.id = p_product
$$;

-- ---------- the till operator sends an order for the shop admin to approve ----------
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
  if cust = '' then raise exception 'Enter the customer name'; end if;
  if length(cust) > 60 then raise exception 'Customer name is too long'; end if;
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
  perform app.log(u, format('Order for %s sent for approval, %s items', cust, n));
  return jsonb_build_object('status', 'ok');
end $$;

create or replace function public.reject_order(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); o public.sale_orders;
begin
  select * into o from sale_orders where id = p_id and shop_id = u.shop_id for update;
  if not found then raise exception 'Order not found'; end if;
  if o.status <> 'pending' then raise exception 'This order was already %', o.status; end if;
  if length(btrim(coalesce(p_reason,''))) < 3 then raise exception 'Write a short reason'; end if;
  update sale_orders set status = 'rejected', reviewed_by_name = u.name, reviewed_at = now(), reason = btrim(p_reason) where id = p_id;
  perform app.log(u, format('Order for %s from %s rejected: %s', o.customer, o.created_by_name, btrim(p_reason)));
end $$;

-- ---------- sales: only the shop admin completes them; the customer name is required ----------
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
  -- the shop admin who approved and took the cash; another shop admin of this shop may send it later
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
    if piece then mult := 0; cur := app.to_cdf(pr.piece_usd, r); cost := coalesce(pc.cost_usd,0) / greatest(pr.pieces_per_set,1);
    elsif unit = 'set' or unit = 'pcs' then cur := app.to_cdf(pr.price_usd, r); cost := coalesce(pc.cost_usd,0);
    elsif unit = 'dzn' then cur := app.to_cdf(pr.dozen_usd, r); cost := coalesce(pc.cost_usd,0) * 12;
    else cur := app.to_cdf(pr.carton_usd, r); cost := coalesce(pc.cost_usd,0) * mult;
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
  if oid is not null then
    update sale_orders set status = 'approved', reviewed_by_name = cashier.name, reviewed_at = now(), invoice_id = iid where id = oid;
  end if;
  perform app.log(u, format('Invoice %s for %s, cash, %s%s%s', p->>'no', cust, app.fc(v_total), case when dp > 0 then format(', discount %s%%', dp) else '' end,
    case when oid is not null then ' (order from ' || o.created_by_name || ' approved)' else '' end));
  return jsonb_build_object('status', 'ok', 'no', p->>'no', 'total', v_total, 'price_flag', flag);
end $$;

-- ---------- deliveries: sent now, stock moves when the shop admin receives them ----------
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
  select string_agg(p.name, ', ' order by p.name) into short from products p join app.lines(p_lines) l on l.product_id = p.id where app.available(p.id) < l.qty * k;
  if short is not null then raise exception 'Not enough in the store (counting deliveries not yet received): %', short; end if;
  select rate into r from settings where id = 1;
  foreach sid in array p_shops loop
    dno := 'DEL-' || lpad(nextval('delivery_seq')::text, 4, '0');
    insert into deliveries (no, shop_id, rate, created_by, created_by_name, status) values (dno, sid, r, u.id, u.name, 'pending') returning id into did;
    insert into delivery_items (delivery_id, product_id, qty, price_usd)
      select did, l.product_id, l.qty, p.price_usd from app.lines(p_lines) l join products p on p.id = l.product_id;
    out := out || jsonb_build_object('id', did, 'no', dno, 'shop_id', sid);
    msg := msg || case when msg = '' then '' else ', ' end || dno || ' to ' || (select name from shops where id = sid);
  end loop;
  perform app.log(u, 'Sent ' || msg || ', waiting for the shop to receive');
  return out;
end $$;

-- a delivery can be corrected (items, quantities, outlet) until the shop has received it
create or replace function public.edit_delivery(p_id uuid, p_shop uuid, p_lines jsonb, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin','whop'); d public.deliveries; old_prices jsonb; old_qty int; new_qty int; short text;
begin
  if length(btrim(coalesce(p_reason,''))) < 4 then raise exception 'Write a short reason for the change'; end if;
  select * into d from deliveries where id = p_id for update;
  if not found then raise exception 'Delivery not found'; end if;
  if d.status <> 'pending' then raise exception 'Delivery % was already %; it can no longer be changed', d.no, d.status; end if;
  if not exists (select 1 from shops where id = p_shop and active) then raise exception 'Outlet not found'; end if;
  if not exists (select 1 from app.lines(p_lines)) then raise exception 'Enter a quantity for at least one item'; end if;
  perform 1 from products where id in (select product_id from delivery_items where delivery_id = p_id union select product_id from app.lines(p_lines)) order by id for update;
  select string_agg(p.name, ', ' order by p.name) into short from products p join app.lines(p_lines) l on l.product_id = p.id where app.available(p.id, p_id) < l.qty;
  if short is not null then raise exception 'Not enough in the store (counting deliveries not yet received): %', short; end if;
  select coalesce(jsonb_object_agg(product_id, price_usd), '{}'), coalesce(sum(qty),0) into old_prices, old_qty from delivery_items where delivery_id = p_id;
  delete from delivery_items where delivery_id = p_id;
  insert into delivery_items (delivery_id, product_id, qty, price_usd)
    select p_id, l.product_id, l.qty, coalesce((old_prices->>l.product_id::text)::numeric, p.price_usd) from app.lines(p_lines) l join products p on p.id = l.product_id;
  select sum(qty) into new_qty from delivery_items where delivery_id = p_id;
  update deliveries set shop_id = p_shop, edited_at = now() where id = p_id;
  insert into delivery_edits (delivery_id, by_name, reason, from_shop, from_qty, to_qty) values (p_id, u.name, btrim(p_reason), d.shop_id, old_qty, new_qty);
  perform app.log(u, format('Delivery %s edited by %s%s: %s to %s units, %s', d.no, u.name,
    case when d.shop_id <> p_shop then format(', moved from %s to %s', (select name from shops where id = d.shop_id), (select name from shops where id = p_shop)) else '' end,
    old_qty, new_qty, btrim(p_reason)));
  return jsonb_build_object('negative', 0, 'from_shop', d.shop_id);
end $$;

create or replace function public.cancel_delivery(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin','whop'); d public.deliveries;
begin
  if length(btrim(coalesce(p_reason,''))) < 4 then raise exception 'Write a short reason'; end if;
  select * into d from deliveries where id = p_id for update;
  if not found then raise exception 'Delivery not found'; end if;
  if d.status <> 'pending' then raise exception 'Delivery % was already %', d.no, d.status; end if;
  update deliveries set status = 'cancelled', received_note = btrim(p_reason), edited_at = now() where id = p_id;
  perform app.log(u, format('Delivery %s cancelled: %s', d.no, btrim(p_reason)));
end $$;

-- the shop admin counts what arrived; that quantity leaves the store and enters the shop
create or replace function public.receive_delivery(p_id uuid, p_lines jsonb, p_note text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); d public.deliveries; short text; bad text; sent int; got int; v_note text := btrim(coalesce(p_note,''));
begin
  select * into d from deliveries where id = p_id and shop_id = u.shop_id for update;
  if not found then raise exception 'Delivery not found'; end if;
  if d.status <> 'pending' then raise exception 'Delivery % was already %', d.no, d.status; end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p_lines,'[]')) e where coalesce(e->>'qty','') !~ '^\d{1,7}$') then
    raise exception 'Quantities must be whole numbers';
  end if;
  perform 1 from products where id in (select product_id from delivery_items where delivery_id = p_id) order by id for update;
  -- received quantity per line: what was entered, or the sent quantity if the line was left out
  update delivery_items i set received_qty = coalesce((select (e->>'qty')::int from jsonb_array_elements(p_lines) e where (e->>'product_id')::uuid = i.product_id), i.qty)
    where i.delivery_id = p_id;
  select string_agg(p.name, ', ') into bad from delivery_items i join products p on p.id = i.product_id where i.delivery_id = p_id and i.received_qty > i.qty;
  if bad is not null then raise exception 'You cannot receive more than was sent: %', bad; end if;
  select sum(qty), sum(received_qty) into sent, got from delivery_items where delivery_id = p_id;
  if got < sent and length(v_note) < 4 then raise exception 'Some items arrived short. Write a short note saying what happened'; end if;
  select string_agg(p.name, ', ') into short from delivery_items i join products p on p.id = i.product_id where i.delivery_id = p_id and p.wh_qty < i.received_qty;
  if short is not null then raise exception 'The store no longer has enough of: %. Ask the warehouse to correct the delivery', short; end if;
  update products p set wh_qty = p.wh_qty - i.received_qty, updated_at = now() from delivery_items i where i.delivery_id = p_id and p.id = i.product_id;
  insert into shop_stock (shop_id, product_id, qty) select d.shop_id, i.product_id, i.received_qty from delivery_items i where i.delivery_id = p_id
    on conflict (shop_id, product_id) do update set qty = shop_stock.qty + excluded.qty;
  update deliveries set status = 'received', received_at = now(), received_by_name = u.name, received_note = nullif(v_note, '') where id = p_id;
  perform app.log(u, format('Delivery %s received at %s: %s of %s units%s', d.no, (select name from shops where id = d.shop_id), got, sent,
    case when v_note <> '' then ', ' || v_note else '' end));
  return jsonb_build_object('sent', sent, 'received', got);
end $$;

-- ---------- report: customer on the invoice list ----------
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
    'by_day', (select coalesce(jsonb_agg(bd order by bd.day), '[]') from (select day, count(*) n, sum(q) q, sum(disc) d, sum(total) v from inv group by day) bd),
    'top', (select coalesce(jsonb_agg(x order by x.val desc), '[]') from (
        select ii.name, sum(ii.qty) qty, sum(ii.line) val from invoice_items ii join inv on inv.id = ii.invoice_id group by ii.product_id, ii.name order by 3 desc limit 15) x),
    'by_cashier', (select coalesce(jsonb_agg(c order by c.v desc), '[]') from (select cashier_name as name, sum(total) v from inv group by cashier_name) c),
    'slips', (select coalesce(jsonb_agg(sl order by sl.shop_name), '[]') from (
        select s.id as shop_id, s.name as shop_name, s.code, count(inv.id) n, coalesce(sum(inv.total),0) value_fc, coalesce(sum(inv.total / inv.rate),0) value_usd,
          coalesce(sum(inv.col),0) collected, coalesce(sum(inv.ret),0) returned
        from shops s left join inv on inv.shop_id = s.id
        where (sid is null and s.active) or s.id = sid group by s.id, s.name, s.code) sl),
    'invoices', (select coalesce(jsonb_agg(v order by v.t desc), '[]') from (
        select id, no, t, shop_id, cashier_name, customer, q as items, disc, total, edited from inv order by t desc limit 300) v)
  ) into res;
  return res;
end $$;

-- ---------- who may call what ----------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.submit_order(jsonb), public.reject_order(uuid, text), public.cancel_delivery(uuid, text),
  public.receive_delivery(uuid, jsonb, text), public.submit_invoice(jsonb), public.create_deliveries(uuid[], jsonb),
  public.edit_delivery(uuid, uuid, jsonb, text), public.sales_report(date, date, uuid) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
