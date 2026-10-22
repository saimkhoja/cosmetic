-- SIM: two exchange rates.
--   rate      = the SALES rate (taux de vente): shop prices, tickets, tills, invoices and the sales they collect
--   book_rate = the INTERNAL rate (taux interne): supplier bills and payments, expenses, vouchers (for example
--               cash taken from the shops) and opening balances
-- The internal rate starts equal to today's rate, so nothing changes until the Admin edits it.
-- Already running SIM? Run this file once, after 20261020000001_cash_change.sql; it keeps your data.

alter table public.settings add column if not exists book_rate numeric(12,2);
update public.settings set book_rate = rate where book_rate is null;
alter table public.settings alter column book_rate set not null;
alter table public.settings drop constraint if exists settings_book_rate_check;
alter table public.settings add constraint settings_book_rate_check check (book_rate > 0);

-- ---------- settings: both rates ----------
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
  foreach k in array array['customer_optional','barcode','till_sells','cash_change'] loop
    fe := fe || jsonb_build_object(k, coalesce((p->'features'->>k)::boolean, false));
  end loop;
  select rate, book_rate into old, old_br from settings where id = 1 for update;
  br := coalesce(br, old_br);   -- an older app that does not send the internal rate keeps it as it is
  update settings set rate = r, book_rate = br, vat = v, company = c, features = fe, updated_at = now() where id = 1;
  if old <> r then perform app.log(u, format('Sales rate changed %s to %s', old, r)); end if;
  if old_br <> br then perform app.log(u, format('Internal rate changed %s to %s', old_br, br)); end if;
  if old = r and old_br = br then perform app.log(u, 'Settings updated'); end if;
end $$;

-- one rate at a time, for the quick edit on the Items page: p_kind 'sales' or 'book'
create or replace function public.save_rate(p_kind text, p_rate numeric) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); old numeric;
begin
  if p_rate is null or p_rate <= 0 then raise exception 'Enter a valid exchange rate'; end if;
  if p_kind = 'sales' then
    select rate into old from settings where id = 1 for update;
    update settings set rate = p_rate, updated_at = now() where id = 1;
    if old <> p_rate then perform app.log(u, format('Sales rate changed %s to %s', old, p_rate)); end if;
  elsif p_kind = 'book' then
    select book_rate into old from settings where id = 1 for update;
    update settings set book_rate = p_rate, updated_at = now() where id = 1;
    if old <> p_rate then perform app.log(u, format('Internal rate changed %s to %s', old, p_rate)); end if;
  else
    raise exception 'Unknown rate';
  end if;
end $$;

