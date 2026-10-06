-- SIM database tests. Run on a fresh database that has the migrations applied:
--   supabase/tests/run.sh
-- Each role is played by setting the JWT claims and switching to the role PostgREST would use.
\set ON_ERROR_STOP 1
\set QUIET 1
\pset tuples_only on
\pset format unaligned
set client_min_messages = notice;

create schema t;
grant usage on schema t to anon, authenticated, service_role;
create function t.ok(cond boolean, msg text) returns void language plpgsql as $$
begin if cond is not true then raise exception 'FAIL: %', msg; end if; raise notice 'ok - %', msg; end $$;
create function t.fails(q text, expect text, msg text) returns void language plpgsql as $$
begin
  begin execute q; exception when others then
    if sqlerrm ilike '%' || expect || '%' then raise notice 'ok - % (%)', msg, sqlerrm; return; end if;
    raise exception 'FAIL: % - wrong error: %', msg, sqlerrm;
  end;
  raise exception 'FAIL: % - no error raised', msg;
end $$;
create function t.as(u uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', coalesce(u::text,''), false),
         set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, false);
$$;
create table t.v (k text primary key, v text);
grant all on t.v to anon, authenticated, service_role;
create function t.put(k text, v text) returns void language sql as $$ insert into t.v values (k, v) on conflict (k) do update set v = excluded.v $$;
create function t.get(k text) returns text language sql as $$ select v from t.v where t.v.k = get.k $$;
grant execute on all functions in schema t to anon, authenticated, service_role;

-- logins (normally made by Supabase Auth through the Edge Functions)
insert into auth.users (id, email) values
 ('00000000-0000-0000-0000-00000000000a','admin@users.sim.local'),
 ('00000000-0000-0000-0000-00000000000b','operator@users.sim.local'),
 ('00000000-0000-0000-0000-00000000000c','admin.gombe@users.sim.local'),
 ('00000000-0000-0000-0000-00000000000d','till.gombe@users.sim.local'),
 ('00000000-0000-0000-0000-00000000000e','admin.limete@users.sim.local');

-- ===== setup =====
select t.ok(public.setup_needed(), 'setup is needed on an empty install');
set role service_role;
select public.app_setup('00000000-0000-0000-0000-00000000000a','admin','Mireille Tshibanda',
  '{"rate":2850,"vat":16,"company":{"name":"SIM Beauté"},"shops":[{"code":"GOM","name":"SIM Gombe","address":"Gombe"},{"code":"LIM","name":"SIM Limete"}]}');
select t.fails($$select public.app_setup('00000000-0000-0000-0000-00000000000b','x2','Someone','{}')$$, 'already set up', 'setup cannot run twice');
reset role;
select t.ok(not public.setup_needed(), 'setup no longer needed');
select t.put('gom', (select id::text from shops where code='GOM')), t.put('lim', (select id::text from shops where code='LIM'));
insert into profiles (id, username, name, role, shop_id) values
 ('00000000-0000-0000-0000-00000000000b','operator','Joseph Mbala','whop',null),
 ('00000000-0000-0000-0000-00000000000c','admin.gombe','Patrick Kabongo','shopadmin',t.get('gom')::uuid),
 ('00000000-0000-0000-0000-00000000000d','till.gombe','Grace Mbuyi','till',t.get('gom')::uuid),
 ('00000000-0000-0000-0000-00000000000e','admin.limete','Aline Mukendi','shopadmin',t.get('lim')::uuid);

-- ===== anonymous visitor =====
set role anon;
select t.as(null);
select t.fails('select * from public.products', 'permission denied', 'anon cannot read products');
select t.fails($$select public.save_product('{}')$$, 'permission denied', 'anon cannot call save_product');
reset role;

