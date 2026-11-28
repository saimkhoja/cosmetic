-- QuickSales: a sale on credit counts in USD at the internal rate (taux interne) of its sale.
-- What a vendeur owes for goods on credit is the invoice's Francs divided by the internal rate of the day of the sale
-- (kept on the invoice), no longer by the sales rate; paid back in Francs at the internal rate, the same Francs clear it.
-- Sales on credit already made are counted the same way, at the internal rate kept on each of them, and booked again
-- (same voucher numbers): the vendeur's ledger in USD, the difference with the sale at the sales rate as exchange.
-- A sale on credit can be entered for a past day (the Shop Admin picks the date at the till), with the internal rate of
-- that day: it is due after the credit days from that date.
-- Already running QuickSales? Run this file once, after 20261202000001_usd_credit_grn_edit_cash_promo.sql.

-- stop at once if the update before this one was not run
do $$ begin
  if not exists (select 1 from pg_proc where proname = 'edit_grn') then
    raise exception 'Run supabase/migrations/20261202000001_usd_credit_grn_edit_cash_promo.sql (and every earlier file) first, then this file. supabase/scripts/check_migrations.sql shows what is missing';
  end if;
end $$;

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
    select i.id, i.no, (i.t at time zone tz)::date, coalesce(i.due_date, (i.t at time zone tz)::date + vd.credit_days), round(i.total / coalesce(i.usd_rate, i.rate), 2), i.total, i.t
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
  bal := round(vd.opening_value_usd, 2) + coalesce((select sum(round(total / coalesce(usd_rate, rate), 2)) from invoices where vendeur_id = vd.id), 0) - round(paid, 2);
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
      round(i.total / coalesce(i.usd_rate, i.rate), 2), 0, i.total, coalesce(i.usd_rate, i.rate), i.due_date, i.id
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
  -- goods on credit count at this internal rate: one typed for a past sale is checked for a typing slip
  if vid is not null and (ur < (select coalesce(nullif(book_rate, 0), rate) from settings where id = 1) / 2 or ur > (select coalesce(nullif(book_rate, 0), rate) from settings where id = 1) * 2) then
    raise exception 'Check the internal rate: % FC is far from the internal rate in Settings', trim_scale(ur);
  end if;
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
    case when vid is null then 'cash' else format('on credit%s at %s, due %s%s',
      case when (t at time zone (select tz from settings where id = 1))::date < (now() at time zone (select tz from settings where id = 1))::date
        then ' dated ' || to_char((t at time zone (select tz from settings where id = 1))::date, 'DD/MM/YYYY') else '' end, trim_scale(ur), to_char(v_due, 'DD/MM/YYYY'),
      case when (before->>'balance')::numeric + round(v_total / ur, 2) > vd.credit_limit_usd then format(', over the credit limit of %s', app.usd(vd.credit_limit_usd)) else '' end
      || case when (before->>'overdue')::boolean then format(', %s overdue', app.usd((before->>'overdue_amount')::numeric)) else '' end
      || case when v_promo is not null then format(', promo items %s (%s)', app.fc((v_promo->>'value')::bigint), v_promo->>'no') else '' end) end,
    app.fc(v_total), case when v_disc > 0 then format(', discount %s (%s%%)', app.fc(v_disc), trim_scale(dp)) else '' end,
    case when oid is not null then ' (order from ' || o.created_by_name || ' approved' || case when revised then ', changed from ' || app.fc(o.total) else '' end || ')' else '' end));
  return jsonb_build_object('status', 'ok', 'no', p->>'no', 'total', v_total, 'price_flag', flag, 'revised', revised, 'due_date', v_due, 'promo', v_promo,
    'vendeur', case when vid is not null then app.vendeur_state(vd) end);
end $$;

