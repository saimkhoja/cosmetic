-- SIM: returns to the supplier, and goods a bill charges for but the warehouse never received.
--   Return:  the warehouse (or Admin) sends goods back; they leave the central store at once and what we owe the
--            supplier drops at item cost (a debit note). The Admin settles it: the amount the supplier credits and
--            the bill it is set against.
--   Short:   when the Admin enters the bill for a goods receipt with the billed quantities, goods billed but not
--            received become a claim against the supplier, set against that bill.
-- Already running SIM? Run this file once, after 20261023000001_usd_payment.sql; it keeps your data.

create sequence if not exists public.supplier_return_seq;
create table if not exists public.supplier_returns (
  id              uuid primary key default gen_random_uuid(),
  no              text not null unique,
  supplier_id     uuid not null references public.suppliers(id),
  kind            text not null check (kind in ('return','short')),
  grn_id          uuid references public.grns(id),
  reason          text not null,
  note            text not null default '',
  status          text not null default 'open' check (status in ('open','settled','cancelled')),
  value_usd       numeric(18,2) not null default 0,
  amount_usd      numeric(18,2) not null default 0 check (amount_usd >= 0),
  voucher_id      uuid references public.vouchers(id),
  bill_id         uuid references public.vouchers(id),
  created_by_name text not null,
  created_at      timestamptz not null default now(),
  settled_by_name text,
  settled_at      timestamptz,
  cancel_reason   text
);
create table if not exists public.supplier_return_items (
  return_id  uuid not null references public.supplier_returns(id) on delete cascade,
  product_id uuid not null references public.products(id),
  qty        int not null check (qty > 0),
  cost_usd   numeric(16,6) not null default 0,
  primary key (return_id, product_id)
);
alter table public.supplier_returns enable row level security;
alter table public.supplier_return_items enable row level security;
revoke all on public.supplier_returns, public.supplier_return_items from anon, authenticated;
revoke all on sequence public.supplier_return_seq from anon, authenticated;
-- the warehouse sees what went back but not its value (no cost prices for the warehouse); the Admin reads the values
grant select (id, no, supplier_id, kind, grn_id, reason, note, status, voucher_id, bill_id, created_by_name, created_at, settled_by_name, settled_at, cancel_reason)
  on public.supplier_returns to authenticated;
grant select (return_id, product_id, qty) on public.supplier_return_items to authenticated;
drop policy if exists r on public.supplier_returns; create policy r on public.supplier_returns for select to authenticated using (app.my_role() in ('admin','whop'));
drop policy if exists r on public.supplier_return_items; create policy r on public.supplier_return_items for select to authenticated
  using (exists (select 1 from public.supplier_returns x where x.id = return_id));

-- the debit note of a return or claim: Dr the supplier by what they credit, Cr the store stock (return) or the
-- purchase price difference (short) at item cost, the difference to purchase price difference; set against its bill
create or replace function app.post_supplier_return(p_id uuid, p_by text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.supplier_returns; sup public.suppliers; vid uuid; tz text; owed numeric;
begin
  select * into r from supplier_returns where id = p_id;
  select * into sup from suppliers where id = r.supplier_id;
  select settings.tz into tz from settings where id = 1;
  vid := app.post('debit_note', (r.created_at at time zone tz)::date,
    case r.kind when 'return' then 'Return ' || r.no || ' to ' || sup.name || ': ' || r.reason else 'Claim ' || r.no || ' on ' || sup.name || ': ' || r.reason end,
    r.no, 'supplier_return', r.id,
    jsonb_build_array(
      jsonb_build_object('account', sup.account_id, 'side', 'Dr', 'amount', r.amount_usd, 'memo', r.no),
      jsonb_build_object('code', case r.kind when 'return' then 'INV_STORE' else 'PPV' end, 'side', 'Cr', 'amount', r.value_usd, 'memo', r.no),
      jsonb_build_object('code', 'PPV', 'side', case when r.amount_usd > r.value_usd then 'Cr' else 'Dr' end, 'amount', abs(r.amount_usd - r.value_usd), 'memo', 'Credited vs item cost')),
    p_by);
  update supplier_returns set voucher_id = vid where id = p_id;
  if vid is not null then
    delete from bill_allocations where voucher_id = vid;
    if r.bill_id is not null then
      owed := app.bill_outstanding(r.bill_id);
      if least(r.amount_usd, owed) > 0 then insert into bill_allocations (voucher_id, bill_id, amount_base) values (vid, r.bill_id, least(r.amount_usd, owed)); end if;
    end if;
  end if;
end $$;

create or replace function public.supplier_return_values() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'value_usd', r.value_usd, 'amount_usd', r.amount_usd,
    'bill_no', (select v.no || coalesce(' · ' || nullif(v.ref, ''), '') from vouchers v where v.id = r.bill_id))), '[]'::jsonb)
  from supplier_returns r where (select app.req('admin')) is not null