-- ===== admin: items, prices, import =====
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.put('lotion', public.save_product('{"name":"Test lotion","category":"Skin care","carton_cost":24,"per_carton":24,"pc":1.5,"dzn":16,"ctn":30,"qty_cartons":2,"qty_loose":3,"reorder":20}')::text);
select t.ok((select wh_qty from products where id = t.get('lotion')::uuid) = 51, 'opening stock 2 cartons + 3 pcs = 51 pcs');
select t.ok((select cost_usd from product_costs where product_id = t.get('lotion')::uuid) = 1, 'cost per pc = carton cost / pcs');
select t.ok((select count(*) from shop_stock where product_id = t.get('lotion')::uuid) = 2, 'new item is listed in every shop at 0');
select t.fails($$select public.save_product('{"name":"Bad","category":"X","carton_cost":24,"per_carton":24,"pc":0.5,"ctn":30}')$$, 'below the cost of one pc', 'price below cost is refused');
select t.fails($$select public.save_product('{"name":"test LOTION","category":"X","carton_cost":24,"per_carton":24,"pc":2,"ctn":30}')$$, 'already exists', 'duplicate name refused (any case)');
select t.put('brush', public.save_product('{"name":"Brush set","category":"Accessories","is_bundle":true,"set_cost":6,"set_price":14,"pcs":12,"piece":1.8,"qty_loose":10}')::text);
select public.save_product(jsonb_build_object('id', t.get('lotion'), 'name','Test lotion','category','Skin care','carton_cost',24,'per_carton',24,'pc',1.6,'dzn',16,'ctn',30,'reorder',20));
select t.ok(exists (select 1 from audit_log where action like 'Prices changed for Test lotion%'), 'price change is logged');
select t.ok((public.import_products('[{"row":2,"name":"Aloe gel","category":"Skin care","carton_cost":60,"per_carton":24,"pc":4,"dzn":45,"ctn":90,"open_cartons":5},
  {"row":3,"name":"Test Lotion","category":"Skin care","carton_cost":60,"per_carton":24,"pc":4,"ctn":90},
  {"row":4,"name":"Argan shampoo","category":"Hair care","carton_cost":72,"per_carton":12,"pc":9,"ctn":100,"sku":"AR-1"}]', 'test.xlsx')->>'imported')::int = 2,
  'import adds new rows and skips a duplicate name');
select t.ok((select wh_qty from products where name='Aloe gel') = 120 and (select reorder from products where name='Aloe gel') = 24, 'import opening stock and default reorder');
select t.fails($$select public.import_products('[{"row":2,"name":"Fine","category":"X","carton_cost":10,"per_carton":10,"pc":2,"ctn":15},{"row":3,"name":"Cheap","category":"X","carton_cost":100,"per_carton":10,"pc":5,"ctn":90}]')$$,
  'Nothing was imported', 'an invalid row stops the whole import');
select t.ok(not exists (select 1 from products where name = 'Fine'), 'nothing from the failed import was saved');
select t.fails($$update public.products set price_usd = 1$$, 'permission denied', 'admin cannot write tables directly either');
reset role;

-- ===== warehouse operator: no cost, deliveries =====
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000b');
select t.ok((select count(*) from product_costs) = 0, 'operator cannot see cost prices');
select t.ok((select count(*) from products) = 4, 'operator sees the items');
select t.fails($$select public.save_product('{"name":"X","category":"X","carton_cost":1,"per_carton":2,"pc":1,"ctn":2}')$$, 'permission', 'operator cannot create or price items');
select public.receive_stock(t.get('lotion')::uuid, 0, 1, 'Supplier A');
select t.ok((select wh_qty from products where id = t.get('lotion')::uuid) = 52, 'receive stock adds to the store');
select t.put('dels', public.create_deliveries(array[t.get('gom')::uuid, t.get('lim')::uuid],
  jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 24), jsonb_build_object('product_id', t.get('brush'), 'qty', 2)))::text);
