-- QuickSales: are the "new stock arrived" notices working on this database? Read only: it changes nothing.
-- Run by ops/check-arrivals.sh (and .github/workflows/check-arrivals.yml); can also be pasted into the SQL Editor.
begin read only;
set local search_path = public, pg_temp;
\pset footer off
\echo '== The update and the switch'
select (select exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = 'stock_arrivals')) as notices_table,
       (select pg_get_functiondef('public.stock_in_shops(uuid[],jsonb,jsonb,text,text)'::regprocedure) like '%app.stock_arrived%') as add_stock_tells_the_shop,
       (select pg_get_functiondef('public.receive_goods(jsonb)'::regprocedure) like '%app.stock_arrived%') as goods_in_tells_the_shop,
       (select coalesce((features->>'no_warehouse')::boolean, false) from settings where id = 1) as no_central_store;
\echo '== Each shop: its Shop Admins, and its notices'
select s.name as shop, s.active,
       (select count(*) from profiles p where p.shop_id = s.id and p.role = 'shopadmin' and p.active) as shop_admins,
       (select count(*) from profiles p where p.shop_id = s.id and p.role = 'till' and p.active) as till_operators,
       (select count(*) from stock_arrivals a where a.shop_id = s.id) as notices,
       (select count(*) from stock_arrivals a where a.shop_id = s.id and a.seen_at is null) as not_seen_yet,
       (select to_char(max(a.at) at time zone 'Africa/Kinshasa', 'DD Mon HH24:MI') from stock_arrivals a where a.shop_id = s.id) as last_notice
  from shops s order by s.name;
\echo '== The last 10 notices (Kinshasa time)'
select to_char(a.at at time zone 'Africa/Kinshasa', 'DD Mon HH24:MI') as at, s.name as shop, a.kind, left(a.what, 40) as what,
       (select count(*) from stock_arrival_items i where i.arrival_id = a.id) as items, (select coalesce(sum(qty), 0) from stock_arrival_items i where i.arrival_id = a.id) as units,
       coalesce(to_char(a.seen_at at time zone 'Africa/Kinshasa', 'DD Mon HH24:MI'), 'not yet') as seen
  from stock_arrivals a join shops s on s.id = a.shop_id order by a.at desc limit 10;
\echo '== The last 10 times stock was added to shops or received into one (Activity, Kinshasa time)'
select to_char(at at time zone 'Africa/Kinshasa', 'DD Mon HH24:MI') as at, left(action, 110) as action
  from audit_log where action like 'Stock added to %' or (action like 'Received GRN-%' and action like '% into %')
  order by at desc limit 10;
\echo '== When the notices update ran'
select version, name from supabase_migrations.schema_migrations where name like '%stock_arrivals%';
rollback;
