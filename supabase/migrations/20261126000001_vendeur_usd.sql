-- QuickSales: vendeurs pay in dollars, Francs or both.
-- The Shop Admin takes a vendeur's payment in USD and CDF together. The dollars count at the internal rate (what the
-- shop gives for a dollar over the counter) unless the Shop Admin types the taux agreed with the vendeur. When the
-- dollars come to more than is owed, the rest is given back in Francs. The dollars go into the shop's USD cash, the
-- Francs into its Franc cash, and a dollar taken below the sales rate is booked as an exchange difference, as at the
-- till. The shift end report, the day end slip and the reports count the vendeurs' dollars in Collected USD.
-- Payments made before this update were all in Francs and stay as they are.
-- Already running QuickSales? Run this file once, after 20261125000001_round_50.sql. It changes no amounts.

-- stop at once if the update before this one was not run
do $$ begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'to_cdf' and pg_get_functiondef(p.oid) like '%/ 50%') then
    raise exception 'Run supabase/migrations/20261125000001_round_50.sql (and every earlier file) first, then this file. supabase/scripts/check_migrations.sql shows what is missing';
  end if;
end $$;

-- amount stays what the payment takes off the debt, in CDF; the new columns say how it was paid
alter table public.vendeur_payments add column if not exists paid_usd numeric(12,2) not null default 0 check (paid_usd >= 0);
alter table public.vendeur_payments add column if not exists paid_cdf bigint not null default 0 check (paid_cdf >= 0);
alter table public.vendeur_payments add column if not exists usd_rate numeric(12,2);           -- the rate the dollars were taken at
alter table public.vendeur_payments add column if not exists change_cdf bigint not null default 0 check (change_cdf >= 0);
-- payments from before were Francs only
update public.vendeur_payments set paid_cdf = amount where paid_usd = 0 and paid_cdf = 0;

-- ", $40 at 2 800 + 5 000 FC" for a payment with dollars, '' for one in Francs only
create or replace function app.vp_how(x public.vendeur_payments) returns text
language sql immutable as $$
  select case when x.paid_usd > 0 then ', ' || app.usd(x.paid_usd) || ' at ' || trim_scale(x.usd_rate) || ' FC'
    || case when x.paid_cdf > 0 then ' + ' || app.fc(x.paid_cdf) else '' end
    || case when x.change_cdf > 0 then ', ' || app.fc(x.change_cdf) || ' given back' else '' end else '' end
$$;

-- a payment from a vendeur, partial or full: Francs, dollars or both. Dollars count at the internal rate, or at the
-- taux the Shop Admin types; dollars worth more than is owed get the rest back in Francs.
create or replace function public.vendeur_pay(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); v public.vendeurs; st jsonb; r numeric; book numeric; tz text;
  pusd numeric := round(coalesce(app.num(p->>'paid_usd'), 0), 2); pcdf numeric := app.num(p->>'paid_cdf'); ur numeric;
  val bigint; usd_fc bigint := 0; chg bigint := 0; amt bigint; fc bigint; diff numeric; cash jsonb; how text := '';
  pid uuid := gen_random_uuid(); pno text; dev uuid := nullif(p->>'device_id', '')::uuid; bal bigint; x public.vendeur_payments;