select t.ok((select wh_qty from products where id = t.get('lotion')::uuid) = 4, 'two outlets x 24 pcs taken from the store');
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('lotion')::uuid) = 24, 'Gombe received 24');
select t.ok((select string_agg(no, ',' order by no) from deliveries) = 'DEL-0001,DEL-0002', 'one delivery note number per outlet');
select t.fails(format($$select public.create_deliveries(array['%s'::uuid], '[{"product_id":"%s","qty":999}]')$$, t.get('gom'), t.get('lotion')), 'Not enough in the store', 'shortage is refused');
select t.fails(format($$select public.create_deliveries(array['%s'::uuid], '[{"product_id":"%s","qty":1.5}]')$$, t.get('gom'), t.get('lotion')), 'whole numbers', 'fractional quantity refused');
-- move DEL-0002 (Limete) to Gombe and change 24 -> 26
select t.fails(format($$select public.edit_delivery('%s', '%s', '[{"product_id":"%s","qty":26}]', 'x')$$, (select id from deliveries where no='DEL-0002'), t.get('gom'), t.get('lotion')), 'reason', 'edit needs a reason');
select public.edit_delivery((select id from deliveries where no='DEL-0002'), t.get('gom')::uuid, jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 26)), 'Wrong shop at loading');
select t.ok((select qty from shop_stock where shop_id = t.get('lim')::uuid and product_id = t.get('lotion')::uuid) = 0, 'old outlet stock reversed');
select t.ok((select qty from shop_stock where shop_id = t.get('lim')::uuid and product_id = t.get('brush')::uuid) = 0, 'removed line reversed');
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('lotion')::uuid) = 50, 'new outlet got 26 more');
select t.ok((select wh_qty from products where id = t.get('lotion')::uuid) = 2 and (select wh_qty from products where id = t.get('brush')::uuid) = 8, 'store stock re-applied');
select t.ok((select price_usd from delivery_items i join deliveries d on d.id = i.delivery_id where d.no='DEL-0002') = 1.6, 'price frozen from first dispatch');
reset role;

-- ===== till operator: sell, never read invoices =====
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000d');
select t.put('dev1', (public.register_device()->>'id'));
select t.ok((select code from devices where id = t.get('dev1')::uuid) = 'T1', 'first till of the shop is T1');
select t.ok((public.register_device(t.get('dev1')::uuid)->>'code') = 'T1', 'same browser keeps its till code');
select t.ok((select count(*) from shop_stock where shop_id = t.get('lim')::uuid) = 0, 'till cannot see another shop''s stock');
select t.put('inv1', gen_random_uuid()::text);
select t.ok((public.submit_invoice(jsonb_build_object('id', t.get('inv1'), 'no', 'GOM-T1-000001', 'device_id', t.get('dev1'), 't', now(), 'rate', 2850, 'vat_rate', 16,
  'items', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'mult', 1, 'qty', 3, 'price', 4560),
                             jsonb_build_object('product_id', t.get('brush'), 'piece', true, 'qty', 13, 'price', 5130))))->>'status') = 'ok', 'till submits a sale');
select t.ok((public.submit_invoice(jsonb_build_object('id', t.get('inv1'), 'no', 'GOM-T1-000001', 'device_id', t.get('dev1'), 'rate', 2850, 'vat_rate', 16,
  'items', '[]'::jsonb))->>'status') = 'duplicate', 'a sale sent twice is saved once');
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('lotion')::uuid) = 47, 'shop stock lowered by 3 pcs');
select t.ok((select qty || '/' || open_pieces from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('brush')::uuid) = '1/1', '13 pieces open 2 sets: 1 set left, 1 piece sold from the open one');
select t.ok((select count(*) from invoices) = 0, 'till cannot read invoices');
select t.fails(format($$select public.submit_invoice('{"id":"%s","no":"GOM-T1-000002","device_id":"%s","rate":2850,"vat_rate":16,"disc_pct":10,"items":[{"product_id":"%s","mult":1,"qty":1,"price":4560}]}')$$, gen_random_uuid(), t.get('dev1'), t.get('lotion')),
  'Only the shop admin', 'till cannot give a discount');
select t.fails(format($$select public.submit_invoice('{"id":"%s","no":"LIM-T1-000002","device_id":"%s","rate":2850,"vat_rate":16,"items":[{"product_id":"%s","mult":1,"qty":1,"price":4560}]}')$$, gen_random_uuid(), t.get('dev1'), t.get('lotion')),
  'does not match', 'invoice number must belong to this till');
select t.fails(format($$select public.submit_invoice('{"id":"%s","no":"GOM-T1-000003","device_id":"%s","rate":2850,"vat_rate":16,"items":[{"product_id":"%s","mult":7,"qty":1,"price":4560}]}')$$, gen_random_uuid(), t.get('dev1'), t.get('lotion')),
  'Unit not valid', 'unknown unit refused');
select t.fails(format($$select public.edit_invoice('%s', '[]', 0, 'test test')$$, t.get('inv1')), 'permission', 'till cannot edit invoices');
reset role;

