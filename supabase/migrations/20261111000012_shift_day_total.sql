-- QuickSales: from the second shift of the day, the shift end report shows the total of the day.
-- Printing shift 2 (or 3, ...) keeps, inside the slip, today's shift slips added up for the same choice (all tills
-- together, or the one till), and the slip prints them as one line, "Total of the day". It is the slips that are
-- added, not the sales counted again, so the total agrees with the slips the cashier already holds.
-- It is kept inside the slip, so a shift printed again shows the day as it stood when that shift was printed.
-- The first shift of the day has no such line: it would repeat the shift's own figure.
-- Already running QuickSales? Run this file once, after 20261111000011_keep_switches.sql. It changes no data.

-- stop at once if the update before this one was not run
do $$ begin
  if not exists (select 1 from pg_proc where proname = 'save_settings' and pg_get_functiondef(oid) like '%cur->>k%') then
    raise exception 'Run supabase/migrations/20261111000011_keep_switches.sql (and every earlier file) first, then this file. supabase/scripts/check_migrations.sql shows what is missing';
  end if;
end $$;

create or replace function public.shift_end_report(p_code text, p_action text default 'close', p_device uuid default null, p_day date default null, p_shift uuid default null) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); err text; tz text; dv public.devices; today date; prev timestamptz; fr timestamptz; t2 timestamptz := now();
  sc public.shift_closes; n int; sl jsonb; what text; dsum jsonb;
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

-- ---------- who may call what ----------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.shift_end_report(text, text, uuid, date, uuid) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
