-- QuickSales: vendeurs owe in USD; goods in corrected or deleted, before or after the bill; promo items on cash sales.
-- Already running QuickSales? Run this file once, after 20261201000001_vendeur_opening_usd.sql. It changes no amounts:
-- what vendeurs owed in Francs is shown in dollars at the value the books already gave it.

-- stop at once if the update before this one was not run
do $$ begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'vendeurs' and column_name = 'opening_usd') then
    raise exception 'Run supabase/migrations/20261201000001_vendeur_opening_usd.sql (and every earlier file) first, then this file. supabase/scripts/check_migrations.sql shows what is missing';
  end if;
end $$;

-- ======================= 1. vendeurs: what they owe is kept in USD =======================
-- Each sale on credit counts in dollars at the rate of its sale (its Francs / its rate); dollars paid count one for one,
-- Francs paid at the taux of the payment (the internal rate unless the Shop Admin types another). The credit limit is in
-- dollars. A vendeur's ledger keeps the same value in the books: the payments are booked in USD.
alter table public.vendeurs add column if not exists credit_limit_usd numeric(12,2) not null default 0 check (credit_limit_usd >= 0);
alter table public.vendeurs add column if not exists opening_value_usd numeric(14,4) not null default 0 check (opening_value_usd >= 0);
alter table public.vendeur_payments add column if not exists amount_usd numeric(14,4);
-- what there was before, in dollars: the limit at today's sales rate; the opening and each payment at the value the
-- books gave them (their Francs at their rate), so the balances in USD agree with the ledgers
do $$ declare r numeric; begin
  select rate into r from settings where id = 1;
  if r > 0 then
    update public.vendeurs set credit_limit_usd = round(credit_limit / r, 2) where credit_limit_usd = 0 and credit_limit > 0;
  end if;
end $$;
update public.vendeurs v set opening_value_usd = round(coalesce(app.opening_base(a), 0), 4)
  from public.accounts a where a.id = v.account_id and v.opening_value_usd = 0 and v.opening_balance > 0;
update public.vendeur_payments set amount_usd = round(amount / nullif(rate, 0), 4) where amount_usd is null;

-- how a payment was made: ", $20.00 + 5 000 CDF at 2800, 1 000 CDF given back"
create or replace function app.vp_how(x public.vendeur_payments) returns text
language sql immutable as $$
  select case when x.paid_usd > 0 or x.change_cdf > 0 then ', '
    || concat_ws(' + ', case when x.paid_usd > 0 then app.usd(x.paid_usd) end, case when x.paid_cdf > 0 then app.fc(x.paid_cdf) || ' at ' || trim_scale(x.usd_rate) end)
    || case when x.change_cdf > 0 then ', ' || app.fc(x.change_cdf) || ' given back' else '' end else '' end
$$;

-- what a vendeur owes in USD, what is due and overdue, and the credit left. Payments settle the oldest goods first.
create or replace function app.vendeur_state(vd public.vendeurs) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare tz text; today date; sr numeric; paid numeric; rest numeric; bal numeric; r record; items jsonb := '[]'; od numeric := 0; oldest date; ow numeric;
  lp public.vendeur_payments;
begin
  select settings.tz, rate into tz, sr from settings where id = 1;
  today := (now() at time zone tz)::date;
  select coalesce(sum(amount_usd), 0) into paid from vendeur_payments where vendeur_id = vd.id and status = 'ok';
  rest := round(paid, 2);
  for r in
    select null::uuid as id, 'Opening balance'::text as no, (vd.created_at at time zone tz)::date as d,
      (vd.created_at at time zone tz)::date + vd.credit_days as due, round(vd.opening_value_usd, 2) as amt, vd.opening_balance::bigint as cdf, vd.created_at as t
    where vd.opening_value_usd > 0
    union all
    select i.id, i.no, (i.t at time zone tz)::date, coalesce(i.due_date, (i.t at time zone tz)::date + vd.credit_days), round(i.total / i.rate, 2), i.total, i.t
    from invoices i where i.vendeur_id = vd.id and i.total > 0
    order by t, no
  loop
    if rest >= r.amt then rest := rest - r.amt; continue; end if;
    ow := r.amt - rest; rest := 0;
    items := items || jsonb_build_object('invoice_id', r.id, 'no', r.no, 'date', r.d, 'due', r.due, 'amount', r.amt, 'amount_cdf', r.cdf, 'owed', ow,
      'days_overdue', greatest(today - r.due, 0));
    if oldest is null or r.due < oldest then oldest := r.due; end if;
    if r.due < today then od := od + ow; end if;
  end loop;
  bal := round(vd.opening_value_usd, 2) + coalesce((select sum(round(total / rate, 2)) from invoices where vendeur_id = vd.id), 0) - round(paid, 2);
  select * into lp from vendeur_payments where vendeur_id = vd.id and status = 'ok' order by at desc limit 1;
  return jsonb_build_object('currency', 'USD', 'balance', bal, 'balance_cdf', round(bal * sr), 'credit_limit_usd', vd.credit_limit_usd,
    'available', vd.credit_limit_usd - bal, 'over_limit', bal > vd.credit_limit_usd,
    'overdue', od > 0.004, 'overdue_amount', od, 'oldest_due', oldest,
    'days_overdue', case when oldest is not null and oldest < today then today - oldest else 0 end,
    'open', items,
    'last_payment', case when lp.id is not null then jsonb_build_object('no', lp.no, 'at', lp.at, 'amount', round(lp.amount_usd, 2), 'amount_cdf', lp.amount) end,
    'promo_open', (select coalesce(sum(value), 0) from vendeur_promos where vendeur_id = vd.id and status = 'open'),
    'promo_open_n', (select count(*) from vendeur_promos where vendeur_id = vd.id and status = 'open'));
end $$;

