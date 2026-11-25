-- QuickSales: money exchange at the shop counter, and the shift end report shows all the cash in the drawer.
--
-- Money exchange (a switch in Settings → Options → Payment, off by default). The Shop Admin changes money for people
-- who come to the shop, out of the cash collected: the shop BUYS dollars (takes USD, gives CDF) at the buying rate,
-- or SELLS dollars (takes CDF, gives USD) at the selling rate. Both rates are set by the Admin in Settings and can be
-- changed on one exchange. Francs given out are rounded down to 50 FC, Francs taken in rounded up to 50 FC.
-- Each exchange moves the money between the shop's two cash ledgers (Cash – shop in CDF, Cash USD – shop) at the
-- internal rate; the difference is the shop's margin, booked to Exchange gain on dollars (a gain, or a loss when the
-- rate given is worse for the shop than the internal rate). The Shop Admin or the Admin can cancel one with a reason.
--
-- The shift end report and the day end slip now show, besides the sales (each part only when there is any, so a
-- business without vendeurs or exchanges gets the slip it had):
-- * the cash sales apart from the vendeurs' payments, and each vendeur who paid, by name, in USD and CDF (a payment
--   now keeps the till it was taken on, so the till's own shift end report counts it too);
-- * the money exchanged, dollars and Francs in or out of the drawer;
-- * the expenses the Admin paid from the shop's cash (Store upkeep, paid from Cash – shop or Cash USD – shop),
--   taken off the balance. They count in the report of all tills (by the day of the expense on the day end slip,
--   and by when it was recorded on a shift end report).
-- Already running QuickSales? Run this file once, after 20261128000001_upkeep_delete.sql. It changes no amounts.

-- stop at once if the update before this one was not run
do $$ begin
  if not exists (select 1 from pg_proc where proname = 'delete_upkeep') then
    raise exception 'Run supabase/migrations/20261128000001_upkeep_delete.sql (and every earlier file) first, then this file. supabase/scripts/check_migrations.sql shows what is missing';
  end if;
end $$;

-- the rates of money changed at the counter, 1 USD in CDF; they start at the internal rate
alter table public.settings add column if not exists fx_buy_rate numeric(12,2);
alter table public.settings add column if not exists fx_sell_rate numeric(12,2);
update public.settings set fx_buy_rate = coalesce(fx_buy_rate, book_rate, rate), fx_sell_rate = coalesce(fx_sell_rate, book_rate, rate) where id = 1;

create table if not exists public.money_exchanges (
  id                uuid primary key default gen_random_uuid(),
  no                text not null unique,
  shop_id           uuid not null references public.shops(id),
  device_id         uuid references public.devices(id),          -- the till it was done at, if any
  dir               text not null check (dir in ('buy','sell')),  -- buy: the shop takes dollars and gives Francs; sell: the other way
  usd               numeric(12,2) not null check (usd > 0),
  cdf               bigint not null check (cdf > 0),
  rate              numeric(12,2) not null,                       -- the rate given to the customer
  book_rate         numeric(12,2) not null,                       -- the internal rate the cash is booked at
  gain_usd          numeric(12,2) not null default 0,             -- the shop's margin (negative: a loss)
  customer          text not null default '',
  note              text not null default '',
  status            text not null default 'ok' check (status in ('ok','cancelled')),
  by_name           text not null,
  at                timestamptz not null default now(),
  cancel_reason     text,
  cancelled_by_name text,
  cancelled_at      timestamptz
);
create index if not exists money_exchanges_shop on public.money_exchanges (shop_id, at);
alter table public.money_exchanges enable row level security;
revoke all on public.money_exchanges from anon, authenticated;

-- an expense paid from a shop's cash is in the currency that cash holds (it is taken off that drawer)
create or replace function app.trg_upkeep_cash() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare a public.accounts;
begin
  select * into a from accounts where id = new.from_id;
  if a.code like 'CASH_SHOP_USD:%' and new.currency <> 'USD' then raise exception '% holds dollars: enter the expense in USD', a.name; end if;
  if a.code like 'CASH_SHOP:%' and new.currency <> 'FC' then raise exception '% holds Francs: enter the expense in CDF', a.name; end if;
  return new;