begin
  if not app.feature('vendeurs') then raise exception 'Vendeurs (goods on credit) are not turned on in Settings'; end if;
  select * into v from vendeurs where id = (p->>'vendeur_id')::uuid and shop_id = u.shop_id for update;
  if not found then raise exception 'Vendeur not found'; end if;
  -- an app from before this update sends the Francs as "amount"
  if pcdf is null and pusd = 0 then pcdf := app.num(p->>'amount'); end if;
  pcdf := coalesce(pcdf, 0);
  if pusd < 0 or pcdf < 0 then raise exception 'Amounts paid cannot be negative'; end if;
  if pcdf <> trunc(pcdf) then raise exception 'Enter the Francs paid as a whole number'; end if;
  if pusd = 0 and pcdf = 0 then raise exception 'Enter the amount paid, in USD or CDF'; end if;
  select rate, coalesce(nullif(book_rate, 0), rate), settings.tz into r, book, tz from settings where id = 1;
  if pusd > 0 then
    ur := round(coalesce(app.num(p->>'usd_rate'), book), 2);
    if ur is null or ur <= 0 then raise exception 'Enter the exchange rate for the dollars'; end if;
    -- a typing slip (a zero too many or too few) is caught: the taux stays within half and double the internal rate
    if ur < book / 2 or ur > book * 2 then raise exception 'Check the exchange rate: % FC is far from the internal rate (% FC)', trim_scale(ur), trim_scale(book); end if;
    usd_fc := round(pusd * ur)::bigint;
  end if;
  val := pcdf::bigint + usd_fc;
  st := app.vendeur_state(v); bal := (st->>'balance')::bigint;
  if bal <= 0 then raise exception 'Vendeur % owes nothing', v.name; end if;
  if val > bal then
    if pusd = 0 then raise exception 'Vendeur % owes only %', v.name, app.fc(bal); end if;
    if pcdf >= bal then raise exception 'The Francs alone pay all that % owes (%): take no dollars', v.name, app.fc(bal); end if;
    chg := val - bal;   -- the dollars come to more than is owed: the rest is given back in Francs
  end if;
  amt := val - chg;
  if dev is not null and not exists (select 1 from devices where id = dev and shop_id = u.shop_id) then dev := null; end if;
  pno := app.vnum('VP', v.shop_id);
  insert into vendeur_payments (id, no, vendeur_id, shop_id, device_id, amount, rate, note, by_name, paid_usd, paid_cdf, usd_rate, change_cdf)
    values (pid, pno, v.id, v.shop_id, dev, amt, r, left(btrim(coalesce(p->>'note', '')), 120), u.name, pusd, pcdf::bigint, ur, chg)
    returning * into x;
  if pusd = 0 then
    cash := jsonb_build_array(jsonb_build_object('account', app.shop_acc('CASH_SHOP', v.shop_id), 'side', 'Dr', 'amount', amt, 'currency', 'FC', 'rate', r));
  else
    -- the dollars into the USD cash; the Francs kept (less any given back) into the Franc cash
    fc := amt - usd_fc;
    cash := jsonb_build_array(
      jsonb_build_object('account', app.shop_acc('CASH_SHOP_USD', v.shop_id), 'side', 'Dr', 'amount', pusd, 'currency', 'USD', 'memo', 'Paid in USD at ' || ur),
      jsonb_build_object('account', app.shop_acc('CASH_SHOP', v.shop_id), 'side', case when fc >= 0 then 'Dr' else 'Cr' end, 'amount', abs(fc), 'currency', 'FC', 'rate', r));
    -- the debt is in Francs at the sales rate; a dollar taken for less than that is the exchange difference
    diff := round(pusd * (r - ur) / r, 2);
    if abs(diff) >= 0.005 then
      cash := cash || jsonb_build_array(jsonb_build_object('code', 'FX_GAIN', 'side', case when diff > 0 then 'Cr' else 'Dr' end,
        'amount', abs(diff), 'currency', 'USD', 'memo', 'Exchange on dollars'));
    end if;
    how := format(' (%s at %s FC%s%s%s)', app.usd(pusd), trim_scale(ur), case when ur <> book then ', taux typed by the Shop Admin' else '' end,
      case when pcdf > 0 then ' + ' || app.fc(pcdf::bigint) else '' end, case when chg > 0 then ', ' || app.fc(chg) || ' given back' else '' end);
  end if;
  perform app.post('receipt', (now() at time zone tz)::date, format('Payment %s from vendeur %s', pno, v.name), pno, 'vendeur_payment', pid,
    cash || jsonb_build_array(
      jsonb_build_object('account', v.account_id, 'side', 'Cr', 'amount', amt, 'currency', 'FC', 'rate', r, 'memo', nullif(btrim(coalesce(p->>'note', '')), ''))),
    u.name);
  perform app.log(u, format('Payment %s from vendeur %s: %s%s, %s left to pay', pno, v.name, app.fc(amt), how, app.fc(bal - amt)));
  return jsonb_build_object('id', pid, 'no', pno, 'amount', amt, 'at', now(), 'by_name', u.name, 'vendeur', v.name, 'before', bal,
    'paid_usd', pusd, 'paid_cdf', pcdf::bigint, 'usd_rate', ur, 'change_cdf', chg, 'state', app.vendeur_state(v));
