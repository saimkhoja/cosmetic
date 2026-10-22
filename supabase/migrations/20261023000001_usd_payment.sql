-- SIM: a fifth switch in Settings (off by default): the till accepts payment in USD, in CDF or both, at the
-- sale's rate. Change is in CDF, or whole dollars plus the rest in CDF. Invoices keep what came in and what went
-- back; the dollars go to the shop's "Cash USD" ledger; the day end slip shows Collected USD and Collected CDF.
-- With the switch off nothing changes.
-- Already running SIM? Run this file once, after 20261022000001_two_rates.sql; it keeps your data.

alter table public.invoices add column if not exists paid_usd numeric(12,2) not null default 0;
alter table public.invoices add column if not exists paid_cdf bigint not null default 0;
alter table public.invoices add column if not exists change_usd int not null default 0;
alter table public.invoices add column if not exists change_cdf bigint not null default 0;
-- invoices from before were paid in Francs
update public.invoices set paid_cdf = tendered, change_cdf = change where paid_usd = 0 and paid_cdf = 0 and tendered > 0;

-- ---------- settings: the fifth switch ----------
create or replace function public.save_settings(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); r numeric := app.num(p->>'rate'); v numeric := app.num(p->>'vat'); old numeric; c jsonb := '{}'; k text;
  br numeric := app.num(p->>'book_rate'); old_br numeric;
  fe jsonb := '{}';
begin
  if r is null or r <= 0 then raise exception 'Enter a valid exchange rate'; end if;
  if v is null or v < 0 or v > 30 then raise exception 'VAT must be between 0 and 30'; end if;
  if br is not null and br <= 0 then raise exception 'Enter a valid internal rate'; end if;
  foreach k in array array['name','address','phone','email','rccm','idnat','nif','footer'] loop
    c := c || jsonb_build_object(k, left(btrim(coalesce(p->'company'->>k, '')), 80));
  end loop;
  foreach k in array array['customer_optional','barcode','till_sells','cash_change','usd_pay'] loop
    fe := fe || jsonb_build_object(k, coalesce((p->'features'->>k)::boolean, false));
  end loop;
  select rate, book_rate into old, old_br from settings where id = 1 for update;
  br := coalesce(br, old_br);   -- an older app that does not send the internal rate keeps it as it is
  update settings set rate = r, book_rate = br, vat = v, company = c, features = fe, updated_at = now() where id = 1;
  if old <> r then perform app.log(u, format('Sales rate changed %s to %s', old, r)); end if;
  if old_br <> br then perform app.log(u, format('Internal rate changed %s to %s', old_br, br)); end if;
  if old = r and old_br = br then perform app.log(u, 'Settings updated'); end if;
end $$;

-- ---------- the shop's ledgers: a Cash USD ledger, made the first time it is needed ----------
create or replace function app.shop_acc(p_kind text, p_shop uuid) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare a uuid; c text := p_kind || ':' || p_shop; s public.shops; nm text;
begin
  select id into a from accounts where code = c;
  if a is not null then return a; end if;
  select * into s from shops where id = p_shop;
  nm := case p_kind when 'INV_SHOP' then 'Stock – ' when 'CASH_SHOP' then 'Cash – ' when 'CASH_SHOP_USD' then 'Cash USD – ' else 'Sales – ' end || s.name;
  if exists (select 1 from accounts where lower(name) = lower(nm)) then nm := nm || ' (' || s.code || ')'; end if;
  insert into accounts (code, name, group_code, currency, shop_id, system)
    values (c, nm, case p_kind when 'INV_SHOP' then 'stock' when 'CASH_SHOP' then 'cash' when 'CASH_SHOP_USD' then 'cash' else 'sales' end,
            case p_kind when 'INV_SHOP' then 'USD' when 'CASH_SHOP_USD' then 'USD' else 'FC' end, p_shop, true)
    on conflict (code) do nothing returning id into a;
  if a is null then select id into a from accounts where code = c; end if;
  return a;
end $$;

