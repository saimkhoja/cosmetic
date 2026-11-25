-- QuickSales: returns from a shop, decided by the Admin (for a business without a central store).
-- Without a central store nobody can receive a shop's return into the store. The Shop Admin still sends goods back
-- (Returns, New return): they leave the shop at once and wait for the Admin. The Admin then counts what came back
-- (a missing piece is booked as a loss, with a note) and decides where the goods go:
--   supplier   back to the supplier: a return to supplier (RTS) is made with those goods and what we owe the supplier
--              drops at item cost; the Admin settles or cancels it later under Accounts, like any return to supplier.
--              Cancelling it puts the goods back in the shop they came from.
--   shop       into another shop's stock
--   writeoff   thrown away (damaged, expired): booked as a stock adjustment
-- The Shop Admin (or the Admin) can still cancel a return while it waits: the goods go back into the shop.
-- Books: sending is Dr goods in transit, Cr the shop's stock (as before). Deciding clears the goods in transit:
--   supplier: Dr the supplier, Cr goods in transit (the debit note);  shop: Dr the other shop's stock;
--   writeoff and short: Dr stock adjustment.
-- Already running QuickSales? Run this file once, after 20261123000001_stock_in_fix.sql. It keeps your data.

-- stop at once if the update before this one was not run
do $$ begin
  if not exists (select 1 from pg_proc where proname = 'stock_in_shops' and pg_get_functiondef(oid) like '%delete from stock_in_lines where true%') then
    raise exception 'Run supabase/migrations/20261123000001_stock_in_fix.sql (and every earlier file) first, then this file. supabase/scripts/check_migrations.sql shows what is missing';
  end if;
end $$;

-- what became of a return: received into the central store, or the Admin's decision
alter table public.shop_returns add column if not exists outcome text check (outcome in ('store','supplier','shop','writeoff'));
alter table public.shop_returns add column if not exists to_shop_id uuid references public.shops(id);
alter table public.shop_returns add column if not exists supplier_return_id uuid references public.supplier_returns(id);
update public.shop_returns set outcome = 'store' where status = 'received' and outcome is null;
-- a return to supplier made from a shop's return: its goods are in transit, not in the central store
alter table public.supplier_returns add column if not exists from_return_id uuid references public.shop_returns(id);
grant select (from_return_id) on public.supplier_returns to authenticated;

-- the debit note of a return or claim (as before); a return made from a shop's return credits goods in transit
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
      jsonb_build_object('code', case when r.kind = 'short' then 'PPV' when r.from_return_id is not null then 'TRANSIT' else 'INV_STORE' end,
        'side', 'Cr', 'amount', r.value_usd, 'memo', r.no),
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

-- ---------- the Admin decides where a shop's returned goods go ----------
-- p: {id, outcome: supplier|shop|writeoff, lines: [{product_id, qty}] (what came back; missing = all), note,
--     supplier_id (for supplier), shop_id (for shop)}
create or replace function public.decide_return(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); x public.shop_returns; dest text := coalesce(p->>'outcome', ''); note text := btrim(coalesce(p->>'note',''));
  sent int; got int; vgot numeric; vshort numeric; bad text; from_shop text; sup public.suppliers; sh public.shops; rid uuid; rno text; what text;