-- ===== shop admin: discount, offline price, edit, report =====
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.put('dev2', (public.register_device()->>'id'));
select t.ok((select code from devices where id = t.get('dev2')::uuid) = 'T2', 'second till is T2');
select t.put('inv2', gen_random_uuid()::text);
-- sold offline at an old price (4000 FC): accepted as printed, flagged
select public.submit_invoice(jsonb_build_object('id', t.get('inv2'), 'no', 'GOM-T2-000001', 'device_id', t.get('dev2'), 'rate', 2850, 'vat_rate', 16, 'disc_pct', 10,
  'cashier_id', '00000000-0000-0000-0000-00000000000c',
  'items', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'mult', 24, 'qty', 1, 'price', 85500),
                             jsonb_build_object('product_id', t.get('lotion'), 'mult', 1, 'qty', 1, 'price', 4000))));
select t.ok((select total from invoices where id = t.get('inv2')::uuid) = 80550, 'discount 10% on 89 500 = 80 550 (rounded to 10 FC)');
select t.ok((select vat from invoices where id = t.get('inv2')::uuid) = 11110, 'VAT included = total x 16/116, rounded');
select t.ok((select price_flag from invoices where id = t.get('inv2')::uuid), 'an old price is accepted and flagged');
select t.ok((select count(*) from invoices) = 2, 'shop admin sees the shop''s invoices');
select t.ok((select last_seq from devices where id = t.get('dev2')::uuid) = 1, 'till sequence remembered on the server');
-- edit the till's sale: lotion 3 -> 2, brush pieces 13 -> 1
select public.edit_invoice(t.get('inv1')::uuid, '[{"line_no":1,"qty":2},{"line_no":2,"qty":1}]', 0, 'Customer returned items');
select t.ok((select total from invoices where id = t.get('inv1')::uuid) = 2 * 4560 + 5130, 'edited total');
select t.ok((select qty || '/' || open_pieces from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('brush')::uuid) = '2/1', 'brush stock put back: 2 sets, 1 piece sold from the open one');
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('lotion')::uuid) = 50 - 3 - 25 + 1, 'lotion stock: 50 received, 3 + 25 sold, 1 returned');
select t.put('rep', public.sales_report(current_date, current_date)::text);
select t.ok((t.get('rep')::jsonb->>'n')::int = 2, 'report counts the shop''s 2 invoices');
select t.ok((t.get('rep')::jsonb->'slips'->0->>'returned')::bigint = (3 * 4560 + 13 * 5130) - (2 * 4560 + 5130), 'day end Return FC = money given back by the edit');
select t.ok((t.get('rep')::jsonb->'slips'->0->>'collected')::bigint - (t.get('rep')::jsonb->'slips'->0->>'returned')::bigint = (t.get('rep')::jsonb->>'total')::bigint, 'Balance FC = invoice value');
select t.ok(jsonb_array_length(t.get('rep')::jsonb->'slips') = 1, 'shop admin report covers only their shop');
select t.ok((t.get('rep')::jsonb->'profit_usd') = 'null'::jsonb, 'shop admin does not get profit (cost) figures');
select public.record_reprint(t.get('inv1')::uuid);
reset role;

-- ===== another shop's admin =====
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000e');
select t.ok((select count(*) from invoices) = 0, 'Limete admin cannot see Gombe invoices');
select t.fails(format($$select public.edit_invoice('%s', '[{"line_no":1,"qty":1}]', 0, 'not mine')$$, t.get('inv1')), 'not found', 'cannot edit another shop''s invoice');
select t.ok((select count(*) from deliveries) = 0, 'Limete sees no deliveries now that DEL-0002 moved to Gombe');
reset role;

-- ===== admin sees everything; disabled users are shut out =====
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.ok(jsonb_array_length(public.sales_report(current_date, current_date)->'slips') = 2, 'admin all-shops report has a slip per shop');
select t.ok((public.sales_report(current_date, current_date)->>'profit_usd') is not null, 'admin gets profit');
select t.ok((select count(*) from audit_log) > 10, 'admin reads the activity log');
reset role;
update profiles set active = false where username = 'till.gombe';
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000d');
select t.ok((select count(*) from products) = 0, 'disabled account reads nothing');
select t.fails($$select public.register_device()$$, 'permission', 'disabled account cannot sell');
reset role;

\echo ALL TESTS PASSED
