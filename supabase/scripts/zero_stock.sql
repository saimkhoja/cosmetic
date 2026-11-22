-- QuickSales: set ALL stock to zero, in the central store and in every shop, for one client.
-- Run by .github/workflows/zero-stock.yml for the one client chosen (it backs up first), or by hand in that client's
-- SQL Editor. It is not a migration: it never runs on its own or on other clients.
--
-- Clears:  every quantity in the central store and in every shop (open sets included), to 0.
-- Books:   the value removed, at cost, as a stock adjustment: Cr each stock ledger (central store, each shop),
--          Dr Stock adjustments (STOCK_ADJ), one entry per place, so the stock ledgers keep matching the stock.
--          A negative quantity (sold on order) set to 0 is booked the other way round.
-- Keeps:   every invoice and sale, reports, shift reports, vendeurs, the books so far, items (names, prices, costs,
--          barcodes, categories), suppliers, logins and settings. New stock comes in by goods in or Add stock to shops.
-- Refuses: while a delivery or a shop return is still on its way (receive or cancel it in the app first), because
--          receiving it afterwards would move stock that is no longer counted.
-- Before:  check every till shows nothing waiting to send: a sale still on a till would take stock after this.
--
-- psql variable apply: true makes the change; anything else does it all and then rolls it back, showing what would
-- change (plan). All of it runs as one transaction: it either completes or changes nothing.
\set ON_ERROR_STOP 1
\if :{?apply}
\else
  \set apply false
\endif
set client_min_messages = notice;
begin;
create temp table zs_where (place text, account uuid, lines int, units bigint, value numeric) on commit drop;
do $$
declare tz text; today date; sid record; n int; u bigint; v numeric; total numeric := 0; lines_all int := 0; d int; r int;
begin
  if to_regclass('public.vendeurs') is null then
    raise exception 'This database is missing recent updates. Run the Update client databases workflow first';
  end if;
  select count(*) into d from deliveries where status = 'pending';
  select count(*) into r from shop_returns where status = 'pending';
  if d > 0 or r > 0 then
    raise exception 'Nothing was changed: % deliveries and % returns to the store are still on their way. Receive or cancel them in the app first, then run this again', d, r;
  end if;
  select settings.tz into tz from settings where id = 1;
  today := (now() at time zone tz)::date;

  -- the central store
  select count(*), coalesce(sum(p.wh_qty), 0), coalesce(sum(p.wh_qty * coalesce(c.cost_usd, 0)), 0) into n, u, v
    from products p left join product_costs c on c.product_id = p.id where p.wh_qty <> 0;
  insert into zs_where values ('Central store', app.acc('INV_STORE'), n, u, v);
  update products set wh_qty = 0, updated_at = now() where wh_qty <> 0;

  -- each shop: a mixed set already opened counts as the pieces left in it
  for sid in select id, name from shops order by name loop
    select count(*), coalesce(sum(s.qty), 0),
        coalesce(sum((s.qty - s.open_pieces::numeric / greatest(coalesce(p.pieces_per_set, 1), 1)) * coalesce(c.cost_usd, 0)), 0)
      into n, u, v
      from shop_stock s join products p on p.id = s.product_id left join product_costs c on c.product_id = s.product_id
      where s.shop_id = sid.id and (s.qty <> 0 or s.open_pieces <> 0);
    insert into zs_where values (sid.name, app.shop_acc('INV_SHOP', sid.id), n, u, v);
    update shop_stock set qty = 0, open_pieces = 0 where shop_id = sid.id and (qty <> 0 or open_pieces <> 0);
  end loop;

  -- the books: the value removed from each place, at cost, as a stock adjustment
  for sid in select * from zs_where where lines > 0 loop
    if round(sid.value, 2) <> 0 then
      perform app.post('adjustment', today, left(format('Stock cleared to zero in %s: %s items, %s units', sid.place, sid.lines, sid.units), 200), 'ZERO-STOCK', null, null,
        jsonb_build_array(
          jsonb_build_object('account', sid.account, 'side', case when sid.value > 0 then 'Cr' else 'Dr' end, 'amount', round(abs(sid.value), 2)),
          jsonb_build_object('code', 'STOCK_ADJ', 'side', case when sid.value > 0 then 'Dr' else 'Cr' end, 'amount', round(abs(sid.value), 2))),
        'system');
    end if;
    raise notice '%: % items, % units, % at cost', sid.place, sid.lines, sid.units, app.usd(sid.value);
    total := total + sid.value; lines_all := lines_all + sid.lines;
  end loop;
  if lines_all = 0 then raise notice 'Every place already has zero stock: nothing to clear'; end if;
  raise notice 'In all: % stock lines cleared, % at cost booked as a stock adjustment', lines_all, app.usd(total);
  insert into audit_log (username, action)
    values ('system', format('All stock set to zero in the central store and every shop (%s stock lines, %s at cost booked as a stock adjustment); sales kept', lines_all, app.usd(total)));
end $$;
select 'remaining stock lines: ' || ((select count(*) from products where wh_qty <> 0) + (select count(*) from shop_stock where qty <> 0 or open_pieces <> 0)) as check;
\if :apply
  commit;
  \echo 'Done: all stock is now zero.'
\else
  rollback;
  \echo 'Plan only: nothing was changed. Run with apply to do it.'
\endif