end $$;
drop trigger if exists upkeep_cash on public.upkeep;
create trigger upkeep_cash before insert or update of from_id, currency on public.upkeep for each row execute function app.trg_upkeep_cash();

-- ---------- Settings: the switch and the two rates ----------
create or replace function public.save_settings(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); r numeric := app.num(p->>'rate'); v numeric := app.num(p->>'vat'); old numeric; c jsonb := '{}'; k text;
  br numeric := app.num(p->>'book_rate'); old_br numeric;
  fe jsonb := '{}'; cur jsonb;
  fb numeric := app.num(p->>'fx_buy_rate'); fs numeric := app.num(p->>'fx_sell_rate'); old_fb numeric; old_fs numeric;
begin
  if r is null or r <= 0 then raise exception 'Enter a valid exchange rate'; end if;
  if v is null or v < 0 or v > 30 then raise exception 'VAT must be between 0 and 30'; end if;
  if br is not null and br <= 0 then raise exception 'Enter a valid internal rate'; end if;
  foreach k in array array['name','address','phone','email','rccm','idnat','nif','footer'] loop
    c := c || jsonb_build_object(k, left(btrim(coalesce(p->'company'->>k, '')), 80));
  end loop;
  select rate, book_rate, coalesce(features, '{}'::jsonb), fx_buy_rate, fx_sell_rate into old, old_br, cur, old_fb, old_fs from settings where id = 1 for update;
  -- the rates of money changed at the counter: an older app that does not send them keeps them as they are
  fb := coalesce(fb, old_fb); fs := coalesce(fs, old_fs);
  if fb is not null and fb <= 0 or fs is not null and fs <= 0 then raise exception 'Enter valid buying and selling rates for dollars'; end if;
  if fb > fs then raise exception 'The buying rate for dollars (%) cannot be above the selling rate (%)', trim_scale(fb), trim_scale(fs); end if;
  -- a switch the app did not send keeps the value it has. Turning one off still works, because the app sends it as
  -- false; but an app that knows nothing about a switch can no longer turn it off by saving the page.
  foreach k in array array['customer_optional','barcode','till_sells','cash_change','usd_pay','one_copy','no_warehouse','vendeurs','money_exchange'] loop
    fe := fe || jsonb_build_object(k, coalesce((p->'features'->>k)::boolean, coalesce((cur->>k)::boolean, false)));
  end loop;
  br := coalesce(br, old_br);   -- an older app that does not send the internal rate keeps it as it is
  update settings set rate = r, book_rate = br, vat = v, company = c, features = fe, fx_buy_rate = fb, fx_sell_rate = fs, updated_at = now() where id = 1;
  if old_fb is distinct from fb or old_fs is distinct from fs then
    perform app.log(u, format('Money exchange rates changed: buying %s to %s, selling %s to %s', trim_scale(old_fb), trim_scale(fb), trim_scale(old_fs), trim_scale(fs)));
  end if;
  if old <> r then perform app.log(u, format('Sales rate changed %s to %s', old, r)); end if;
  if old_br <> br then perform app.log(u, format('Internal rate changed %s to %s', old_br, br)); end if;
  if old = r and old_br = br then perform app.log(u, 'Settings updated'); end if;
end $$;