-- a vendeur: name, credit period, credit limit in USD, and what was owed from before (USD and/or CDF at a taux)
create or replace function public.save_vendeur(p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin','admin'); vid uuid := nullif(p->>'id', '')::uuid; v public.vendeurs; s public.shops; sid uuid;
  n text := btrim(regexp_replace(coalesce(p->>'name', ''), '\s+', ' ', 'g'));
  cd numeric := app.num(p->>'credit_days'); lim numeric := round(app.num(p->>'credit_limit_usd'), 2);
  ou numeric := round(coalesce(app.num(p->>'opening_usd'), 0), 2); oc numeric := app.num(p->>'opening_cdf'); orate numeric; book numeric; sr numeric;
  oval numeric; ob numeric; aname text; aid uuid; chg text[] := '{}'; how text;
begin
  if u.role = 'shopadmin' and not app.feature('vendeurs') then raise exception 'Vendeurs (goods on credit) are not turned on in Settings'; end if;
  sid := case when u.role = 'shopadmin' then u.shop_id else nullif(p->>'shop_id', '')::uuid end;
  if vid is not null then
    select * into v from vendeurs where id = vid for update;
    if not found or (u.role = 'shopadmin' and v.shop_id <> u.shop_id) then raise exception 'Vendeur not found'; end if;
    sid := v.shop_id;
  end if;
  select * into s from shops where id = sid;
  if not found then raise exception 'Choose the shop'; end if;
  if n = '' then raise exception 'Enter the vendeur name'; end if;
  if length(n) > 40 then raise exception 'Vendeur name is too long (40 characters at most)'; end if;
  if cd is null or cd < 0 or cd > 365 or cd <> trunc(cd) then raise exception 'Credit period must be 0 to 365 days'; end if;
  select rate, coalesce(nullif(book_rate, 0), rate) into sr, book from settings where id = 1;
  -- an older app sends the limit in CDF: it becomes dollars at the sales rate
  if lim is null and app.num(p->>'credit_limit') > 0 then lim := round(app.num(p->>'credit_limit') / sr, 2); end if;
  if lim is null or lim <= 0 then raise exception 'Enter the credit limit in USD'; end if;
  -- what the vendeur already owed: dollars, Francs at a taux, or both (an older app sends the Francs as opening_balance)
  if oc is null and ou = 0 then oc := coalesce(app.num(p->>'opening_balance'), 0); end if;
  oc := coalesce(oc, 0);
  if oc < 0 or oc <> trunc(oc) or ou < 0 then raise exception 'Opening balance must be a whole amount of 0 or more'; end if;
  orate := round(coalesce(app.num(p->>'opening_rate'), book), 2);
  if oc > 0 and (orate is null or orate <= 0) then raise exception 'Enter the taux for the Francs owed'; end if;
  if oc > 0 and (orate < book / 2 or orate > book * 2) then raise exception 'Check the rate: % FC is far from the internal rate (% FC)', trim_scale(orate), trim_scale(book); end if;
  oval := ou + case when oc > 0 then oc / orate else 0 end;
  ob := oc + round(ou * orate);
  how := case when ou > 0 and oc > 0 then format(' (%s + %s at %s FC)', app.usd(ou), app.fc(oc::bigint), trim_scale(orate))
              when oc > 0 then format(' (%s at %s FC)', app.fc(oc::bigint), trim_scale(orate)) else '' end;
  if exists (select 1 from vendeurs where shop_id = sid and lower(name) = lower(n) and id is distinct from vid) then
    raise exception 'A vendeur called "%" already exists in this shop', n;
  end if;
  aname := 'Vendeur ' || n || ' (' || s.code || ')';
  if exists (select 1 from accounts where lower(name) = lower(aname) and id is distinct from v.account_id) then
    raise exception 'A ledger called "%" already exists', aname;
  end if;
  if vid is null then
    insert into accounts (name, group_code, currency, shop_id, opening_amount, opening_side, opening_currency, opening_rate)
      values (aname, 'debtors', 'FC', sid, round(oval, 2), 'Dr', 'USD', orate) returning id into aid;
    insert into vendeurs (shop_id, name, phone, address, notes, credit_days, credit_limit, credit_limit_usd, opening_balance, opening_usd, opening_cdf, opening_rate,
        opening_value_usd, account_id, created_by_name)
      values (sid, n, left(btrim(coalesce(p->>'phone', '')), 30), left(btrim(coalesce(p->>'address', '')), 80), left(btrim(coalesce(p->>'notes', '')), 200),
        cd::int, round(lim * sr), lim, ob::bigint, ou, oc::bigint, case when oc > 0 or ou > 0 then orate end, round(oval, 4), aid, u.name)
      returning id into vid;
    update accounts set vendeur_id = vid where id = aid;
    perform app.log(u, format('Added vendeur %s (%s): credit %s days, limit %s%s', n, s.name, cd::int, app.usd(lim),
      case when oval > 0 then ', opening balance ' || app.usd(round(oval, 2)) || how else '' end));
  else
    if v.credit_limit_usd <> lim then chg := chg || format('limit %s to %s', app.usd(v.credit_limit_usd), app.usd(lim)); end if;
    if v.credit_days <> cd then chg := chg || format('credit %s to %s days', v.credit_days, cd::int); end if;
    if round(v.opening_value_usd, 2) <> round(oval, 2) or v.opening_usd <> ou or v.opening_cdf <> oc then
      chg := chg || format('opening balance %s to %s%s', app.usd(round(v.opening_value_usd, 2)), app.usd(round(oval, 2)), how);
    end if;
    if v.active <> coalesce((p->>'active')::boolean, v.active) then chg := chg || case when (p->>'active')::boolean then 'made active' else 'made inactive' end; end if;
    update vendeurs set name = n, phone = left(btrim(coalesce(p->>'phone', '')), 30), address = left(btrim(coalesce(p->>'address', '')), 80),
      notes = left(btrim(coalesce(p->>'notes', '')), 200), credit_days = cd::int, credit_limit = round(lim * sr), credit_limit_usd = lim,
      opening_balance = ob::bigint, opening_usd = ou, opening_cdf = oc::bigint, opening_rate = case when oc > 0 or ou > 0 then orate end, opening_value_usd = round(oval, 4),
      active = coalesce((p->>'active')::boolean, active)
      where id = vid;
    -- the opening as a value in USD; one that did not change keeps how it was booked
    if round(v.opening_value_usd, 2) <> round(oval, 2) or v.opening_usd <> ou or v.opening_cdf <> oc then
      update accounts set name = aname, opening_amount = round(oval, 2), opening_currency = 'USD', opening_side = 'Dr', opening_rate = orate where id = v.account_id;
    else
      update accounts set name = aname where id = v.account_id;
    end if;
    perform app.log(u, format('Updated vendeur %s%s', n, case when cardinality(chg) > 0 then ': ' || array_to_string(chg, ', ') else '' end));
  end if;
  return vid;
end $$;

-- a payment from a vendeur: dollars, Francs or both, taken off what they owe in USD. Dollars count one for one; Francs
-- at the taux (the internal rate unless the Shop Admin types another). More than is owed: the rest is given back in
-- Francs, rounded down to 50 FC.
create or replace function public.vendeur_pay(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); v public.vendeurs; st jsonb; book numeric; sr numeric; tz text;
  pusd numeric := round(coalesce(app.num(p->>'paid_usd'), 0), 2); pcdf numeric := app.num(p->>'paid_cdf'); rt numeric;
  val numeric; bal numeric; chg bigint := 0; kept bigint; amt_usd numeric; amt bigint; diff numeric; cash jsonb := '[]'; how text;
  pid uuid := gen_random_uuid(); pno text; dev uuid := nullif(p->>'device_id', '')::uuid;
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
  select rate, coalesce(nullif(book_rate, 0), rate), settings.tz into sr, book, tz from settings where id = 1;
  rt := round(coalesce(app.num(p->>'rate'), app.num(p->>'usd_rate'), book), 2);
  if rt is null or rt <= 0 then raise exception 'Enter the taux for the Francs'; end if;
  if rt < book / 2 or rt > book * 2 then raise exception 'Check the exchange rate: % FC is far from the internal rate (% FC)', trim_scale(rt), trim_scale(book); end if;
  st := app.vendeur_state(v); bal := (st->>'balance')::numeric;
  if bal <= 0 then raise exception 'Vendeur % owes nothing', v.name; end if;
  val := round(pusd + pcdf / rt, 2);
  if val > bal then
    -- Francs only: what is owed is collected rounded up to 50 FC, so up to 49 FC over is the rounding, not too much
    if pusd = 0 and pcdf - bal * rt >= 50 then
      raise exception 'Vendeur % owes only % (% at %)', v.name, app.usd(bal), app.fc((ceil(bal * rt / 50) * 50)::bigint), trim_scale(rt);
    end if;
    if pusd > 0 then
      if round(pcdf / rt, 2) >= bal then raise exception 'The Francs alone pay all that % owes (%): take no dollars', v.name, app.usd(bal); end if;
      chg := (floor((val - bal) * rt / 50) * 50)::bigint;   -- the rest, back in Francs
    end if;
  end if;
  kept := pcdf::bigint - chg;
  amt_usd := least(round(pusd + kept / rt, 2), bal);
  amt := kept + round(pusd * rt)::bigint;
  if amt <= 0 then raise exception 'Enter the amount paid, in USD or CDF'; end if;
  if dev is not null and not exists (select 1 from devices where id = dev and shop_id = u.shop_id) then dev := null; end if;
  pno := app.vnum('VP', v.shop_id);
  insert into vendeur_payments (id, no, vendeur_id, shop_id, device_id, amount, rate, note, by_name, paid_usd, paid_cdf, usd_rate, change_cdf, amount_usd)
    values (pid, pno, v.id, v.shop_id, dev, amt, sr, left(btrim(coalesce(p->>'note', '')), 120), u.name, pusd, pcdf::bigint, rt, chg, amt_usd);
  -- the dollars into the shop's USD cash, the Francs kept into its Franc cash, off the vendeur's ledger in USD
  if pusd > 0 then cash := cash || jsonb_build_array(jsonb_build_object('account', app.shop_acc('CASH_SHOP_USD', v.shop_id), 'side', 'Dr', 'amount', pusd, 'currency', 'USD', 'memo', 'Paid in USD')); end if;
  if kept <> 0 then cash := cash || jsonb_build_array(jsonb_build_object('account', app.shop_acc('CASH_SHOP', v.shop_id), 'side', case when kept > 0 then 'Dr' else 'Cr' end,
    'amount', abs(kept), 'currency', 'FC', 'rate', rt)); end if;
  -- what the rounding of the Francs (given back, or collected to the next 50 FC) leaves over
  diff := round(pusd + kept / rt - amt_usd, 2);
  if abs(diff) >= 0.005 then
    cash := cash || jsonb_build_array(jsonb_build_object('code', 'FX_GAIN', 'side', case when diff > 0 then 'Cr' else 'Dr' end, 'amount', abs(diff), 'currency', 'USD', 'memo', 'Rounding of the Francs given back'));
  end if;
  perform app.post('receipt', (now() at time zone tz)::date, format('Payment %s from vendeur %s', pno, v.name), pno, 'vendeur_payment', pid,
    cash || jsonb_build_array(
      jsonb_build_object('account', v.account_id, 'side', 'Cr', 'amount', amt_usd, 'currency', 'USD', 'memo', nullif(btrim(coalesce(p->>'note', '')), ''))),
    u.name);
  how := concat_ws(' + ', case when pusd > 0 then app.usd(pusd) end, case when pcdf > 0 then app.fc(pcdf::bigint) || ' at ' || trim_scale(rt) end)
    || case when chg > 0 then ', ' || app.fc(chg) || ' given back' else '' end
    || case when pcdf > 0 and rt <> book then ', taux typed by the Shop Admin' else '' end;
  perform app.log(u, format('Payment %s from vendeur %s: %s (%s), %s left to pay', pno, v.name, app.usd(amt_usd), how, app.usd(bal - amt_usd)));
  return jsonb_build_object('id', pid, 'no', pno, 'amount', amt_usd, 'amount_cdf', amt, 'at', now(), 'by_name', u.name, 'vendeur', v.name, 'before', bal,
    'paid_usd', pusd, 'paid_cdf', pcdf::bigint, 'usd_rate', rt, 'change_cdf', chg, 'state', app.vendeur_state(v));
end $$;

-- a vendeur's statement in USD: goods on credit at the rate of their sale, payments, the running balance; the Francs beside
create or replace function public.vendeur_statement(p_id uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin','admin'); v public.vendeurs; tz text; res jsonb;
begin
  select * into v from vendeurs where id = p_id;
  if not found or (u.role = 'shopadmin' and v.shop_id <> u.shop_id) then raise exception 'Vendeur not found'; end if;
  if p_from is null or p_to is null then raise exception 'Choose the dates'; end if;
  if p_from > p_to then select p_to, p_from into p_from, p_to; end if;
  select settings.tz into tz from settings where id = 1;
  with l as (
    select v.created_at as t, (v.created_at at time zone tz)::date as d, ''::text as no,
      'Opening balance' || case when v.opening_usd > 0 or v.opening_cdf > 0 then ', ' || concat_ws(' + ', case when v.opening_usd > 0 then app.usd(v.opening_usd) end,
        case when v.opening_cdf > 0 then app.fc(v.opening_cdf) || coalesce(' at ' || trim_scale(v.opening_rate), '') end) else '' end as what,
      round(v.opening_value_usd, 2) as dr, 0::numeric as cr, v.opening_balance::bigint as cdf, null::numeric as rate, null::date as due, null::uuid as invoice_id
    where v.opening_value_usd > 0
    union all
    select i.t, (i.t at time zone tz)::date, i.no,
      'Goods on credit, ' || (select coalesce(sum(qty), 0) from invoice_items where invoice_id = i.id) || ' items'
        || case when exists (select 1 from invoice_edits where invoice_id = i.id) then ' (changed)' else '' end,
      round(i.total / i.rate, 2), 0, i.total, i.rate, i.due_date, i.id
    from invoices i where i.vendeur_id = v.id
    union all
    select x.at, (x.at at time zone tz)::date, x.no, 'Payment' || app.vp_how(x) || coalesce(', ' || nullif(x.note, ''), ''), 0, round(x.amount_usd, 2), x.amount, null, null, null
    from vendeur_payments x where x.vendeur_id = v.id and x.status = 'ok'
  )
  select jsonb_build_object(
    'currency', 'USD',
    'vendeur', (to_jsonb(v) - 'account_id') || jsonb_build_object('shop_name', (select name from shops where id = v.shop_id)),
    'from', p_from, 'to', p_to,
    'brought_forward', (select coalesce(sum(dr - cr), 0) from l where d < p_from),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('date', d, 'no', no, 'what', what, 'dr', dr, 'cr', cr, 'cdf', cdf, 'rate', rate, 'due', due, 'invoice_id', invoice_id) order by t, no), '[]')
              from l where d between p_from and p_to),
    'total_dr', (select coalesce(sum(dr), 0) from l where d between p_from and p_to),
    'total_cr', (select coalesce(sum(cr), 0) from l where d between p_from and p_to),
    'closing', (select coalesce(sum(dr - cr), 0) from l where d <= p_to),
    'promos', (select coalesce(jsonb_agg(jsonb_build_object('id', pr.id, 'no', pr.no, 'date', (pr.t at time zone tz)::date, 'value', pr.value, 'status', pr.status,
        'note', pr.note, 'invoice', (select no from invoices where id = pr.invoice_id),
        'items', (select jsonb_agg(jsonb_build_object('name', i.name, 'unit', i.unit, 'qty', i.qty, 'line', i.line) order by i.line_no) from vendeur_promo_items i where i.promo_id = pr.id))
        order by pr.t), '[]')
      from vendeur_promos pr where pr.vendeur_id = v.id and pr.status <> 'cancelled' and (pr.t at time zone tz)::date between p_from and p_to),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'no', x.no, 'at', x.at, 'amount', round(x.amount_usd, 2), 'amount_cdf', x.amount, 'note', x.note, 'status', x.status, 'by_name', x.by_name,
        'cancel_reason', x.cancel_reason, 'paid_usd', x.paid_usd, 'paid_cdf', x.paid_cdf, 'usd_rate', x.usd_rate, 'change_cdf', x.change_cdf) order by x.at desc), '[]')
      from vendeur_payments x where x.vendeur_id = v.id and (x.at at time zone tz)::date between p_from and p_to),
    'state', app.vendeur_state(v)
  ) into res;
  return res;