-- a new installation starts with both rates equal
create or replace function public.app_setup(p_user uuid, p_username text, p_name text, p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles; s jsonb;
begin
  if exists (select 1 from profiles) then raise exception 'SIM is already set up'; end if;
  perform pg_advisory_xact_lock(4242);
  if exists (select 1 from profiles) then raise exception 'SIM is already set up'; end if;
  insert into profiles (id, username, name, role, must_change_password) values (p_user, lower(p_username), btrim(p_name), 'admin', false)
  returning * into u;
  update settings set rate = coalesce(app.num(p->>'rate'), rate), book_rate = coalesce(app.num(p->>'book_rate'), app.num(p->>'rate'), book_rate), vat = coalesce(app.num(p->>'vat'), vat),
    company = coalesce(p->'company', '{}'::jsonb), updated_at = now() where id = 1;
  for s in select * from jsonb_array_elements(coalesce(p->'shops','[]'::jsonb)) loop
    insert into shops (code, name, address) values (upper(btrim(s->>'code')), btrim(s->>'name'), btrim(coalesce(s->>'address','')));
  end loop;
  perform app.log(u, 'SIM set up, Admin account created');
end $$;

-- ---------- the internal rate is the default for everything that is not a sale ----------
-- voucher lines without a rate (sales vouchers always carry the invoice's own rate)
create or replace function app.post(p_type text, p_date date, p_narr text, p_ref text, p_src_type text, p_src uuid, p_lines jsonb, p_by text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare vid uuid; l jsonb; acc uuid; amt numeric; cur text; r numeric; dr numeric := 0; cr numeric := 0; b numeric; def_rate numeric;
begin
  select book_rate into def_rate from settings where id = 1;
  if p_src is not null then
    select id into vid from vouchers where source_type = p_src_type and source_id = p_src and status = 'posted';
  end if;
  if vid is null then
    insert into vouchers (type, no, date, narration, ref, source_type, source_id, created_by_name)
      values (p_type, app.next_no(p_type), p_date, left(coalesce(p_narr,''), 200), left(coalesce(p_ref,''), 60), p_src_type, p_src, p_by) returning id into vid;
  else
    update vouchers set date = p_date, narration = left(coalesce(p_narr,''), 200), ref = left(coalesce(p_ref,''), 60) where id = vid;
    delete from voucher_lines where voucher_id = vid;
  end if;
  for l in select * from jsonb_array_elements(p_lines) loop
    amt := round(app.num(l->>'amount'), 2);
    if amt is null or amt = 0 then continue; end if;
    if amt < 0 then raise exception 'Amounts must be positive'; end if;
    acc := coalesce((l->>'account')::uuid, app.acc(l->>'code'));
    if not exists (select 1 from accounts where id = acc and active) then raise exception 'One of the ledgers is not active'; end if;
    cur := coalesce(l->>'currency', 'USD');
    if cur not in ('USD','FC') then raise exception 'Currency must be USD or FC'; end if;
    r := coalesce(app.num(l->>'rate'), def_rate);
    if r <= 0 then raise exception 'Exchange rate must be above zero'; end if;
    b := case when cur = 'USD' then amt else amt / r end;
    if l->>'side' not in ('Dr','Cr') then raise exception 'Each line must be Dr or Cr'; end if;
    insert into voucher_lines (voucher_id, account_id, side, amount, currency, rate, base, memo, bill_ref, due_date)
      values (vid, acc, l->>'side', amt, cur, r, b, left(coalesce(l->>'memo',''), 120), nullif(l->>'bill_ref',''), (l->>'due_date')::date);
    if l->>'side' = 'Dr' then dr := dr + b; else cr := cr + b; end if;
  end loop;
  if dr = 0 and cr = 0 then
    -- nothing to book: drop an empty voucher that was just made for this source
    delete from vouchers where id = vid and not exists (select 1 from voucher_lines where voucher_id = vid);
    return null;
  end if;
  if abs(dr - cr) > 0.011 then raise exception 'Debit and credit are not equal (Dr % USD, Cr % USD)', round(dr, 2), round(cr, 2); end if;
  return vid;
end $$;

create or replace function public.enter_bill(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); g public.grns; sup public.suppliers; cur text := coalesce(p->>'currency', 'USD');
  r numeric := app.num(p->>'rate'); amt numeric := app.num(p->>'amount'); vat numeric := coalesce(app.num(p->>'vat'), 0);
  bdate date := coalesce((p->>'bill_date')::date, current_date); due date; bno text := btrim(coalesce(p->>'bill_no','')); std numeric := 0;
  base_total numeric; diff numeric; lines jsonb; vid uuid; debit uuid := (p->>'account_id')::uuid;
begin
  if (p->>'grn_id') is not null then
    select * into g from grns where id = (p->>'grn_id')::uuid for update;
    if not found then raise exception 'Goods receipt not found'; end if;
    if g.status <> 'awaiting_bill' then raise exception 'The bill for % was already entered', g.no; end if;
    select * into sup from suppliers where id = g.supplier_id;
    select coalesce(sum(qty * std_cost_usd), 0) into std from grn_items where grn_id = g.id;
  else
    select * into sup from suppliers where id = (p->>'supplier_id')::uuid;
    if not found then raise exception 'Choose the supplier'; end if;
    if debit is null or not exists (select 1 from accounts where id = debit and active) then raise exception 'Choose what the bill is for (the ledger to charge)'; end if;
  end if;
  if bno = '' then raise exception 'Enter the supplier''s bill number'; end if;
  if amt is null or amt <= 0 then raise exception 'Enter the bill amount'; end if;
  if vat < 0 then raise exception 'VAT cannot be negative'; end if;
  if cur not in ('USD','FC') then raise exception 'Currency must be USD or FC'; end if;
  r := coalesce(r, (select book_rate from settings where id = 1));
  if r <= 0 then raise exception 'Exchange rate must be above zero'; end if;
  due := coalesce((p->>'due_date')::date, bdate + sup.credit_days);
  base_total := case when cur = 'USD' then amt + vat else (amt + vat) / r end;
  lines := jsonb_build_array(jsonb_build_object('account', sup.account_id, 'side', 'Cr', 'amount', amt + vat, 'currency', cur, 'rate', r,
             'bill_ref', bno, 'due_date', due, 'memo', 'Bill ' || bno),
           jsonb_build_object('code', 'VAT_IN', 'side', 'Dr', 'amount', vat, 'currency', cur, 'rate', r, 'memo', 'VAT on bill ' || bno));
  if g.id is not null then
    -- goods valued at their item cost go to GRNI; the difference with the bill goes to purchase price difference
    diff := (base_total - case when cur = 'USD' then vat else vat / r end) - round(std, 2);
    lines := lines || jsonb_build_array(jsonb_build_object('code', 'GRNI', 'side', 'Dr', 'amount', round(std, 2), 'memo', g.no),
      jsonb_build_object('code', 'PPV', 'side', case when diff >= 0 then 'Dr' else 'Cr' end, 'amount', round(abs(diff), 2), 'memo', 'Bill vs item cost, ' || g.no));
  else
    lines := lines || jsonb_build_array(jsonb_build_object('account', debit, 'side', 'Dr', 'amount', amt, 'currency', cur, 'rate', r, 'memo', coalesce(p->>'narration','')));
  end if;
  vid := app.post('purchase', bdate, 'Bill ' || bno || ' from ' || sup.name || coalesce(', ' || g.no, '') || coalesce(', ' || nullif(btrim(p->>'narration'), ''), ''),
    bno, 'bill', coalesce(g.id, gen_random_uuid()), lines, u.name);
  if g.id is not null then update grns set status = 'billed', bill_voucher_id = vid where id = g.id; end if;
  perform app.log(u, format('Bill %s from %s entered: %s %s, due %s', bno, sup.name, amt + vat, cur, due));
  return jsonb_build_object('voucher_id', vid, 'due_date', due);
end $$;

create or replace function public.add_upkeep(p_date date, p_category text, p_desc text, p_amount numeric, p_currency text default 'USD', p_from uuid default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); acc uuid; usd numeric; r numeric;
begin
  if p_date is null or p_date > current_date + 1 then raise exception 'Choose a date'; end if;
  if length(btrim(coalesce(p_desc,''))) = 0 then raise exception 'Describe the expense'; end if;
  if coalesce(p_amount,0) <= 0 then raise exception 'Enter an amount above zero'; end if;
  if coalesce(p_currency,'USD') not in ('USD','FC') then raise exception 'Currency must be USD or FC'; end if;
  select book_rate into r from settings where id = 1;
  usd := case when p_currency = 'FC' then p_amount / r else p_amount end;
  acc := app.acc(case btrim(p_category) when 'Rent' then 'EXP_RENT' when 'Electricity & fuel' then 'EXP_POWER' when 'Security' then 'EXP_SECURITY'
    when 'Salaries' then 'EXP_SALARIES' when 'Transport' then 'EXP_TRANSPORT' when 'Maintenance' then 'EXP_MAINT' when 'Taxes & licences' then 'EXP_TAXES' else 'EXP_OTHER' end);
  if p_from is not null and not exists (select 1 from accounts where id = p_from and group_code in ('cash','bank') and active) then raise exception 'Pay from a cash or bank ledger'; end if;
  insert into upkeep (date, category, description, amount_usd, by_name) values (p_date, left(btrim(p_category),40), left(btrim(p_desc),80), round(usd, 2), u.name);
  perform app.post('payment', p_date, btrim(p_category) || ': ' || btrim(p_desc), '', null, null,
    jsonb_build_array(jsonb_build_object('account', acc, 'side', 'Dr', 'amount', p_amount, 'currency', coalesce(p_currency,'USD'), 'rate', r),
                      jsonb_build_object('account', coalesce(p_from, app.acc('CASH_HO')), 'side', 'Cr', 'amount', p_amount, 'currency', coalesce(p_currency,'USD'), 'rate', r)), u.name);
  perform app.log(u, format('Expense %s: %s %s', btrim(p_category), p_amount, coalesce(p_currency,'USD')));
end $$;

create or replace function public.save_supplier(p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); sid uuid := (p->>'id')::uuid; n text := btrim(coalesce(p->>'name','')); s public.suppliers;
  aid uuid; oa numeric := coalesce(app.num(p->>'opening_amount'), 0); ocur text := coalesce(p->>'opening_currency', 'USD');
  orate numeric := app.num(p->>'opening_rate'); oside text := coalesce(p->>'opening_side', 'Cr');
begin
  if n = '' then raise exception 'Enter the supplier name'; end if;
  if exists (select 1 from suppliers where lower(name) = lower(n) and id is distinct from sid) then raise exception 'Supplier "%" already exists', n; end if;
  if coalesce(app.num(p->>'credit_days'), 30) < 0 or coalesce(app.num(p->>'credit_days'), 30) > 365 then raise exception 'Credit days must be 0 to 365'; end if;
  if oa < 0 then raise exception 'Opening balance cannot be negative; choose Dr or Cr'; end if;
  if ocur = 'FC' and coalesce(orate, 0) <= 0 then select book_rate into orate from settings where id = 1; end if;
  if sid is null then
    if exists (select 1 from accounts where lower(name) = lower(n)) then raise exception 'A ledger called "%" already exists', n; end if;
    insert into accounts (name, group_code, currency, opening_amount, opening_side, opening_currency, opening_rate, system)
      values (n, 'creditors', coalesce(p->>'currency','USD'), oa, oside, ocur, orate, false) returning id into aid;
    insert into suppliers (name, contact, phone, email, address, tax_no, credit_days, credit_limit, currency, notes, account_id)
      values (n, coalesce(p->>'contact',''), coalesce(p->>'phone',''), coalesce(p->>'email',''), coalesce(p->>'address',''), coalesce(p->>'tax_no',''),
        coalesce(app.num(p->>'credit_days'), 30)::int, coalesce(app.num(p->>'credit_limit'), 0), coalesce(p->>'currency','USD'), coalesce(p->>'notes',''), aid)
      returning id into sid;
    update accounts set supplier_id = sid where id = aid;
    perform app.log(u, 'Added supplier ' || n);
  else
    select * into s from suppliers where id = sid for update;
    if not found then raise exception 'Supplier not found'; end if;
    if exists (select 1 from accounts where lower(name) = lower(n) and id <> s.account_id) then raise exception 'A ledger called "%" already exists', n; end if;
    update suppliers set name = n, contact = coalesce(p->>'contact',''), phone = coalesce(p->>'phone',''), email = coalesce(p->>'email',''),
      address = coalesce(p->>'address',''), tax_no = coalesce(p->>'tax_no',''), credit_days = coalesce(app.num(p->>'credit_days'), 30)::int,
      credit_limit = coalesce(app.num(p->>'credit_limit'), 0), currency = coalesce(p->>'currency','USD'), notes = coalesce(p->>'notes',''),
      active = coalesce((p->>'active')::boolean, active) where id = sid;
    update accounts set name = n, currency = coalesce(p->>'currency','USD'), opening_amount = oa, opening_side = oside, opening_currency = ocur, opening_rate = orate
      where id = s.account_id;
    perform app.log(u, 'Updated supplier ' || n);
  end if;
  if p ? 'items' then
    delete from supplier_items where supplier_id = sid;
    insert into supplier_items (supplier_id, product_id) select sid, (x)::uuid from jsonb_array_elements_text(p->'items') x
      where exists (select 1 from products where id = (x)::uuid) on conflict do nothing;
  end if;
  return sid;
end $$;

create or replace function public.save_account(p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); aid uuid := (p->>'id')::uuid; a public.accounts; n text := btrim(coalesce(p->>'name',''));
  g text := p->>'group_code'; oa numeric := coalesce(app.num(p->>'opening_amount'), 0); ocur text := coalesce(p->>'opening_currency','USD'); orate numeric := app.num(p->>'opening_rate');
begin
  if n = '' then raise exception 'Enter the ledger name'; end if;
  if exists (select 1 from accounts where lower(name) = lower(n) and id is distinct from aid) then raise exception 'A ledger called "%" already exists', n; end if;
  if oa < 0 then raise exception 'Opening balance cannot be negative; choose Dr or Cr'; end if;
  if ocur = 'FC' and coalesce(orate,0) <= 0 then select book_rate into orate from settings where id = 1; end if;
  if aid is null then
    if not exists (select 1 from account_groups where code = g) then raise exception 'Choose the group'; end if;
    if g = 'creditors' then raise exception 'Suppliers are added under Suppliers, which also makes their ledger'; end if;
    insert into accounts (name, group_code, currency, opening_amount, opening_side, opening_currency, opening_rate)
      values (n, g, coalesce(p->>'currency','USD'), oa, coalesce(p->>'opening_side','Dr'), ocur, orate) returning id into aid;
    perform app.log(u, 'Added ledger ' || n);
  else
    select * into a from accounts where id = aid for update;
    if not found then raise exception 'Ledger not found'; end if;
    if a.supplier_id is not null then raise exception 'Edit this ledger from the supplier'; end if;
    update accounts set name = n, group_code = case when a.system then a.group_code else coalesce(g, a.group_code) end, currency = coalesce(p->>'currency', a.currency),
      opening_amount = oa, opening_side = coalesce(p->>'opening_side','Dr'), opening_currency = ocur, opening_rate = orate,
      active = case when a.system then true else coalesce((p->>'active')::boolean, a.active) end where id = aid;
    perform app.log(u, 'Updated ledger ' || n);
  end if;
  return aid;
end $$;

-- ---------- who may call what ----------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.save_settings(jsonb), public.save_rate(text, numeric), public.enter_bill(jsonb),
  public.save_supplier(jsonb), public.save_account(jsonb), public.add_upkeep(date, text, text, numeric, text, uuid) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
grant execute on function public.app_setup(uuid, text, text, jsonb) to service_role;
