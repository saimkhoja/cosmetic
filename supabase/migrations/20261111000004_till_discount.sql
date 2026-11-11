-- QuickSales: a till operator gives a discount on an invoice with a passcode from the Admin.
-- The till has a Discount button, locked. The till operator presses it and types the Discount passcode the Admin
-- gave them (Users, the shield button on the till operator's row); the discount window then opens for that sale: a
-- percentage or an amount in CDF, 30% at most, as for the Shop Admin. One passcode entry covers one invoice.
--   Till operators sell directly: the sale is made with the discount.
--   Orders sent for approval: the invoice prints at the till with the discount and the Shop Admin sees it on the
--     order; approving it as it is completes that invoice, changing the discount prints the corrected invoice.
-- Without the passcode the server refuses a discount from a till operator. Passcodes are 4 to 12 digits, kept only
-- as hashes; 5 wrong tries block one for 10 minutes; discounts given with it are in the activity log.
-- Already running QuickSales? Run this file once, after 20261111000003_shop_passcodes.sql, BEFORE the new app goes live.

-- stop at once if the update before this one was not run
do $$ begin
  if not exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = 'shop_passcodes') then
    raise exception 'Run supabase/migrations/20261111000003_shop_passcodes.sql (and every earlier file) first, then this file. supabase/scripts/check_migrations.sql shows what is missing';
  end if;
end $$;

alter table public.shop_passcodes drop constraint if exists shop_passcodes_kind_check;
alter table public.shop_passcodes add constraint shop_passcodes_kind_check check (kind in ('invoices', 'day_end', 'discount'));
-- the discount on the invoice a till operator printed for an order (CDF)
alter table public.sale_orders add column if not exists disc bigint not null default 0;

-- each right passcode entry lets the till operator discount one invoice (kept while the till is offline)
create table if not exists public.discount_grants (
  token      uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  granted_at timestamptz not null default now(),
  used_for   uuid                                   -- the invoice or order it was used on
);
alter table public.discount_grants enable row level security;
revoke all on public.discount_grants from anon, authenticated;

-- the Admin sets, changes or removes a passcode: Invoices and Shift end report for a Shop Admin, Discount for a till operator
create or replace function public.set_passcode(p_user uuid, p_kind text, p_code text) returns void
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare u public.profiles := app.req('admin'); t public.profiles; c text := btrim(coalesce(p_code, ''));
  what text := case p_kind when 'invoices' then 'Invoices' when 'day_end' then 'Shift end report' when 'discount' then 'Discount' end;
begin
  if what is null then raise exception 'Unknown passcode'; end if;
  select * into t from profiles where id = p_user;
  if p_kind = 'discount' then
    if t.id is null or t.role <> 'till' then raise exception 'The Discount passcode is for Till Operator logins'; end if;
  elsif t.id is null or t.role <> 'shopadmin' then raise exception 'Passcodes are for Shop Admin logins'; end if;
  if c = '' then
    delete from shop_passcodes where user_id = p_user and kind = p_kind;
    if found then perform app.log(u, format('%s passcode removed for %s', what, t.username)); end if;
    return;
  end if;
  if c !~ '^[0-9]{4,12}$' then raise exception 'A passcode is 4 to 12 digits'; end if;
  insert into shop_passcodes (user_id, kind, hash, set_by_name) values (p_user, p_kind, crypt(c, gen_salt('bf')), u.name)
    on conflict (user_id, kind) do update set hash = excluded.hash, set_at = now(), set_by_name = excluded.set_by_name, fails = 0, blocked_until = null, open_until = null;
  perform app.log(u, format('%s passcode set for %s', what, t.username));
end $$;

-- checking a passcode, as before; the activity log names the Discount passcode when it is blocked
create or replace function app.check_passcode(u public.profiles, p_kind text, p_code text) returns text
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare r public.shop_passcodes;
begin
  select * into r from shop_passcodes where user_id = u.id and kind = p_kind for update;
  if not found then return 'No passcode has been set yet. Ask the Admin for one'; end if;
  if r.blocked_until > now() then
    return format('Too many wrong passcodes. Try again in %s minutes, or ask the Admin for a new passcode', greatest(1, ceil(extract(epoch from r.blocked_until - now()) / 60)::int));
  end if;
  if r.hash = crypt(btrim(coalesce(p_code, '')), r.hash) then
    update shop_passcodes set fails = 0, blocked_until = null where user_id = u.id and kind = p_kind;
    return null;
  end if;
  if r.fails + 1 >= 5 then
    update shop_passcodes set fails = 0, blocked_until = now() + interval '10 minutes' where user_id = u.id and kind = p_kind;
    perform app.log(u, format('%s passcode blocked for 10 minutes after 5 wrong tries', case p_kind when 'invoices' then 'Invoices' when 'discount' then 'Discount' else 'Shift end report' end));
    return 'Wrong passcode. Too many wrong tries: blocked for 10 minutes';
  end if;
  update shop_passcodes set fails = r.fails + 1 where user_id = u.id and kind = p_kind;
  return 'Wrong passcode';
