-- QuickSales: dollars taken at the till are worth the INTERNAL rate (taux interne), not the sales rate.
-- Why: a shop prices its goods at the sales rate (say 2 350) but gives less for a dollar over the counter (say
-- 2 300). Before this file the till counted a dollar at the sales rate, so a 23 500 CDF bill was fully paid by
-- 10 dollars and the 500 CDF the customer also handed over was never asked for, never recorded, and never showed
-- on the shift end report. The cashier could keep it.
-- Now the till values the dollars at the internal rate, so it asks for the 500 CDF, prints it on the invoice and
-- shows it on the shift end report as Francs collected. Each invoice keeps the dollar rate of its moment
-- (invoices.usd_rate), so a sale made offline and a past sale never change.
-- The cash taken is then worth a little more than the sale: that difference is what the shop earns on the
-- exchange and it is booked to "Exchange gain on dollars", so the books balance and the owner can see it.
-- Set the internal rate in Settings. While it equals the sales rate nothing changes.
-- Already running QuickSales? Run this file once, after 20261111000007_no_warehouse.sql, BEFORE the new app goes live.

-- stop at once if the update before this one was not run
do $$ begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'grns' and column_name = 'shop_id') then
    raise exception 'Run supabase/migrations/20261111000007_no_warehouse.sql (and every earlier file) first, then this file. supabase/scripts/check_migrations.sql shows what is missing';
  end if;
end $$;

-- the rate the dollars on this invoice were taken at; empty on sales made before this update (they used the sales rate)
alter table public.invoices add column if not exists usd_rate numeric(12,2);
alter table public.invoices drop constraint if exists invoices_usd_rate_check;
alter table public.invoices add constraint invoices_usd_rate_check check (usd_rate is null or usd_rate > 0);

-- what the shop earns (or loses) by taking a dollar for less than the sales rate
insert into public.accounts (code, name, group_code, currency, system) values
  ('FX_GAIN','Exchange gain on dollars','indinc','USD',true)
on conflict (code) do nothing;