end $$;

create or replace function public.delete_vendeur(p_id uuid) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin','admin'); v public.vendeurs; st jsonb;
begin
  select * into v from vendeurs where id = p_id for update;
  if not found or (u.role = 'shopadmin' and v.shop_id <> u.shop_id) then raise exception 'Vendeur not found'; end if;
  -- created by mistake: nothing was ever recorded for it, so it goes completely (an opening amount included)
  if not exists (select 1 from invoices where vendeur_id = v.id) and not exists (select 1 from vendeur_payments where vendeur_id = v.id)
     and not exists (select 1 from vendeur_promos where vendeur_id = v.id) and not exists (select 1 from voucher_lines where account_id = v.account_id) then
    delete from vendeurs where id = v.id;
    delete from accounts where id = v.account_id;
    perform app.log(u, format('Deleted vendeur %s (%s)%s', v.name, (select name from shops where id = v.shop_id),
      case when v.opening_value_usd > 0 then format(', with the %s it was entered as owing', app.usd(round(v.opening_value_usd, 2))) else '' end));
    return 'deleted';
  end if;
  -- with history: kept, made inactive once it owes nothing
  st := app.vendeur_state(v);
  if abs((st->>'balance')::numeric) >= 0.005 then
    raise exception 'Vendeur % has goods or payments recorded and still owes %. Take the payment first; it is then made inactive, keeping its history', v.name, app.usd((st->>'balance')::numeric);
  end if;
  update vendeurs set active = false where id = v.id;
  perform app.log(u, format('Vendeur %s made inactive (its history is kept)', v.name));
  return 'inactive';