-- ---------- sales: dollars and Francs received, change in Francs or dollars + Francs ----------
create or replace function public.submit_invoice(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin','till'); iid uuid := (p->>'id')::uuid; ex public.invoices; dv public.devices; s public.shops;
  cashier public.profiles; seq int; r numeric := app.num(p->>'rate'); vr numeric := app.num(p->>'vat_rate'); dp int; t timestamptz;
  it jsonb; pr public.products; pc public.product_costs; ln int := 0; q int; mult int; piece boolean; price bigint; cur bigint; unit text; cost numeric;
  v_gross bigint := 0; v_disc bigint; v_total bigint; v_vat bigint; tend bigint; flag boolean := false;
  cust text := btrim(coalesce(p->>'customer','')); o public.sale_orders; oid uuid := (p->>'order_id')::uuid;
  pusd numeric := round(coalesce(app.num(p->>'paid_usd'), 0), 2); cusd numeric := coalesce(app.num(p->>'change_usd'), 0); pcdf bigint; ccdf bigint;
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
  update invoices set gross = v_gross, disc = v_disc, total = v_total, vat = v_vat, ht = v_total - v_vat, tendered = tend, change = tend - v_total,
    paid_usd = pusd, paid_cdf = pcdf, change_usd = cusd::int, change_cdf = ccdf, price_flag = flag
    where id = iid;
  update devices set last_seq = greatest(last_seq, seq) where id = dv.id;
  if oid is not null then
    update sale_orders set status = 'approved', reviewed_by_name = cashier.name, reviewed_at = now(), invoice_id = iid where id = oid;
  end if;
  perform app.log(u, format('Invoice %s for %s, cash, %s%s%s', p->>'no', coalesce(nullif(cust, ''), 'walk-in'), app.fc(v_total), case when dp > 0 then format(', discount %s%%', dp) else '' end,
    case when oid is not null then ' (order from ' || o.created_by_name || ' approved)' else '' end));
  return jsonb_build_object('status', 'ok', 'no', p->>'no', 'total', v_total, 'price_flag', flag);
end $$;

-- the sale in the books: the dollars kept go to Cash USD, the Francs to the shop's cash
create or replace function app.post_invoice(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare i public.invoices; cost numeric; tz text; nusd numeric; fc bigint; cash jsonb;
begin
  select * into i from invoices where id = p_id;
  if i.id is null or i.total <= 0 then return; end if;
  select settings.tz into tz from settings where id = 1;
  select coalesce(sum(cost_usd * qty), 0) into cost from invoice_items where invoice_id = p_id;
  -- the cash that stayed in the drawer: Francs only, or the dollars kept plus the Francs (paid out when the change was in Francs)
  nusd := coalesce(i.paid_usd, 0) - coalesce(i.change_usd, 0);
  if coalesce(i.paid_usd, 0) = 0 then
    cash := jsonb_build_array(jsonb_build_object('account', app.shop_acc('CASH_SHOP', i.shop_id), 'side', 'Dr', 'amount', i.total, 'currency', 'FC', 'rate', i.rate));
  else
    fc := i.total - round(nusd * i.rate)::bigint;
    cash := jsonb_build_array(
      jsonb_build_object('account', app.shop_acc('CASH_SHOP_USD', i.shop_id), 'side', case when nusd >= 0 then 'Dr' else 'Cr' end, 'amount', abs(nusd), 'currency', 'USD', 'memo', 'Paid in USD'),
      jsonb_build_object('account', app.shop_acc('CASH_SHOP', i.shop_id), 'side', case when fc >= 0 then 'Dr' else 'Cr' end, 'amount', abs(fc), 'currency', 'FC', 'rate', i.rate));
  end if;
  perform app.post('sales', (i.t at time zone tz)::date, 'Invoice ' || i.no || coalesce(', ' || nullif(i.customer, ''), ''), i.no, 'invoice', i.id,
    cash || jsonb_build_array(
      jsonb_build_object('account', app.shop_acc('SALES_SHOP', i.shop_id), 'side', 'Cr', 'amount', i.ht, 'currency', 'FC', 'rate', i.rate),
      jsonb_build_object('code', 'VAT_OUT', 'side', 'Cr', 'amount', i.vat, 'currency', 'FC', 'rate', i.rate),
      jsonb_build_object('code', 'COGS', 'side', 'Dr', 'amount', round(cost, 2), 'currency', 'USD', 'memo', 'Cost of goods sold'),
      jsonb_build_object('account', app.shop_acc('INV_SHOP', i.shop_id), 'side', 'Cr', 'amount', round(cost, 2), 'currency', 'USD', 'memo', 'Cost of goods sold')),
    i.cashier_name);
end $$;

-- ---------- day end slip: Collected USD and Collected CDF ----------
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
          coalesce(sum(inv.col),0) collected, coalesce(sum(inv.ret),0) returned,
          coalesce(sum(inv.paid_usd - inv.change_usd),0) collected_usd,
          coalesce(sum(inv.col - round((inv.paid_usd - inv.change_usd) * inv.rate)),0)::bigint collected_cdf
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
grant execute on function public.save_settings(jsonb), public.submit_invoice(jsonb), public.sales_report(date, date, uuid) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
