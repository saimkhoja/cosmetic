-- QuickSales: more expense types in Store upkeep, and the Admin can correct an expense after saving it.
-- Eight new types, each with its own ledger under Indirect expenses so the profit and loss shows them apart:
-- Miscellaneous expense, Journalier (labour), Moto expense, Local staff salary, Stationery, Food expense,
-- Local transport and Overtime.
-- Editing an expense (date, type, description, amount, currency, paid from) corrects its payment voucher in place:
-- same voucher number, the new lines. To do that each expense now keeps its voucher; expenses saved before this update
-- are matched to the voucher they made (same date, text, amount and the moment it was saved). An expense whose
-- voucher was cancelled in Accounts, or that has none, is not edited: it is recorded again instead.
-- Already running QuickSales? Run this file once, after 20261126000001_vendeur_usd.sql. It changes no amounts.

-- stop at once if the update before this one was not run
do $$ begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'vendeur_payments' and column_name = 'paid_usd') then
    raise exception 'Run supabase/migrations/20261126000001_vendeur_usd.sql (and every earlier file) first, then this file. supabase/scripts/check_migrations.sql shows what is missing';
  end if;
end $$;

-- ---------- a ledger for each new type ----------
-- a business that already made a ledger with the same name keeps it; the new one is named "… (upkeep)"
do $$
declare x record; nm text;
begin
  for x in select * from (values
      ('EXP_MISC', 'Miscellaneous expenses'), ('EXP_LABOUR', 'Journalier (labour)'), ('EXP_MOTO', 'Moto expenses'),
      ('EXP_LOCAL_SALARY', 'Local staff salaries'), ('EXP_STATIONERY', 'Stationery'), ('EXP_FOOD', 'Food expenses'),
      ('EXP_LOCAL_TRANSPORT', 'Local transport'), ('EXP_OVERTIME', 'Overtime')) as t(code, name)
  loop
    if exists (select 1 from accounts where code = x.code) then continue; end if;
    nm := x.name;
    if exists (select 1 from accounts where lower(name) = lower(nm)) then nm := nm || ' (upkeep)'; end if;
    insert into accounts (code, name, group_code, currency, system) values (x.code, nm, 'indexp', 'USD', true);
  end loop;
end $$;

-- the ledger an expense type is booked to; an unknown type goes to Other expenses
create or replace function app.upkeep_acc(p_category text) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select app.acc(case btrim(p_category)
    when 'Rent' then 'EXP_RENT' when 'Electricity & fuel' then 'EXP_POWER' when 'Security' then 'EXP_SECURITY'
    when 'Salaries' then 'EXP_SALARIES' when 'Transport' then 'EXP_TRANSPORT' when 'Maintenance' then 'EXP_MAINT' when 'Taxes & licences' then 'EXP_TAXES'
    when 'Miscellaneous expense' then 'EXP_MISC' when 'Journalier (labour)' then 'EXP_LABOUR' when 'Moto expense' then 'EXP_MOTO'
    when 'Local staff salary' then 'EXP_LOCAL_SALARY' when 'Stationery' then 'EXP_STATIONERY' when 'Food expense' then 'EXP_FOOD'
    when 'Local transport' then 'EXP_LOCAL_TRANSPORT' when 'Overtime' then 'EXP_OVERTIME'
    else 'EXP_OTHER' end)
$$;

-- ---------- each expense keeps how it was paid and its voucher ----------
alter table public.upkeep add column if not exists amount numeric(14,2);          -- as typed, in its currency
alter table public.upkeep add column if not exists currency text check (currency in ('USD','FC'));
alter table public.upkeep add column if not exists rate numeric(12,2);            -- the internal rate it was booked at
alter table public.upkeep add column if not exists from_id uuid references public.accounts(id);
alter table public.upkeep add column if not exists voucher_id uuid references public.vouchers(id);
alter table public.upkeep add column if not exists edited_by_name text;
alter table public.upkeep add column if not exists edited_at timestamptz;

-- expenses saved before: find the payment voucher each one made (same date, text, by, amount; the nearest in time,
-- within a minute, so two identical expenses each get their own)
do $$
declare u record; v record;
begin
  for u in select * from upkeep where voucher_id is null order by at loop
    select vo.id, dr.amount, dr.currency, dr.rate, cr.account_id as from_id into v
      from vouchers vo
      join voucher_lines dr on dr.voucher_id = vo.id and dr.side = 'Dr'
      join voucher_lines cr on cr.voucher_id = vo.id and cr.side = 'Cr'
      where vo.type = 'payment' and vo.source_id is null and vo.date = u.date and vo.created_by_name = u.by_name
        and vo.narration = left(btrim(u.category) || ': ' || btrim(u.description), 200)
        and abs(dr.base - u.amount_usd) < 0.011
        and abs(extract(epoch from vo.created_at - u.at)) < 60
        and not exists (select 1 from upkeep x where x.voucher_id = vo.id)
        and (select count(*) from voucher_lines l where l.voucher_id = vo.id) = 2
      order by abs(extract(epoch from vo.created_at - u.at)) limit 1;
    if v.id is null then continue; end if;
    update upkeep set voucher_id = v.id, amount = v.amount, currency = v.currency, rate = v.rate, from_id = v.from_id where id = u.id;
    -- the voucher now follows the expense, like the vouchers of invoices and deliveries
    update vouchers set source_type = 'upkeep', source_id = u.id where id = v.id;
  end loop;
