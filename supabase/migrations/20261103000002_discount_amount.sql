-- QuickSales: a discount can be given as an amount in CDF as well as a percentage. The percentage of an
-- amount follows from the invoice total (2 decimals), so invoices.disc_pct becomes numeric. The 30% limit is the same.
-- submit_invoice takes "disc" (an amount) or "disc_pct"; edit_invoice takes p_disc (%) or p_disc_amount.
-- Already running QuickSales? Run this file once, after 20261103000001_till_invoices.sql, BEFORE the new app goes live.
-- It keeps your data; tills with the old app keep giving discounts in whole percentages.

alter table public.invoices alter column disc_pct type numeric(5,2);

-- ---------- sales and approvals: a discount as a percentage or an amount ----------
create or replace function public.submit_invoice(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin','till'); iid uuid := (p->>'id')::uuid; ex public.invoices; dv public.devices; s public.shops;
  cashier public.profiles; seq int; r numeric := app.num(p->>'rate'); vr numeric := app.num(p->>'vat_rate'); dp numeric; t timestamptz;
  da bigint := app.num(p->>'disc')::bigint;
  it jsonb; pr public.products; pc public.product_costs; ln int := 0; q int; mult int; piece boolean; price bigint; cur bigint; unit text; cost numeric;
  v_gross bigint := 0; v_disc bigint; v_total bigint; v_vat bigint; tend bigint; flag boolean := false;
  cust text := btrim(coalesce(p->>'customer','')); o public.sale_orders; oid uuid := (p->>'order_id')::uuid;
  pusd numeric := round(coalesce(app.num(p->>'paid_usd'), 0), 2); cusd numeric := coalesce(app.num(p->>'change_usd'), 0); pcdf bigint; ccdf bigint;
  sold text; printed text; revised boolean := false;
begin
  if iid is null then raise exception 'Invoice id is missing'; end if;
  select * into ex from invoices where id = iid;
  if found then
    if ex.shop_id <> u.shop_id then raise exception 'Invoice id already used'; end if;
    return jsonb_build_object('status', 'duplicate', 'no', ex.no);
  end if;
  -- a till operator sells only when the Admin turned the switch on, and never approves orders or gives discounts
  if u.role = 'till' then
    if not app.feature('till_sells') then raise exception 'You do not have permission for this action'; end if;
    if oid is not null then raise exception 'Only the shop admin approves orders'; end if;
    if coalesce(app.num(p->>'disc_pct'), 0) <> 0 or coalesce(da, 0) <> 0 then raise exception 'Only the shop admin gives a discount'; end if;
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
    unit := app.unit_of(pr, mult, piece);
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
  v_total := v_gross - v_disc; v_vat := round(v_total * vr / (100 + vr))::bigint;
  -- payment: Francs only, or (with "Accept payment in USD" on) dollars and Francs at the sale's rate
  if pusd < 0 or cusd < 0 or coalesce(app.num(p->>'paid_cdf'), 0) < 0 then raise exception 'Amounts received cannot be negative'; end if;
  if cusd <> trunc(cusd) then raise exception 'Dollars given back must be whole dollars'; end if;
  if (pusd > 0 or cusd > 0) and not app.feature('usd_pay') then raise exception 'Payment in USD is not turned on'; end if;
  if pusd > 0 then
    pcdf := coalesce(app.num(p->>'paid_cdf'), 0)::bigint;
    tend := pcdf + round(pusd * r)::bigint;
  else
    tend := coalesce(app.num(p->>'tendered')::bigint, v_total);
    pcdf := tend;
  end if;
  if tend < v_total then raise exception 'Cash received is less than the total'; end if;
  if cusd > pusd then raise exception 'Dollars given back cannot be more than the dollars received'; end if;
  if round(cusd * r) > tend - v_total then raise exception 'Dollars given back are more than the change'; end if;
  ccdf := (tend - v_total) - round(cusd * r)::bigint;
  -- changed at approval: other lines, quantities, units or prices than printed, or a discount
  if o.invoice_no is not null then
    select string_agg(ii.product_id::text || ':' || ii.mult || ':' || ii.piece || ':' || ii.qty || ':' || ii.price, ','
      order by ii.product_id::text, ii.mult, ii.piece, ii.qty, ii.price)
      into sold from invoice_items ii where ii.invoice_id = iid;
    select string_agg((x->>'product_id') || ':' || (x->>'mult') || ':' || (x->>'piece') || ':' || (x->>'qty') || ':' || (x->>'price'), ','
      order by (x->>'product_id'), (x->>'mult')::int, (x->>'piece')::boolean, (x->>'qty')::int, (x->>'price')::bigint)
      into printed from jsonb_array_elements(o.items) x;
    revised := v_disc > 0 or v_total is distinct from o.total or sold is distinct from printed;
  end if;
  update invoices set gross = v_gross, disc_pct = dp, disc = v_disc, total = v_total, vat = v_vat, ht = v_total - v_vat, tendered = tend, change = tend - v_total,
    paid_usd = pusd, paid_cdf = pcdf, change_usd = cusd::int, change_cdf = ccdf, price_flag = flag,
    revised_from = case when revised then o.total end
    where id = iid;
  update devices set last_seq = greatest(last_seq, seq) where id = dv.id;
  if oid is not null then
    update sale_orders set status = 'approved', reviewed_by_name = cashier.name, reviewed_at = now(), invoice_id = iid where id = oid;
  end if;
  perform app.log(u, format('Invoice %s for %s, cash, %s%s%s', p->>'no', coalesce(nullif(cust, ''), 'walk-in'), app.fc(v_total), case when v_disc > 0 then format(', discount %s (%s%%)', app.fc(v_disc), trim_scale(dp)) else '' end,
    case when oid is not null then ' (order from ' || o.created_by_name || ' approved' || case when revised then ', changed from ' || app.fc(o.total) else '' end || ')' else '' end));
  return jsonb_build_object('status', 'ok', 'no', p->>'no', 'total', v_total, 'price_flag', flag, 'revised', revised);
end $$;

-- ---------- editing an invoice: the discount as a percentage or an amount ----------
drop function if exists public.edit_invoice(uuid, jsonb, int, text);
create or replace function public.edit_invoice(p_id uuid, p_lines jsonb, p_disc numeric, p_reason text, p_disc_amount bigint default null) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); inv public.invoices; it record; x jsonb; li public.invoice_items; pr public.products; pc public.product_costs;
  v_piece boolean; v_mult int; v_unit text; v_price bigint; v_cost numeric; changed text[] := '{}';
  v_gross bigint; v_disc bigint; v_total bigint; v_vat bigint; dp numeric := round(coalesce(p_disc, 0), 2);