end $$;

-- a sale on credit is checked against the credit limit in USD
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
  vid uuid := nullif(p->>'vendeur_id', '')::uuid; vd public.vendeurs; v_due date; before jsonb; v_promo jsonb;
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
  -- goods on credit to a vendeur: the shop admin only, with Vendeurs turned on; the invoice is in the vendeur's name
  if vid is not null then
    if u.role <> 'shopadmin' then raise exception 'Only the shop admin gives goods on credit'; end if;
    if not app.feature('vendeurs') then raise exception 'Vendeurs (goods on credit) are not turned on in Settings'; end if;
    select * into vd from vendeurs where id = vid and shop_id = u.shop_id for update;
    if not found then raise exception 'Vendeur not found'; end if;
    if not vd.active then raise exception 'Vendeur % is inactive', vd.name; end if;
    if pusd > 0 or cusd > 0 then raise exception 'Goods on credit are not paid at the till'; end if;
    cust := vd.name;
    before := app.vendeur_state(vd);
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
  if vid is not null then
    -- on credit: nothing is paid at the till; the vendeur owes the total, due after their credit days
    if pusd > 0 or cusd > 0 then raise exception 'Goods on credit are not paid at the till'; end if;
    tend := 0; pcdf := 0; ccdf := 0;
    v_due := (t at time zone (select tz from settings where id = 1))::date + vd.credit_days;
  else
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
  end if;
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
  update invoices set gross = v_gross, disc_pct = dp, disc = v_disc, total = v_total, vat = v_vat, ht = v_total - v_vat, tendered = tend, change = case when vid is null then tend - v_total else 0 end, vendeur_id = vid, due_date = v_due,
    paid_usd = pusd, paid_cdf = pcdf, change_usd = cusd::int, change_cdf = ccdf, usd_rate = ur, price_flag = flag,
    revised_from = case when revised then o.total end
    where id = iid;
  update devices set last_seq = greatest(last_seq, seq) where id = dv.id;
  if oid is not null then
    update sale_orders set status = 'approved', reviewed_by_name = cashier.name, reviewed_at = now(), invoice_id = iid where id = oid;
  end if;
  -- promo items given with the goods: from the shop's stock, not on the invoice
  if vid is not null and jsonb_typeof(p->'promo') = 'array' and jsonb_array_length(p->'promo') > 0 then
    v_promo := app.add_promo(u, vd, iid, p->'promo', r, p->>'promo_note');
  end if;
  perform app.log(u, format('Invoice %s for %s, %s, %s%s%s', p->>'no', coalesce(nullif(cust, ''), 'walk-in'),
    case when vid is null then 'cash' else format('on credit, due %s%s', to_char(v_due, 'DD/MM/YYYY'),
      case when (before->>'balance')::numeric + v_total / r > vd.credit_limit_usd then format(', over the credit limit of %s', app.usd(vd.credit_limit_usd)) else '' end
      || case when (before->>'overdue')::boolean then format(', %s overdue', app.usd((before->>'overdue_amount')::numeric)) else '' end
      || case when v_promo is not null then format(', promo items %s (%s)', app.fc((v_promo->>'value')::bigint), v_promo->>'no') else '' end) end,
    app.fc(v_total), case when v_disc > 0 then format(', discount %s (%s%%)', app.fc(v_disc), trim_scale(dp)) else '' end,
    case when oid is not null then ' (order from ' || o.created_by_name || ' approved' || case when revised then ', changed from ' || app.fc(o.total) else '' end || ')' else '' end));
  return jsonb_build_object('status', 'ok', 'no', p->>'no', 'total', v_total, 'price_flag', flag, 'revised', revised, 'due_date', v_due, 'promo', v_promo,
    'vendeur', case when vid is not null then app.vendeur_state(vd) end);
end $$;

