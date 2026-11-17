-- QuickSales: shops without a central store.
-- A switch in Settings → Options, off by default: everything works as before, goods arrive in the central store
-- and are sent on to the shops.
-- With "No central store" on, the business has no warehouse: goods bought from a supplier go straight into a shop.
-- Receiving from a supplier then asks which shop, the quantities are added to that shop's stock, and the goods are
-- booked to that shop's stock account instead of the central store's. The tabs that move stock between the store
-- and the shops (Deliveries, Stock requests and Returns to the store) are hidden while the switch is on.
-- Each goods receipt remembers the shop it went into (grns.shop_id; empty means the central store, as before).
-- Already running QuickSales? Run this file once, after 20261111000006_one_copy.sql, BEFORE the new app goes live.

-- stop at once if the update before this one was not run
do $$ begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'invoices' and column_name = 'copies') then
    raise exception 'Run supabase/migrations/20261111000006_one_copy.sql (and every earlier file) first, then this file. supabase/scripts/check_migrations.sql shows what is missing';
  end if;
end $$;

-- the shop a receipt went into; empty = the central store, as every receipt made before this update
alter table public.grns add column if not exists shop_id uuid references public.shops(id);

-- the switch is saved with the others
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
  foreach k in array array['customer_optional','barcode','till_sells','cash_change','usd_pay','one_copy','no_warehouse'] loop
    fe := fe || jsonb_build_object(k, coalesce((p->'features'->>k)::boolean, false));
  end loop;
  select rate, book_rate into old, old_br from settings where id = 1 for update;
  br := coalesce(br, old_br);   -- an older app that does not send the internal rate keeps it as it is
  update settings set rate = r, book_rate = br, vat = v, company = c, features = fe, updated_at = now() where id = 1;
  if old <> r then perform app.log(u, format('Sales rate changed %s to %s', old, r)); end if;
  if old_br <> br then perform app.log(u, format('Internal rate changed %s to %s', old_br, br)); end if;
  if old = r and old_br = br then perform app.log(u, 'Settings updated'); end if;
end $$;

-- receiving from a supplier: into the central store as before, or straight into a shop when there is no store
create or replace function public.receive_goods(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin','whop'); sup public.suppliers; gid uuid; gno text; v numeric; n int;
  direct boolean := app.feature('no_warehouse'); sid uuid := (p->>'shop_id')::uuid; sh public.shops; into_txt text := '';
begin
  select * into sup from suppliers where id = (p->>'supplier_id')::uuid and active;
  if not found then raise exception 'Choose the supplier'; end if;
  if direct then
    select * into sh from shops where id = sid and active;
    if not found then raise exception 'Choose the shop the goods go into'; end if;
    into_txt := ' into ' || sh.name;
  else
    sid := null;   -- with a central store the goods always arrive there
  end if;
  if not exists (select 1 from app.lines(p->'lines')) then raise exception 'Enter a quantity for at least one item'; end if;
  if (select count(*) from products where active and id in (select product_id from app.lines(p->'lines'))) <> (select count(*) from app.lines(p->'lines')) then
    raise exception 'One of the items was not found';
  end if;
  gno := 'GRN-' || lpad(nextval('grn_seq')::text, 4, '0');
  insert into grns (no, supplier_id, ref, note, received_by_name, shop_id) values (gno, sup.id, left(btrim(coalesce(p->>'ref','')), 60), left(btrim(coalesce(p->>'note','')), 120), u.name, sid)
    returning id into gid;
  insert into grn_items (grn_id, product_id, qty, std_cost_usd)
    select gid, l.product_id, l.qty, coalesce(c.cost_usd, 0) from app.lines(p->'lines') l left join product_costs c on c.product_id = l.product_id;
  if direct then
    insert into shop_stock (shop_id, product_id, qty) select sid, l.product_id, l.qty from app.lines(p->'lines') l
      on conflict (shop_id, product_id) do update set qty = shop_stock.qty + excluded.qty;
  else
    update products pr set wh_qty = pr.wh_qty + l.qty, updated_at = now() from app.lines(p->'lines') l where pr.id = l.product_id;
  end if;
  insert into purchases (product_id, qty, supplier, by_id, by_name) select l.product_id, l.qty, sup.name || ' ' || gno, u.id, u.name from app.lines(p->'lines') l;
  select sum(qty * std_cost_usd), sum(qty) into v, n from grn_items where grn_id = gid;
  perform app.post('goods_in', current_date, gno || ' from ' || sup.name || coalesce(', ' || nullif(btrim(p->>'ref'), ''), '') || into_txt, gno, 'grn', gid,
    jsonb_build_array(case when direct then jsonb_build_object('account', app.shop_acc('INV_SHOP', sid), 'side', 'Dr', 'amount', round(v, 2))
                           else jsonb_build_object('code', 'INV_STORE', 'side', 'Dr', 'amount', round(v, 2)) end,
                      jsonb_build_object('code', 'GRNI', 'side', 'Cr', 'amount', round(v, 2))), u.name);
  perform app.log(u, format('Received %s from %s: %s units%s, waiting for the bill', gno, sup.name, n, into_txt));
  return jsonb_build_object('id', gid, 'no', gno);
end $$;

-- ---------- who may call what ----------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.save_settings(jsonb), public.receive_goods(jsonb) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
