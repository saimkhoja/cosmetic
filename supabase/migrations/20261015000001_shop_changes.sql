-- SIM update 3: selling price per pc is optional (like half dozen, dozen and carton), the unit of
-- an invoice line can be changed when the invoice is edited, and the shop admin can delete an invoice.
-- Run after the earlier files. Safe to run more than once.

-- ---------- price per pc optional ----------
alter table public.products drop constraint if exists products_price_usd_check;
alter table public.products add constraint products_price_usd_check check (price_usd >= 0);

-- value of one pc (or set) at selling price, from the first unit that has a price
create or replace function app.pc_value(pr public.products) returns numeric
language sql immutable as $$
  select case when pr.price_usd > 0 then pr.price_usd
    when pr.half_dozen_usd > 0 then pr.half_dozen_usd / 6
    when pr.dozen_usd > 0 then pr.dozen_usd / 12
    when pr.carton_usd > 0 and pr.per_carton > 0 then pr.carton_usd / pr.per_carton
    else 0 end
$$;

create or replace function app.product_fields(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  name text := btrim(regexp_replace(coalesce(p->>'name',''), '\s+', ' ', 'g'));
  cat text := btrim(coalesce(p->>'category',''));
  b boolean := coalesce((p->>'is_bundle')::boolean, false);
  cc numeric; per numeric; pc numeric; dz numeric; hz numeric; ctn numeric; cpc numeric;
  sc numeric; sp numeric; pcs numeric; pp numeric;
begin
  if name = '' then raise exception 'Enter the item name'; end if;
  if length(name) > 60 then raise exception 'Item name is too long (60 characters at most)'; end if;
  if cat = '' then raise exception 'Choose the category'; end if;
  select c.name into cat from categories c where lower(c.name) = lower(cat);
  if cat is null then raise exception 'Category "%" does not exist. The Admin creates categories first', btrim(p->>'category'); end if;
  if b then
    sc := app.num(p->>'set_cost'); sp := app.num(p->>'set_price'); pcs := app.num(p->>'pcs'); pp := app.num(p->>'piece');
    if sc is null or sc < 0 or sp is null or sp <= 0 then raise exception 'Enter the cost and selling price of one set'; end if;
    if sp < sc then raise exception 'Set price cannot be below its cost'; end if;
    if pcs is null or pcs < 2 or pcs <> trunc(pcs) or pp is null or pp <= 0 then
      raise exception 'For a mixed set, enter the pieces per set and the last price for one piece';
    end if;
    return jsonb_build_object('name',name,'category',cat,'stock_unit','set','is_bundle',true,
      'per_carton',0,'pieces_per_set',pcs::int,'price_usd',sp,'dozen_usd',0,'half_dozen_usd',0,'carton_usd',0,'piece_usd',pp,
      'carton_cost_usd',0,'cost_usd',sc);
  end if;
  cc := app.num(p->>'carton_cost'); per := app.num(p->>'per_carton'); pc := coalesce(app.num(p->>'pc'), 0);
  dz := coalesce(app.num(p->>'dzn'), 0); hz := coalesce(app.num(p->>'half'), 0); ctn := coalesce(app.num(p->>'ctn'), 0);
  if cc is null or cc < 0 then raise exception 'Enter the cost of one carton'; end if;
  if per is null or per < 2 or per <> trunc(per) then raise exception 'Enter how many pcs are in one carton (2 or more)'; end if;
  if pc < 0 or dz < 0 or hz < 0 or ctn < 0 then raise exception 'Prices cannot be negative'; end if;
  cpc := cc / per;
  -- a carton of 12 (or 6) is the dozen (or half dozen): that price is the carton price
  if per = 12 then ctn := coalesce(nullif(ctn, 0), dz); dz := 0; end if;
  if per = 6 then ctn := coalesce(nullif(ctn, 0), hz); hz := 0; end if;
  if pc = 0 and hz = 0 and dz = 0 and ctn = 0 then raise exception 'Enter at least one selling price: per pc, half dozen, dozen or carton'; end if;
  if pc > 0 and pc < cpc - 0.000000001 then raise exception 'Price per pc is below the cost of one pc (%)', app.usd(cpc); end if;
  if hz > 0 and hz < cpc * 6 - 0.000000001 then raise exception 'Price per half dozen is below the cost of 6 pcs (%)', app.usd(cpc * 6); end if;
  if dz > 0 and dz < cpc * 12 - 0.000000001 then raise exception 'Price per dozen is below the cost of 12 pcs (%)', app.usd(cpc * 12); end if;
  if ctn > 0 and ctn < cc then raise exception 'Price per carton cannot be below the carton cost'; end if;
  return jsonb_build_object('name',name,'category',cat,'stock_unit','pcs','is_bundle',false,
    'per_carton',per::int,'pieces_per_set',0,'price_usd',pc,'dozen_usd',dz,'half_dozen_usd',hz,'carton_usd',ctn,'piece_usd',0,
    'carton_cost_usd',cc,'cost_usd',cpc);
end $$;

create or replace function app.units_text(p public.products) returns text
language sql immutable as $$
  select case when p.is_bundle then 'set ' || app.usd(p.price_usd) || ', piece ' || app.usd(p.piece_usd)
    else concat_ws(', ', case when p.price_usd > 0 then 'pcs ' || app.usd(p.price_usd) end,
         case when p.half_dozen_usd > 0 then 'half dzn ' || app.usd(p.half_dozen_usd) end,
         case when p.dozen_usd > 0 then 'dzn ' || app.usd(p.dozen_usd) end,
         case when p.carton_usd > 0 then 'carton ' || app.usd(p.carton_usd) end) end
$$;

create or replace function app.unit_of(pr public.products, mult int, piece boolean) returns text
language plpgsql stable as $$
begin
  if piece then
    if not pr.is_bundle then raise exception '% is not sold by piece', pr.name; end if;
    return 'piece';
  elsif pr.is_bundle then
    if mult <> 1 then raise exception 'Unit not valid for %', pr.name; end if;
    return 'set';
  elsif mult = 1 and pr.price_usd > 0 then return 'pcs';
  elsif mult = 6 and pr.half_dozen_usd > 0 and pr.per_carton <> 6 then return 'half dzn';
  elsif mult = 12 and pr.dozen_usd > 0 and pr.per_carton <> 12 then return 'dzn';
  elsif mult = pr.per_carton and pr.carton_usd > 0 then return 'carton';
  end if;
  raise exception 'Unit not valid for %', pr.name;
end $$;

-- the delivery note values goods at the selling price of one pc; an item sold only by the dozen or carton gets its per-pc value
create or replace function app.trg_delivery_price() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if coalesce(new.price_usd, 0) = 0 then select app.pc_value(p) into new.price_usd from products p where p.id = new.product_id; end if;
  return new;
end $$;
drop trigger if exists delivery_price on public.delivery_items;
create trigger delivery_price before insert on public.delivery_items for each row execute function app.trg_delivery_price();

-- ---------- edit an invoice: quantities, units and discount ----------
-- lines: [{line_no, qty, mult?, piece?}]. A changed unit is charged at the current price of that unit, at the invoice's rate.
create or replace function public.edit_invoice(p_id uuid, p_lines jsonb, p_disc int, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); inv public.invoices; it record; x jsonb; li public.invoice_items; pr public.products; pc public.product_costs;
  v_piece boolean; v_mult int; v_unit text; v_price bigint; v_cost numeric; changed text[] := '{}';
  v_gross bigint; v_disc bigint; v_total bigint; v_vat bigint;
begin
  select * into inv from invoices where id = p_id and shop_id = u.shop_id for update;
  if not found then raise exception 'Invoice not found'; end if;
  if length(btrim(coalesce(p_reason,''))) < 4 then raise exception 'Write a short reason for the change'; end if;
  if coalesce(p_disc,0) < 0 or coalesce(p_disc,0) > 30 then raise exception 'Discount must be between 0%% and 30%%'; end if;
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
  v_disc := (round(v_gross * coalesce(p_disc,0) / 1000.0) * 10)::bigint; v_total := v_gross - v_disc; v_vat := round(v_total * inv.vat_rate / (100 + inv.vat_rate))::bigint;
  update invoices set gross = v_gross, disc_pct = coalesce(p_disc,0), disc = v_disc, total = v_total,
    vat = v_vat, ht = v_total - v_vat, tendered = v_total, change = 0 where id = p_id;
  insert into invoice_edits (invoice_id, by_id, by_name, reason, from_total, to_total) values (p_id, u.id, u.name, btrim(p_reason), inv.total, v_total);
  perform app.log(u, format('Invoice %s edited by %s: %s to %s%s, %s', inv.no, u.name, app.fc(inv.total), app.fc(v_total),
    case when array_length(changed, 1) > 0 then ', unit ' || array_to_string(changed, ', ') else '' end, btrim(p_reason)));
  return jsonb_build_object('from_total', inv.total, 'to_total', v_total);
end $$;

-- ---------- delete an invoice ----------
-- removes the invoice completely: its stock goes back to the shop and it leaves the sales, reports and books.
-- The activity log keeps what it was and why it was deleted.
create or replace function public.delete_invoice(p_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin','admin'); inv public.invoices; it record; lines text;
begin
  select * into inv from invoices where id = p_id and (u.role = 'admin' or shop_id = u.shop_id) for update;
  if not found then raise exception 'Invoice not found'; end if;
  if length(btrim(coalesce(p_reason,''))) < 4 then raise exception 'Write a short reason for deleting this invoice'; end if;
  select string_agg(qty || ' ' || unit || ' ' || name, ', ' order by line_no) into lines from invoice_items where invoice_id = p_id;
  for it in select i.*, p.pieces_per_set from invoice_items i join products p on p.id = i.product_id where i.invoice_id = p_id loop
    perform app.give_back(inv.shop_id, it.product_id, it.qty, it.mult, it.piece, it.pieces_per_set);
  end loop;
  delete from vouchers where source_type = 'invoice' and source_id = p_id;
  update sale_orders set status = 'rejected', invoice_id = null, reason = left('Invoice ' || inv.no || ' deleted: ' || btrim(p_reason), 120),
    reviewed_by_name = u.name, reviewed_at = now() where invoice_id = p_id;
  delete from invoices where id = p_id;
  perform app.log(u, format('Invoice %s deleted by %s: %s, customer %s, %s (%s). Reason: %s', inv.no, u.name, app.fc(inv.total),
    coalesce(nullif(inv.customer, ''), '-'), coalesce(lines, ''), (select name from shops where id = inv.shop_id), btrim(p_reason)));
  return jsonb_build_object('no', inv.no, 'total', inv.total);
end $$;

-- ---------- delete a supplier ----------
-- A supplier with nothing recorded is deleted with its ledger. One with goods received, bills or
-- payments keeps its history: it is made inactive (hidden, nothing new can be received from it) and
-- can be made active again from its form. Money still owed either way must be settled first.
create or replace function public.delete_supplier(p_id uuid) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); s public.suppliers; a public.accounts; bal numeric;
begin
  select * into s from suppliers where id = p_id for update;
  if not found then raise exception 'Supplier not found'; end if;
  select * into a from accounts where id = s.account_id;
  bal := app.opening_base(a) + coalesce((select sum(case when l.side = 'Dr' then l.base else -l.base end) from voucher_lines l join vouchers v on v.id = l.voucher_id
    where l.account_id = a.id and v.status = 'posted'), 0);
  if abs(bal) > 0.005 then
    raise exception '% still has a balance of % %. Settle it (or clear the opening balance) first', s.name, app.usd(abs(bal)), case when bal < 0 then 'owed to them' else 'owed to us' end;
  end if;
  if exists (select 1 from grns where supplier_id = p_id) or exists (select 1 from voucher_lines where account_id = a.id) then
    update suppliers set active = false where id = p_id;
    perform app.log(u, 'Supplier ' || s.name || ' made inactive (it has goods receipts or entries)');
    return 'archived';
  end if;
  delete from suppliers where id = p_id;
  delete from accounts where id = a.id;
  perform app.log(u, 'Deleted supplier ' || s.name);
  return 'deleted';
end $$;

-- ---------- who may call what ----------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.edit_invoice(uuid, jsonb, int, text), public.delete_invoice(uuid, text), public.delete_supplier(uuid) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