end $$;

-- ---------- the shift end report, the day end slip and the reports: the vendeurs' dollars in Collected USD ----------
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
    select amount, paid_usd, paid_cdf - change_cdf as cdf from vendeur_payments
    where shop_id = p_shop and status = 'ok' and (p_device is null or device_id = p_device) and at > p_from and at <= p_to
  ), x as (
    select (select count(*) from inv) n,
      (select coalesce(sum(total), 0) from inv) value_fc,
      (select coalesce(sum(total / coalesce(usd_rate, rate)), 0) from inv) value_usd,   -- the dollars the sales are worth at the till's rate
      (select coalesce(sum(first_total), 0) from inv where vendeur_id is null) + (select coalesce(sum(greatest(0, to_total - from_total)), 0) from ed)
        + (select coalesce(sum(amount), 0) from vp) collected,
      (select coalesce(sum(total), 0) from inv where vendeur_id is not null) on_credit,
      (select coalesce(sum(amount), 0) from vp) vendeur_paid,
      (select coalesce(sum(greatest(0, from_total - to_total)), 0) from ed) returned,
      (select coalesce(sum(paid_usd - change_usd), 0) from inv) + (select coalesce(sum(paid_usd), 0) from vp) collected_usd,
      (select coalesce(sum(round((paid_usd - change_usd) * coalesce(usd_rate, rate))), 0) from inv)
        + (select coalesce(sum(amount - cdf), 0) from vp) usd_in_cdf   -- the vendeurs' dollars at the rate they were taken
  )
  select jsonb_build_object('shop_id', s.id, 'shop_name', s.name, 'code', s.code, 'n', x.n, 'value_fc', x.value_fc, 'value_usd', x.value_usd,
    'collected', x.collected, 'returned', x.returned, 'collected_usd', x.collected_usd, 'collected_cdf', (x.collected - x.usd_in_cdf)::bigint,
    'on_credit', x.on_credit, 'vendeur_paid', x.vendeur_paid)
  from shops s, x where s.id = p_shop
$$;

create or replace function public.shift_end_report(p_code text, p_action text default 'close', p_device uuid default null, p_day date default null, p_shift uuid default null) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); err text; tz text; dv public.devices; today date; prev timestamptz; fr timestamptz; t2 timestamptz := now();
  sc public.shift_closes; n int; sl jsonb; what text; dsum jsonb; vpaid bigint; vusd numeric; vcdf bigint;
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
        'on_credit', coalesce(sum(inv.total) filter (where inv.vendeur_id is not null),0), 'vendeur_paid', vpaid)
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
          coalesce(sum(inv.total) filter (where inv.vendeur_id is not null),0) on_credit, vp.paid vendeur_paid
        from shops s left join inv on inv.shop_id = s.id
          -- cash paid by vendeurs for goods taken on credit
          left join lateral (select coalesce(sum(x.amount), 0)::bigint paid, coalesce(sum(x.paid_usd), 0) usd, coalesce(sum(x.paid_cdf - x.change_cdf), 0)::bigint cdf from vendeur_payments x
            where x.shop_id = s.id and x.status = 'ok' and (x.at at time zone tz)::date between p_from and p_to) vp on true
        where (sid is null and s.active) or s.id = sid group by s.id, s.name, s.code, vp.paid, vp.usd, vp.cdf) sl),
    'invoices', (select coalesce(jsonb_agg(v order by v.t desc), '[]') from (
        select id, no, t, shop_id, cashier_name, customer, q as items, disc, total, edited from inv order by t desc limit 300) v)
  ) into res;
  return res;
