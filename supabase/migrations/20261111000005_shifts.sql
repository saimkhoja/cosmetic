-- QuickSales: shift end reports, combined or per till.
-- A supermarket works in shifts. Printing today's shift end report closes the shift: the next shift end report
-- starts fresh, with the sales made after it. The sales report, Sales today and the Admin's reports keep counting
-- the whole day, every shift together.
--   Combined (the default): every till of the shop. Per till: one till only (Till T1, T2...). Each has its own
--   shifts: printing Till T1's report starts a new shift for Till T1 only, and the combined report keeps its own.
--   A shift holds the sales that reached the server since the last shift end report of the same choice (since the
--   start of the day for the first one), so a sale sent late from a till that was offline goes in the next shift
--   instead of being missed. Invoice corrections count in the shift they were made in: money given back or
--   collected by an edit shows in that shift's Return and Collected.
--   A printed shift can be printed again, the same as it was (Reprint); a past day prints the whole day as before.
-- The Shift end report passcode from the Admin is needed for all of these.
-- Already running QuickSales? Run this file once, after 20261111000004_till_discount.sql, BEFORE the new app goes live.

-- stop at once if the update before this one was not run
do $$ begin
  if not exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = 'discount_grants') then
    raise exception 'Run supabase/migrations/20261111000004_till_discount.sql (and every earlier file) first, then this file. supabase/scripts/check_migrations.sql shows what is missing';
  end if;
end $$;

-- each printed shift end report: what it covered and the slip as printed, so it can be printed again unchanged
create table if not exists public.shift_closes (
  id          uuid primary key default gen_random_uuid(),
  shop_id     uuid not null references public.shops(id),
  device_id   uuid references public.devices(id),          -- null: every till of the shop (combined)
  day         date not null,                                -- the shop's day it was printed on
  shift_no    int not null,                                 -- 1, 2... that day, for this choice
  from_at     timestamptz not null,
  to_at       timestamptz not null,
  slip        jsonb not null,
  closed_by   uuid,
  closed_by_name text not null,
  created_at  timestamptz not null default now()
);
create index if not exists shift_closes_scope on public.shift_closes (shop_id, device_id, to_at desc);
alter table public.shift_closes enable row level security;
revoke all on public.shift_closes from anon, authenticated;
-- the list of printed shifts (no amounts: those come with the passcode)
grant select (id, shop_id, device_id, day, shift_no, from_at, to_at, closed_by_name, created_at) on public.shift_closes to authenticated;
drop policy if exists read_shift_closes on public.shift_closes;
create policy read_shift_closes on public.shift_closes for select to authenticated
  using (app.my_role() = 'admin' or (app.my_role() = 'shopadmin' and shop_id = app.my_shop()));

-- the slip of one shift: sales that reached the server in (p_from, p_to], and corrections made in that time
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
      (select coalesce(sum(round((paid_usd - change_usd) * rate)), 0) from inv) usd_in_cdf
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

-- ---------- who may call what ----------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.shift_end_report(text, text, uuid, date, uuid) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