-- ======================= 3. promo items on cash sales =======================
-- A switch in Settings (cash_promo): the Shop Admin gives promo items free with a cash sale, like with goods on credit.
-- They leave the stock at cost as a promotion expense, are not on the invoice, and add up in the same monthly promo report,
-- which now gives for each item the pieces given in all, from cash sales and from credit sales.
alter table public.vendeur_promos alter column vendeur_id drop not null;          -- no vendeur: given with a cash sale
alter table public.vendeur_promos add column if not exists invoice_no text;        -- the cash sale it went with

-- promo items out of a shop's stock, valued at the shop price, booked at cost as a promotion expense; to a vendeur or with a cash sale
create or replace function app.add_promo_to(u public.profiles, p_shop uuid, vd public.vendeurs, p_invoice uuid, p_invoice_no text, p_lines jsonb, p_rate numeric, p_note text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare pid uuid := gen_random_uuid(); pno text; x jsonb; pr public.products; q int; ln int := 0; price bigint; cost numeric;
  val bigint := 0; cst numeric := 0; have int; tz text;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Choose the promo items'; end if;
  if jsonb_array_length(p_lines) > 100 then raise exception 'At most 100 promo lines at a time'; end if;
  if p_rate is null or p_rate <= 0 then raise exception 'Exchange rate is missing'; end if;
  pno := app.vnum('PR', p_shop);
  insert into vendeur_promos (id, no, shop_id, vendeur_id, invoice_id, invoice_no, rate, note, by_name)
    values (pid, pno, p_shop, vd.id, p_invoice, nullif(btrim(coalesce(p_invoice_no, '')), ''), p_rate, left(btrim(coalesce(p_note, '')), 120), u.name);
  for x in select * from jsonb_array_elements(p_lines) loop
    ln := ln + 1;
    select * into pr from products where id = (x->>'product_id')::uuid and active;
    if not found then raise exception 'Unknown promo item on line %', ln; end if;
    q := app.int_or_raise(x->>'qty', 'Promo quantity');
    if q < 1 then raise exception 'Promo quantities must be 1 or more'; end if;
    select qty into have from shop_stock where shop_id = p_shop and product_id = pr.id for update;
    if coalesce(have, 0) < q then
      raise exception 'Not enough % in the shop for the promo: % % in stock', pr.name, greatest(coalesce(have, 0), 0), pr.stock_unit;
    end if;
    price := app.to_cdf(app.pc_usd(pr), p_rate);
    cost := coalesce((select cost_usd from product_costs where product_id = pr.id), 0);
    insert into vendeur_promo_items (promo_id, line_no, product_id, name, unit, qty, price, line, cost_usd)
      values (pid, ln, pr.id, pr.name, pr.stock_unit, q, price, price * q, cost);
    perform app.take(p_shop, pr.id, q, 1, false, pr.pieces_per_set);
    val := val + price * q; cst := cst + cost * q;
  end loop;
  update vendeur_promos set value = val, cost_usd = cst where id = pid;
  select settings.tz into tz from settings where id = 1;
  perform app.post('journal', (now() at time zone tz)::date,
    case when vd.id is not null then format('Promo items %s given to vendeur %s', pno, vd.name)
         else format('Promo items %s given with cash sale %s', pno, coalesce(nullif(btrim(p_invoice_no), ''), '-')) end, pno, 'promo', pid,
    jsonb_build_array(
      jsonb_build_object('code', 'PROMO_EXP', 'side', 'Dr', 'amount', round(cst, 2), 'currency', 'USD', 'memo', 'Promo items at cost'),
      jsonb_build_object('account', app.shop_acc('INV_SHOP', p_shop), 'side', 'Cr', 'amount', round(cst, 2), 'currency', 'USD', 'memo', 'Promo items at cost')),
    u.name);
  return jsonb_build_object('id', pid, 'no', pno, 'value', val, 'n', ln);
end $$;

-- to a vendeur, as before
create or replace function app.add_promo(u public.profiles, vd public.vendeurs, p_invoice uuid, p_lines jsonb, p_rate numeric, p_note text) returns jsonb
language sql security definer set search_path = public, pg_temp as $$ select app.add_promo_to(u, vd.shop_id, vd, p_invoice, null, p_lines, p_rate, p_note) $$;

-- promo items with a cash sale: the Shop Admin, with the switch on; sent by the till just after the sale
create or replace function public.give_cash_promo(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); r numeric; res jsonb; ino text := btrim(coalesce(p->>'invoice_no', '')); iid uuid; vd public.vendeurs;
begin
  if not app.feature('cash_promo') then raise exception 'Promo items on cash sales are not turned on in Settings'; end if;
  select id into iid from invoices where no = ino and shop_id = u.shop_id;
  select rate into r from settings where id = 1;
  res := app.add_promo_to(u, u.shop_id, vd, iid, ino, p->'lines', coalesce(app.num(p->>'rate'), r), p->>'note');
  perform app.log(u, format('Promo items %s given with cash sale %s: %s, %s lines', res->>'no', coalesce(nullif(ino, ''), '-'), app.fc((res->>'value')::bigint), res->>'n'));
  return res;
end $$;

-- a promo given by mistake, before it is settled: its items go back into the shop's stock
create or replace function public.cancel_promo(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); x public.vendeur_promos; it record;
begin
  select * into x from vendeur_promos where id = p_id and shop_id = u.shop_id for update;
  if not found then raise exception 'Promo not found'; end if;
  if x.status = 'settled' then raise exception 'Promo % is in a settled report and cannot be cancelled', x.no; end if;
  if x.status = 'cancelled' then raise exception 'Promo % is already cancelled', x.no; end if;
  if length(btrim(coalesce(p_reason, ''))) < 4 then raise exception 'Write a short reason for cancelling this promo'; end if;
  for it in select i.*, pr.pieces_per_set from vendeur_promo_items i join products pr on pr.id = i.product_id where i.promo_id = p_id loop
    perform app.give_back(x.shop_id, it.product_id, it.qty, 1, false, it.pieces_per_set);
  end loop;
  update vendeur_promos set status = 'cancelled', cancel_reason = left(btrim(p_reason), 120), cancelled_by_name = u.name, cancelled_at = now() where id = p_id;
  update vouchers set status = 'cancelled', cancel_reason = left('Promo cancelled: ' || btrim(p_reason), 120)
    where source_type = 'promo' and source_id = p_id and status = 'posted';
  perform app.log(u, format('Promo %s %s (%s) cancelled, items back in stock: %s', x.no,
    coalesce('to vendeur ' || (select name from vendeurs where id = x.vendeur_id), 'with cash sale ' || coalesce(x.invoice_no, '-')), app.fc(x.value), btrim(p_reason)));
end $$;

-- the promo items of a shop still open at the end of a month (those of earlier months that were kept included): each
-- item and how many were given out in all, with cash sales and with credit sales; and the cash-sale promos one by one
create or replace function app.promo_open(p_shop uuid, p_month date) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  with z as (select tz from settings where id = 1),
  pr as (
    select p.*, (p.t at time zone (select tz from z))::date as d from vendeur_promos p
    where p.shop_id = p_shop and p.status = 'open' and (p.t at time zone (select tz from z))::date < (p_month + interval '1 month')::date
  ), it as (
    select i.product_id, min(i.name) as name, min(i.unit) as unit, sum(i.qty) as qty, coalesce(sum(i.qty) filter (where pr.d < p_month), 0) as carried,
      coalesce(sum(i.qty) filter (where pr.vendeur_id is null), 0) as cash_qty, coalesce(sum(i.qty) filter (where pr.vendeur_id is not null), 0) as credit_qty
    from pr join vendeur_promo_items i on i.promo_id = pr.id group by i.product_id
  )
  select jsonb_build_object('month', p_month,
    'n', (select count(*) from pr), 'value', (select coalesce(sum(value), 0) from pr),
    'pcs', (select coalesce(sum(qty), 0) from it), 'carried_pcs', (select coalesce(sum(carried), 0) from it),
    'cash_pcs', (select coalesce(sum(cash_qty), 0) from it), 'credit_pcs', (select coalesce(sum(credit_qty), 0) from it),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('name', name, 'unit', unit, 'qty', qty, 'carried', carried, 'cash_qty', cash_qty, 'credit_qty', credit_qty)
      order by lower(name)), '[]') from it),
    'cash_promos', (select coalesce(jsonb_agg(jsonb_build_object('id', pr.id, 'no', pr.no, 'date', pr.d, 'invoice', pr.invoice_no, 'value', pr.value, 'by_name', pr.by_name,
        'items', (select jsonb_agg(jsonb_build_object('name', i.name, 'unit', i.unit, 'qty', i.qty) order by i.line_no) from vendeur_promo_items i where i.promo_id = pr.id))
      order by pr.t desc), '[]') from pr where pr.vendeur_id is null))
