-- QuickSales: two cost prices per item, the gross cost and an optional net cost.
-- The Admin enters the gross cost of one carton (or of one set) as before, and may also enter a net cost. When a net
-- cost is given, it is the cost of those goods everywhere: the cost of goods sold on each invoice, deliveries to the
-- shops at cost, goods in at item cost, stock value at cost, margins, and the check that no price is below cost.
-- Left empty, the gross cost counts, as it always has.
--   product_costs.carton_cost_usd  gross cost of one carton, or of one set (sets kept 0 here before; now their cost)
--   product_costs.net_cost_usd     net cost of one carton, or of one set; empty: the gross cost counts
--   product_costs.cost_usd         the cost that counts, per pc (or per set): net if given, else gross
-- Every item already in the database keeps its gross cost: no net cost is set, so nothing is revalued.
-- An app that does not send the net cost (an older build still cached on a computer) keeps the item's net cost as it is.
-- Already running QuickSales? Run this file once, after 20261111000012_shift_day_total.sql. It changes no costs.

-- stop at once if the update before this one was not run
do $$ begin
  if not exists (select 1 from pg_proc where proname = 'shift_end_report' and pg_get_functiondef(oid) like '%dsum%') then
    raise exception 'Run supabase/migrations/20261111000012_shift_day_total.sql (and every earlier file) first, then this file. supabase/scripts/check_migrations.sql shows what is missing';
  end if;
end $$;

alter table public.product_costs add column if not exists net_cost_usd numeric(16,6);
alter table public.product_costs alter column carton_cost_usd type numeric(16,6);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'product_costs_net_cost_check') then
    alter table public.product_costs add constraint product_costs_net_cost_check check (net_cost_usd is null or net_cost_usd >= 0);
  end if;
end $$;
comment on column public.product_costs.carton_cost_usd is 'Gross cost of one carton, or of one set';
comment on column public.product_costs.net_cost_usd is 'Net cost of one carton, or of one set; empty: the gross cost counts';
comment on column public.product_costs.cost_usd is 'The cost that counts, per pc (or per set): the net cost if given, else the gross cost';

-- a set's gross cost was only kept as its cost per set; keep it as its gross cost too (cost_usd is untouched)
update public.product_costs c set carton_cost_usd = c.cost_usd
from public.products p where p.id = c.product_id and p.is_bundle and c.carton_cost_usd = 0 and c.net_cost_usd is null;