begin
  select * into x from shop_returns where id = (p->>'id')::uuid for update;
  if not found then raise exception 'Return not found'; end if;
  if x.status <> 'pending' then raise exception 'Return % was already %', x.no, x.status; end if;
  if dest not in ('supplier','shop','writeoff') then raise exception 'Choose where the goods go: back to the supplier, to another shop, or thrown away'; end if;
  select name into from_shop from shops where id = x.shop_id;
  if dest = 'supplier' then
    select * into sup from suppliers where id = (p->>'supplier_id')::uuid and active;
    if not found then raise exception 'Choose the supplier'; end if;
  elsif dest = 'shop' then
    select * into sh from shops where id = (p->>'shop_id')::uuid and active;
    if not found then raise exception 'Choose the shop'; end if;
    if sh.id = x.shop_id then raise exception 'The goods came from %; choose another shop, or cancel the return to put them back', sh.name; end if;
  end if;

  -- what came back
  if exists (select 1 from jsonb_array_elements(case when jsonb_typeof(p->'lines') = 'array' then p->'lines' else '[]' end) e
             where coalesce(e->>'qty','') !~ '^\d{1,7}$') then
    raise exception 'Quantities must be whole numbers';
  end if;
  update return_items i set received_qty = coalesce((select (e->>'qty')::int from jsonb_array_elements(case when jsonb_typeof(p->'lines') = 'array' then p->'lines' else '[]' end) e
      where (e->>'product_id')::uuid = i.product_id limit 1), i.qty)
    where i.return_id = x.id;
  select string_agg(pr.name, ', ') into bad from return_items i join products pr on pr.id = i.product_id where i.return_id = x.id and i.received_qty > i.qty;
  if bad is not null then raise exception 'You cannot receive more than was sent: %', bad; end if;
  select sum(qty), sum(received_qty), sum(received_qty * cost_usd), sum((qty - received_qty) * cost_usd) into sent, got, vgot, vshort from return_items where return_id = x.id;
  if got < sent and length(note) < 4 then raise exception 'Some items came back short. Write a short note saying what happened'; end if;
  if got = 0 and dest <> 'writeoff' then raise exception 'Nothing came back: enter what came back, or choose thrown away'; end if;

  if dest = 'supplier' then
    rno := 'RTS-' || lpad(nextval('supplier_return_seq')::text, 4, '0');
    insert into supplier_returns (no, supplier_id, kind, reason, note, created_by_name, from_return_id)
      values (rno, sup.id, 'return', left(x.reason, 60), left(format('From %s, %s', x.no, from_shop) || coalesce(', ' || nullif(note, ''), ''), 160), u.name, x.id)
      returning id into rid;
    insert into supplier_return_items (return_id, product_id, qty, cost_usd)
      select rid, i.product_id, i.received_qty, i.cost_usd from return_items i where i.return_id = x.id and i.received_qty > 0;
    update supplier_returns set value_usd = v.v, amount_usd = v.v
      from (select round(coalesce(sum(qty * cost_usd), 0), 2) v from supplier_return_items where return_id = rid) v where id = rid;
    perform app.post_supplier_return(rid, u.name);
    what := format('back to %s as %s', sup.name, rno);
  elsif dest = 'shop' then
    insert into shop_stock (shop_id, product_id, qty)
      select sh.id, i.product_id, i.received_qty from return_items i where i.return_id = x.id and i.received_qty > 0
      on conflict (shop_id, product_id) do update set qty = shop_stock.qty + excluded.qty;
    what := 'into ' || sh.name;
  else
    what := 'thrown away';
  end if;

  update shop_returns set status = 'received', received_at = now(), received_by_name = u.name, received_note = nullif(note, ''),
    outcome = dest, to_shop_id = sh.id, supplier_return_id = rid where id = x.id;
  -- goods in transit cleared: the other shop's stock, or a loss; a return to supplier clears them with its debit note
  perform app.post('return', current_date, left(format('%s from %s: %s%s', x.no, from_shop, what, coalesce(', ' || nullif(note, ''), '')), 200), x.no, 'return_in', x.id,
    jsonb_build_array(
      jsonb_build_object('account', case when dest = 'shop' then app.shop_acc('INV_SHOP', sh.id) end, 'code', case when dest = 'writeoff' then 'STOCK_ADJ' end,
        'side', 'Dr', 'amount', case when dest = 'supplier' then 0 else round(vgot, 2) end, 'memo', case when dest = 'writeoff' then 'Thrown away, return ' || x.no end),
      jsonb_build_object('code', 'STOCK_ADJ', 'side', 'Dr', 'amount', round(vshort, 2), 'memo', 'Short on return ' || x.no),
      jsonb_build_object('code', 'TRANSIT', 'side', 'Cr', 'amount', case when dest = 'supplier' then 0 else round(vgot, 2) end + round(vshort, 2))), u.name);
  perform app.log(u, format('Return %s from %s: %s of %s units %s%s', x.no, from_shop, got, sent, what, coalesce(', ' || nullif(note, ''), '')));
  return jsonb_build_object('sent', sent, 'received', got, 'supplier_return', rno);
end $$;

-- ---------- cancel a return or claim made by mistake (as before); goods from a shop's return go back to that shop ----------
create or replace function public.cancel_supplier_return(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); r public.supplier_returns; x public.shop_returns;
begin
  select * into r from supplier_returns where id = p_id for update;
  if not found then raise exception 'Return not found'; end if;
  if r.status = 'cancelled' then raise exception '% was already cancelled', r.no; end if;
  if length(btrim(coalesce(p_reason,''))) < 4 then raise exception 'Write a short reason'; end if;
  if r.kind = 'return' and r.from_return_id is not null then
    select * into x from shop_returns where id = r.from_return_id;
    insert into shop_stock (shop_id, product_id, qty)
      select x.shop_id, i.product_id, i.qty from supplier_return_items i where i.return_id = r.id
      on conflict (shop_id, product_id) do update set qty = shop_stock.qty + excluded.qty;
    perform app.post('return', current_date, left(format('%s cancelled: the goods of %s go back to %s', r.no, x.no, (select name from shops where id = x.shop_id)), 200),
      r.no, 'return_back', r.id,
      jsonb_build_array(jsonb_build_object('account', app.shop_acc('INV_SHOP', x.shop_id), 'side', 'Dr', 'amount', r.value_usd, 'memo', r.no),
                        jsonb_build_object('code', 'TRANSIT', 'side', 'Cr', 'amount', r.value_usd, 'memo', r.no)), u.name);
  elsif r.kind = 'return' then
    update products pr set wh_qty = pr.wh_qty + i.qty, updated_at = now() from supplier_return_items i where i.return_id = r.id and pr.id = i.product_id;
  end if;
  if r.voucher_id is not null then
    update vouchers set status = 'cancelled', cancel_reason = btrim(p_reason) where id = r.voucher_id;
    delete from bill_allocations where voucher_id = r.voucher_id;
  end if;
  update supplier_returns set status = 'cancelled', cancel_reason = btrim(p_reason) where id = r.id;
  perform app.log(u, format('%s cancelled: %s', r.no, btrim(p_reason)));
end $$;

-- ---------- who may call what ----------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.decide_return(jsonb), public.cancel_supplier_return(uuid, text) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
