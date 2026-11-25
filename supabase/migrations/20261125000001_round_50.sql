-- QuickSales: shop prices in Francs end in 50 or 00.
-- A price in USD times the sales rate (taux) is rounded UP to the next 50 FC: 4 220 -> 4 250, 4 260 -> 4 300,
-- 4 250 and 4 300 stay as they are. Before, it was rounded to the nearest 10 FC. Every price at the till, on the
-- tickets, the orders, the deliveries and the stock values follows, since they all go through app.to_cdf.
-- Sales already made keep the prices they were made at.
-- Already running QuickSales? Run this file once, after 20261123000001_stock_in_fix.sql. It changes no data.

-- stop at once if the update before this one was not run
do $$ begin
  if not exists (select 1 from pg_proc where proname = 'stock_in_shops' and pg_get_functiondef(oid) like '%delete from stock_in_lines where true%') then
    raise exception 'Run supabase/migrations/20261123000001_stock_in_fix.sql (and every earlier file) first, then this file. supabase/scripts/check_migrations.sql shows what is missing';
  end if;
end $$;

-- shop price in Francs: USD x rate, rounded up to the next 50 FC
create or replace function app.to_cdf(usd numeric, r numeric) returns bigint
language sql immutable as $$ select (ceil(round(usd * r, 2) / 50) * 50)::bigint $$;