$$;

-- the promo report of a month (vendeurs or promos on cash sales turned on)
create or replace function public.promo_report(p_month date default null, p_shop uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin','admin'); sid uuid; m date; tz text;
begin
  if u.role = 'shopadmin' and not (app.feature('vendeurs') or app.feature('cash_promo')) then raise exception 'Promo items are not turned on in Settings'; end if;
  sid := case when u.role = 'shopadmin' then u.shop_id else p_shop end;
  if sid is null then raise exception 'Choose the shop'; end if;
  select settings.tz into tz from settings where id = 1;
  m := date_trunc('month', coalesce(p_month, (now() at time zone tz)::date))::date;
  return app.promo_open(sid, m) || jsonb_build_object('shop_id', sid, 'shop_name', (select name from shops where id = sid),
    'oldest_open', (select min((t at time zone tz)::date) from vendeur_promos where shop_id = sid and status = 'open'),
    'reports', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'month', r.month, 'status', r.status, 'n', r.n, 'total', r.total, 'by_name', r.by_name, 'at', r.at, 'data', r.data)
        order by r.at desc), '[]') from (select * from promo_reports where shop_id = sid order by at desc limit 36) r));
end $$;

create or replace function public.close_promo_report(p_month date, p_action text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); m date; d jsonb; rid uuid; tz text; mname text;
begin
  if not (app.feature('vendeurs') or app.feature('cash_promo')) then raise exception 'Promo items are not turned on in Settings'; end if;
  if p_action not in ('keep', 'settle') then raise exception 'Choose keep or settle'; end if;
  if p_month is null then raise exception 'Choose the month'; end if;
  select settings.tz into tz from settings where id = 1;
  m := date_trunc('month', p_month)::date;
  if m > (now() at time zone tz)::date then raise exception 'That month has not started yet'; end if;
  mname := to_char(m, 'FMMonth YYYY');
  perform 1 from shops where id = u.shop_id for update;   -- one report at a time per shop
  d := app.promo_open(u.shop_id, m);
  if (d->>'n')::int = 0 then raise exception 'There are no open promo items up to the end of %', mname; end if;
  if p_action = 'keep' then
    update promo_reports set n = (d->>'n')::int, total = (d->>'value')::bigint, data = d, by_name = u.name, at = now()
      where shop_id = u.shop_id and month = m and status = 'kept' returning id into rid;
    if rid is null then
      insert into promo_reports (shop_id, month, status, n, total, data, by_name)
        values (u.shop_id, m, 'kept', (d->>'n')::int, (d->>'value')::bigint, d, u.name) returning id into rid;
    end if;
    perform app.log(u, format('Promo report of %s kept: %s promos, %s, still open', mname, d->>'n', app.fc((d->>'value')::bigint)));
  else
    insert into promo_reports (shop_id, month, status, n, total, data, by_name)
      values (u.shop_id, m, 'settled', (d->>'n')::int, (d->>'value')::bigint, d, u.name) returning id into rid;
    update vendeur_promos set status = 'settled', report_id = rid, settled_at = now(), settled_by_name = u.name
      where shop_id = u.shop_id and status = 'open' and (t at time zone tz)::date < (m + interval '1 month')::date;
    -- the report kept for this month is replaced by the settled one
    delete from promo_reports where shop_id = u.shop_id and month = m and status = 'kept';
    perform app.log(u, format('Promo report of %s settled: %s promos, %s; the promo count starts again at zero', mname, d->>'n', app.fc((d->>'value')::bigint)));
  end if;
  return (select to_jsonb(r) from promo_reports r where r.id = rid);
end $$;

-- ---------- Settings: the promo-on-cash-sales switch ----------
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
  foreach k in array array['customer_optional','barcode','till_sells','cash_change','usd_pay','one_copy','no_warehouse','vendeurs','money_exchange','cash_promo'] loop
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

