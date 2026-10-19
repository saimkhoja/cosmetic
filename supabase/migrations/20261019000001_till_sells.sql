-- SIM: till operators may sell directly, without the shop admin's approval (a third switch in
-- Settings, off by default). Amounts in the activity log are written in CDF instead of FC.
-- Already running SIM? Run this file once, after 20261018000001_supermarket.sql; it keeps your data.

-- money in Francs as written in the activity log and messages
create or replace function app.fc(n bigint) returns text
language sql immutable as $$ select replace(to_char(n, 'FM999,999,999,999,990'), ',', ' ') || ' CDF' $$;

-- ---------- settings: the third switch ----------
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
  foreach k in array array['customer_optional','barcode','till_sells'] loop
    fe := fe || jsonb_build_object(k, coalesce((p->'features'->>k)::boolean, false));
  end loop;
  select rate into old from settings where id = 1 for update;
  update settings set rate = r, vat = v, company = c, features = fe, updated_at = now() where id = 1;
  perform app.log(u, case when old <> r then format('Exchange rate changed %s to %s', old, r) else 'Settings updated' end);
end $$;

-- ---------- sales: the till operator completes a sale when the switch is on ----------
create or replace function public.submit_invoice(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin','till'); iid uuid := (p->>'id')::uuid; ex public.invoices; dv public.devices; s public.shops;
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
  -- a till operator sells only when the Admin turned the switch on, and never approves orders or gives discounts
  if u.role = 'till' then
    if not app.feature('till_sells') then raise exception 'You do not have permission for this action'; end if;
    if oid is not null then raise exception 'Only the shop admin approves orders'; end if;
    if coalesce(app.num(p->>'disc_pct'), 0) <> 0 then raise exception 'Only the shop admin gives a discount'; end if;
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
grant execute on function public.save_settings(jsonb), public.submit_invoice(jsonb) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