-- ---------- the sale: dollars valued at the internal rate ----------
create or replace function public.submit_invoice(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin','till'); iid uuid := (p->>'id')::uuid; ex public.invoices; dv public.devices; s public.shops;
  cashier public.profiles; seq int; r numeric := app.num(p->>'rate'); vr numeric := app.num(p->>'vat_rate'); dp numeric; t timestamptz;
  da bigint := app.num(p->>'disc')::bigint;
  it jsonb; pr public.products; pc public.product_costs; ln int := 0; q int; mult int; piece boolean; price bigint; cur bigint; unit text; cost numeric;
  v_gross bigint := 0; v_disc bigint; v_total bigint; v_vat bigint; tend bigint; flag boolean := false;
  cust text := btrim(coalesce(p->>'customer','')); o public.sale_orders; oid uuid := (p->>'order_id')::uuid;
  pusd numeric := round(coalesce(app.num(p->>'paid_usd'), 0), 2); cusd numeric := coalesce(app.num(p->>'change_usd'), 0); pcdf bigint; ccdf bigint; ur numeric;
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
  -- dollars are worth the INTERNAL rate here, not the sales rate: what the shop gives for a dollar over the counter.
  -- The till sends the rate it used, so a sale made offline keeps the rate of its moment.
  ur := coalesce(app.num(p->>'usd_rate'), (select book_rate from settings where id = 1), r);
  if ur is null or ur <= 0 then raise exception 'Exchange rate for dollars is missing'; end if;
  if pusd > 0 then
    pcdf := coalesce(app.num(p->>'paid_cdf'), 0)::bigint;
    tend := pcdf + round(pusd * ur)::bigint;
  else
    tend := coalesce(app.num(p->>'tendered')::bigint, v_total);
    pcdf := tend;
  end if;
  if tend < v_total then raise exception 'Cash received is less than the total'; end if;
  if cusd > pusd then raise exception 'Dollars given back cannot be more than the dollars received'; end if;
  if round(cusd * ur) > tend - v_total then raise exception 'Dollars given back are more than the change'; end if;
  ccdf := (tend - v_total) - round(cusd * ur)::bigint;
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
    paid_usd = pusd, paid_cdf = pcdf, change_usd = cusd::int, change_cdf = ccdf, usd_rate = ur, price_flag = flag,
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

-- ---------- the books: the cash in the drawer, and the exchange gain ----------
create or replace function app.post_invoice(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare i public.invoices; cost numeric; tz text; nusd numeric; ur numeric; fc bigint; cash jsonb; diff numeric := 0;
begin
  select * into i from invoices where id = p_id;
  if i.id is null or i.total <= 0 then return; end if;
  select settings.tz into tz from settings where id = 1;
  select coalesce(sum(cost_usd * qty), 0) into cost from invoice_items where invoice_id = p_id;
  -- the dollars kept, and the rate they were taken at (sales made before this update used the sales rate)
  ur := coalesce(i.usd_rate, i.rate);
  nusd := coalesce(i.paid_usd, 0) - coalesce(i.change_usd, 0);
  if coalesce(i.paid_usd, 0) = 0 then
    cash := jsonb_build_array(jsonb_build_object('account', app.shop_acc('CASH_SHOP', i.shop_id), 'side', 'Dr', 'amount', i.total, 'currency', 'FC', 'rate', i.rate));
  else
    -- the Francs that went with the dollars: the sale less what the dollars were taken for
    fc := i.total - round(nusd * ur)::bigint;
    cash := jsonb_build_array(
      jsonb_build_object('account', app.shop_acc('CASH_SHOP_USD', i.shop_id), 'side', case when nusd >= 0 then 'Dr' else 'Cr' end, 'amount', abs(nusd), 'currency', 'USD', 'memo', 'Paid in USD'),
      jsonb_build_object('account', app.shop_acc('CASH_SHOP', i.shop_id), 'side', case when fc >= 0 then 'Dr' else 'Cr' end, 'amount', abs(fc), 'currency', 'FC', 'rate', i.rate));
    -- a dollar taken in for less than the sales rate leaves the shop better off by the difference: that is the
    -- exchange gain, and booking it keeps the sale, the drawer and the books all right
    diff := round(nusd * (i.rate - ur) / i.rate, 2);
    if abs(diff) >= 0.005 then
      cash := cash || jsonb_build_array(jsonb_build_object('code', 'FX_GAIN', 'side', case when diff > 0 then 'Cr' else 'Dr' end,
        'amount', abs(diff), 'currency', 'USD', 'memo', 'Exchange on dollars'));
    end if;
  end if;
  perform app.post('sales', (i.t at time zone tz)::date, 'Invoice ' || i.no || coalesce(', ' || nullif(i.customer, ''), ''), i.no, 'invoice', i.id,
    cash || jsonb_build_array(
      jsonb_build_object('account', app.shop_acc('SALES_SHOP', i.shop_id), 'side', 'Cr', 'amount', i.ht, 'currency', 'FC', 'rate', i.rate),
      jsonb_build_object('code', 'VAT_OUT', 'side', 'Cr', 'amount', i.vat, 'currency', 'FC', 'rate', i.rate),
      jsonb_build_object('code', 'COGS', 'side', 'Dr', 'amount', round(cost, 2), 'currency', 'USD', 'memo', 'Cost of goods sold'),
      jsonb_build_object('account', app.shop_acc('INV_SHOP', i.shop_id), 'side', 'Cr', 'amount', round(cost, 2), 'currency', 'USD', 'memo', 'Cost of goods sold')),
    i.cashier_name);
end $$;

-- ---------- the reports: Francs collected, with the dollars at their own rate ----------
create or replace function public.sales_report(p_from date, p_to date, p_shop uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin','shopadmin'); sid uuid; tz text; lim numeric; res jsonb;
begin
  if p_from is null or p_to is null then raise exception 'Choose the dates'; end if;
  if p_from > p_to then select p_to, p_from into p_from, p_to; end if;
  sid := case when u.role = 'shopadmin' then u.shop_id else p_shop end;
  -- the Shop Admin's report leaves out the sales above the limit; the Admin's report has every sale
  select settings.tz, case when u.role = 'shopadmin' then settings.shop_sales_limit_usd end into tz, lim from settings where id = 1;
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
      and (lim is null or i.total / nullif(i.rate, 0) <= lim)
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
    -- gross profit: the margin of each invoice (sales, VAT included, less the cost of the goods) less the VAT rate on that margin
    'profit_usd', case when u.role = 'admin' then (select coalesce(sum((total / rate - cogs) * (1 - vat_rate / 100)),0) from inv) end,
    'by_day', (select coalesce(jsonb_agg(bd order by bd.day), '[]') from (select day, count(*) n, sum(q) q, sum(disc) d, sum(total) v from inv group by day) bd),
    'top', (select coalesce(jsonb_agg(x order by x.val desc), '[]') from (
        select ii.name, sum(ii.qty) qty, sum(ii.line) val from invoice_items ii join inv on inv.id = ii.invoice_id group by ii.product_id, ii.name order by 3 desc limit 15) x),
    -- sales by category (the item's category now), each with its items: the amount after the invoice's discount,
    -- the pcs sold (pieces of a mixed set apart) and how many of each unit
    'by_category', (select coalesce(jsonb_agg(jsonb_build_object('category', bc.cat, 'val', bc.val, 'pcs', bc.pcs, 'items', bc.items) order by bc.val desc, bc.cat), '[]') from (
        select bi.cat, sum(bi.val)::bigint val, sum(bi.pcs)::bigint pcs,
          jsonb_agg(jsonb_build_object('product_id', bi.product_id, 'name', bi.name, 'val', bi.val, 'pcs', bi.pcs, 'pieces', bi.pieces, 'units', bi.units)
            order by bi.val desc, bi.name) items
        from (
          select bu.cat, bu.product_id, min(bu.name) name, sum(bu.val)::bigint val, sum(bu.pcs)::bigint pcs, sum(bu.pieces)::bigint pieces,
            jsonb_object_agg(bu.unit, bu.qty) units
          from (
            select coalesce(nullif(btrim(p.category), ''), 'No category') cat, ii.product_id, min(ii.name) name, ii.unit, sum(ii.qty) qty,
              coalesce(round(sum(ii.line * inv.total::numeric / nullif(inv.gross, 0))), 0) val,
              sum(case when ii.piece then 0 else ii.qty * ii.mult end) pcs, sum(case when ii.piece then ii.qty else 0 end) pieces
            from invoice_items ii join inv on inv.id = ii.invoice_id join products p on p.id = ii.product_id
            group by 1, 2, 4) bu
          group by bu.cat, bu.product_id) bi
        group by bi.cat) bc),
    'by_cashier', (select coalesce(jsonb_agg(c order by c.v desc), '[]') from (select cashier_name as name, sum(total) v from inv group by cashier_name) c),
    'slips', (select coalesce(jsonb_agg(sl order by sl.shop_name), '[]') from (
        select s.id as shop_id, s.name as shop_name, s.code, count(inv.id) n, coalesce(sum(inv.total),0) value_fc, coalesce(sum(inv.total / inv.rate),0) value_usd,
          coalesce(sum(inv.col),0) collected, coalesce(sum(inv.ret),0) returned,
          coalesce(sum(inv.paid_usd - inv.change_usd),0) collected_usd,
          coalesce(sum(inv.col - round((inv.paid_usd - inv.change_usd) * coalesce(inv.usd_rate, inv.rate))),0)::bigint collected_cdf
        from shops s left join inv on inv.shop_id = s.id
        where (sid is null and s.active) or s.id = sid group by s.id, s.name, s.code) sl),
    'invoices', (select coalesce(jsonb_agg(v order by v.t desc), '[]') from (
        select id, no, t, shop_id, cashier_name, customer, q as items, disc, total, edited from inv order by t desc limit 300) v)
  ) into res;
  return res;
end $$;

create or replace function app.shift_slip(p_shop uuid, p_device uuid, p_from timestamptz, p_to timestamptz) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  with inv as (
    select i.*, coalesce((select e.from_total from invoice_edits e where e.invoice_id = i.id order by e.at, e.id limit 1), i.total) as first_total
    from invoices i
    where i.shop_id = p_shop and (p_device is null or i.device_id = p_device) and i.received_at > p_from and i.received_at <= p_to
  ), ed as (
    select e.from_total, e.to_total from invoice_edits e join invoices i on i.id = e.invoice_id
    where i.shop_id = p_shop and (p_device is null or i.device_id = p_device) and e.at > p_from and e.at <= p_to
  ), x as (
    select (select count(*) from inv) n,
      (select coalesce(sum(total), 0) from inv) value_fc,
      (select coalesce(sum(total / rate), 0) from inv) value_usd,
      (select coalesce(sum(first_total), 0) from inv) + (select coalesce(sum(greatest(0, to_total - from_total)), 0) from ed) collected,
      (select coalesce(sum(greatest(0, from_total - to_total)), 0) from ed) returned,
      (select coalesce(sum(paid_usd - change_usd), 0) from inv) collected_usd,
      (select coalesce(sum(round((paid_usd - change_usd) * coalesce(usd_rate, rate))), 0) from inv) usd_in_cdf
  )
  select jsonb_build_object('shop_id', s.id, 'shop_name', s.name, 'code', s.code, 'n', x.n, 'value_fc', x.value_fc, 'value_usd', x.value_usd,
    'collected', x.collected, 'returned', x.returned, 'collected_usd', x.collected_usd, 'collected_cdf', (x.collected - x.usd_in_cdf)::bigint)
  from shops s, x where s.id = p_shop
$$;

-- the Shop Admin's shift end report, for the Shift end report passcode
--   p_action 'close':   today's shift since the last one printed for this choice, then a new shift starts
--   p_action 'reprint': a shift already printed (p_shift), the same as it was
--   p_action 'day':     the whole of a day (p_day), as the day end report always was; nothing closes
-- p_device: one till of the shop, or null for every till (combined)
create or replace function public.shift_end_report(p_code text, p_action text default 'close', p_device uuid default null, p_day date default null, p_shift uuid default null) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); err text; tz text; dv public.devices; today date; prev timestamptz; fr timestamptz; t2 timestamptz := now();
  sc public.shift_closes; n int; sl jsonb; what text;
begin
  if p_action not in ('close', 'reprint', 'day') then raise exception 'Unknown report'; end if;
  if p_device is not null then
    select * into dv from devices where id = p_device and shop_id = u.shop_id;
    if not found then raise exception 'This till is not in your shop'; end if;
  end if;
  err := app.check_passcode(u, 'day_end', p_code);
  if err is not null then return jsonb_build_object('ok', false, 'error', err); end if;
  select settings.tz into tz from settings where id = 1;
  today := (now() at time zone tz)::date;
  what := coalesce('Till ' || dv.code, 'all tills');

  if p_action = 'reprint' then
    select * into sc from shift_closes where id = p_shift and shop_id = u.shop_id;
    if not found then raise exception 'That shift end report was not found'; end if;
    select code into what from devices where id = sc.device_id;
    perform app.log(u, format('Shift end report %s of %s (%s) printed again', sc.shift_no, to_char(sc.day, 'DD/MM/YYYY'), coalesce('Till ' || what, 'all tills')));
    return jsonb_build_object('ok', true, 'slip', sc.slip, 'shift_no', sc.shift_no, 'from', sc.from_at, 'to', sc.to_at, 'till', what, 'reprint', true);
  end if;

  if p_action = 'day' then
    if p_day is null then raise exception 'Choose the day'; end if;
    with inv as (
      select i.*,
        coalesce((select e.from_total from invoice_edits e where e.invoice_id = i.id order by e.at, e.id limit 1), i.total)
          + (select coalesce(sum(greatest(0, to_total - from_total)),0) from invoice_edits where invoice_id = i.id) as col,
        (select coalesce(sum(greatest(0, from_total - to_total)),0) from invoice_edits where invoice_id = i.id) as ret
      from invoices i
      where i.shop_id = u.shop_id and (p_device is null or i.device_id = p_device) and (i.t at time zone tz)::date = p_day
    )
    select jsonb_build_object('shop_id', s.id, 'shop_name', s.name, 'code', s.code, 'n', count(inv.id),
        'value_fc', coalesce(sum(inv.total),0), 'value_usd', coalesce(sum(inv.total / inv.rate),0),
        'collected', coalesce(sum(inv.col),0), 'returned', coalesce(sum(inv.ret),0),
        'collected_usd', coalesce(sum(inv.paid_usd - inv.change_usd),0),
        'collected_cdf', coalesce(sum(inv.col - round((inv.paid_usd - inv.change_usd) * inv.rate)),0)::bigint)
      into sl from shops s left join inv on inv.shop_id = s.id where s.id = u.shop_id group by s.id, s.name, s.code;
    perform app.log(u, format('Day end report of %s (%s) printed with the passcode', to_char(p_day, 'DD/MM/YYYY'), what));
    return jsonb_build_object('ok', true, 'slip', sl, 'day', p_day, 'till', dv.code);
  end if;

  -- close today's shift: one at a time per shop, so two prints at once never make the same shift twice
  perform 1 from shops where id = u.shop_id for update;
  select max(to_at) into prev from shift_closes where shop_id = u.shop_id and device_id is not distinct from p_device;
  -- the first shift starts at the start of the day; after that, where the last one ended (even on an earlier day,
  -- so the sales of a shift that was never printed are not lost)
  fr := coalesce(prev, (today::timestamp at time zone tz));
  sl := app.shift_slip(u.shop_id, p_device, fr, t2);
  select count(*) + 1 into n from shift_closes where shop_id = u.shop_id and device_id is not distinct from p_device and day = today;
  insert into shift_closes (shop_id, device_id, day, shift_no, from_at, to_at, slip, closed_by, closed_by_name)
    values (u.shop_id, p_device, today, n, fr, t2, sl, u.id, u.name) returning * into sc;
  perform app.log(u, format('Shift end report %s of %s (%s) printed, %s invoices, %s; a new shift starts', n, to_char(today, 'DD/MM/YYYY'), what, sl->>'n', app.fc((sl->>'value_fc')::bigint)));
  return jsonb_build_object('ok', true, 'slip', sl, 'shift_no', n, 'from', fr, 'to', t2, 'till', dv.code, 'id', sc.id);
end $$;

create or replace function public.shift_end_report(p_code text, p_action text default 'close', p_device uuid default null, p_day date default null, p_shift uuid default null) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); err text; tz text; dv public.devices; today date; prev timestamptz; fr timestamptz; t2 timestamptz := now();
  sc public.shift_closes; n int; sl jsonb; what text;
begin
  if p_action not in ('close', 'reprint', 'day') then raise exception 'Unknown report'; end if;
  if p_device is not null then
    select * into dv from devices where id = p_device and shop_id = u.shop_id;
    if not found then raise exception 'This till is not in your shop'; end if;
  end if;
  err := app.check_passcode(u, 'day_end', p_code);
  if err is not null then return jsonb_build_object('ok', false, 'error', err); end if;
  select settings.tz into tz from settings where id = 1;
  today := (now() at time zone tz)::date;
  what := coalesce('Till ' || dv.code, 'all tills');

  if p_action = 'reprint' then
    select * into sc from shift_closes where id = p_shift and shop_id = u.shop_id;
    if not found then raise exception 'That shift end report was not found'; end if;
    select code into what from devices where id = sc.device_id;
    perform app.log(u, format('Shift end report %s of %s (%s) printed again', sc.shift_no, to_char(sc.day, 'DD/MM/YYYY'), coalesce('Till ' || what, 'all tills')));
    return jsonb_build_object('ok', true, 'slip', sc.slip, 'shift_no', sc.shift_no, 'from', sc.from_at, 'to', sc.to_at, 'till', what, 'reprint', true);
  end if;

  if p_action = 'day' then
    if p_day is null then raise exception 'Choose the day'; end if;
    with inv as (
      select i.*,
        coalesce((select e.from_total from invoice_edits e where e.invoice_id = i.id order by e.at, e.id limit 1), i.total)
          + (select coalesce(sum(greatest(0, to_total - from_total)),0) from invoice_edits where invoice_id = i.id) as col,
        (select coalesce(sum(greatest(0, from_total - to_total)),0) from invoice_edits where invoice_id = i.id) as ret
      from invoices i
      where i.shop_id = u.shop_id and (p_device is null or i.device_id = p_device) and (i.t at time zone tz)::date = p_day
    )
    select jsonb_build_object('shop_id', s.id, 'shop_name', s.name, 'code', s.code, 'n', count(inv.id),
        'value_fc', coalesce(sum(inv.total),0), 'value_usd', coalesce(sum(inv.total / inv.rate),0),
        'collected', coalesce(sum(inv.col),0), 'returned', coalesce(sum(inv.ret),0),
        'collected_usd', coalesce(sum(inv.paid_usd - inv.change_usd),0),
        'collected_cdf', coalesce(sum(inv.col - round((inv.paid_usd - inv.change_usd) * coalesce(inv.usd_rate, inv.rate))),0)::bigint)
      into sl from shops s left join inv on inv.shop_id = s.id where s.id = u.shop_id group by s.id, s.name, s.code;
    perform app.log(u, format('Day end report of %s (%s) printed with the passcode', to_char(p_day, 'DD/MM/YYYY'), what));
    return jsonb_build_object('ok', true, 'slip', sl, 'day', p_day, 'till', dv.code);
  end if;

  -- close today's shift: one at a time per shop, so two prints at once never make the same shift twice
  perform 1 from shops where id = u.shop_id for update;
  select max(to_at) into prev from shift_closes where shop_id = u.shop_id and device_id is not distinct from p_device;
  -- the first shift starts at the start of the day; after that, where the last one ended (even on an earlier day,
  -- so the sales of a shift that was never printed are not lost)
  fr := coalesce(prev, (today::timestamp at time zone tz));
  sl := app.shift_slip(u.shop_id, p_device, fr, t2);
  select count(*) + 1 into n from shift_closes where shop_id = u.shop_id and device_id is not distinct from p_device and day = today;
  insert into shift_closes (shop_id, device_id, day, shift_no, from_at, to_at, slip, closed_by, closed_by_name)
    values (u.shop_id, p_device, today, n, fr, t2, sl, u.id, u.name) returning * into sc;
  perform app.log(u, format('Shift end report %s of %s (%s) printed, %s invoices, %s; a new shift starts', n, to_char(today, 'DD/MM/YYYY'), what, sl->>'n', app.fc((sl->>'value_fc')::bigint)));
  return jsonb_build_object('ok', true, 'slip', sl, 'shift_no', n, 'from', fr, 'to', t2, 'till', dv.code, 'id', sc.id);
end $$;

-- ---------- who may call what ----------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.submit_invoice(jsonb), public.sales_report(date, date, uuid), public.shift_end_report(text, text, uuid, date, uuid) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