-- ======================= 2. goods in: corrected or deleted, before or after the bill =======================
-- A goods receipt (GRN) can be corrected (items and quantities, its reference and note; and once the bill is entered,
-- the bill's number, dates, amount, VAT, currency and rate) or deleted, waiting for the bill or billed. The stock and
-- both vouchers (goods in, and the bill) are corrected in place; deleting takes the goods back out of the stock and
-- cancels both. Not while the bill is (partly) paid, or while goods of the receipt are being returned to the supplier:
-- that is cancelled first. A receipt whose goods were already sold or sent on cannot take more back than is left.
alter table public.grns drop constraint if exists grns_status_check;
alter table public.grns add constraint grns_status_check check (status in ('awaiting_bill','billed','cancelled'));
alter table public.grns add column if not exists cancel_reason text;
alter table public.grns add column if not exists cancelled_by_name text;
alter table public.grns add column if not exists cancelled_at timestamptz;
alter table public.grns add column if not exists edited_by_name text;
alter table public.grns add column if not exists edited_at timestamptz;

-- goods of a receipt in or out of the place they came into (the central store, or the shop with no central store)
create or replace function app.grn_move(g public.grns, p_product uuid, p_delta int) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare have int; pr public.products;
begin
  if p_delta = 0 then return; end if;
  select * into pr from products where id = p_product;
  if g.shop_id is not null then
    select qty into have from shop_stock where shop_id = g.shop_id and product_id = p_product for update;
    if coalesce(have, 0) + p_delta < 0 then
      raise exception 'Only % % of % are left in %: the rest was already sold or sent on, so % cannot take them back', greatest(coalesce(have, 0), 0), pr.stock_unit, pr.name,
        (select name from shops where id = g.shop_id), g.no;
    end if;
    insert into shop_stock (shop_id, product_id, qty) values (g.shop_id, p_product, p_delta)
      on conflict (shop_id, product_id) do update set qty = shop_stock.qty + excluded.qty;
  else
    if pr.wh_qty + p_delta < 0 then
      raise exception 'Only % % of % are left in the store: the rest was already sent to the shops or used, so % cannot take them back', greatest(pr.wh_qty, 0), pr.stock_unit, pr.name, g.no;
    end if;
    update products set wh_qty = wh_qty + p_delta, updated_at = now() where id = p_product;
  end if;
end $$;

-- the goods-in voucher of a receipt, at item cost (corrected in place)
create or replace function app.grn_post(g public.grns, p_by text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v numeric; sup public.suppliers; d date;
begin
  select * into sup from suppliers where id = g.supplier_id;
  select coalesce(sum(qty * std_cost_usd), 0) into v from grn_items where grn_id = g.id;
  select date into d from vouchers where source_type = 'grn' and source_id = g.id and status = 'posted';
  perform app.post('goods_in', coalesce(d, (g.received_at at time zone (select tz from settings where id = 1))::date),
    g.no || ' from ' || sup.name || coalesce(', ' || nullif(btrim(g.ref), ''), '') || coalesce(' into ' || (select name from shops where id = g.shop_id), ''), g.no, 'grn', g.id,
    jsonb_build_array(case when g.shop_id is not null then jsonb_build_object('account', app.shop_acc('INV_SHOP', g.shop_id), 'side', 'Dr', 'amount', round(v, 2))
                           else jsonb_build_object('code', 'INV_STORE', 'side', 'Dr', 'amount', round(v, 2)) end,
                      jsonb_build_object('code', 'GRNI', 'side', 'Cr', 'amount', round(v, 2))), p_by);
end $$;

-- what stops a receipt being corrected or deleted: a bill that is (partly) paid, or goods of it being returned to the supplier
create or replace function app.grn_locked(g public.grns) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select case
    when g.bill_voucher_id is not null and exists (select 1 from bill_allocations ba join vouchers v on v.id = ba.voucher_id
           where ba.bill_id = g.bill_voucher_id and v.status = 'posted'
             and not exists (select 1 from supplier_returns sr where sr.voucher_id = v.id and sr.kind = 'short' and sr.bill_id = g.bill_voucher_id))
      then format('The bill for %s is already (partly) paid. Cancel the payment under Accounts first', g.no)
    when exists (select 1 from supplier_returns sr where sr.grn_id = g.id and sr.kind = 'return' and sr.status <> 'cancelled')
      then format('Goods of %s are being returned to the supplier. Cancel that return first', g.no)
  end
$$;

-- a receipt with its items and, once billed, its bill as it was entered
create or replace function public.grn_detail(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin','whop'); g public.grns; b public.vouchers; sl public.voucher_lines; vat numeric := 0;
begin
  select * into g from grns where id = p_id;
  if not found then raise exception 'Goods receipt not found'; end if;
  if g.bill_voucher_id is not null then
    select * into b from vouchers where id = g.bill_voucher_id;
    select * into sl from voucher_lines where voucher_id = b.id and account_id = (select account_id from suppliers where id = g.supplier_id) and side = 'Cr' limit 1;
    select coalesce(sum(amount), 0) into vat from voucher_lines l where l.voucher_id = b.id and l.account_id = app.acc('VAT_IN');
  end if;
  return jsonb_build_object('grn', to_jsonb(g), 'supplier', (select name from suppliers where id = g.supplier_id),
    'shop_name', (select name from shops where id = g.shop_id),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('product_id', i.product_id, 'name', p.name, 'unit', p.stock_unit, 'qty', i.qty, 'cost', i.std_cost_usd) order by p.name), '[]')
      from grn_items i join products p on p.id = i.product_id where i.grn_id = g.id),
    'bill', case when b.id is not null then jsonb_build_object('voucher', b.no, 'bill_no', b.ref, 'bill_date', b.date, 'due_date', sl.due_date, 'currency', sl.currency, 'rate', sl.rate,
      'amount', sl.amount - vat, 'vat', vat) end,
    'locked', app.grn_locked(g),
    'claims', (select count(*) from supplier_returns sr where sr.bill_id = g.bill_voucher_id and sr.kind = 'short' and sr.status <> 'cancelled'));
end $$;

