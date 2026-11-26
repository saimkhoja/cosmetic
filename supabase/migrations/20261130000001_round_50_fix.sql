-- QuickSales: a round price stays round.
-- Since prices were rounded up to the next 50 FC, a price a fraction of a Franc (or a few Francs) above a round one went
-- up by 50: $1.0715 at 2 800 is 3 000.2 FC, and became 3 050 instead of the 3 000 on the shop's tickets. Now the price
-- is first taken to the nearest 10 FC, as it always was, and only then rounded up to the next 50 FC: 3 000 stays 3 000,
-- 3 010 to 3 040 become 3 050, 4 280 becomes 4 300. Sales already made keep their prices.
-- Already running QuickSales? Run this file once, after 20261129000001_money_exchange.sql. It changes no data.

-- stop at once if the update before this one was not run
do $$ begin
  if not exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = 'money_exchanges') then
    raise exception 'Run supabase/migrations/20261129000001_money_exchange.sql (and every earlier file) first, then this file. supabase/scripts/check_migrations.sql shows what is missing';
  end if;
end $$;

-- shop price in Francs: USD x rate to the nearest 10 FC, then up to the next 50 FC
create or replace function app.to_cdf(usd numeric, r numeric) returns bigint
language sql immutable as $$ select (ceil(round(round(usd * r, 2) / 10) * 10 / 50) * 50)::bigint $$;

revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