-- ---------- the shift end report, the day end slip and the reports: the money changed at the counter ----------
create or replace function app.shift_slip(p_shop uuid, p_device uuid, p_from timestamptz, p_to timestamptz) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  with inv as (
    select i.*, coalesce((select e.from_total from invoice_edits e where e.invoice_id = i.id order by e.at, e.id limit 1), i.total) as first_total
    from invoices i
    where i.shop_id = p_shop and (p_device is null or i.device_id = p_device) and i.received_at > p_from and i.received_at <= p_to
  ), ed as (
    select e.from_total, e.to_total from invoice_edits e join invoices i on i.id = e.invoice_id
    where i.shop_id = p_shop and (p_device is null or i.device_id = p_device) and e.at > p_from and e.at <= p_to and i.vendeur_id is null
  ), vp as (
    -- cash paid by vendeurs for goods taken on credit (in the combined report, and in the till's own when taken there)
    select vendeur_id, amount, paid_usd, paid_cdf - change_cdf as cdf from vendeur_payments
    where shop_id = p_shop and status = 'ok' and (p_device is null or device_id = p_device) and at > p_from and at <= p_to
  ), fx as (
    -- money changed at the counter: dollars bought (USD in, CDF out) and sold (CDF in, USD out)
    select case when dir = 'buy' then usd else -usd end as usd, case when dir = 'sell' then cdf else -cdf end as cdf from money_exchanges
    where shop_id = p_shop and status = 'ok' and (p_device is null or device_id = p_device) and at > p_from and at <= p_to
  ), ex as (
    -- expenses the Admin paid from this shop's cash, taken off the drawer (in the report of all tills)
    select case when u.currency = 'USD' then u.amount else 0 end as usd, case when u.currency = 'FC' then u.amount else 0 end as cdf
    from upkeep u join accounts a on a.id = u.from_id join vouchers v on v.id = u.voucher_id and v.status = 'posted'
    where p_device is null and a.shop_id = p_shop and a.code like 'CASH_SHOP%' and u.at > p_from and u.at <= p_to
  ), x as (
    select (select count(*) from inv) n,
      (select coalesce(sum(total), 0) from inv) value_fc,
      (select coalesce(sum(total / coalesce(usd_rate, rate)), 0) from inv) value_usd,   -- the dollars the sales are worth at the till's rate
      (select coalesce(sum(first_total), 0) from inv where vendeur_id is null) + (select coalesce(sum(greatest(0, to_total - from_total)), 0) from ed)
        + (select coalesce(sum(amount), 0) from vp) collected,
      (select coalesce(sum(total), 0) from inv where vendeur_id is not null) on_credit,
      (select coalesce(sum(amount), 0) from vp) vendeur_paid,
      (select coalesce(sum(usd), 0) from fx) fx_usd, (select coalesce(sum(cdf), 0) from fx) fx_cdf, (select count(*) from fx) fx_n,
      (select coalesce(sum(paid_usd), 0) from vp) vendeur_usd, (select coalesce(sum(cdf), 0) from vp) vendeur_cdf,
      (select coalesce(sum(usd), 0) from ex) exp_usd, (select coalesce(sum(cdf), 0) from ex)::bigint exp_cdf, (select count(*) from ex) exp_n,
      (select coalesce(sum(greatest(0, from_total - to_total)), 0) from ed) returned,
      (select coalesce(sum(paid_usd - change_usd), 0) from inv) + (select coalesce(sum(paid_usd), 0) from vp) collected_usd,
      (select coalesce(sum(round((paid_usd - change_usd) * coalesce(usd_rate, rate))), 0) from inv)
        + (select coalesce(sum(amount - cdf), 0) from vp) usd_in_cdf   -- the vendeurs' dollars at the rate they were taken
  )
  select jsonb_build_object('shop_id', s.id, 'shop_name', s.name, 'code', s.code, 'n', x.n, 'value_fc', x.value_fc, 'value_usd', x.value_usd,
    'collected', x.collected, 'returned', x.returned, 'collected_usd', x.collected_usd, 'collected_cdf', (x.collected - x.usd_in_cdf)::bigint,
    'on_credit', x.on_credit, 'vendeur_paid', x.vendeur_paid, 'fx_usd', x.fx_usd, 'fx_cdf', x.fx_cdf, 'fx_n', x.fx_n,
    'vendeur_usd', x.vendeur_usd, 'vendeur_cdf', x.vendeur_cdf, 'exp_usd', x.exp_usd, 'exp_cdf', x.exp_cdf, 'exp_n', x.exp_n,
    -- each vendeur who paid, with the dollars and the Francs kept
    'vendeurs', (select coalesce(jsonb_agg(jsonb_build_object('name', y.name, 'usd', y.usd, 'cdf', y.cdf) order by y.name), '[]') from (
      select v.name, sum(vp.paid_usd) usd, sum(vp.cdf) cdf from vp join vendeurs v on v.id = vp.vendeur_id group by v.name) y))
  from shops s, x where s.id = p_shop
$$;

create or replace function public.shift_end_report(p_code text, p_action text default 'close', p_device uuid default null, p_day date default null, p_shift uuid default null) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); err text; tz text; dv public.devices; today date; prev timestamptz; fr timestamptz; t2 timestamptz := now();
  sc public.shift_closes; n int; sl jsonb; what text; dsum jsonb; vpaid bigint; vusd numeric; vcdf bigint; vlist jsonb; xusd numeric; xcdf bigint; xn int; eusd numeric; ecdf bigint; en int;
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
    select coalesce(sum(amount), 0), coalesce(sum(paid_usd), 0), coalesce(sum(paid_cdf - change_cdf), 0) into vpaid, vusd, vcdf from vendeur_payments
      where shop_id = u.shop_id and status = 'ok' and (p_device is null or device_id = p_device) and (at at time zone tz)::date = p_day;
    select coalesce(sum(case when dir = 'buy' then usd else -usd end), 0), coalesce(sum(case when dir = 'sell' then cdf else -cdf end), 0), count(*)
      into xusd, xcdf, xn from money_exchanges
      where shop_id = u.shop_id and status = 'ok' and (p_device is null or device_id = p_device) and (at at time zone tz)::date = p_day;
    select coalesce(jsonb_agg(jsonb_build_object('name', y.name, 'usd', y.usd, 'cdf', y.cdf) order by y.name), '[]') into vlist from (
      select v.name, sum(x.paid_usd) usd, sum(x.paid_cdf - x.change_cdf) cdf from vendeur_payments x join vendeurs v on v.id = x.vendeur_id
      where x.shop_id = u.shop_id and x.status = 'ok' and (p_device is null or x.device_id = p_device) and (x.at at time zone tz)::date = p_day group by v.name) y;
    select coalesce(sum(case when x.currency = 'USD' then x.amount else 0 end), 0), coalesce(sum(case when x.currency = 'FC' then x.amount else 0 end), 0), count(*)
      into eusd, ecdf, en from upkeep x join accounts a on a.id = x.from_id join vouchers v on v.id = x.voucher_id and v.status = 'posted'
      where p_device is null and a.shop_id = u.shop_id and a.code like 'CASH_SHOP%' and x.date = p_day;
    with inv as (
      select i.*,
        case when i.vendeur_id is not null then 0 else coalesce((select e.from_total from invoice_edits e where e.invoice_id = i.id order by e.at, e.id limit 1), i.total)
          + (select coalesce(sum(greatest(0, to_total - from_total)),0) from invoice_edits where invoice_id = i.id) end as col,
        case when i.vendeur_id is not null then 0 else (select coalesce(sum(greatest(0, from_total - to_total)),0) from invoice_edits where invoice_id = i.id) end as ret
      from invoices i
      where i.shop_id = u.shop_id and (p_device is null or i.device_id = p_device) and (i.t at time zone tz)::date = p_day
    )
    select jsonb_build_object('shop_id', s.id, 'shop_name', s.name, 'code', s.code, 'n', count(inv.id),
        'value_fc', coalesce(sum(inv.total),0), 'value_usd', coalesce(sum(inv.total / coalesce(inv.usd_rate, inv.rate)),0),
        'collected', coalesce(sum(inv.col),0) + vpaid, 'returned', coalesce(sum(inv.ret),0),
        'collected_usd', coalesce(sum(inv.paid_usd - inv.change_usd),0) + vusd,
        'collected_cdf', (coalesce(sum(inv.col - round((inv.paid_usd - inv.change_usd) * coalesce(inv.usd_rate, inv.rate))),0) + vcdf)::bigint,
        'on_credit', coalesce(sum(inv.total) filter (where inv.vendeur_id is not null),0), 'vendeur_paid', vpaid, 'fx_usd', xusd, 'fx_cdf', xcdf, 'fx_n', xn,
        'vendeur_usd', vusd, 'vendeur_cdf', vcdf, 'exp_usd', eusd, 'exp_cdf', ecdf, 'exp_n', en, 'vendeurs', vlist)
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
  -- From the second shift of the day, the slip also carries the day so far: today's shift slips added up, line by
  -- line, with this one. It is the slips themselves that are added, not the sales counted again, so every line agrees
  -- with the slips the cashier already holds -- even when an invoice of an earlier shift was corrected since: the
  -- correction is in the shift it was made in, as money given back. It is kept inside the slip, so a shift printed
  -- again shows the day as it stood when that shift was printed.
  if n > 1 then
    select jsonb_build_object(
        'n',             (coalesce(sum((slip->>'n')::numeric), 0) + (sl->>'n')::numeric)::int,
        'value_fc',      (coalesce(sum((slip->>'value_fc')::numeric), 0) + (sl->>'value_fc')::numeric)::bigint,
        'value_usd',      coalesce(sum((slip->>'value_usd')::numeric), 0) + (sl->>'value_usd')::numeric,
        'collected',     (coalesce(sum((slip->>'collected')::numeric), 0) + (sl->>'collected')::numeric)::bigint,
        'returned',      (coalesce(sum((slip->>'returned')::numeric), 0) + (sl->>'returned')::numeric)::bigint,
        'collected_usd',  coalesce(sum((slip->>'collected_usd')::numeric), 0) + (sl->>'collected_usd')::numeric,
        'collected_cdf', (coalesce(sum((slip->>'collected_cdf')::numeric), 0) + (sl->>'collected_cdf')::numeric)::bigint,
        'on_credit',     (coalesce(sum((slip->>'on_credit')::numeric), 0) + coalesce((sl->>'on_credit')::numeric, 0))::bigint,
        'vendeur_paid',  (coalesce(sum((slip->>'vendeur_paid')::numeric), 0) + coalesce((sl->>'vendeur_paid')::numeric, 0))::bigint,
        'fx_usd',         coalesce(sum((slip->>'fx_usd')::numeric), 0) + coalesce((sl->>'fx_usd')::numeric, 0),
        'fx_cdf',        (coalesce(sum((slip->>'fx_cdf')::numeric), 0) + coalesce((sl->>'fx_cdf')::numeric, 0))::bigint,
        'vendeur_usd',    coalesce(sum((slip->>'vendeur_usd')::numeric), 0) + coalesce((sl->>'vendeur_usd')::numeric, 0),
        'vendeur_cdf',   (coalesce(sum((slip->>'vendeur_cdf')::numeric), 0) + coalesce((sl->>'vendeur_cdf')::numeric, 0))::bigint,
        'exp_usd',        coalesce(sum((slip->>'exp_usd')::numeric), 0) + coalesce((sl->>'exp_usd')::numeric, 0),
        'exp_cdf',       (coalesce(sum((slip->>'exp_cdf')::numeric), 0) + coalesce((sl->>'exp_cdf')::numeric, 0))::bigint,
        'from', min(from_at), 'shifts', n)
      into dsum
      from shift_closes where shop_id = u.shop_id and device_id is not distinct from p_device and day = today;
    sl := sl || jsonb_build_object('day', dsum);
  end if;
  insert into shift_closes (shop_id, device_id, day, shift_no, from_at, to_at, slip, closed_by, closed_by_name)
    values (u.shop_id, p_device, today, n, fr, t2, sl, u.id, u.name) returning * into sc;
  perform app.log(u, format('Shift end report %s of %s (%s) printed, %s invoices, %s; a new shift starts', n, to_char(today, 'DD/MM/YYYY'), what, sl->>'n', app.fc((sl->>'value_fc')::bigint)));
  return jsonb_build_object('ok', true, 'slip', sl, 'shift_no', n, 'from', fr, 'to', t2, 'till', dv.code, 'id', sc.id);