-- correct a receipt: items and quantities, reference and note; with its bill, the bill too
create or replace function public.edit_grn(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin','whop'); g public.grns; sup public.suppliers; lk text; x record; nl jsonb := coalesce(p->'lines', '[]');
  b jsonb := p->'bill'; cur text; r numeric; amt numeric; vat numeric; bdate date; due date; bno text; std numeric; base_total numeric; diff numeric; lines jsonb;
  oldv numeric; newv numeric; chg text[] := '{}'; n int;
begin
  select * into g from grns where id = (p->>'id')::uuid for update;
  if not found or g.status = 'cancelled' then raise exception 'Goods receipt not found'; end if;
  if g.status = 'billed' and u.role <> 'admin' then raise exception 'Only the Admin corrects a receipt once its bill is entered'; end if;
  lk := app.grn_locked(g);
  if lk is not null then raise exception '%', lk; end if;
  if g.status = 'billed' and exists (select 1 from supplier_returns sr where sr.bill_id = g.bill_voucher_id and sr.kind = 'short' and sr.status <> 'cancelled') then
    raise exception 'The bill for % has a claim for goods billed but not received. Cancel the claim under Returns to supplier first', g.no;
  end if;
  select * into sup from suppliers where id = g.supplier_id;
  if jsonb_typeof(nl) <> 'array' then raise exception 'Enter the items'; end if;
  if exists (select 1 from jsonb_array_elements(nl) e where coalesce(app.num(e->>'qty'), -1) < 0 or app.num(e->>'qty') <> trunc(app.num(e->>'qty'))) then
    raise exception 'Quantities must be whole numbers of 0 or more';
  end if;
  if not exists (select 1 from jsonb_array_elements(nl) e where app.num(e->>'qty') > 0) then
    raise exception 'A receipt needs at least one item. To take it all back, delete it';
  end if;
  if exists (select 1 from jsonb_array_elements(nl) e where not exists (select 1 from products where id = (e->>'product_id')::uuid)) then
    raise exception 'One of the items was not found';
  end if;
  select coalesce(sum(qty * std_cost_usd), 0) into oldv from grn_items where grn_id = g.id;
  -- the stock follows each change of quantity
  for x in
    select coalesce(o.product_id, nn.product_id) as product_id, coalesce(o.qty, 0) as was, coalesce(nn.qty, 0) as now
    from (select product_id, qty from grn_items where grn_id = g.id) o
    full join (select (e->>'product_id')::uuid as product_id, sum(app.num(e->>'qty'))::int as qty from jsonb_array_elements(nl) e group by 1) nn on nn.product_id = o.product_id
  loop
    if x.was = x.now then continue; end if;
    perform app.grn_move(g, x.product_id, x.now - x.was);
    chg := chg || format('%s %s to %s', (select name from products where id = x.product_id), x.was, x.now);
    if x.now = 0 then delete from grn_items where grn_id = g.id and product_id = x.product_id;
    elsif x.was = 0 then insert into grn_items (grn_id, product_id, qty, std_cost_usd)
      values (g.id, x.product_id, x.now, coalesce((select cost_usd from product_costs where product_id = x.product_id), 0));
    else update grn_items set qty = x.now where grn_id = g.id and product_id = x.product_id;
    end if;
    -- the purchase history of the item follows
    delete from purchases where product_id = x.product_id and supplier = sup.name || ' ' || g.no;
    if x.now > 0 then insert into purchases (product_id, qty, supplier, by_id, by_name, at) values (x.product_id, x.now, sup.name || ' ' || g.no, u.id, u.name, g.received_at); end if;
  end loop;
  if coalesce(btrim(p->>'ref'), g.ref) <> g.ref then chg := chg || format('reference %s to %s', nullif(g.ref, ''), btrim(p->>'ref')); end if;
  update grns set ref = left(btrim(coalesce(p->>'ref', ref)), 60), note = left(btrim(coalesce(p->>'note', note)), 120), edited_by_name = u.name, edited_at = now()
    where id = g.id returning * into g;
  perform app.grn_post(g, u.name);
  select coalesce(sum(qty * std_cost_usd), 0), count(*) into newv, n from grn_items where grn_id = g.id;
  -- the bill, entered again in place (same voucher number): with what was given, or as it was, against the corrected goods
  if g.status = 'billed' and b is null then b := public.grn_detail(g.id)->'bill'; end if;
  if g.status = 'billed' and b is not null then
    cur := coalesce(b->>'currency', 'USD'); r := app.num(b->>'rate'); amt := app.num(b->>'amount'); vat := coalesce(app.num(b->>'vat'), 0);
    bno := btrim(coalesce(b->>'bill_no', '')); bdate := coalesce((b->>'bill_date')::date, current_date);
    if bno = '' then raise exception 'Enter the supplier''s bill number'; end if;
    if amt is null or amt <= 0 then raise exception 'Enter the bill amount'; end if;
    if vat < 0 then raise exception 'VAT cannot be negative'; end if;
    if cur not in ('USD','FC') then raise exception 'Currency must be USD or FC'; end if;
    r := coalesce(r, (select book_rate from settings where id = 1));
    if r <= 0 then raise exception 'Exchange rate must be above zero'; end if;
    due := coalesce((b->>'due_date')::date, bdate + sup.credit_days);
    std := newv;
    base_total := case when cur = 'USD' then amt + vat else (amt + vat) / r end;
    diff := (base_total - case when cur = 'USD' then vat else vat / r end) - round(std, 2);
    lines := jsonb_build_array(jsonb_build_object('account', sup.account_id, 'side', 'Cr', 'amount', amt + vat, 'currency', cur, 'rate', r,
               'bill_ref', bno, 'due_date', due, 'memo', 'Bill ' || bno),
             jsonb_build_object('code', 'VAT_IN', 'side', 'Dr', 'amount', vat, 'currency', cur, 'rate', r, 'memo', 'VAT on bill ' || bno),
             jsonb_build_object('code', 'GRNI', 'side', 'Dr', 'amount', round(std, 2), 'memo', g.no),
             jsonb_build_object('code', 'PPV', 'side', case when diff >= 0 then 'Dr' else 'Cr' end, 'amount', round(abs(diff), 2), 'memo', 'Bill vs item cost, ' || g.no));
    perform app.post('purchase', bdate, 'Bill ' || bno || ' from ' || sup.name || ', ' || g.no, bno, 'bill', g.id, lines, u.name);
    if p->'bill' is not null then chg := chg || format('bill %s, %s %s, due %s', bno, amt + vat, cur, to_char(due, 'DD/MM/YYYY')); end if;
  end if;
  perform app.log(u, format('Corrected %s from %s%s', g.no, sup.name, case when cardinality(chg) > 0 then ': ' || array_to_string(chg, '; ') else '' end));
  return jsonb_build_object('id', g.id, 'no', g.no, 'value', round(newv, 2), 'n', n);
end $$;

-- delete a receipt: its goods leave the stock again, its goods-in voucher and its bill are cancelled
create or replace function public.delete_grn(p_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin','whop'); g public.grns; sup public.suppliers; lk text; x record; why text := btrim(coalesce(p_reason, '')); bno text;
begin
  select * into g from grns where id = p_id for update;
  if not found or g.status = 'cancelled' then raise exception 'Goods receipt not found'; end if;
  if g.status = 'billed' and u.role <> 'admin' then raise exception 'Only the Admin deletes a receipt once its bill is entered'; end if;
  if length(why) < 4 then raise exception 'Write a short reason for deleting this receipt'; end if;
  lk := app.grn_locked(g);
  if lk is not null then raise exception '%', lk; end if;
  select * into sup from suppliers where id = g.supplier_id;
  for x in select product_id, qty from grn_items where grn_id = g.id loop
    perform app.grn_move(g, x.product_id, -x.qty);
    delete from purchases where product_id = x.product_id and supplier = sup.name || ' ' || g.no;
  end loop;
  update vouchers set status = 'cancelled', cancel_reason = left(g.no || ' deleted: ' || why, 120) where source_type = 'grn' and source_id = g.id and status = 'posted';
  if g.bill_voucher_id is not null then
    select ref into bno from vouchers where id = g.bill_voucher_id;
    -- the bill's own claims for goods not received go with it
    update vouchers set status = 'cancelled', cancel_reason = left('Bill ' || bno || ' cancelled with ' || g.no, 120)
      where id in (select voucher_id from supplier_returns where bill_id = g.bill_voucher_id and kind = 'short' and status <> 'cancelled' and voucher_id is not null);
    delete from bill_allocations where voucher_id in (select voucher_id from supplier_returns where bill_id = g.bill_voucher_id and kind = 'short' and voucher_id is not null);
    update supplier_returns set status = 'cancelled', cancel_reason = left(g.no || ' deleted', 120) where bill_id = g.bill_voucher_id and kind = 'short' and status <> 'cancelled';
    update vouchers set status = 'cancelled', cancel_reason = left(g.no || ' deleted: ' || why, 120) where id = g.bill_voucher_id and status = 'posted';
    delete from bill_allocations where voucher_id = g.bill_voucher_id;
  end if;
  update grns set status = 'cancelled', cancel_reason = left(why, 120), cancelled_by_name = u.name, cancelled_at = now() where id = g.id;
  perform app.log(u, format('Deleted %s from %s%s: %s', g.no, sup.name, case when bno is not null then ' and its bill ' || bno else '' end, why));
  return jsonb_build_object('no', g.no, 'bill', bno);
end $$;


-- ---------- who may call what ----------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.give_cash_promo(jsonb), public.grn_detail(uuid), public.edit_grn(jsonb), public.delete_grn(uuid, text) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