begin
  select * into inv from invoices where id = p_id and shop_id = u.shop_id for update;
  if not found then raise exception 'Invoice not found'; end if;
  if length(btrim(coalesce(p_reason,''))) < 4 then raise exception 'Write a short reason for the change'; end if;
  if dp < 0 or dp > 30 or p_disc_amount < 0 then raise exception 'Discount must be between 0%% and 30%%'; end if;
  if jsonb_typeof(p_lines) <> 'array' then raise exception 'The lines are missing'; end if;
  if exists (select 1 from jsonb_array_elements(p_lines) e where coalesce(e->>'qty','') !~ '^\d{1,7}$') then
    raise exception 'Quantities must be whole numbers';
  end if;
  for it in select i.*, p.pieces_per_set from invoice_items i join products p on p.id = i.product_id where i.invoice_id = p_id loop
    perform app.give_back(inv.shop_id, it.product_id, it.qty, it.mult, it.piece, it.pieces_per_set);
  end loop;
  for x in select * from jsonb_array_elements(p_lines) loop
    select * into li from invoice_items where invoice_id = p_id and line_no = (x->>'line_no')::int;
    if not found or not (x ? 'mult' or x ? 'piece') then continue; end if;
    v_piece := coalesce((x->>'piece')::boolean, li.piece);
    v_mult := case when v_piece then 0 else coalesce(app.num(x->>'mult')::int, li.mult) end;
    if v_piece is not distinct from li.piece and v_mult = li.mult then continue; end if;
    select * into pr from products where id = li.product_id;
    select * into pc from product_costs where product_id = pr.id;
    v_unit := app.unit_of(pr, v_mult, v_piece);
    v_price := app.unit_price(pr, v_unit, inv.rate);
    if v_price <= 0 then raise exception '% has no price for %', pr.name, v_unit; end if;
    v_cost := case when v_piece then coalesce(pc.cost_usd,0) / greatest(pr.pieces_per_set,1) else coalesce(pc.cost_usd,0) * v_mult end;
    update invoice_items set unit = v_unit, mult = v_mult, piece = v_piece, price = v_price, cost_usd = v_cost where invoice_id = p_id and line_no = li.line_no;
    changed := changed || format('%s %s to %s', li.name, li.unit, v_unit);
  end loop;
  update invoice_items i set qty = (e->>'qty')::int, line = i.price * (e->>'qty')::int
    from jsonb_array_elements(p_lines) e where i.invoice_id = p_id and i.line_no = (e->>'line_no')::int and (e->>'qty')::int > 0;
  delete from invoice_items i where i.invoice_id = p_id and not exists
    (select 1 from jsonb_array_elements(p_lines) e where (e->>'line_no')::int = i.line_no and (e->>'qty')::int > 0);
  if not exists (select 1 from invoice_items where invoice_id = p_id) then raise exception 'Keep at least one line on the invoice'; end if;
  for it in select i.*, p.pieces_per_set from invoice_items i join products p on p.id = i.product_id where i.invoice_id = p_id loop
    perform app.take(inv.shop_id, it.product_id, it.qty, it.mult, it.piece, it.pieces_per_set);
  end loop;
  select sum(line) into v_gross from invoice_items where invoice_id = p_id;
  -- a percentage (the amount rounded to 10 CDF), or an amount whose percentage follows from the new total
  if p_disc_amount is not null then
    if p_disc_amount * 100 > v_gross * 30 then raise exception 'Discount must be between 0%% and 30%%'; end if;
    v_disc := p_disc_amount; dp := case when v_gross > 0 then round(p_disc_amount * 100.0 / v_gross, 2) else 0 end;
  else
    v_disc := (round(v_gross * dp / 1000.0) * 10)::bigint;
  end if;
  v_total := v_gross - v_disc; v_vat := round(v_total * inv.vat_rate / (100 + inv.vat_rate))::bigint;
  update invoices set gross = v_gross, disc_pct = dp, disc = v_disc, total = v_total,
    vat = v_vat, ht = v_total - v_vat, tendered = v_total, change = 0 where id = p_id;
  insert into invoice_edits (invoice_id, by_id, by_name, reason, from_total, to_total) values (p_id, u.id, u.name, btrim(p_reason), inv.total, v_total);
  perform app.log(u, format('Invoice %s edited by %s: %s to %s%s, %s', inv.no, u.name, app.fc(inv.total), app.fc(v_total),
    case when array_length(changed, 1) > 0 then ', unit ' || array_to_string(changed, ', ') else '' end, btrim(p_reason)));
  return jsonb_build_object('from_total', inv.total, 'to_total', v_total);
end $$;

-- ---------- who may call what ----------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.edit_invoice(uuid, jsonb, numeric, text, bigint) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