$$;

-- ---------- the warehouse (or Admin) sends goods back ----------
create or replace function public.create_supplier_return(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin','whop'); sup public.suppliers; rid uuid; rno text; short text; n int;
  reason text := btrim(coalesce(p->>'reason',''));
begin
  select * into sup from suppliers where id = (p->>'supplier_id')::uuid and active;
  if not found then raise exception 'Choose the supplier'; end if;
  if length(reason) < 3 then raise exception 'Choose why the goods go back'; end if;
  if not exists (select 1 from app.lines(p->'lines')) then raise exception 'Enter a quantity for at least one item'; end if;
  perform 1 from products where id in (select product_id from app.lines(p->'lines')) order by id for update;
  if (select count(*) from products where id in (select product_id from app.lines(p->'lines'))) <> (select count(*) from app.lines(p->'lines')) then
    raise exception 'One of the items was not found';
  end if;
  select string_agg(pr.name, ', ' order by pr.name) into short from products pr join app.lines(p->'lines') l on l.product_id = pr.id where app.available(pr.id) < l.qty;
  if short is not null then raise exception 'Not enough in the store (counting deliveries not yet received): %', short; end if;
  rno := 'RTS-' || lpad(nextval('supplier_return_seq')::text, 4, '0');
  insert into supplier_returns (no, supplier_id, kind, reason, note, created_by_name)
    values (rno, sup.id, 'return', left(reason, 60), left(btrim(coalesce(p->>'note','')), 160), u.name) returning id into rid;
  insert into supplier_return_items (return_id, product_id, qty, cost_usd)
    select rid, l.product_id, l.qty, coalesce(c.cost_usd, 0) from app.lines(p->'lines') l left join product_costs c on c.product_id = l.product_id;
  update supplier_returns set value_usd = x.v, amount_usd = x.v
    from (select round(coalesce(sum(qty * cost_usd), 0), 2) v from supplier_return_items where return_id = rid) x where id = rid;
  update products pr set wh_qty = pr.wh_qty - l.qty, updated_at = now() from app.lines(p->'lines') l where pr.id = l.product_id;
  perform app.post_supplier_return(rid, u.name);
  select sum(qty) into n from supplier_return_items where return_id = rid;
  perform app.log(u, format('Returned %s to %s: %s units, %s', rno, sup.name, n, left(reason, 60)));
  return jsonb_build_object('id', rid, 'no', rno);
end $$;

-- ---------- the Admin settles a return or claim: what the supplier credits, and the bill it goes against ----------
create or replace function public.settle_supplier_return(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); r public.supplier_returns; sup public.suppliers; amt numeric; bill uuid := (p->>'bill_id')::uuid;
begin
  select * into r from supplier_returns where id = (p->>'id')::uuid for update;
  if not found then raise exception 'Return not found'; end if;
  if r.status = 'cancelled' then raise exception '% was cancelled', r.no; end if;
  amt := round(coalesce(app.num(p->>'amount_usd'), r.amount_usd), 2);
  if amt < 0 then raise exception 'The amount cannot be negative'; end if;
  select * into sup from suppliers where id = r.supplier_id;
  if bill is not null and not exists (select 1 from vouchers v join voucher_lines l on l.voucher_id = v.id
      where v.id = bill and v.status = 'posted' and l.account_id = sup.account_id and l.side = 'Cr') then
    raise exception 'Choose a bill from %', sup.name;
  end if;
  update supplier_returns set amount_usd = amt, bill_id = coalesce(bill, case when r.kind = 'short' then r.bill_id end),
    status = 'settled', settled_by_name = u.name, settled_at = now() where id = r.id;
  perform app.post_supplier_return(r.id, u.name);
  perform app.log(u, format('%s settled with %s: %s USD', r.no, sup.name, amt));
end $$;

-- ---------- cancel a return or claim made by mistake: a return's goods come back into the store ----------
create or replace function public.cancel_supplier_return(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); r public.supplier_returns;
begin
  select * into r from supplier_returns where id = p_id for update;
  if not found then raise exception 'Return not found'; end if;
  if r.status = 'cancelled' then raise exception '% was already cancelled', r.no; end if;
  if length(btrim(coalesce(p_reason,''))) < 4 then raise exception 'Write a short reason'; end if;
  if r.kind = 'return' then
    update products pr set wh_qty = pr.wh_qty + i.qty, updated_at = now() from supplier_return_items i where i.return_id = r.id and pr.id = i.product_id;
  end if;
  if r.voucher_id is not null then
    update vouchers set status = 'cancelled', cancel_reason = btrim(p_reason) where id = r.voucher_id;
    delete from bill_allocations where voucher_id = r.voucher_id;
  end if;
  update supplier_returns set status = 'cancelled', cancel_reason = btrim(p_reason) where id = r.id;
  perform app.log(u, format('%s cancelled: %s', r.no, btrim(p_reason)));
end $$;

-- ---------- bills: billed quantities turn goods not received into a claim ----------
create or replace function public.enter_bill(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); g public.grns; sup public.suppliers; cur text := coalesce(p->>'currency', 'USD');
  r numeric := app.num(p->>'rate'); amt numeric := app.num(p->>'amount'); vat numeric := coalesce(app.num(p->>'vat'), 0);
  bdate date := coalesce((p->>'bill_date')::date, current_date); due date; bno text := btrim(coalesce(p->>'bill_no','')); std numeric := 0;
  base_total numeric; diff numeric; lines jsonb; vid uuid; debit uuid := (p->>'account_id')::uuid;
  sv numeric; rid uuid; rno text;
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
  -- goods on the bill that the warehouse did not receive become a claim against the supplier, set against this bill
  if g.id is not null and jsonb_typeof(p->'billed') = 'array' and jsonb_array_length(p->'billed') > 0 then
  if exists (select 1 from app.lines(p->'billed') b join grn_items gi on gi.grn_id = g.id and gi.product_id = b.product_id where b.qty > gi.qty) then
    select coalesce(sum((b.qty - gi.qty) * gi.std_cost_usd), 0) into sv
      from app.lines(p->'billed') b join grn_items gi on gi.grn_id = g.id and gi.product_id = b.product_id where b.qty > gi.qty;
    rno := 'RTS-' || lpad(nextval('supplier_return_seq')::text, 4, '0');
    insert into supplier_returns (no, supplier_id, kind, grn_id, reason, note, value_usd, amount_usd, bill_id, created_by_name)
      values (rno, sup.id, 'short', g.id, 'Billed but not received', 'Bill ' || bno || ', ' || g.no, round(sv, 2), round(sv, 2), vid, u.name) returning id into rid;
    insert into supplier_return_items (return_id, product_id, qty, cost_usd)
      select rid, b.product_id, b.qty - gi.qty, gi.std_cost_usd from app.lines(p->'billed') b join grn_items gi on gi.grn_id = g.id and gi.product_id = b.product_id where b.qty > gi.qty;
    perform app.post_supplier_return(rid, u.name);
    perform app.log(u, format('Claim %s against %s: billed on %s but not received, %s USD', rno, sup.name, bno, round(sv, 2)));
  end if;
  end if;
  return jsonb_build_object('voucher_id', vid, 'due_date', due, 'claim', rno);
end $$;

-- ---------- a debit note made by a return follows the return; a bill takes its own claims with it ----------
create or replace function public.cancel_voucher(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); v public.vouchers;
begin
  select * into v from vouchers where id = p_id and status = 'posted' for update;
  if not found then raise exception 'Voucher not found'; end if;
  if length(btrim(coalesce(p_reason,''))) < 4 then raise exception 'Write a short reason'; end if;
  if v.source_type = 'supplier_return' then raise exception 'This debit note follows a return to the supplier; cancel it under Goods in, Returns to supplier'; end if;
  if v.type not in ('payment','receipt','contra','journal','debit_note','credit_note','purchase') then
    raise exception 'This voucher was made by SIM from % and follows it; correct the source instead', v.source_type;
  end if;
  -- the bill's own claims for goods not received go with it; anything else set against it must be cancelled first
  if v.type = 'purchase' and exists (select 1 from bill_allocations ba join vouchers dv on dv.id = ba.voucher_id where ba.bill_id = p_id and dv.status = 'posted'
       and not exists (select 1 from supplier_returns sr where sr.voucher_id = dv.id and sr.kind = 'short' and sr.bill_id = p_id)) then
    raise exception 'This bill is already (partly) paid or has a return set against it; cancel that first';
  end if;
  if v.type = 'purchase' then
    update vouchers set status = 'cancelled', cancel_reason = 'Bill ' || v.no || ' cancelled'
      where id in (select voucher_id from supplier_returns where bill_id = p_id and kind = 'short' and status <> 'cancelled' and voucher_id is not null);
    delete from bill_allocations where voucher_id in (select voucher_id from supplier_returns where bill_id = p_id and kind = 'short' and voucher_id is not null);
    update supplier_returns set status = 'cancelled', cancel_reason = 'Bill ' || v.no || ' cancelled' where bill_id = p_id and kind = 'short' and status <> 'cancelled';
  end if;
  update vouchers set status = 'cancelled', cancel_reason = btrim(p_reason) where id = p_id;
  delete from bill_allocations where voucher_id = p_id;
  update grns set status = 'awaiting_bill', bill_voucher_id = null where bill_voucher_id = p_id;
  perform app.log(u, format('Voucher %s cancelled: %s', v.no, btrim(p_reason)));
end $$;

-- ---------- who may call what ----------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.create_supplier_return(jsonb), public.settle_supplier_return(jsonb), public.cancel_supplier_return(uuid, text), public.supplier_return_values(),
  public.enter_bill(jsonb), public.cancel_voucher(uuid, text) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
