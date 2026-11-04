-- QuickSales: the till operator prints the invoice when sending an order; there is no order slip any more.
-- The order keeps the invoice number, till, rates and prices the till printed. The shop admin's approval
-- turns it into that same invoice (no second number) and only then takes the stock. When the shop admin
-- changes the order first, the invoice is saved as changed and keeps the total the till printed
-- (revised_from); a rejected order's number is void and never becomes an invoice.
-- Already running QuickSales? Run this file once, after 20261026000001_multi_barcodes.sql, BEFORE the new
-- app goes live. It keeps your data; orders sent from tills with the old app still work as before.

-- stop at once if the update before this one was not run (supabase/scripts/check_migrations.sql lists what is missing)
do $$ begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'invoices' and column_name = 'paid_usd')
     or not exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = 'supplier_returns')
     or not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'products' and column_name = 'barcodes') then
    raise exception 'Run supabase/migrations/20261026000001_multi_barcodes.sql (and every earlier file) first, then this file. supabase/scripts/check_migrations.sql shows what is missing';
  end if;
end $$;

alter table public.sale_orders add column if not exists invoice_no text;
alter table public.sale_orders add column if not exists device_id uuid references public.devices(id);
alter table public.sale_orders add column if not exists rate numeric(12,2);
alter table public.sale_orders add column if not exists vat_rate numeric(5,2);
alter table public.sale_orders add column if not exists total bigint;
create unique index if not exists sale_orders_invoice_no on public.sale_orders (invoice_no) where invoice_no is not null;
alter table public.invoices add column if not exists revised_from bigint;

-- ---------- the till operator sends the order with the invoice it printed ----------
-- With "no" and "device_id" the order carries the till's invoice: the number must be this till's and unused,
-- each line has its printed price. Without them it is an order as before (tills with the old app).
create or replace function public.submit_order(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('till','shopadmin'); oid uuid := (p->>'id')::uuid; ex public.sale_orders; cust text := btrim(coalesce(p->>'customer',''));
  it jsonb; pr public.products; items jsonb := '[]'; q int; n int := 0; piece boolean; mult int; price bigint;
  ino text := nullif(btrim(coalesce(p->>'no','')), ''); dv public.devices; s public.shops; r numeric := app.num(p->>'rate'); vr numeric := app.num(p->>'vat_rate'); tot bigint := 0;
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
    perform app.unit_of(pr, mult, piece);
    if piece then mult := 0; end if;
    if ino is not null then
      price := app.num(it->>'price')::bigint;
      if price is null or price <= 0 then raise exception 'Price missing for %', pr.name; end if;
      items := items || jsonb_build_object('product_id', pr.id, 'mult', mult, 'piece', piece, 'qty', q, 'price', price);
      tot := tot + price * q;
    else
      items := items || jsonb_build_object('product_id', pr.id, 'mult', mult, 'piece', piece, 'qty', q);
    end if;
    n := n + q;
  end loop;
  insert into sale_orders (id, shop_id, customer, items, created_by, created_by_name, created_at, invoice_no, device_id, rate, vat_rate, total)
    values (oid, u.shop_id, cust, items, u.id, u.name, least(coalesce((p->>'t')::timestamptz, now()), now()),
            ino, dv.id, case when ino is not null then r end, case when ino is not null then vr end, case when ino is not null then tot end);
  if ino is not null then
    update devices set last_seq = greatest(last_seq, right(ino, 6)::int) where id = dv.id;
    perform app.log(u, format('Invoice %s for %s printed at the till, waiting for approval, %s items, %s', ino, coalesce(nullif(cust, ''), 'walk-in'), n, app.fc(tot)));
  else
    perform app.log(u, format('Order for %s sent for approval, %s items', coalesce(nullif(cust, ''), 'walk-in'), n));
  end if;
  return jsonb_build_object('status', 'ok');
end $$;

-- ---------- approving: the order becomes the invoice the till printed ----------
create or replace function public.submit_invoice(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin','till'); iid uuid := (p->>'id')::uuid; ex public.invoices; dv public.devices; s public.shops;
  cashier public.profiles; seq int; r numeric := app.num(p->>'rate'); vr numeric := app.num(p->>'vat_rate'); dp int; t timestamptz;
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
    -- the invoice the till operator printed keeps its number: approving it never makes a second one
    if o.invoice_no is not null and (p->>'no' is distinct from o.invoice_no or dv.id is distinct from o.device_id) then
      raise exception 'This order was printed at the till as invoice %. Approve it with that number', o.invoice_no;
    end if;
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
  -- changed at approval: other lines, quantities, units or prices than printed, or a discount
  if o.invoice_no is not null then
    select string_agg(ii.product_id::text || ':' || ii.mult || ':' || ii.piece || ':' || ii.qty || ':' || ii.price, ','
      order by ii.product_id::text, ii.mult, ii.piece, ii.qty, ii.price)
      into sold from invoice_items ii where ii.invoice_id = iid;
    select string_agg((x->>'product_id') || ':' || (x->>'mult') || ':' || (x->>'piece') || ':' || (x->>'qty') || ':' || (x->>'price'), ','
      order by (x->>'product_id'), (x->>'mult')::int, (x->>'piece')::boolean, (x->>'qty')::int, (x->>'price')::bigint)
      into printed from jsonb_array_elements(o.items) x;
    revised := dp > 0 or v_total is distinct from o.total or sold is distinct from printed;
  end if;
  update invoices set gross = v_gross, disc = v_disc, total = v_total, vat = v_vat, ht = v_total - v_vat, tendered = tend, change = tend - v_total,
    paid_usd = pusd, paid_cdf = pcdf, change_usd = cusd::int, change_cdf = ccdf, price_flag = flag,
    revised_from = case when revised then o.total end
    where id = iid;
  update devices set last_seq = greatest(last_seq, seq) where id = dv.id;
  if oid is not null then
    update sale_orders set status = 'approved', reviewed_by_name = cashier.name, reviewed_at = now(), invoice_id = iid where id = oid;
  end if;
  perform app.log(u, format('Invoice %s for %s, cash, %s%s%s', p->>'no', coalesce(nullif(cust, ''), 'walk-in'), app.fc(v_total), case when dp > 0 then format(', discount %s%%', dp) else '' end,
    case when oid is not null then ' (order from ' || o.created_by_name || ' approved' || case when revised then ', changed from ' || app.fc(o.total) else '' end || ')' else '' end));
  return jsonb_build_object('status', 'ok', 'no', p->>'no', 'total', v_total, 'price_flag', flag, 'revised', revised);
end $$;

-- ---------- rejecting: the invoice the till printed is void ----------
create or replace function public.reject_order(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); o public.sale_orders;
begin
  select * into o from sale_orders where id = p_id and shop_id = u.shop_id for update;
  if not found then raise exception 'Order not found'; end if;
  if o.status <> 'pending' then raise exception 'This order was already %', o.status; end if;
  if length(btrim(coalesce(p_reason,''))) < 3 then raise exception 'Write a short reason'; end if;
  update sale_orders set status = 'rejected', reviewed_by_name = u.name, reviewed_at = now(), reason = btrim(p_reason) where id = p_id;
  perform app.log(u, format('Order for %s from %s rejected%s: %s', o.customer, o.created_by_name,
    case when o.invoice_no is not null then ', invoice ' || o.invoice_no || ' printed at the till voided' else '' end, btrim(p_reason)));
end $$;