create or replace function app.product_fields(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  name text := btrim(regexp_replace(coalesce(p->>'name',''), '\s+', ' ', 'g'));
  cat text := btrim(coalesce(p->>'category',''));
  b boolean := coalesce((p->>'is_bundle')::boolean, false);
  cc numeric; per numeric; pc numeric; dz numeric; hz numeric; ctn numeric; cpc numeric;
  sc numeric; sp numeric; pcs numeric; pp numeric;
  net numeric; eff numeric;   -- net cost (empty: none) and the cost that counts, of one carton or one set
begin
  if name = '' then raise exception 'Enter the item name'; end if;
  if length(name) > 60 then raise exception 'Item name is too long (60 characters at most)'; end if;
  if cat = '' then raise exception 'Choose the category'; end if;
  select c.name into cat from categories c where lower(c.name) = lower(cat);
  if cat is null then raise exception 'Category "%" does not exist. The Admin creates categories first', btrim(p->>'category'); end if;
  -- the net cost: as sent; not sent at all (an older app), the item keeps the one it has
  if p ? 'net_cost' then
    net := app.num(p->>'net_cost');
    if net is null and btrim(coalesce(p->>'net_cost', '')) <> '' then raise exception 'Enter a valid net cost, or leave it empty'; end if;
  elsif coalesce(p->>'id', '') <> '' then
    select c.net_cost_usd into net from product_costs c where c.product_id = (p->>'id')::uuid;
  end if;
  if net < 0 then raise exception 'The net cost cannot be negative'; end if;
  if b then
    sc := app.num(p->>'set_cost'); sp := app.num(p->>'set_price'); pcs := app.num(p->>'pcs'); pp := app.num(p->>'piece');
    if sc is null or sc < 0 or sp is null or sp <= 0 then raise exception 'Enter the cost and selling price of one set'; end if;
    eff := coalesce(net, sc);
    if sp < eff then raise exception 'Set price cannot be below its cost'; end if;
    if pcs is null or pcs < 2 or pcs <> trunc(pcs) or pp is null or pp <= 0 then
      raise exception 'For a mixed set, enter the pieces per set and the last price for one piece';
    end if;
    return jsonb_build_object('name',name,'category',cat,'stock_unit','set','is_bundle',true,
      'per_carton',0,'pieces_per_set',pcs::int,'price_usd',sp,'dozen_usd',0,'half_dozen_usd',0,'carton_usd',0,'piece_usd',pp,
      'carton_cost_usd',sc,'net_cost_usd',net,'cost_usd',eff);
  end if;
  cc := app.num(p->>'carton_cost'); per := app.num(p->>'per_carton'); pc := coalesce(app.num(p->>'pc'), 0);
  dz := coalesce(app.num(p->>'dzn'), 0); hz := coalesce(app.num(p->>'half'), 0); ctn := coalesce(app.num(p->>'ctn'), 0);
  if cc is null or cc < 0 then raise exception 'Enter the cost of one carton'; end if;
  if per is null or per < 1 or per <> trunc(per) then raise exception 'Enter how many pcs are in one carton (1 or more)'; end if;
  if pc < 0 or dz < 0 or hz < 0 or ctn < 0 then raise exception 'Prices cannot be negative'; end if;
  eff := coalesce(net, cc);
  cpc := eff / per;
  -- a carton of 12 (or 6) is the dozen (or half dozen): that price is the carton price
  if per = 12 then ctn := coalesce(nullif(ctn, 0), dz); dz := 0; end if;
  if per = 6 then ctn := coalesce(nullif(ctn, 0), hz); hz := 0; end if;
  -- one pc per carton: the carton is the pc, so the carton price is the price per pc
  if per = 1 then pc := coalesce(nullif(pc, 0), ctn); ctn := 0; end if;
  if pc = 0 and hz = 0 and dz = 0 and ctn = 0 then raise exception 'Enter at least one selling price: per pc, half dozen, dozen or carton'; end if;
  if pc > 0 and pc < cpc - 0.000000001 then raise exception 'Price per pc is below the cost of one pc (%)', app.usd(cpc); end if;
  if hz > 0 and hz < cpc * 6 - 0.000000001 then raise exception 'Price per half dozen is below the cost of 6 pcs (%)', app.usd(cpc * 6); end if;
  if dz > 0 and dz < cpc * 12 - 0.000000001 then raise exception 'Price per dozen is below the cost of 12 pcs (%)', app.usd(cpc * 12); end if;
  if ctn > 0 and ctn < eff then raise exception 'Price per carton cannot be below the carton cost'; end if;
  return jsonb_build_object('name',name,'category',cat,'stock_unit','pcs','is_bundle',false,
    'per_carton',per::int,'pieces_per_set',0,'price_usd',pc,'dozen_usd',dz,'half_dozen_usd',hz,'carton_usd',ctn,'piece_usd',0,
    'carton_cost_usd',cc,'net_cost_usd',net,'cost_usd',cpc);
end $$;

create or replace function app.insert_product(f jsonb, sku text, qty int, reorder int, supplier text, u public.profiles)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare pid uuid; s text := nullif(btrim(coalesce(sku,'')), '');
begin
  if exists (select 1 from products where active and lower(name) = lower(f->>'name')) then
    raise exception 'An item called "%" already exists', f->>'name';
  end if;
  if s is not null and exists (select 1 from products where lower(products.sku) = lower(s)) then
    raise exception 'The code % is already used', s;
  end if;
  if s is null then
    loop s := 'SK-' || nextval('sku_seq'); exit when not exists (select 1 from products where products.sku = s); end loop;
  end if;
  insert into products (sku, name, category, stock_unit, is_bundle, per_carton, pieces_per_set, price_usd, dozen_usd, half_dozen_usd, carton_usd, piece_usd, reorder, wh_qty)
  values (s, f->>'name', f->>'category', f->>'stock_unit', (f->>'is_bundle')::boolean, (f->>'per_carton')::int, (f->>'pieces_per_set')::int,
    (f->>'price_usd')::numeric, (f->>'dozen_usd')::numeric, (f->>'half_dozen_usd')::numeric, (f->>'carton_usd')::numeric, (f->>'piece_usd')::numeric, reorder, qty)
  returning id into pid;
  insert into product_costs (product_id, carton_cost_usd, net_cost_usd, cost_usd)
  values (pid, (f->>'carton_cost_usd')::numeric, (f->>'net_cost_usd')::numeric, (f->>'cost_usd')::numeric);
  insert into shop_stock (shop_id, product_id) select id, pid from shops;
  if qty > 0 then insert into purchases (product_id, qty, supplier, by_id, by_name) values (pid, qty, coalesce(supplier,''), u.id, u.name); end if;
  return pid;
end $$;

create or replace function public.save_product(p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); f jsonb := app.product_fields(p); pid uuid := (p->>'id')::uuid;
  old public.products; nw public.products; v_qty int; v_reorder int := app.int_or_raise(p->>'reorder', 'Reorder level');
  oc public.product_costs; nc public.product_costs;
begin
  if pid is null then
    v_qty := case when (f->>'is_bundle')::boolean then 0 else app.int_or_raise(p->>'qty_cartons', 'Cartons') * (f->>'per_carton')::int end
           + app.int_or_raise(p->>'qty_loose', 'Quantity');
    pid := app.insert_product(f, p->>'sku', v_qty, v_reorder, 'Opening stock', u);
    perform app.log(u, format('Added item %s%s%s', f->>'name',
      case when f->>'net_cost_usd' is not null then format(', net cost %s per %s', app.usd((f->>'net_cost_usd')::numeric), case when (f->>'is_bundle')::boolean then 'set' else 'carton' end) else '' end,
      case when v_qty > 0 then format(', opening stock %s %s', v_qty, f->>'stock_unit') else '' end));
    perform app.set_barcode(pid, p->>'barcode');
    perform app.after_opening_stock(pid, v_qty, u);
    return pid;
  end if;
  select * into old from products where id = pid and active for update;
  if not found then raise exception 'Item not found'; end if;
  if exists (select 1 from products where active and lower(name) = lower(f->>'name') and id <> pid) then
    raise exception 'An item called "%" already exists', f->>'name';
  end if;
  update products set name = f->>'name', category = f->>'category', stock_unit = f->>'stock_unit', is_bundle = (f->>'is_bundle')::boolean,
    per_carton = (f->>'per_carton')::int, pieces_per_set = (f->>'pieces_per_set')::int, price_usd = (f->>'price_usd')::numeric,
    dozen_usd = (f->>'dozen_usd')::numeric, half_dozen_usd = (f->>'half_dozen_usd')::numeric, carton_usd = (f->>'carton_usd')::numeric,
    piece_usd = (f->>'piece_usd')::numeric, reorder = v_reorder, updated_at = now()
  where id = pid returning * into nw;
  select * into oc from product_costs where product_id = pid;
  insert into product_costs (product_id, carton_cost_usd, net_cost_usd, cost_usd)
  values (pid, (f->>'carton_cost_usd')::numeric, (f->>'net_cost_usd')::numeric, (f->>'cost_usd')::numeric)
  on conflict (product_id) do update set carton_cost_usd = excluded.carton_cost_usd, net_cost_usd = excluded.net_cost_usd, cost_usd = excluded.cost_usd
  returning * into nc;
  if app.units_text(old) <> app.units_text(nw) then
    perform app.log(u, format('Prices changed for %s: %s to %s', nw.name, app.units_text(old), app.units_text(nw)));
  end if;
  if oc.net_cost_usd is distinct from nc.net_cost_usd then
    perform app.log(u, format('Net cost of %s %s', nw.name, case
      when nc.net_cost_usd is null then format('removed: the gross cost %s counts', app.usd(nc.carton_cost_usd))
      when oc.net_cost_usd is null then format('set to %s per %s (gross %s)', app.usd(nc.net_cost_usd), case when nw.is_bundle then 'set' else 'carton' end, app.usd(nc.carton_cost_usd))
      else format('changed %s to %s per %s', app.usd(oc.net_cost_usd), app.usd(nc.net_cost_usd), case when nw.is_bundle then 'set' else 'carton' end) end));
  end if;
  perform app.set_barcode(pid, p->>'barcode');
  perform app.log(u, 'Updated item ' || nw.name);
  return pid;
end $$;

-- ---------- who may call what ----------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.save_product(jsonb), public.import_products(jsonb, text) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
