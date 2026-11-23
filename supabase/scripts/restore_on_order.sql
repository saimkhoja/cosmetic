-- QuickSales: put back the stock that was "on order" (sold before it was in stock, so below zero) from a backup, after
-- all stock was cleared with zero_stock.sql. Physical stock stays cleared; only the quantities below zero come back.
-- Run by ops/restore-on-order.sh (and .github/workflows/restore-on-order.yml), which first loads, from the backup,
--   zs_old_stock     the shops' stock (like public.shop_stock)
--   zs_old_products  the items, for the central store's quantities (like public.products)
-- and sets zs.file to the backup's name.
--
-- Each quantity below zero in the backup is ADDED to today's: a sale made since the clean-up stays counted.
-- Books: the value put back, at cost, as a stock adjustment per place (the reverse of that part of the clean-up).
-- It runs once per backup: a second run for the same backup is refused.
-- psql variable apply: true makes the change; anything else does it all and rolls it back, showing what would change.
\set ON_ERROR_STOP 1
\if :{?apply}
\else
  \set apply false
\endif
set search_path = public, pg_temp;
set client_min_messages = notice;
begin;
do $$
declare f text := current_setting('zs.file'); tz text; today date; s record; v numeric; n int; u bigint; total numeric := 0; lines int := 0;
begin
  if exists (select 1 from audit_log where action like 'On-order stock restored from ' || f || ':%') then
    raise exception 'The on-order stock of % was already put back: nothing was changed', f;
  end if;
  if (select count(*) from zs_old_stock) = 0 and (select count(*) from zs_old_products) = 0 then
    raise exception 'The backup % has no stock to read', f;
  end if;
  select settings.tz into tz from settings where id = 1;
  today := (now() at time zone tz)::date;

  -- each shop
  for s in select id, name from shops order by name loop
    select count(*), coalesce(sum(o.qty), 0), coalesce(sum(o.qty * coalesce(c.cost_usd, 0)), 0) into n, u, v
      from zs_old_stock o join products p on p.id = o.product_id left join product_costs c on c.product_id = o.product_id
      where o.shop_id = s.id and o.qty < 0;
    continue when n = 0;
    insert into shop_stock (shop_id, product_id, qty)
      select o.shop_id, o.product_id, o.qty from zs_old_stock o join products p on p.id = o.product_id where o.shop_id = s.id and o.qty < 0
      on conflict (shop_id, product_id) do update set qty = shop_stock.qty + excluded.qty;
    if round(v, 2) <> 0 then
      perform app.post('adjustment', today, left(format('On-order stock put back in %s: %s items, %s units (from %s)', s.name, n, u, f), 200), 'ON-ORDER', null, null,
        jsonb_build_array(
          jsonb_build_object('account', app.shop_acc('INV_SHOP', s.id), 'side', case when v > 0 then 'Dr' else 'Cr' end, 'amount', round(abs(v), 2)),
          jsonb_build_object('code', 'STOCK_ADJ', 'side', case when v > 0 then 'Cr' else 'Dr' end, 'amount', round(abs(v), 2))),
        'system');
    end if;
    raise notice '%: % items back on order, % units, % at cost', s.name, n, u, app.usd(v);
    total := total + v; lines := lines + n;
  end loop;

  -- the central store
  select count(*), coalesce(sum(o.wh_qty), 0), coalesce(sum(o.wh_qty * coalesce(c.cost_usd, 0)), 0) into n, u, v
    from zs_old_products o join products p on p.id = o.id left join product_costs c on c.product_id = o.id where o.wh_qty < 0;
  if n > 0 then
    update products p set wh_qty = p.wh_qty + o.wh_qty, updated_at = now() from zs_old_products o where o.id = p.id and o.wh_qty < 0;
    if round(v, 2) <> 0 then
      perform app.post('adjustment', today, left(format('On-order stock put back in the central store: %s items, %s units (from %s)', n, u, f), 200), 'ON-ORDER', null, null,
        jsonb_build_array(
          jsonb_build_object('code', 'INV_STORE', 'side', case when v > 0 then 'Dr' else 'Cr' end, 'amount', round(abs(v), 2)),
          jsonb_build_object('code', 'STOCK_ADJ', 'side', case when v > 0 then 'Cr' else 'Dr' end, 'amount', round(abs(v), 2))),
        'system');
    end if;
    raise notice 'Central store: % items back on order, % units, % at cost', n, u, app.usd(v);
    total := total + v; lines := lines + n;
  end if;

  if lines = 0 then
    raise notice 'The backup has no stock on order (below zero): nothing to put back';
  else
    raise notice 'In all: % stock lines back on order, % at cost booked as a stock adjustment', lines, app.usd(total);
    insert into audit_log (username, action)
      values ('system', format('On-order stock restored from %s: %s stock lines, %s at cost booked as a stock adjustment', f, lines, app.usd(total)));
  end if;
end $$;
\if :apply
  commit;
  \echo 'Done: the on-order stock is back.'
\else
  rollback;
  \echo 'Plan only: nothing was changed. Run with apply to do it.'
\endif