end $$;

-- ---------- the statement says how each payment was made ----------
create or replace function public.vendeur_statement(p_id uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin','admin'); v public.vendeurs; tz text; bf bigint; res jsonb;
begin
  select * into v from vendeurs where id = p_id;
  if not found or (u.role = 'shopadmin' and v.shop_id <> u.shop_id) then raise exception 'Vendeur not found'; end if;
  if p_from is null or p_to is null then raise exception 'Choose the dates'; end if;
  if p_from > p_to then select p_to, p_from into p_from, p_to; end if;
  select settings.tz into tz from settings where id = 1;
  with l as (
    select v.created_at as t, (v.created_at at time zone tz)::date as d, ''::text as no, 'Opening balance'::text as what, v.opening_balance::bigint as dr, 0::bigint as cr,
      null::date as due, null::uuid as invoice_id
    where v.opening_balance > 0
    union all
    select i.t, (i.t at time zone tz)::date, i.no,
      'Goods on credit, ' || (select coalesce(sum(qty), 0) from invoice_items where invoice_id = i.id) || ' items'
        || case when exists (select 1 from invoice_edits where invoice_id = i.id) then ' (changed)' else '' end,
      i.total, 0, i.due_date, i.id
    from invoices i where i.vendeur_id = v.id
    union all
    select x.at, (x.at at time zone tz)::date, x.no, 'Payment' || app.vp_how(x) || coalesce(', ' || nullif(x.note, ''), ''), 0, x.amount, null, null
    from vendeur_payments x where x.vendeur_id = v.id and x.status = 'ok'
  )
  select jsonb_build_object(
    'vendeur', (to_jsonb(v) - 'account_id') || jsonb_build_object('shop_name', (select name from shops where id = v.shop_id)),
    'from', p_from, 'to', p_to,
    'brought_forward', (select coalesce(sum(dr - cr), 0) from l where d < p_from),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('date', d, 'no', no, 'what', what, 'dr', dr, 'cr', cr, 'due', due, 'invoice_id', invoice_id) order by t, no), '[]')
              from l where d between p_from and p_to),
    'total_dr', (select coalesce(sum(dr), 0) from l where d between p_from and p_to),
    'total_cr', (select coalesce(sum(cr), 0) from l where d between p_from and p_to),
    'closing', (select coalesce(sum(dr - cr), 0) from l where d <= p_to),
    'promos', (select coalesce(jsonb_agg(jsonb_build_object('id', pr.id, 'no', pr.no, 'date', (pr.t at time zone tz)::date, 'value', pr.value, 'status', pr.status,
        'note', pr.note, 'invoice', (select no from invoices where id = pr.invoice_id),
        'items', (select jsonb_agg(jsonb_build_object('name', i.name, 'unit', i.unit, 'qty', i.qty, 'line', i.line) order by i.line_no) from vendeur_promo_items i where i.promo_id = pr.id))
        order by pr.t), '[]')
      from vendeur_promos pr where pr.vendeur_id = v.id and pr.status <> 'cancelled' and (pr.t at time zone tz)::date between p_from and p_to),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'no', x.no, 'at', x.at, 'amount', x.amount, 'note', x.note, 'status', x.status, 'by_name', x.by_name,
        'paid_usd', x.paid_usd, 'paid_cdf', x.paid_cdf, 'usd_rate', x.usd_rate, 'change_cdf', x.change_cdf,
        'cancel_reason', x.cancel_reason) order by x.at desc), '[]')
      from vendeur_payments x where x.vendeur_id = v.id and (x.at at time zone tz)::date between p_from and p_to),
    'state', app.vendeur_state(v)
  ) into res;
  return res;
end $$;

revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
