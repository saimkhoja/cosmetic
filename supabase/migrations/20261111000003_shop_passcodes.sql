-- QuickSales: passcodes the Admin gives to a Shop Admin.
--   Invoices: the Shop Admin's Invoices tab is locked. With the Invoices passcode it opens and lists every invoice
--     of the shop, also those above the limit on the sales shown (347 USD), to view, edit, delete or reprint as usual.
--     It locks again when the Shop Admin leaves the tab, and after 30 minutes at the latest.
--   Shift end report: printing the day end (shift end) report needs the Shift end report passcode. The printed slip
--     then has every sale of the day, so it matches the cash in the drawer.
-- The sales figures on the Shop Admin's screens (Sales today, the Sales report) keep the limit. Nothing changes for
-- the Admin, who sets, changes or removes the passcodes under Users. Passcodes are 4 to 12 digits, kept only as
-- hashes; 5 wrong tries block that passcode for 10 minutes. Until the Admin sets a passcode, the tab or the report
-- stays locked.
-- Already running QuickSales? Run this file once, after 20261111000002_shop_sales_limit.sql, BEFORE the new app goes live.

-- stop at once if the update before this one was not run
do $$ begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'settings' and column_name = 'shop_sales_limit_usd') then
    raise exception 'Run supabase/migrations/20261111000002_shop_sales_limit.sql (and every earlier file) first, then this file. supabase/scripts/check_migrations.sql shows what is missing';
  end if;
end $$;

create table if not exists public.shop_passcodes (
  user_id       uuid not null references public.profiles(id) on delete cascade,
  kind          text not null check (kind in ('invoices', 'day_end')),
  hash          text not null,
  set_at        timestamptz not null default now(),
  set_by_name   text not null default '',
  fails         int not null default 0,          -- wrong tries in a row
  blocked_until timestamptz,                     -- after 5 wrong tries
  open_until    timestamptz,                     -- invoices: opened with the passcode until then
  primary key (user_id, kind)
);
alter table public.shop_passcodes enable row level security;
revoke all on public.shop_passcodes from anon, authenticated;
-- the Admin sees which passcodes are set and when, never the passcode
grant select (user_id, kind, set_at, set_by_name) on public.shop_passcodes to authenticated;
drop policy if exists read_shop_passcodes on public.shop_passcodes;
create policy read_shop_passcodes on public.shop_passcodes for select to authenticated using (app.my_role() = 'admin');

-- the Admin sets or changes a Shop Admin's passcode; an empty passcode removes it (locked until a new one is set)
create or replace function public.set_passcode(p_user uuid, p_kind text, p_code text) returns void
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare u public.profiles := app.req('admin'); t public.profiles; c text := btrim(coalesce(p_code, ''));
  what text := case p_kind when 'invoices' then 'Invoices' when 'day_end' then 'Shift end report' end;
begin
  if what is null then raise exception 'Unknown passcode'; end if;
  select * into t from profiles where id = p_user;
  if t.id is null or t.role <> 'shopadmin' then raise exception 'Passcodes are for Shop Admin logins'; end if;
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

-- checks a passcode: null when right, otherwise what to tell the user. Wrong tries are counted, so callers return
-- the message instead of raising it (an error would undo the count).
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
    perform app.log(u, format('%s passcode blocked for 10 minutes after 5 wrong tries', case p_kind when 'invoices' then 'Invoices' else 'Shift end report' end));
    return 'Wrong passcode. Too many wrong tries: blocked for 10 minutes';
  end if;
  update shop_passcodes set fails = r.fails + 1 where user_id = u.id and kind = p_kind;
  return 'Wrong passcode';
end $$;

-- the Shop Admin opens the Invoices tab with the passcode, for 30 minutes at most
create or replace function public.open_invoices(p_code text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); err text; till timestamptz := now() + interval '30 minutes';
begin
  err := app.check_passcode(u, 'invoices', p_code);
  if err is not null then return jsonb_build_object('ok', false, 'error', err); end if;
  update shop_passcodes set open_until = till where user_id = u.id and kind = 'invoices';
  perform app.log(u, 'Invoices opened with the passcode');
  return jsonb_build_object('ok', true, 'until', till);
end $$;
-- and it locks again when they leave the tab
create or replace function public.close_invoices() returns void
language sql security definer set search_path = public, pg_temp as $$
  update public.shop_passcodes set open_until = null where user_id = auth.uid() and kind = 'invoices'
$$;
create or replace function app.invoices_open() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.shop_passcodes where user_id = auth.uid() and kind = 'invoices' and open_until > now())
$$;
grant execute on function app.invoices_open() to authenticated, service_role;

-- the Shop Admin reads every invoice of the shop while the Invoices tab is open with the passcode; otherwise only
-- those up to the limit on the sales shown. The Admin reads all; a till operator the invoices of their own orders.
drop policy if exists read_invoices on public.invoices;
create policy read_invoices on public.invoices for select to authenticated
  using (app.my_role() = 'admin'
    or (app.my_role() = 'shopadmin' and shop_id = app.my_shop()
      and ((select app.invoices_open())
        or (total / nullif(rate, 0) <= (select s.shop_sales_limit_usd from public.settings s where s.id = 1)) is not false))
    or (app.my_role() = 'till' and order_id in (select o.id from sale_orders o where o.created_by = auth.uid())));

-- the day end (shift end) slip of the Shop Admin's shop, with every sale of the day, for the passcode
create or replace function public.day_end_report(p_day date, p_code text) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); err text; tz text; res jsonb;
begin
  if p_day is null then raise exception 'Choose the day'; end if;
  err := app.check_passcode(u, 'day_end', p_code);
  if err is not null then return jsonb_build_object('ok', false, 'error', err); end if;
  select settings.tz into tz from settings where id = 1;
  with inv as (
    select i.*,
      coalesce((select e.from_total from invoice_edits e where e.invoice_id = i.id order by e.at, e.id limit 1), i.total)
        + (select coalesce(sum(greatest(0, to_total - from_total)),0) from invoice_edits where invoice_id = i.id) as col,
      (select coalesce(sum(greatest(0, from_total - to_total)),0) from invoice_edits where invoice_id = i.id) as ret
    from invoices i
    where i.shop_id = u.shop_id and (i.t at time zone tz)::date = p_day
  )
  select jsonb_build_object('ok', true, 'day', p_day, 'slip', (
      select jsonb_build_object('shop_id', s.id, 'shop_name', s.name, 'code', s.code, 'n', count(inv.id),
        'value_fc', coalesce(sum(inv.total),0), 'value_usd', coalesce(sum(inv.total / inv.rate),0),
        'collected', coalesce(sum(inv.col),0), 'returned', coalesce(sum(inv.ret),0),
        'collected_usd', coalesce(sum(inv.paid_usd - inv.change_usd),0),
        'collected_cdf', coalesce(sum(inv.col - round((inv.paid_usd - inv.change_usd) * inv.rate)),0)::bigint)
      from shops s left join inv on inv.shop_id = s.id where s.id = u.shop_id group by s.id, s.name, s.code)) into res;
  perform app.log(u, format('Shift end report of %s printed with the passcode', to_char(p_day, 'DD/MM/YYYY')));
  return res;
end $$;

-- ---------- who may call what ----------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.set_passcode(uuid, text, text), public.open_invoices(text), public.close_invoices(), public.day_end_report(date, text) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
