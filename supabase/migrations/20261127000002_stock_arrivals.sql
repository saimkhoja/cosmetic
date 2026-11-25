-- QuickSales: the Shop Admin is told when stock is added straight into their shop (no central store).
-- When the Admin adds stock to shops (typed or from Excel) or receives goods from a supplier straight into a shop, each
-- shop gets a "stock arrived" record with its items and quantities. The Shop Admin's app shows it as a notice in the
-- top right; opening it lists the items, quantities and selling prices, and "Got it" marks it seen. The Shop Admin can
-- look back at what arrived from the Stock page.
-- Already running QuickSales? Run this file once, after 20261127000001_upkeep_edit.sql. It keeps your data.

-- stop at once if the update before this one was not run
do $$ begin
  if not exists (select 1 from pg_proc where proname = 'edit_upkeep') then
    raise exception 'Run supabase/migrations/20261127000001_upkeep_edit.sql (and every earlier file) first, then this file. supabase/scripts/check_migrations.sql shows what is missing';
  end if;
end $$;

create table if not exists public.stock_arrivals (
  id           uuid primary key default gen_random_uuid(),
  shop_id      uuid not null references public.shops(id),
  kind         text not null check (kind in ('stock_in','goods_in')),
  what         text not null default '',
  note         text not null default '',
  by_name      text not null,
  at           timestamptz not null default now(),
  seen_at      timestamptz,
  seen_by_name text
);
create index if not exists stock_arrivals_shop on public.stock_arrivals (shop_id, at desc);
create table if not exists public.stock_arrival_items (
  arrival_id uuid not null references public.stock_arrivals(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  qty        int not null check (qty > 0),
  primary key (arrival_id, product_id)
);
alter table public.stock_arrivals enable row level security;
alter table public.stock_arrival_items enable row level security;
revoke all on public.stock_arrivals, public.stock_arrival_items from anon, authenticated;
grant select on public.stock_arrivals, public.stock_arrival_items to authenticated;
drop policy if exists r on public.stock_arrivals; create policy r on public.stock_arrivals for select to authenticated
  using (app.my_role() = 'admin' or (app.my_role() = 'shopadmin' and shop_id = app.my_shop()));
drop policy if exists r on public.stock_arrival_items; create policy r on public.stock_arrival_items for select to authenticated
  using (exists (select 1 from public.stock_arrivals a where a.id = arrival_id));

-- records what came into a shop; p_lines: [{product_id, qty}]
create or replace function app.stock_arrived(p_shop uuid, p_kind text, p_what text, p_note text, p_by text, p_lines jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare aid uuid;
begin
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or not exists (select 1 from app.lines(p_lines) where qty > 0) then return null; end if;
  insert into stock_arrivals (shop_id, kind, what, note, by_name) values (p_shop, p_kind, left(coalesce(p_what, ''), 120), left(btrim(coalesce(p_note, '')), 160), p_by)
    returning id into aid;
  insert into stock_arrival_items (arrival_id, product_id, qty)
    select aid, l.product_id, sum(l.qty) from app.lines(p_lines) l where l.qty > 0 group by l.product_id;
  return aid;
end $$;

-- the Shop Admin has seen what arrived (all of it, or one)
create or replace function public.stock_arrivals_seen(p_ids uuid[]) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); n int;
begin
  update stock_arrivals set seen_at = now(), seen_by_name = u.name
    where id = any(coalesce(p_ids, '{}')) and shop_id = u.shop_id and seen_at is null;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------- adding stock to shops and receiving goods into a shop now tell the shop ----------
create or replace function public.stock_in_shops(p_shops uuid[], p_lines jsonb, p_new jsonb default '[]', p_file text default '', p_note text default '')
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); r jsonb; f jsonb; s text; b text[]; pid uuid; q int; errs text[] := '{}';
  names text[] := '{}'; skus text[] := '{}'; codes text[] := '{}'; created int := 0; newcats int := 0; c text;
  sh public.shops; v numeric; n int; units int; tz text; what text;