end $$;

-- ---------- recording an expense ----------
create or replace function public.add_upkeep(p_date date, p_category text, p_desc text, p_amount numeric, p_currency text default 'USD', p_from uuid default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); acc uuid; r numeric; cur text := coalesce(p_currency, 'USD'); amt numeric := round(p_amount, 2);
  uid uuid := gen_random_uuid(); vid uuid; frm uuid;
begin
  if p_date is null or p_date > current_date + 1 then raise exception 'Choose a date'; end if;
  if length(btrim(coalesce(p_category,''))) = 0 then raise exception 'Choose the type of expense'; end if;
  if length(btrim(coalesce(p_desc,''))) = 0 then raise exception 'Describe the expense'; end if;
  if coalesce(amt,0) <= 0 then raise exception 'Enter an amount above zero'; end if;
  if cur not in ('USD','FC') then raise exception 'Currency must be USD or FC'; end if;
  if p_from is not null and not exists (select 1 from accounts where id = p_from and group_code in ('cash','bank') and active) then raise exception 'Pay from a cash or bank ledger'; end if;
  select book_rate into r from settings where id = 1;
  acc := app.upkeep_acc(p_category); frm := coalesce(p_from, app.acc('CASH_HO'));
  insert into upkeep (id, date, category, description, amount_usd, by_name, amount, currency, rate, from_id)
    values (uid, p_date, left(btrim(p_category),40), left(btrim(p_desc),80), round(case when cur = 'FC' then amt / r else amt end, 2), u.name, amt, cur, r, frm);
  vid := app.post('payment', p_date, btrim(p_category) || ': ' || btrim(p_desc), '', 'upkeep', uid,
    jsonb_build_array(jsonb_build_object('account', acc, 'side', 'Dr', 'amount', amt, 'currency', cur, 'rate', r),
                      jsonb_build_object('account', frm, 'side', 'Cr', 'amount', amt, 'currency', cur, 'rate', r)), u.name);
  update upkeep set voucher_id = vid where id = uid;
  perform app.log(u, format('Expense %s: %s %s', btrim(p_category), amt, cur));
end $$;

-- ---------- correcting an expense: the same record and the same voucher, with the new figures ----------
create or replace function public.edit_upkeep(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); x public.upkeep; vs text;
  d date := (p->>'date')::date; cat text := btrim(coalesce(p->>'category', '')); dsc text := btrim(coalesce(p->>'description', ''));
  amt numeric := round(app.num(p->>'amount'), 2); cur text := coalesce(p->>'currency', 'USD'); frm uuid := nullif(p->>'from_id', '')::uuid;
  r numeric; was text; now_ text; vid uuid;
begin
  select * into x from upkeep where id = (p->>'id')::uuid for update;
  if not found then raise exception 'Expense not found'; end if;
  if x.voucher_id is null then raise exception 'This expense was saved before expenses could be corrected and no payment voucher was found for it. Record it again, and cancel the old payment under Accounts if it was booked'; end if;
  select status into vs from vouchers where id = x.voucher_id;
  if vs is distinct from 'posted' then raise exception 'The payment voucher of this expense was cancelled in Accounts, so it cannot be corrected. Record the expense again instead'; end if;
  if d is null or d > current_date + 1 then raise exception 'Choose a date'; end if;
  if cat = '' then raise exception 'Choose the type of expense'; end if;
  if dsc = '' then raise exception 'Describe the expense'; end if;
  if coalesce(amt, 0) <= 0 then raise exception 'Enter an amount above zero'; end if;
  if cur not in ('USD','FC') then raise exception 'Currency must be USD or FC'; end if;
  frm := coalesce(frm, app.acc('CASH_HO'));
  if not exists (select 1 from accounts where id = frm and group_code in ('cash','bank') and active) then raise exception 'Pay from a cash or bank ledger'; end if;
  -- the rate the expense was booked at stays, so correcting a typo does not revalue it
  r := coalesce(x.rate, (select book_rate from settings where id = 1));
  was := format('%s, %s, %s: %s %s from %s', to_char(x.date, 'DD/MM/YYYY'), x.category, x.description, x.amount, x.currency, (select name from accounts where id = x.from_id));
  now_ := format('%s, %s, %s: %s %s from %s', to_char(d, 'DD/MM/YYYY'), left(cat, 40), left(dsc, 80), amt, cur, (select name from accounts where id = frm));
  if was = now_ then raise exception 'Nothing was changed'; end if;
  vid := app.post('payment', d, cat || ': ' || dsc, '', 'upkeep', x.id,
    jsonb_build_array(jsonb_build_object('account', app.upkeep_acc(cat), 'side', 'Dr', 'amount', amt, 'currency', cur, 'rate', r),
                      jsonb_build_object('account', frm, 'side', 'Cr', 'amount', amt, 'currency', cur, 'rate', r)), u.name);
  update upkeep set date = d, category = left(cat, 40), description = left(dsc, 80), amount = amt, currency = cur, rate = r, from_id = frm,
      amount_usd = round(case when cur = 'FC' then amt / r else amt end, 2), voucher_id = vid, edited_by_name = u.name, edited_at = now()
    where id = x.id;
  perform app.log(u, format('Expense corrected (voucher %s): was %s; now %s', (select no from vouchers where id = vid), was, now_));
end $$;

revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.edit_upkeep(jsonb) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