end $$;

create or replace function public.sales_report(p_from date, p_to date, p_shop uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin','shopadmin'); sid uuid; tz text; lim numeric; res jsonb;
  keep uuid[] := '{}'; seen int := 0; acc numeric := 0; cur date; r record;
begin
  if p_from is null or p_to is null then raise exception 'Choose the dates'; end if;
  if p_from > p_to then select p_to, p_from into p_from, p_to; end if;
  sid := case when u.role = 'shopadmin' then u.shop_id else p_shop end;
  -- The Shop Admin's figures stop at the shop's daily limit: the day's sales are taken in the order they were made
  -- and counted while they still fit under it, so the total, the list, the categories and the cashiers all agree.
  -- The Admin has no limit, and the shift end report (its own function) always has every sale.
  select settings.tz, case when u.role = 'shopadmin' then settings.shop_sales_limit_usd end into tz, lim from settings where id = 1;
  if lim is not null then
    for r in select i.id, (i.t at time zone tz)::date as d, i.total / nullif(i.rate, 0) as usd from invoices i
      where (sid is null or i.shop_id = sid) and (i.t at time zone tz)::date between p_from and p_to
      order by (i.t at time zone tz)::date, i.t, i.id
    loop
      seen := seen + 1;
      if cur is distinct from r.d then cur := r.d; acc := 0; end if;
      if acc + coalesce(r.usd, 0) <= lim then acc := acc + coalesce(r.usd, 0); keep := keep || r.id; end if;
    end loop;
  end if;
  with inv as (
    select i.*, (i.t at time zone tz)::date as day,
      (select coalesce(sum(qty),0) from invoice_items where invoice_id = i.id) as q,
      (select coalesce(sum(cost_usd * qty),0) from invoice_items where invoice_id = i.id) as cogs,
      case when i.vendeur_id is not null then 0 else coalesce((select e.from_total from invoice_edits e where e.invoice_id = i.id order by e.at, e.id limit 1), i.total)
        + (select coalesce(sum(greatest(0, to_total - from_total)),0) from invoice_edits where invoice_id = i.id) end as col,
      case when i.vendeur_id is not null then 0 else (select coalesce(sum(greatest(0, from_total - to_total)),0) from invoice_edits where invoice_id = i.id) end as ret,
      exists (select 1 from invoice_edits where invoice_id = i.id) as edited
    from invoices i
    where (sid is null or i.shop_id = sid) and (i.t at time zone tz)::date between p_from and p_to
      and (lim is null or i.id = any(keep))
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'shop_id', sid,
    -- true when sales were left out to stay under the limit, so the screen can say the figures stop there
    'capped', lim is not null and seen > coalesce(array_length(keep, 1), 0),
    'n', (select count(*) from inv),
    'total', (select coalesce(sum(total),0) from inv),
    -- sales in dollars: what they are worth at the rate the till takes dollars, so the figure matches the cash
    'total_usd', (select coalesce(sum(total / coalesce(usd_rate, rate)),0) from inv),
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
        select s.id as shop_id, s.name as shop_name, s.code, count(inv.id) n, coalesce(sum(inv.total),0) value_fc, coalesce(sum(inv.total / coalesce(inv.usd_rate, inv.rate)),0) value_usd,
          coalesce(sum(inv.col),0) + vp.paid collected, coalesce(sum(inv.ret),0) returned,
          coalesce(sum(inv.paid_usd - inv.change_usd),0) + vp.usd collected_usd,
          (coalesce(sum(inv.col - round((inv.paid_usd - inv.change_usd) * coalesce(inv.usd_rate, inv.rate))),0) + vp.cdf)::bigint collected_cdf,
          coalesce(sum(inv.total) filter (where inv.vendeur_id is not null),0) on_credit, vp.paid vendeur_paid, fx.usd fx_usd, fx.cdf fx_cdf, fx.n fx_n,
          vp.usd vendeur_usd, vp.cdf vendeur_cdf, ex.usd exp_usd, ex.cdf exp_cdf, ex.n exp_n,
          (select coalesce(jsonb_agg(jsonb_build_object('name', y.name, 'usd', y.usd, 'cdf', y.cdf) order by y.name), '[]') from (
            select v.name, sum(x.paid_usd) usd, sum(x.paid_cdf - x.change_cdf) cdf from vendeur_payments x join vendeurs v on v.id = x.vendeur_id
            where x.shop_id = s.id and x.status = 'ok' and (x.at at time zone tz)::date between p_from and p_to group by v.name) y) vendeurs
        from shops s left join inv on inv.shop_id = s.id
          -- cash paid by vendeurs for goods taken on credit
          left join lateral (select coalesce(sum(x.amount), 0)::bigint paid, coalesce(sum(x.paid_usd), 0) usd, coalesce(sum(x.paid_cdf - x.change_cdf), 0)::bigint cdf from vendeur_payments x
            where x.shop_id = s.id and x.status = 'ok' and (x.at at time zone tz)::date between p_from and p_to) vp on true
          -- money changed at the counter: net dollars and Francs into the drawer
          left join lateral (select coalesce(sum(case when e.dir = 'buy' then e.usd else -e.usd end), 0) usd,
              coalesce(sum(case when e.dir = 'sell' then e.cdf else -e.cdf end), 0)::bigint cdf, count(*)::int n from money_exchanges e
            where e.shop_id = s.id and e.status = 'ok' and (e.at at time zone tz)::date between p_from and p_to) fx on true
          -- expenses the Admin paid from the shop's cash, taken off the balance
          left join lateral (select coalesce(sum(case when x.currency = 'USD' then x.amount else 0 end), 0) usd,
              coalesce(sum(case when x.currency = 'FC' then x.amount else 0 end), 0)::bigint cdf, count(*)::int n
            from upkeep x join accounts a on a.id = x.from_id join vouchers v on v.id = x.voucher_id and v.status = 'posted'
            where a.shop_id = s.id and a.code like 'CASH_SHOP%' and x.date between p_from and p_to) ex on true
        where (sid is null and s.active) or s.id = sid group by s.id, s.name, s.code, vp.paid, vp.usd, vp.cdf, fx.usd, fx.cdf, fx.n, ex.usd, ex.cdf, ex.n) sl),
    'invoices', (select coalesce(jsonb_agg(v order by v.t desc), '[]') from (
        select id, no, t, shop_id, cashier_name, customer, q as items, disc, total, edited from inv order by t desc limit 300) v)
  ) into res;
  return res;