create or replace function app.post_invoice(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare i public.invoices; cost numeric; tz text; nusd numeric; ur numeric; fc bigint; cash jsonb; diff numeric := 0;
begin
  select * into i from invoices where id = p_id;
  if i.id is null or i.total <= 0 then return; end if;
  select settings.tz into tz from settings where id = 1;
  select coalesce(sum(cost_usd * qty), 0) into cost from invoice_items where invoice_id = p_id;
  -- the dollars kept, and the rate they were taken at (sales made before this update used the sales rate)
  ur := coalesce(i.usd_rate, i.rate);
  nusd := coalesce(i.paid_usd, 0) - coalesce(i.change_usd, 0);
  if i.vendeur_id is not null then
    -- on credit: the vendeur owes the Francs in USD at the internal rate of the sale; against the sale at the sales rate,
    -- the difference is the exchange on the credit, as for dollars taken at the till
    cash := jsonb_build_array(jsonb_build_object('account', (select account_id from vendeurs where id = i.vendeur_id), 'side', 'Dr', 'amount', round(i.total / ur, 2),
      'currency', 'USD', 'memo', format('On credit, %s CDF at %s', i.total, trim_scale(ur)) || coalesce(', due ' || to_char(i.due_date, 'DD/MM/YYYY'), '')));
    diff := round(i.total / ur, 2) - i.total / i.rate;
    if abs(diff) >= 0.005 then
      cash := cash || jsonb_build_array(jsonb_build_object('code', 'FX_GAIN', 'side', case when diff > 0 then 'Cr' else 'Dr' end,
        'amount', round(abs(diff), 2), 'currency', 'USD', 'memo', 'Exchange on goods on credit'));
    end if;
  elsif coalesce(i.paid_usd, 0) = 0 then
    cash := jsonb_build_array(jsonb_build_object('account', app.shop_acc('CASH_SHOP', i.shop_id), 'side', 'Dr', 'amount', i.total, 'currency', 'FC', 'rate', i.rate));
  else
    -- the Francs that went with the dollars: the sale less what the dollars were taken for
    fc := i.total - round(nusd * ur)::bigint;
    cash := jsonb_build_array(
      jsonb_build_object('account', app.shop_acc('CASH_SHOP_USD', i.shop_id), 'side', case when nusd >= 0 then 'Dr' else 'Cr' end, 'amount', abs(nusd), 'currency', 'USD', 'memo', 'Paid in USD'),
      jsonb_build_object('account', app.shop_acc('CASH_SHOP', i.shop_id), 'side', case when fc >= 0 then 'Dr' else 'Cr' end, 'amount', abs(fc), 'currency', 'FC', 'rate', i.rate));
    -- a dollar taken in for less than the sales rate leaves the shop better off by the difference: that is the
    -- exchange gain, and booking it keeps the sale, the drawer and the books all right
    diff := round(nusd * (i.rate - ur) / i.rate, 2);
    if abs(diff) >= 0.005 then
      cash := cash || jsonb_build_array(jsonb_build_object('code', 'FX_GAIN', 'side', case when diff > 0 then 'Cr' else 'Dr' end,
        'amount', abs(diff), 'currency', 'USD', 'memo', 'Exchange on dollars'));
    end if;
  end if;
  perform app.post('sales', (i.t at time zone tz)::date, 'Invoice ' || i.no || coalesce(', ' || nullif(i.customer, ''), ''), i.no, 'invoice', i.id,
    cash || jsonb_build_array(
      jsonb_build_object('account', app.shop_acc('SALES_SHOP', i.shop_id), 'side', 'Cr', 'amount', i.ht, 'currency', 'FC', 'rate', i.rate),
      jsonb_build_object('code', 'VAT_OUT', 'side', 'Cr', 'amount', i.vat, 'currency', 'FC', 'rate', i.rate),
      jsonb_build_object('code', 'COGS', 'side', 'Dr', 'amount', round(cost, 2), 'currency', 'USD', 'memo', 'Cost of goods sold'),
      jsonb_build_object('account', app.shop_acc('INV_SHOP', i.shop_id), 'side', 'Cr', 'amount', round(cost, 2), 'currency', 'USD', 'memo', 'Cost of goods sold')),
    i.cashier_name);
end $$;

-- the sales on credit already made: booked again at the internal rate of their sale
do $$ declare x record; begin
  for x in select id from invoices where vendeur_id is not null and total > 0 loop perform app.post_invoice(x.id); end loop;
end $$;

revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