begin
  if not app.feature('no_warehouse') then raise exception 'With a central store, stock goes to the shops by delivery'; end if;
  if p_shops is null or cardinality(p_shops) = 0 then raise exception 'Tick at least one shop'; end if;
  if (select count(*) from shops where active and id = any(p_shops)) <> cardinality(array(select distinct x from unnest(p_shops) x)) then
    raise exception 'One of the shops was not found';
  end if;
  if p_new is null or jsonb_typeof(p_new) <> 'array' then p_new := '[]'; end if;
  if jsonb_array_length(p_new) > 5000 then raise exception 'Import at most 5000 new items at a time'; end if;
  create temp table if not exists stock_in_lines (product_id uuid, qty int) on commit drop;
  delete from stock_in_lines where true;   -- the Supabase API refuses a DELETE without WHERE
  -- items already in the catalogue
  insert into stock_in_lines select l.product_id, l.qty from app.lines(coalesce(p_lines, '[]')) l;
  if exists (select 1 from stock_in_lines l where not exists (select 1 from products p where p.id = l.product_id and p.active)) then
    raise exception 'One of the items was not found';
  end if;
  -- categories named in the file are made if they do not exist yet
  for c in select distinct btrim(e->>'category') from jsonb_array_elements(p_new) e where btrim(coalesce(e->>'category', '')) <> '' loop
    if length(c) <= 30 and not exists (select 1 from categories where lower(name) = lower(c)) then
      insert into categories (name) values (c); newcats := newcats + 1;
    end if;
  end loop;
  -- items not in the catalogue: checked like the item import, then made
  for r in select * from jsonb_array_elements(p_new) loop
    begin
      f := app.product_fields(r);
      s := nullif(btrim(coalesce(r->>'sku', '')), '');
      b := app.barcode_list(r->>'barcode');
      if exists (select 1 from products where active and lower(name) = lower(f->>'name')) or lower(f->>'name') = any(names) then
        raise exception 'an item called "%" already exists', f->>'name';
      end if;
      if s is not null and (exists (select 1 from products where lower(sku) = lower(s)) or lower(s) = any(skus)) then raise exception 'the code % is already used', s; end if;
      if cardinality(b) > 0 and (exists (select 1 from products where barcodes && b) or b && codes) then raise exception 'one of its barcodes is already used'; end if;
      q := case when (f->>'is_bundle')::boolean then 0 else app.int_or_raise(r->>'open_cartons', 'Cartons') * (f->>'per_carton')::int end
           + app.int_or_raise(r->>'open_pcs', 'Pcs');
      names := names || lower(f->>'name'); if s is not null then skus := skus || lower(s); end if; codes := codes || b;
      pid := app.insert_product(f, s, 0, case when coalesce(r->>'reorder', '') = '' then (f->>'per_carton')::int else app.int_or_raise(r->>'reorder', 'Reorder') end,
        '', u);
      perform app.set_barcode(pid, array_to_string(b, ';'));
      created := created + 1;
      if q > 0 then insert into stock_in_lines values (pid, q); end if;
    exception when raise_exception then
      errs := errs || format('row %s: %s', coalesce(r->>'row', '?'), sqlerrm);
    end;
  end loop;
  if array_length(errs, 1) > 0 then
    raise exception 'Nothing was added. Fix these rows first: %', array_to_string(errs[1:8], '; ');
  end if;
  select count(distinct product_id), coalesce(sum(qty), 0) into n, units from stock_in_lines;
  if units = 0 and created = 0 then raise exception 'Enter a quantity for at least one item'; end if;
  select settings.tz into tz from settings where id = 1;
  what := coalesce(nullif(btrim(p_file), ''), 'by hand');
  -- into each shop ticked, booked at cost as opening stock
  for sh in select * from shops where id = any(p_shops) order by name loop
    insert into shop_stock (shop_id, product_id, qty) select sh.id, l.product_id, sum(l.qty) from stock_in_lines l group by l.product_id
      on conflict (shop_id, product_id) do update set qty = shop_stock.qty + excluded.qty;
    insert into purchases (product_id, qty, supplier, by_id, by_name)
      select l.product_id, sum(l.qty), left('Stock added to ' || sh.name || ' (' || what || ')', 120), u.id, u.name from stock_in_lines l group by l.product_id;
    select coalesce(sum(l.qty * coalesce(c.cost_usd, 0)), 0) into v from stock_in_lines l left join product_costs c on c.product_id = l.product_id;
    perform app.post('opening', (now() at time zone tz)::date, left(format('Stock added to %s (%s)%s', sh.name, what, coalesce(': ' || nullif(btrim(p_note), ''), '')), 200),
      sh.code, null, null,
      jsonb_build_array(jsonb_build_object('account', app.shop_acc('INV_SHOP', sh.id), 'side', 'Dr', 'amount', round(v, 2)),
                        jsonb_build_object('code', 'OPENING', 'side', 'Cr', 'amount', round(v, 2))), u.name);
    -- the shop admin is told what came in
    perform app.stock_arrived(sh.id, 'stock_in', what, p_note, u.name,
      (select jsonb_agg(jsonb_build_object('product_id', l.product_id, 'qty', l.qty)) from (select product_id, sum(qty) qty from stock_in_lines group by product_id) l where l.qty > 0));
  end loop;
  perform app.log(u, format('Stock added to %s (%s): %s items, %s units each%s%s',
    (select string_agg(name, ', ' order by name) from shops where id = any(p_shops)), what, n, units,
    case when created > 0 then format(', %s new items made', created) else '' end,
    case when newcats > 0 then format(', %s new categories', newcats) else '' end));
  return jsonb_build_object('created', created, 'items', n, 'units', units, 'shops', cardinality(p_shops), 'new_categories', newcats);
end $$;


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
    -- the shop admin is told what came in
    perform app.stock_arrived(sid, 'goods_in', gno || ' from ' || sup.name, p->>'note', u.name, p->'lines');
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
grant execute on function public.stock_arrivals_seen(uuid[]), public.stock_in_shops(uuid[], jsonb, jsonb, text, text), public.receive_goods(jsonb) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