end $$;

-- ---------- money exchange ----------
-- buy: the shop takes dollars and gives Francs (rounded DOWN to 50 FC); sell: the shop takes Francs (rounded UP to
-- 50 FC) and gives dollars. The rate is the Settings rate unless the Shop Admin types another.
create or replace function app.fx_cdf(p_dir text, p_usd numeric, p_rate numeric) returns bigint
language sql immutable as $$
  select (case when p_dir = 'buy' then floor(round(p_usd * p_rate, 2) / 50) else ceil(round(p_usd * p_rate, 2) / 50) end * 50)::bigint
$$;

create or replace function public.exchange_money(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); s public.settings; dir text := p->>'dir'; usd numeric := round(app.num(p->>'usd'), 2);
  r numeric; b numeric; cdf bigint; gain numeric; eid uuid := gen_random_uuid(); eno text; dev uuid := nullif(p->>'device_id', '')::uuid;
  cust text := left(btrim(coalesce(p->>'customer', '')), 60); note text := left(btrim(coalesce(p->>'note', '')), 120); usd_acc uuid; fc_acc uuid; lines jsonb;
begin
  if not app.feature('money_exchange') then raise exception 'Money exchange is not turned on in Settings'; end if;
  if dir not in ('buy','sell') then raise exception 'Choose whether the shop buys or sells dollars'; end if;
  if usd is null or usd <= 0 then raise exception 'Enter the dollars'; end if;
  if usd > 100000 then raise exception 'That is more dollars than one exchange can be'; end if;
  select * into s from settings where id = 1;
  b := coalesce(nullif(s.book_rate, 0), s.rate);
  r := round(coalesce(app.num(p->>'rate'), case when dir = 'buy' then s.fx_buy_rate else s.fx_sell_rate end, b), 2);
  if r is null or r <= 0 then raise exception 'Enter the exchange rate'; end if;
  if r < b / 2 or r > b * 2 then raise exception 'Check the exchange rate: % FC is far from the internal rate (% FC)', trim_scale(r), trim_scale(b); end if;
  cdf := app.fx_cdf(dir, usd, r);
  if cdf <= 0 then raise exception 'That is too few dollars to change'; end if;
  if dev is not null and not exists (select 1 from devices where id = dev and shop_id = u.shop_id) then dev := null; end if;
  -- the margin, in USD: what came in less what went out, both at the internal rate
  gain := round(case when dir = 'buy' then usd - cdf / b else cdf / b - usd end, 2);
  eno := app.vnum('FX', u.shop_id);
  insert into money_exchanges (id, no, shop_id, device_id, dir, usd, cdf, rate, book_rate, gain_usd, customer, note, by_name)
    values (eid, eno, u.shop_id, dev, dir, usd, cdf, r, b, gain, cust, note, u.name);
  usd_acc := app.shop_acc('CASH_SHOP_USD', u.shop_id); fc_acc := app.shop_acc('CASH_SHOP', u.shop_id);
  lines := jsonb_build_array(
    jsonb_build_object('account', usd_acc, 'side', case when dir = 'buy' then 'Dr' else 'Cr' end, 'amount', usd, 'currency', 'USD', 'memo', format('%s at %s', app.usd(usd), trim_scale(r))),
    jsonb_build_object('account', fc_acc, 'side', case when dir = 'buy' then 'Cr' else 'Dr' end, 'amount', cdf, 'currency', 'FC', 'rate', b));
  if abs(gain) >= 0.005 then
    lines := lines || jsonb_build_array(jsonb_build_object('code', 'FX_GAIN', 'side', case when gain > 0 then 'Cr' else 'Dr' end, 'amount', abs(gain), 'currency', 'USD', 'memo', 'Margin on money exchanged'));
  end if;
  perform app.post('journal', (now() at time zone s.tz)::date,
    format('Money exchange %s: %s %s for %s%s', eno, case when dir = 'buy' then 'bought' else 'sold' end, app.usd(usd), app.fc(cdf), coalesce(', ' || nullif(cust, ''), '')),
    eno, 'money_exchange', eid, lines, u.name);
  perform app.log(u, format('Money exchange %s: %s %s at %s FC for %s%s%s', eno, case when dir = 'buy' then 'bought' else 'sold' end, app.usd(usd), trim_scale(r), app.fc(cdf),
    case when r <> case when dir = 'buy' then s.fx_buy_rate else s.fx_sell_rate end then ' (rate typed by the Shop Admin)' else '' end, coalesce(', ' || nullif(cust, ''), '')));
  return (select to_jsonb(e) from money_exchanges e where id = eid);