end $$;

-- the till operator types the Discount passcode: a right one gives a token for one invoice
create or replace function public.open_discount(p_code text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare u public.profiles := app.req('till'); err text; tok uuid;
begin
  err := app.check_passcode(u, 'discount', p_code);
  if err is not null then return jsonb_build_object('ok', false, 'error', err); end if;
  insert into discount_grants (user_id) values (u.id) returning token into tok;
  return jsonb_build_object('ok', true, 'token', tok);
end $$;

-- a discount from a till operator: the token of their passcode entry, used on this invoice or order only
create or replace function app.use_discount(u public.profiles, p_token text, p_ref uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare g public.discount_grants;
begin
  if p_token ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select * into g from discount_grants where token = p_token::uuid and user_id = u.id for update;
  end if;
  if g.token is null or (g.used_for is not null and g.used_for <> p_ref) then
    raise exception 'A discount needs the Discount passcode from the Admin';
  end if;
  update discount_grants set used_for = p_ref where token = g.token;
end $$;

-- ---------- orders: the invoice printed at the till can carry a discount ----------
create or replace function public.submit_order(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('till','shopadmin'); oid uuid := (p->>'id')::uuid; ex public.sale_orders; cust text := btrim(coalesce(p->>'customer',''));
  it jsonb; pr public.products; items jsonb := '[]'; q int; n int := 0; piece boolean; mult int; price bigint; un text;
  ino text := nullif(btrim(coalesce(p->>'no','')), ''); dv public.devices; s public.shops; r numeric := app.num(p->>'rate'); vr numeric := app.num(p->>'vat_rate'); tot bigint := 0;
  dp numeric := round(coalesce(app.num(p->>'disc_pct'), 0), 2); da bigint := app.num(p->>'disc')::bigint; v_disc bigint := 0;
begin
  if oid is null then raise exception 'Order id is missing'; end if;
  select * into ex from sale_orders where id = oid;
  if found then
    if ex.shop_id <> u.shop_id then raise exception 'Order id already used'; end if;
    return jsonb_build_object('status', 'duplicate');
  end if;
  perform app.check_customer(cust);
  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'The order has no items'; end if;
  if ino is not null then
    select * into dv from devices where id = (p->>'device_id')::uuid and shop_id = u.shop_id for update;
    if not found then raise exception 'This till is not registered for your shop'; end if;
    select * into s from shops where id = u.shop_id;
    if ino !~ ('^' || s.code || '-' || dv.code || '-\d{6}$') then raise exception 'Invoice number does not match this till'; end if;
    if exists (select 1 from invoices where no = ino) or exists (select 1 from sale_orders where invoice_no = ino) then
      raise exception 'Invoice number % is already used', ino;
    end if;
    if r is null or r <= 0 then raise exception 'Exchange rate is missing'; end if;
    if vr is null or vr < 0 or vr > 30 then raise exception 'VAT rate is not valid'; end if;
  end if;
  for it in select * from jsonb_array_elements(p->'items') loop
    select * into pr from products where id = (it->>'product_id')::uuid;
    if not found then raise exception 'Unknown item in the order'; end if;
    q := app.int_or_raise(it->>'qty', 'Quantity'); if q < 1 then raise exception 'Quantity must be 1 or more'; end if;
    piece := coalesce((it->>'piece')::boolean, false); mult := coalesce(app.num(it->>'mult'), 1)::int;
    un := app.unit_named(pr, it->>'unit', mult, piece);
    if piece then mult := 0; end if;
    if ino is not null then
      price := app.num(it->>'price')::bigint;
      if price is null or price <= 0 then raise exception 'Price missing for %', pr.name; end if;
      items := items || jsonb_build_object('product_id', pr.id, 'unit', un, 'mult', mult, 'piece', piece, 'qty', q, 'price', price);
      tot := tot + price * q;
    else
      items := items || jsonb_build_object('product_id', pr.id, 'unit', un, 'mult', mult, 'piece', piece, 'qty', q);
    end if;
    n := n + q;
  end loop;
  -- a discount on the invoice printed at the till: a till operator needs the Discount passcode from the Admin
  if dp <> 0 or coalesce(da, 0) <> 0 then
    if ino is null then raise exception 'A discount needs the invoice printed at the till'; end if;
    if dp < 0 or dp > 30 or da < 0 or da * 100 > tot * 30 then raise exception 'Discount must be between 0%% and 30%%'; end if;
    if da is not null then v_disc := da; dp := case when tot > 0 then round(da * 100.0 / tot, 2) else 0 end;
    else v_disc := (round(tot * dp / 1000.0) * 10)::bigint; end if;
    if v_disc > 0 and u.role = 'till' then perform app.use_discount(u, p->>'discount_token', oid); end if;
  end if;
  insert into sale_orders (id, shop_id, customer, items, created_by, created_by_name, created_at, invoice_no, device_id, rate, vat_rate, total, disc)
    values (oid, u.shop_id, cust, items, u.id, u.name, least(coalesce((p->>'t')::timestamptz, now()), now()),
            ino, dv.id, case when ino is not null then r end, case when ino is not null then vr end, case when ino is not null then tot - v_disc end, v_disc);
  if ino is not null then
    update devices set last_seq = greatest(last_seq, right(ino, 6)::int) where id = dv.id;
    perform app.log(u, format('Invoice %s for %s printed at the till, waiting for approval, %s items, %s%s', ino, coalesce(nullif(cust, ''), 'walk-in'), n, app.fc(tot - v_disc),
      case when v_disc > 0 then format(', discount %s (%s%%) with the passcode', app.fc(v_disc), trim_scale(dp)) else '' end));
  else
    perform app.log(u, format('Order for %s sent for approval, %s items', coalesce(nullif(cust, ''), 'walk-in'), n));
  end if;
  return jsonb_build_object('status', 'ok');
end $$;

-- ---------- sales and approvals: a till operator's discount needs the passcode; an order approved with its discount is not a change ----------
create or replace function public.submit_invoice(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin','till'); iid uuid := (p->>'id')::uuid; ex public.invoices; dv public.devices; s public.shops;
  cashier public.profiles; seq int; r numeric := app.num(p->>'rate'); vr numeric := app.num(p->>'vat_rate'); dp numeric; t timestamptz;
  da bigint := app.num(p->>'disc')::bigint;
  it jsonb; pr public.products; pc public.product_costs; ln int := 0; q int; mult int; piece boolean; price bigint; cur bigint; unit text; cost numeric;
  v_gross bigint := 0; v_disc bigint; v_total bigint; v_vat bigint; tend bigint; flag boolean := false;
  cust text := btrim(coalesce(p->>'customer','')); o public.sale_orders; oid uuid := (p->>'order_id')::uuid;
  pusd numeric := round(coalesce(app.num(p->>'paid_usd'), 0), 2); cusd numeric := coalesce(app.num(p->>'change_usd'), 0); pcdf bigint; ccdf bigint;
  sold text; printed text; revised boolean := false;
begin
  if iid is null then raise exception 'Invoice id is missing'; end if;
  select * into ex from invoices where id = iid;
  if found then
    if ex.shop_id <> u.shop_id then raise exception 'Invoice id already used'; end if;
    return jsonb_build_object('status', 'duplicate', 'no', ex.no);
  end if;
  -- a till operator sells only when the Admin turned the switch on, and never approves orders
  if u.role = 'till' then
    if not app.feature('till_sells') then raise exception 'You do not have permission for this action'; end if;
    if oid is not null then raise exception 'Only the shop admin approves orders'; end if;
    -- a discount from a till operator needs the Discount passcode from the Admin (checked below, once the amount is known)
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
    -- the invoice the till operator printed keeps its number: approving it never makes a second one
    if o.invoice_no is not null and (p->>'no' is distinct from o.invoice_no or dv.id is distinct from o.device_id) then
      raise exception 'This order was printed at the till as invoice %. Approve it with that number', o.invoice_no;
    end if;
  end if;
  select * into cashier from profiles where id = coalesce((p->>'cashier_id')::uuid, u.id) and shop_id = u.shop_id and role = 'shopadmin';
  if cashier.id is null then cashier := u; end if;
  if r is null or r <= 0 then raise exception 'Exchange rate is missing'; end if;
  if vr is null or vr < 0 or vr > 30 then raise exception 'VAT rate is not valid'; end if;
  -- the discount is a percentage, or an amount in CDF ("disc") whose percentage follows from the total
  dp := round(coalesce(app.num(p->>'disc_pct'), 0), 2);
  if dp < 0 or dp > 30 or da < 0 then raise exception 'Discount must be between 0%% and 30%%'; end if;
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
    unit := app.unit_named(pr, it->>'unit', mult, piece);
    if piece then mult := 0; cost := coalesce(pc.cost_usd,0) / greatest(pr.pieces_per_set,1);
    else cost := coalesce(pc.cost_usd,0) * mult; end if;
    cur := app.unit_price(pr, unit, r);
    if price <> cur then flag := true; end if;
    insert into invoice_items (invoice_id, line_no, product_id, name, unit, mult, piece, qty, price, line, cost_usd)
      values (iid, ln, pr.id, pr.name, unit, mult, piece, q, price, price * q, cost);
    v_gross := v_gross + price * q;
    perform app.take(s.id, pr.id, q, mult, piece, pr.pieces_per_set);
  end loop;
  if da is not null then
    if da * 100 > v_gross * 30 then raise exception 'Discount must be between 0%% and 30%%'; end if;
    v_disc := da; dp := case when v_gross > 0 then round(da * 100.0 / v_gross, 2) else 0 end;
  else
    v_disc := (round(v_gross * dp / 1000.0) * 10)::bigint;
  end if;
  if v_disc > 0 and u.role = 'till' then perform app.use_discount(u, p->>'discount_token', iid); end if;
  v_total := v_gross - v_disc; v_vat := round(v_total * vr / (100 + vr))::bigint;
  -- payment: Francs only, or (with "Accept payment in USD" on) dollars and Francs at the sale's rate
  if pusd < 0 or cusd < 0 or coalesce(app.num(p->>'paid_cdf'), 0) < 0 then raise exception 'Amounts received cannot be negative'; end if;
  if cusd <> trunc(cusd) then raise exception 'Dollars given back must be whole dollars'; end if;
  if (pusd > 0 or cusd > 0) and not app.feature('usd_pay') then raise exception 'Payment in USD is not turned on'; end if;
  if pusd > 0 then
    pcdf := coalesce(app.num(p->>'paid_cdf'), 0)::bigint;
    tend := pcdf + round(pusd * r)::bigint;
  else
    tend := coalesce(app.num(p->>'tendered')::bigint, v_total);
    pcdf := tend;
  end if;
  if tend < v_total then raise exception 'Cash received is less than the total'; end if;
  if cusd > pusd then raise exception 'Dollars given back cannot be more than the dollars received'; end if;
  if round(cusd * r) > tend - v_total then raise exception 'Dollars given back are more than the change'; end if;
  ccdf := (tend - v_total) - round(cusd * r)::bigint;
  -- changed at approval: other lines, quantities, units or prices than printed, or another discount
  if o.invoice_no is not null then
    select string_agg(ii.product_id::text || ':' || ii.unit || ':' || ii.mult || ':' || ii.piece || ':' || ii.qty || ':' || ii.price, ','
      order by ii.product_id::text, ii.unit, ii.mult, ii.piece, ii.qty, ii.price)
      into sold from invoice_items ii where ii.invoice_id = iid;
    -- the unit by name (a half carton can be as many pcs as a dozen); orders saved before it was kept get it from mult
    select string_agg(y.pid || ':' || y.un || ':' || y.m || ':' || y.pc || ':' || y.q || ':' || y.pr, ',' order by y.pid, y.un, y.m, y.pc, y.q, y.pr)
      into printed from (select x->>'product_id' pid, coalesce(x->>'unit', app.unit_of(px, (x->>'mult')::int, (x->>'piece')::boolean)) un,
        (x->>'mult')::int m, (x->>'piece')::boolean pc, (x->>'qty')::int q, (x->>'price')::bigint pr
        from jsonb_array_elements(o.items) x join products px on px.id = (x->>'product_id')::uuid) y;
    revised := v_disc is distinct from coalesce(o.disc, 0) or v_total is distinct from o.total or sold is distinct from printed;
  end if;
  update invoices set gross = v_gross, disc_pct = dp, disc = v_disc, total = v_total, vat = v_vat, ht = v_total - v_vat, tendered = tend, change = tend - v_total,
    paid_usd = pusd, paid_cdf = pcdf, change_usd = cusd::int, change_cdf = ccdf, price_flag = flag,
    revised_from = case when revised then o.total end
    where id = iid;
  update devices set last_seq = greatest(last_seq, seq) where id = dv.id;
  if oid is not null then
    update sale_orders set status = 'approved', reviewed_by_name = cashier.name, reviewed_at = now(), invoice_id = iid where id = oid;
  end if;
  perform app.log(u, format('Invoice %s for %s, cash, %s%s%s', p->>'no', coalesce(nullif(cust, ''), 'walk-in'), app.fc(v_total), case when v_disc > 0 then format(', discount %s (%s%%)', app.fc(v_disc), trim_scale(dp)) else '' end,
    case when oid is not null then ' (order from ' || o.created_by_name || ' approved' || case when revised then ', changed from ' || app.fc(o.total) else '' end || ')' else '' end));
  return jsonb_build_object('status', 'ok', 'no', p->>'no', 'total', v_total, 'price_flag', flag, 'revised', revised);
end $$;

-- ---------- who may call what ----------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.set_passcode(uuid, text, text), public.open_discount(text), public.submit_order(jsonb), public.submit_invoice(jsonb) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
