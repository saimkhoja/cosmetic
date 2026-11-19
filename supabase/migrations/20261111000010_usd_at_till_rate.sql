-- QuickSales: sales in dollars are counted at the rate the till takes dollars.
-- A shop prices at the sales rate (say 2 350) but gives less for a dollar (say 2 300). A 1 000 000 CDF invoice is
-- then paid with 434.78 dollars, and that is what goes in the drawer. The shift end report, though, printed
-- "Invoice Value USD 425.53", which is the goods valued at 2 350, so it never agreed with "Collected USD 434.79".
-- Now the dollar figures on the shift end report and on the sales report are worked out at each sale's own dollar
-- rate (invoices.usd_rate; sales made before it was kept fall back to the sales rate). The slip's Invoice Value USD
-- then ties with Collected USD, and the Admin's sales in dollars match the cash the day is worth.
-- The Francs are untouched, and so is the gross profit, which stays on the books' own basis: the books value a sale
-- at the sales rate and carry the difference as Exchange gain on dollars.
-- Already running QuickSales? Run this file once, after 20261111000009_daily_sales_limit.sql, BEFORE the new app goes live.

-- stop at once if the update before this one was not run
do $$ begin
  if not exists (select 1 from pg_proc where proname = 'sales_report' and pg_get_functiondef(oid) like '%capped%') then
    raise exception 'Run supabase/migrations/20261111000009_daily_sales_limit.sql (and every earlier file) first, then this file. supabase/scripts/check_migrations.sql shows what is missing';
  end if;
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
      (select coalesce(sum(total / coalesce(usd_rate, rate)), 0) from inv) value_usd,   -- the dollars the sales are worth at the till's rate
      (select coalesce(sum(first_total), 0) from inv) + (select coalesce(sum(greatest(0, to_total - from_total)), 0) from ed) collected,
      (select coalesce(sum(greatest(0, from_total - to_total)), 0) from ed) returned,
      (select coalesce(sum(paid_usd - change_usd), 0) from inv) collected_usd,
      (select coalesce(sum(round((paid_usd - change_usd) * coalesce(usd_rate, rate))), 0) from inv) usd_in_cdf
  )
  select jsonb_build_object('shop_id', s.id, 'shop_name', s.name, 'code', s.code, 'n', x.n, 'value_fc', x.value_fc, 'value_usd', x.value_usd,
    'collected', x.collected, 'returned', x.returned, 'collected_usd', x.collected_usd, 'collected_cdf', (x.collected - x.usd_in_cdf)::bigint)
  from shops s, x where s.id = p_shop
$$;

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
        'value_fc', coalesce(sum(inv.total),0), 'value_usd', coalesce(sum(inv.total / coalesce(inv.usd_rate, inv.rate)),0),
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
      coalesce((select e.from_total from invoice_edits e where e.invoice_id = i.id order by e.at, e.id limit 1), i.total)
        + (select coalesce(sum(greatest(0, to_total - from_total)),0) from invoice_edits where invoice_id = i.id) as col,
      (select coalesce(sum(greatest(0, from_total - to_total)),0) from invoice_edits where invoice_id = i.id) as ret,
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

-- ---------- who may call what ----------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.sales_report(date, date, uuid), public.shift_end_report(text, text, uuid, date, uuid) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