end $$;

create or replace function public.cancel_exchange(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin','admin'); x public.money_exchanges;
begin
  select * into x from money_exchanges where id = p_id for update;
  if not found or (u.role = 'shopadmin' and x.shop_id <> u.shop_id) then raise exception 'Exchange not found'; end if;
  if x.status <> 'ok' then raise exception 'Exchange % is already cancelled', x.no; end if;
  if length(btrim(coalesce(p_reason, ''))) < 4 then raise exception 'Write a short reason for cancelling this exchange'; end if;
  update money_exchanges set status = 'cancelled', cancel_reason = left(btrim(p_reason), 120), cancelled_by_name = u.name, cancelled_at = now() where id = p_id;
  update vouchers set status = 'cancelled', cancel_reason = left('Exchange cancelled: ' || btrim(p_reason), 120)
    where source_type = 'money_exchange' and source_id = p_id and status = 'posted';
  perform app.log(u, format('Money exchange %s cancelled (%s %s for %s): %s', x.no, case when x.dir = 'buy' then 'bought' else 'sold' end, app.usd(x.usd), app.fc(x.cdf), btrim(p_reason)));
end $$;

-- the exchanges of a shop (the Shop Admin's own; the Admin any shop or all) between two days, with the totals
create or replace function public.exchange_list(p_from date, p_to date, p_shop uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin','admin'); sid uuid; tz text;
begin
  sid := case when u.role = 'shopadmin' then u.shop_id else p_shop end;
  select settings.tz into tz from settings where id = 1;
  return (with e as (
      select x.*, s.name as shop_name from money_exchanges x join shops s on s.id = x.shop_id
      where (sid is null or x.shop_id = sid) and (x.at at time zone tz)::date between p_from and p_to)
    select jsonb_build_object(
      'list', (select coalesce(jsonb_agg(to_jsonb(e) order by e.at desc), '[]') from e),
      'bought_usd', (select coalesce(sum(usd), 0) from e where status = 'ok' and dir = 'buy'),
      'sold_usd', (select coalesce(sum(usd), 0) from e where status = 'ok' and dir = 'sell'),
      'cdf_in', (select coalesce(sum(cdf), 0) from e where status = 'ok' and dir = 'sell'),
      'cdf_out', (select coalesce(sum(cdf), 0) from e where status = 'ok' and dir = 'buy'),
      'gain_usd', (select coalesce(sum(gain_usd), 0) from e where status = 'ok'),
      'n', (select count(*) from e where status = 'ok')));
end $$;

revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.exchange_money(jsonb), public.cancel_exchange(uuid, text), public.exchange_list(date, date, uuid) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
