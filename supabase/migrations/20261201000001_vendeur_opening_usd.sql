-- QuickSales: a vendeur's opening balance in USD, in CDF, or both.
-- What a vendeur already owed when added can now be entered in dollars as well as Francs. The dollars are turned into
-- Francs at a rate: the internal rate unless the Shop Admin (or the Admin) types the taux agreed, the same way a
-- vendeur's dollar payments count, so $100 owed is cleared by $100 paid. What the vendeur owes stays in Francs, as
-- before; the statement shows how the opening was made up. Vendeurs saved before keep their opening in Francs.
-- Already running QuickSales? Run this file once, after 20261130000001_round_50_fix.sql. It changes no amounts.

-- stop at once if the update before this one was not run
do $$ begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'to_cdf' and pg_get_functiondef(p.oid) like '%/ 10) * 10 / 50%') then
    raise exception 'Run supabase/migrations/20261130000001_round_50_fix.sql (and every earlier file) first, then this file. supabase/scripts/check_migrations.sql shows what is missing';
  end if;
end $$;

alter table public.vendeurs add column if not exists opening_usd numeric(12,2) not null default 0 check (opening_usd >= 0);
alter table public.vendeurs add column if not exists opening_cdf bigint not null default 0 check (opening_cdf >= 0);
alter table public.vendeurs add column if not exists opening_rate numeric(12,2);   -- the rate of the dollars owed
-- vendeurs saved before owed Francs only
update public.vendeurs set opening_cdf = opening_balance where opening_usd = 0 and opening_cdf = 0 and opening_balance > 0;

create or replace function public.save_vendeur(p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin','admin'); vid uuid := nullif(p->>'id', '')::uuid; v public.vendeurs; s public.shops; sid uuid;
  n text := btrim(regexp_replace(coalesce(p->>'name', ''), '\s+', ' ', 'g'));
  cd numeric := app.num(p->>'credit_days'); lim numeric := app.num(p->>'credit_limit'); ob numeric;
  ou numeric := round(coalesce(app.num(p->>'opening_usd'), 0), 2); oc numeric := app.num(p->>'opening_cdf'); orate numeric; book numeric; oba numeric;
  aname text; aid uuid; r numeric; chg text[] := '{}'; how text;
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
  if lim is null or lim <= 0 or lim <> trunc(lim) then raise exception 'Enter the credit limit in CDF'; end if;
  -- what the vendeur already owed: Francs, dollars at a rate, or both (an older app sends the Francs as opening_balance)
  if oc is null and ou = 0 then oc := coalesce(app.num(p->>'opening_balance'), 0); end if;
  oc := coalesce(oc, 0);
  if oc < 0 or oc <> trunc(oc) or ou < 0 then raise exception 'Opening balance must be a whole amount of 0 or more'; end if;
  select coalesce(nullif(book_rate, 0), rate) into book from settings where id = 1;
  orate := case when ou > 0 then round(coalesce(app.num(p->>'opening_rate'), book), 2) end;
  if ou > 0 and (orate is null or orate <= 0) then raise exception 'Enter the rate for the dollars owed'; end if;
  if ou > 0 and (orate < book / 2 or orate > book * 2) then raise exception 'Check the rate: % FC is far from the internal rate (% FC)', trim_scale(orate), trim_scale(book); end if;
  ob := oc + case when ou > 0 then round(ou * orate) else 0 end;
  how := case when ou > 0 then format(' (%s at %s FC%s)', app.usd(ou), trim_scale(orate), case when oc > 0 then ' + ' || app.fc(oc::bigint) else '' end) else '' end;
  if exists (select 1 from vendeurs where shop_id = sid and lower(name) = lower(n) and id is distinct from vid) then
    raise exception 'A vendeur called "%" already exists in this shop', n;
  end if;
  aname := 'Vendeur ' || n || ' (' || s.code || ')';
  if exists (select 1 from accounts where lower(name) = lower(aname) and id is distinct from v.account_id) then
    raise exception 'A ledger called "%" already exists', aname;
  end if;
  select rate into r from settings where id = 1;
  -- in the books the opening is in Francs, at the rate that makes it worth the dollars plus the Francs at the sales rate
  oba := case when ob > 0 and ou > 0 then round(ob / (ou + oc / r), 4) else r end;
  if vid is null then
    insert into accounts (name, group_code, currency, shop_id, opening_amount, opening_side, opening_currency, opening_rate)
      values (aname, 'debtors', 'FC', sid, ob, 'Dr', 'FC', oba) returning id into aid;
    insert into vendeurs (shop_id, name, phone, address, notes, credit_days, credit_limit, opening_balance, opening_usd, opening_cdf, opening_rate, account_id, created_by_name)
      values (sid, n, left(btrim(coalesce(p->>'phone', '')), 30), left(btrim(coalesce(p->>'address', '')), 80), left(btrim(coalesce(p->>'notes', '')), 200),
        cd::int, lim::bigint, ob::bigint, ou, oc::bigint, orate, aid, u.name)
      returning id into vid;
    update accounts set vendeur_id = vid where id = aid;
    perform app.log(u, format('Added vendeur %s (%s): credit %s days, limit %s%s', n, s.name, cd::int, app.fc(lim::bigint),
      case when ob > 0 then ', opening balance ' || app.fc(ob::bigint) || how else '' end));
  else
    if v.credit_limit <> lim then chg := chg || format('limit %s to %s', app.fc(v.credit_limit), app.fc(lim::bigint)); end if;
    if v.credit_days <> cd then chg := chg || format('credit %s to %s days', v.credit_days, cd::int); end if;
    if v.opening_balance <> ob or v.opening_usd <> ou or v.opening_rate is distinct from orate then
      chg := chg || format('opening balance %s to %s%s', app.fc(v.opening_balance), app.fc(ob::bigint), how);
    end if;
    if v.active <> coalesce((p->>'active')::boolean, v.active) then chg := chg || case when (p->>'active')::boolean then 'made active' else 'made inactive' end; end if;
    update vendeurs set name = n, phone = left(btrim(coalesce(p->>'phone', '')), 30), address = left(btrim(coalesce(p->>'address', '')), 80),
      notes = left(btrim(coalesce(p->>'notes', '')), 200), credit_days = cd::int, credit_limit = lim::bigint, opening_balance = ob::bigint, opening_usd = ou, opening_cdf = oc::bigint, opening_rate = orate,
      active = coalesce((p->>'active')::boolean, active)
      where id = vid;
    update accounts set name = aname, opening_amount = ob, opening_currency = 'FC', opening_side = 'Dr',
      opening_rate = case when ou > 0 then oba else coalesce(case when v.opening_usd > 0 then null else opening_rate end, r) end where id = v.account_id;
    perform app.log(u, format('Updated vendeur %s%s', n, case when cardinality(chg) > 0 then ': ' || array_to_string(chg, ', ') else '' end));
  end if;
  return vid;
end $$;

-- the statement says how the opening was made up
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
    select v.created_at as t, (v.created_at at time zone tz)::date as d, ''::text as no, 'Opening balance' || case when v.opening_usd > 0 then format(', %s at %s FC%s', app.usd(v.opening_usd), trim_scale(v.opening_rate),
        case when v.opening_cdf > 0 then ' + ' || app.fc(v.opening_cdf) else '' end) else '' end as what, v.opening_balance::bigint as dr, 0::bigint as cr,
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
