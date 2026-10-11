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
-- lookups the tests need while playing a role (the roles themselves cannot call app.*)
create function t.acc(c text) returns uuid language sql security definer as $$ select app.acc(c) $$;
create function t.shop_acc(k text, s uuid) returns uuid language sql security definer as $$ select app.shop_acc(k, s) $$;
create function t.outstanding(b uuid) returns numeric language sql security definer as $$ select app.bill_outstanding(b) $$;
-- vouchers whose Dr and Cr differ in USD
create function t.unbalanced() returns bigint language sql security definer as $$
  select count(*) from (select v.id from vouchers v join voucher_lines l on l.voucher_id = v.id group by v.id
    having abs(sum(case when l.side = 'Dr' then l.base else -l.base end)) > 0.011) x $$;
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
-- categories are made by the Admin
select t.fails($$select public.save_product('{"name":"Test lotion","category":"Skin care","carton_cost":24,"per_carton":24,"pc":1.5}')$$, 'does not exist', 'an item needs a category the Admin made');
select public.save_category('{"name":"Skin care"}'), public.save_category('{"name":"Accessories"}'), public.save_category('{"name":"X"}');
select t.fails($$select public.save_category('{"name":"skin CARE"}')$$, 'already exists', 'category names are unique (any case)');
select t.fails($$select public.save_category('{"name":"School","seasonal":true}')$$, 'months', 'a seasonal category needs its months');
-- School sells only next month, so it is out of season now
select t.put('cat_school', public.save_category(jsonb_build_object('name', 'School', 'seasonal', true,
  'season_months', jsonb_build_array((extract(month from now() at time zone 'Africa/Kinshasa')::int % 12) + 1)))::text);
select t.put('lotion', public.save_product('{"name":"Test lotion","category":"Skin care","carton_cost":24,"per_carton":24,"pc":1.5,"dzn":16,"ctn":30,"qty_cartons":2,"qty_loose":3,"reorder":20}')::text);
select t.ok((select wh_qty from products where id = t.get('lotion')::uuid) = 51, 'opening stock 2 cartons + 3 pcs = 51 pcs');
select t.ok((select cost_usd from product_costs where product_id = t.get('lotion')::uuid) = 1, 'cost per pc = carton cost / pcs');
select t.ok((select count(*) from shop_stock where product_id = t.get('lotion')::uuid) = 2, 'new item is listed in every shop at 0');
select t.fails($$select public.save_product('{"name":"Bad","category":"X","carton_cost":24,"per_carton":24,"pc":0.5,"ctn":30}')$$, 'below the cost of one pc', 'price below cost is refused');
select t.fails($$select public.save_product('{"name":"test LOTION","category":"X","carton_cost":24,"per_carton":24,"pc":2,"ctn":30}')$$, 'already exists', 'duplicate name refused (any case)');
select t.put('brush', public.save_product('{"name":"Brush set","category":"Accessories","is_bundle":true,"set_cost":6,"set_price":14,"pcs":12,"piece":1.8,"qty_loose":10}')::text);
select public.save_product(jsonb_build_object('id', t.get('lotion'), 'name','Test lotion','category','Skin care','carton_cost',24,'per_carton',24,'pc',1.6,'dzn',16,'ctn',30,'reorder',20));
select t.ok(exists (select 1 from audit_log where action like 'Prices changed for Test lotion%'), 'price change is logged');
select t.fails(format($$select public.save_product('{"id":"%s","name":"Test lotion","category":"Skin care","carton_cost":24,"per_carton":24,"pc":1.6,"half":5,"dzn":16,"ctn":30}')$$, t.get('lotion')), 'half dozen is below', 'half dozen price below the cost of 6 pcs is refused');
select public.save_product(jsonb_build_object('id', t.get('lotion'), 'name','Test lotion','category','Skin care','carton_cost',24,'per_carton',24,'pc',1.6,'half',8.5,'dzn',16,'ctn',30,'reorder',20,'qty_loose',99));
select t.ok((select half_dozen_usd from products where id = t.get('lotion')::uuid) = 8.5 and (select wh_qty from products where id = t.get('lotion')::uuid) = 51, 'half dozen price saved; editing an item does not add stock');
select t.put('soap', public.save_product('{"name":"Soap","category":"Skin care","carton_cost":48,"per_carton":48,"pc":1.5,"dzn":13}')::text);
select t.ok((select carton_usd from products where id = t.get('soap')::uuid) = 0, 'carton price is optional');
select t.fails($$select public.save_product('{"name":"Soap 2","category":"Skin care","carton_cost":48,"per_carton":48,"pc":1.5,"ctn":40}')$$, 'below the carton cost', 'a carton price, when given, cannot be below the carton cost');
-- supplier with credit terms, opening balance owed and the items it supplies
select t.put('sup', public.save_supplier(jsonb_build_object('name','Beauty Import SARL','phone','+243 810 000 000','credit_days',30,
  'opening_amount',100,'opening_side','Cr','items',jsonb_build_array(t.get('lotion'))))::text);
select t.put('sup_acc', (select account_id::text from suppliers where id = t.get('sup')::uuid));
select t.ok((select group_code from accounts where id = t.get('sup_acc')::uuid) = 'creditors', 'a supplier gets its own ledger under Sundry Creditors');
select t.fails($$select public.save_supplier('{"name":"beauty import sarl"}')$$, 'already exists', 'supplier names are unique');
select t.ok((public.import_products('[{"row":2,"name":"Aloe gel","category":"Skin care","carton_cost":60,"per_carton":24,"pc":4,"dzn":45,"ctn":90,"open_cartons":5},
  {"row":3,"name":"Test Lotion","category":"Skin care","carton_cost":60,"per_carton":24,"pc":4,"ctn":90},
  {"row":4,"name":"Argan shampoo","category":"Hair care","carton_cost":72,"per_carton":12,"pc":9,"ctn":100,"sku":"AR-1"}]', 'test.xlsx')->>'imported')::int = 2,
  'import adds new rows and skips a duplicate name');
select t.ok((select wh_qty from products where name='Aloe gel') = 120 and (select reorder from products where name='Aloe gel') = 24, 'import opening stock and default reorder');
select t.ok(exists (select 1 from categories where name = 'Hair care'), 'import creates a category it does not know');
select t.fails($$select public.import_products('[{"row":2,"name":"Fine","category":"X","carton_cost":10,"per_carton":10,"pc":2,"ctn":15},{"row":3,"name":"Cheap","category":"X","carton_cost":100,"per_carton":10,"pc":5,"ctn":90}]')$$,
  'Nothing was imported', 'an invalid row stops the whole import');
select t.ok(not exists (select 1 from products where name = 'Fine'), 'nothing from the failed import was saved');
select t.fails($$update public.products set price_usd = 1$$, 'permission denied', 'admin cannot write tables directly either');
reset role;

-- ===== warehouse operator: no cost; deliveries wait for the shop =====
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000b');
select t.ok((select count(*) from product_costs) = 0, 'operator cannot see cost prices');
select t.ok((select count(*) from products) = 5, 'operator sees the items');
select t.fails($$select public.save_product('{"name":"X","category":"X","carton_cost":1,"per_carton":2,"pc":1,"ctn":2}')$$, 'permission', 'operator cannot create or price items');
select t.fails(format($$select public.receive_goods('{"lines":[{"product_id":"%s","qty":1}]}')$$, t.get('lotion')), 'Choose the supplier', 'receiving needs the supplier');
select t.fails(format($$select public.receive_stock('%s', 0, 1, 'x')$$, t.get('lotion')), 'permission', 'the old receive without a supplier is closed');
select t.put('grn1', public.receive_goods(jsonb_build_object('supplier_id', t.get('sup'), 'ref', 'DN 55',
  'lines', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 1))))->>'id');
select t.ok((select wh_qty from products where id = t.get('lotion')::uuid) = 52, 'goods received from the supplier add to the store');
select t.ok((select no || ':' || status from grns where id = t.get('grn1')::uuid) = 'GRN-0001:awaiting_bill', 'goods receipt waits for the bill');
select t.ok((select count(*) from vouchers) = 0 and (select count(*) from accounts) = 0, 'operator cannot read the books directly');
select t.fails($$select public.enter_bill('{}')$$, 'permission', 'operator cannot enter bills');
select t.put('dels', public.create_deliveries(array[t.get('gom')::uuid, t.get('lim')::uuid],
  jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 24), jsonb_build_object('product_id', t.get('brush'), 'qty', 2)))::text);
select t.ok((select string_agg(no || ':' || status, ',' order by no) from deliveries) = 'DEL-0001:pending,DEL-0002:pending', 'one pending delivery per outlet');
select t.ok((select wh_qty from products where id = t.get('lotion')::uuid) = 52, 'sending does not move store stock yet');
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('lotion')::uuid) = 0, 'shop stock unchanged until received');
select t.fails(format($$select public.create_deliveries(array['%s'::uuid], '[{"product_id":"%s","qty":5}]')$$, t.get('gom'), t.get('lotion')), 'not yet received', 'stock promised to waiting deliveries cannot be sent again (52 - 48 = 4 left)');
select t.fails(format($$select public.create_deliveries(array['%s'::uuid], '[{"product_id":"%s","qty":1.5}]')$$, t.get('gom'), t.get('lotion')), 'whole numbers', 'fractional quantity refused');
-- move DEL-0002 (Limete) to Gombe and change 24 -> 26, still waiting
select t.fails(format($$select public.edit_delivery('%s', '%s', '[{"product_id":"%s","qty":26}]', 'x')$$, (select id from deliveries where no='DEL-0002'), t.get('gom'), t.get('lotion')), 'reason', 'edit needs a reason');
select public.edit_delivery((select id from deliveries where no='DEL-0002'), t.get('gom')::uuid, jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 26)), 'Wrong shop at loading');
select t.ok((select shop_id from deliveries where no='DEL-0002') = t.get('gom')::uuid and (select status from deliveries where no='DEL-0002') = 'pending', 'edited delivery moved and still waiting');
select t.ok((select price_usd from delivery_items i join deliveries d on d.id = i.delivery_id where d.no='DEL-0002') = 1.6, 'price frozen from first dispatch');
select t.fails(format($$select public.receive_delivery('%s', '[]', '')$$, (select id from deliveries where no='DEL-0001')), 'permission', 'the operator cannot receive for a shop');
-- a third delivery is cancelled before it arrives
select public.create_deliveries(array[t.get('lim')::uuid], jsonb_build_array(jsonb_build_object('product_id', t.get('brush'), 'qty', 1)));
select public.cancel_delivery((select id from deliveries where no='DEL-0003'), 'Truck broke down');
select t.ok((select status from deliveries where no='DEL-0003') = 'cancelled', 'a waiting delivery can be cancelled');
reset role;

-- ===== shop admin receives the deliveries =====
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.ok((select count(*) from deliveries where status = 'pending') = 2, 'shop admin sees the two deliveries waiting for Gombe');
select t.fails(format($$select public.receive_delivery('%s', '[{"product_id":"%s","qty":30}]', '')$$, (select id from deliveries where no='DEL-0001'), t.get('lotion')), 'more than was sent', 'cannot receive more than was sent');
select t.fails(format($$select public.receive_delivery('%s', '[{"product_id":"%s","qty":20}]', '')$$, (select id from deliveries where no='DEL-0001'), t.get('lotion')), 'arrived short', 'a short delivery needs a note');
select public.receive_delivery((select id from deliveries where no='DEL-0001'), jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 24), jsonb_build_object('product_id', t.get('brush'), 'qty', 2)), '');
select public.receive_delivery((select id from deliveries where no='DEL-0002'), jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 26)), '');
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('lotion')::uuid) = 50, 'Gombe stock goes up only when received (24 + 26)');
select t.ok((select wh_qty from products where id = t.get('lotion')::uuid) = 2 and (select wh_qty from products where id = t.get('brush')::uuid) = 8, 'store stock goes down when received');
select t.fails(format($$select public.receive_delivery('%s', '[]', '')$$, (select id from deliveries where no='DEL-0001')), 'already received', 'a delivery is received once');
reset role;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000b');
select t.fails(format($$select public.edit_delivery('%s', '%s', '[{"product_id":"%s","qty":1}]', 'too late')$$, (select id from deliveries where no='DEL-0001'), t.get('gom'), t.get('lotion')), 'no longer be changed', 'a received delivery can no longer be edited');
reset role;

-- ===== till operator: prepares orders for the shop admin; never sells or reads invoices =====
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000d');
select t.put('dev1', (public.register_device()->>'id'));
select t.ok((select code from devices where id = t.get('dev1')::uuid) = 'T1', 'first till of the shop is T1');
select t.ok((public.register_device(t.get('dev1')::uuid)->>'code') = 'T1', 'same browser keeps its till code');
select t.ok((select count(*) from shop_stock where shop_id = t.get('lim')::uuid) = 0, 'till cannot see another shop''s stock');
select t.fails(format($$select public.submit_order('{"id":"%s","customer":" ","items":[{"product_id":"%s","mult":1,"qty":1}]}')$$, gen_random_uuid(), t.get('lotion')), 'customer name', 'an order needs the customer name');
select t.put('ord1', gen_random_uuid()::text);
select t.ok((public.submit_order(jsonb_build_object('id', t.get('ord1'), 'customer', 'Mama Nzuzi',
  'items', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'mult', 1, 'qty', 3),
                             jsonb_build_object('product_id', t.get('brush'), 'piece', true, 'qty', 13))))->>'status') = 'ok', 'till sends an order for approval');
select t.ok((public.submit_order(jsonb_build_object('id', t.get('ord1'), 'customer', 'Mama Nzuzi', 'items', '[]'::jsonb))->>'status') = 'duplicate', 'an order sent twice is saved once');
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('lotion')::uuid) = 50, 'an order does not take stock');
select t.ok((select count(*) from sale_orders) = 1, 'till sees its own order');
select t.fails(format($$select public.submit_invoice('{"id":"%s","no":"GOM-T1-000001","device_id":"%s","customer":"X","rate":2850,"vat_rate":16,"items":[{"product_id":"%s","mult":1,"qty":1,"price":4560}]}')$$, gen_random_uuid(), t.get('dev1'), t.get('lotion')),
  'permission', 'till cannot complete a sale');
select t.fails(format($$select public.submit_order('{"id":"%s","customer":"Y","items":[{"product_id":"%s","mult":7,"qty":1}]}')$$, gen_random_uuid(), t.get('lotion')), 'Unit not valid', 'unknown unit refused');
select t.ok((select count(*) from invoices) = 0, 'till cannot read invoices');
select t.put('ord2', gen_random_uuid()::text);
select public.submit_order(jsonb_build_object('id', t.get('ord2'), 'customer', 'Papa Lokwa', 'items', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'mult', 1, 'qty', 1))));
reset role;

-- ===== shop admin: approves orders, discount, offline price, edit, report =====
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.put('dev2', (public.register_device()->>'id'));
select t.ok((select code from devices where id = t.get('dev2')::uuid) = 'T2', 'second till is T2');
select t.ok((select count(*) from sale_orders where status = 'pending') = 2, 'shop admin sees the orders waiting for review');
select t.put('inv1', gen_random_uuid()::text);
select t.fails(format($$select public.submit_invoice('{"id":"%s","no":"GOM-T2-000001","device_id":"%s","customer":"","rate":2850,"vat_rate":16,"items":[{"product_id":"%s","mult":1,"qty":1,"price":4560}]}')$$, gen_random_uuid(), t.get('dev2'), t.get('lotion')),
  'customer name', 'an invoice needs the customer name');
-- approve the till's order, as reviewed (same lines)
select t.ok((public.submit_invoice(jsonb_build_object('id', t.get('inv1'), 'no', 'GOM-T2-000001', 'device_id', t.get('dev2'), 't', now(), 'rate', 2850, 'vat_rate', 16,
  'customer', 'Mama Nzuzi', 'order_id', t.get('ord1'),
  'items', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'mult', 1, 'qty', 3, 'price', 4560),
                             jsonb_build_object('product_id', t.get('brush'), 'piece', true, 'qty', 13, 'price', 5130))))->>'status') = 'ok', 'shop admin approves the order into an invoice');
select t.ok((select status || '/' || (invoice_id = t.get('inv1')::uuid)::text from sale_orders where id = t.get('ord1')::uuid) = 'approved/true', 'order marked approved and linked to the invoice');
select t.ok((select customer || '/' || prepared_by_name from invoices where id = t.get('inv1')::uuid) = 'Mama Nzuzi/Grace Mbuyi', 'invoice keeps the customer and who prepared it');
select t.fails(format($$select public.submit_invoice('{"id":"%s","no":"GOM-T2-000009","device_id":"%s","customer":"Again","order_id":"%s","rate":2850,"vat_rate":16,"items":[{"product_id":"%s","mult":1,"qty":1,"price":4560}]}')$$, gen_random_uuid(), t.get('dev2'), t.get('ord1'), t.get('lotion')),
  'already approved', 'an order is approved once');
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('lotion')::uuid) = 47, 'stock lowered by 3 pcs on approval');
select t.ok((select qty || '/' || open_pieces from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('brush')::uuid) = '1/1', '13 pieces open 2 sets: 1 set left, 1 piece sold from the open one');
select t.fails(format($$select public.reject_order('%s', '')$$, t.get('ord2')), 'reason', 'rejecting needs a reason');
select public.reject_order(t.get('ord2')::uuid, 'Customer left');
select t.ok((select status from sale_orders where id = t.get('ord2')::uuid) = 'rejected', 'order rejected');
select t.put('inv2', gen_random_uuid()::text);
-- sold offline at an old price (4000 FC): accepted as printed, flagged
select public.submit_invoice(jsonb_build_object('id', t.get('inv2'), 'no', 'GOM-T2-000002', 'device_id', t.get('dev2'), 'rate', 2850, 'vat_rate', 16, 'disc_pct', 10,
  'cashier_id', '00000000-0000-0000-0000-00000000000c', 'customer', 'Walk-in',
  'items', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'mult', 24, 'qty', 1, 'price', 85500),
                             jsonb_build_object('product_id', t.get('lotion'), 'mult', 1, 'qty', 1, 'price', 4000))));
select t.ok((select total from invoices where id = t.get('inv2')::uuid) = 80550, 'discount 10% on 89 500 = 80 550 (rounded to 10 FC)');
select t.ok((select vat from invoices where id = t.get('inv2')::uuid) = 11110, 'VAT included = total x 16/116, rounded');
select t.ok((select price_flag from invoices where id = t.get('inv2')::uuid), 'an old price is accepted and flagged');
select t.ok((select count(*) from invoices) = 2, 'shop admin sees the shop''s invoices');
select t.ok((select last_seq from devices where id = t.get('dev2')::uuid) = 2, 'till sequence remembered on the server');
-- edit the approved sale: lotion 3 -> 2, brush pieces 13 -> 1
select public.edit_invoice(t.get('inv1')::uuid, '[{"line_no":1,"qty":2},{"line_no":2,"qty":1}]', 0, 'Customer returned items');
select t.ok((select total from invoices where id = t.get('inv1')::uuid) = 2 * 4560 + 5130, 'edited total');
select t.ok((select qty || '/' || open_pieces from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('brush')::uuid) = '2/1', 'brush stock put back: 2 sets, 1 piece sold from the open one');
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('lotion')::uuid) = 50 - 3 - 25 + 1, 'lotion stock: 50 received, 3 + 25 sold, 1 returned');
select t.put('rep', public.sales_report(current_date, current_date)::text);
select t.ok((t.get('rep')::jsonb->>'n')::int = 2, 'report counts the shop''s 2 invoices');
select t.ok((t.get('rep')::jsonb->'slips'->0->>'returned')::bigint = (3 * 4560 + 13 * 5130) - (2 * 4560 + 5130), 'day end Return FC = money given back by the edit');
select t.ok((t.get('rep')::jsonb->'slips'->0->>'collected')::bigint - (t.get('rep')::jsonb->'slips'->0->>'returned')::bigint = (t.get('rep')::jsonb->>'total')::bigint, 'Balance FC = invoice value');
select t.ok(jsonb_array_length(t.get('rep')::jsonb->'slips') = 1, 'shop admin report covers only their shop');
select t.ok((t.get('rep')::jsonb->'by_day'->0->>'day') = current_date::text and (t.get('rep')::jsonb->'by_day'->0->>'n')::int = 2, 'sales by day: one row per day with its count');
select t.ok((t.get('rep')::jsonb->'top'->0->>'name') is not null, 'best sellers list items by name');
select t.ok((t.get('rep')::jsonb->'invoices'->0->>'customer') in ('Walk-in', 'Mama Nzuzi'), 'report lists the customer');
select t.ok((t.get('rep')::jsonb->'profit_usd') = 'null'::jsonb, 'shop admin does not get profit (cost) figures');
select public.record_reprint(t.get('inv1')::uuid);
reset role;

-- ===== another shop's admin =====
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000e');
select t.ok((select count(*) from invoices) = 0, 'Limete admin cannot see Gombe invoices');
select t.fails(format($$select public.edit_invoice('%s', '[{"line_no":1,"qty":1}]', 0, 'not mine')$$, t.get('inv1')), 'not found', 'cannot edit another shop''s invoice');
select t.ok((select string_agg(no, ',') from deliveries) = 'DEL-0003', 'Limete sees only its own (cancelled) delivery now that DEL-0002 moved to Gombe');
select t.ok((select count(*) from sale_orders) = 0, 'Limete admin cannot see Gombe orders');
reset role;

-- ===== half dozen sale and the till printing approved orders =====
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.put('lot_before', (select qty::text from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('lotion')::uuid));
select t.put('inv3', gen_random_uuid()::text);
select public.submit_invoice(jsonb_build_object('id', t.get('inv3'), 'no', 'GOM-T2-000003', 'device_id', t.get('dev2'), 'rate', 2850, 'vat_rate', 16, 'customer', 'Maman Rose',
  'items', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'mult', 6, 'qty', 1, 'price', 24230))));
select t.ok((select unit || '/' || price_flag::text from invoice_items ii join invoices i on i.id = ii.invoice_id where i.id = t.get('inv3')::uuid) = 'half dzn/false', 'sold by half dozen at the half dozen price');
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('lotion')::uuid) = t.get('lot_before')::int - 6, 'a half dozen takes 6 pcs');
select t.fails(format($$select public.submit_invoice('{"id":"%s","no":"GOM-T2-000004","device_id":"%s","customer":"X","rate":2850,"vat_rate":16,"items":[{"product_id":"%s","mult":48,"qty":1,"price":1000}]}')$$, gen_random_uuid(), t.get('dev2'), t.get('soap')),
  'Unit not valid', 'no carton price means no carton unit');
select t.ok((select sold_30 from public.item_ranks(null) where product_id = t.get('lotion')::uuid) = 2 + 25 + 6, 'hot items: units sold in the last 30 days, in this shop');
reset role;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000d');
select t.ok((select string_agg(no, ',') from invoices) = 'GOM-T2-000001', 'till reads only the invoices of its own approved orders');
select public.record_till_print(t.get('inv1')::uuid);
select t.fails(format($$select public.record_till_print('%s')$$, t.get('inv1')), 'Already printed', 'the till prints an approved order once');
select t.fails(format($$select public.record_till_print('%s')$$, t.get('inv2')), 'not found', 'the till cannot print other invoices');
select t.fails($$select public.ledger_list()$$, 'permission', 'till cannot open the books');
reset role;

-- ===== book keeping =====
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.ok(t.unbalanced() = 0, 'every voucher posted by SIM balances');
select t.ok((select sum(l.amount) from voucher_lines l join vouchers v on v.id = l.voucher_id where v.type = 'opening' and l.account_id = t.acc('INV_STORE')) = 51 + 60 + 300,
  'opening stock of new items booked at cost (lotion 51, brushes 60, aloe 300)');
select t.ok((select l.amount from voucher_lines l join vouchers v on v.id = l.voucher_id where v.source_id = t.get('grn1')::uuid and l.side = 'Dr') = 1, 'goods in booked at item cost against GRNI');
-- sale: cash and sales in FC; cost of goods sold at cost; an edit reposts the same voucher
select t.ok((select count(*) from vouchers where source_id = t.get('inv1')::uuid) = 1, 'one sales voucher per invoice, rewritten when the invoice is edited');
select t.ok((select l.amount from voucher_lines l join vouchers v on v.id = l.voucher_id where v.source_id = t.get('inv1')::uuid and l.account_id = t.shop_acc('CASH_SHOP', t.get('gom')::uuid))
  = (select total from invoices where id = t.get('inv1')::uuid), 'shop cash debited with the edited invoice total');
select t.ok((select l.amount from voucher_lines l join vouchers v on v.id = l.voucher_id where v.source_id = t.get('inv1')::uuid and l.account_id = t.acc('COGS')) = 2.5,
  'cost of goods sold: 2 pcs at 1 USD + 1 brush piece at 0.50');
select t.ok((select l.amount from voucher_lines l join vouchers v on v.id = l.voucher_id join deliveries d on d.id = v.source_id where d.no = 'DEL-0001' and l.side = 'Dr') = 24 + 12,
  'delivery received: shop stock up and store stock down at cost');
-- the supplier's bill for the goods receipt
select t.fails(format($$select public.enter_bill('{"grn_id":"%s","bill_no":"","amount":1.2}')$$, t.get('grn1')), 'bill number', 'a bill needs the supplier''s number');
select t.put('bill1', public.enter_bill(jsonb_build_object('grn_id', t.get('grn1'), 'bill_no', 'F-778', 'amount', 1.2, 'currency', 'USD'))->>'voucher_id');
select t.ok((select status from grns where id = t.get('grn1')::uuid) = 'billed', 'goods receipt marked billed');
select t.ok((select l.side || l.amount from voucher_lines l where l.voucher_id = t.get('bill1')::uuid and l.account_id = t.acc('PPV')) = 'Dr0.20', 'bill above item cost: difference to purchase price difference');
select t.ok((select due_date from voucher_lines where voucher_id = t.get('bill1')::uuid and bill_ref = 'F-778') = current_date + 30, 'due date = bill date + credit days');
select t.fails(format($$select public.enter_bill('{"grn_id":"%s","bill_no":"F-779","amount":1}')$$, t.get('grn1')), 'already entered', 'a goods receipt is billed once');
-- direct bill (transport) charged to an expense
select public.enter_bill(jsonb_build_object('supplier_id', t.get('sup'), 'account_id', t.acc('EXP_TRANSPORT'), 'bill_no', 'TR-1', 'amount', 28500, 'currency', 'FC', 'rate', 2850));
select t.ok((public.payables()->0->>'balance')::numeric = 100 + 1.2 + 10, 'supplier owes: opening 100 + bill 1.20 + transport 28 500 FC (10 USD)');
-- payment bill by bill, in FC from shop cash and USD from head office
select t.fails(format($$select public.post_voucher('{"type":"payment","lines":[{"account":"%s","side":"Dr","amount":1},{"account":"%s","side":"Cr","amount":2}]}')$$, t.get('sup_acc'), t.acc('CASH_HO')),
  'not equal', 'an unbalanced voucher is refused');
select t.fails(format($$select public.post_voucher('{"type":"contra","lines":[{"account":"%s","side":"Dr","amount":1},{"account":"%s","side":"Cr","amount":1}]}')$$, t.get('sup_acc'), t.acc('CASH_HO')),
  'contra', 'a contra moves money between cash and bank only');
select t.fails(format($$select public.post_voucher('{"type":"payment","lines":[{"account":"%s","side":"Dr","amount":5},{"account":"%s","side":"Cr","amount":5}],"allocations":[{"bill_id":"%s","amount":5}]}')$$, t.get('sup_acc'), t.acc('CASH_HO'), t.get('bill1')),
  'still due', 'cannot settle more than the bill');
select t.put('pay1', public.post_voucher(jsonb_build_object('type', 'payment', 'narration', 'Part payment F-778',
  'lines', jsonb_build_array(jsonb_build_object('account', t.get('sup_acc'), 'side', 'Dr', 'amount', 2850, 'currency', 'FC', 'rate', 2850),
                             jsonb_build_object('account', t.acc('CASH_HO'), 'side', 'Cr', 'amount', 1, 'currency', 'USD')),
  'allocations', jsonb_build_array(jsonb_build_object('bill_id', t.get('bill1'), 'amount', 1))))->>'id');
select t.ok(round(t.outstanding(t.get('bill1')::uuid), 2) = 0.20, 'bill F-778: 0.20 still due after paying 2 850 FC');
select t.ok((select count(*) from jsonb_array_elements(public.payables()->0->'bills')) = 2, 'payables list the open bills with due dates');
select t.fails(format($$select public.cancel_voucher('%s', 'wrong')$$, t.get('bill1')), 'already (partly) paid', 'a paid bill cannot be cancelled before its payment');
select public.cancel_voucher(t.get('pay1')::uuid, 'Paid twice by mistake');
select t.ok(round(t.outstanding(t.get('bill1')::uuid), 2) = 1.20, 'cancelling the payment reopens the bill');
select t.fails(format($$select public.cancel_voucher('%s', 'nope')$$, (select id from vouchers where source_id = t.get('inv1')::uuid)), 'correct the source', 'vouchers made from invoices follow the invoice');
-- expenses are payment vouchers
select public.add_upkeep(current_date, 'Rent', 'Gombe shop rent', 285000, 'FC');
select t.ok((select sum(amount_usd) from upkeep) = 100 and exists (select 1 from vouchers where type = 'payment' and narration like 'Rent:%'), 'an expense in FC is listed in USD and booked as a payment');
-- stock count and items
select t.put('argan', (select id::text from products where name = 'Argan shampoo'));
select public.receive_goods(jsonb_build_object('supplier_id', t.get('sup'), 'lines', jsonb_build_array(jsonb_build_object('product_id', t.get('argan'), 'qty', 2))));
select t.fails(format($$select public.delete_product('%s')$$, t.get('argan')), 'central store', 'an item with stock cannot be deleted');
select public.adjust_stock(jsonb_build_object('product_id', t.get('argan'), 'counted', 0, 'reason', 'Broken bottles'));
select t.ok((select l.amount from voucher_lines l join vouchers v on v.id = l.voucher_id where v.type = 'adjustment' and l.account_id = t.acc('STOCK_ADJ')) = 12, 'stock count loss booked at cost (2 x 6 USD)');
select t.ok(public.delete_product(t.get('argan')::uuid) = 'archived', 'an item with history is archived, not deleted');
select t.ok((select not active from products where id = t.get('argan')::uuid), 'archived item is hidden from lists');
select public.restore_product(t.get('argan')::uuid);
select public.save_product(jsonb_build_object('id', t.get('soap'), 'name','Soap','category','Skin care','carton_cost',48,'per_carton',48,'pc',1.5,'dzn',13));
select t.put('aloe', (select id::text from products where name = 'Aloe gel'));
select public.save_product(jsonb_build_object('id', t.get('aloe'), 'name','Aloe gel','category','Skin care','carton_cost',72,'per_carton',24,'pc',4,'dzn',45,'ctn',90,'reorder',24));
select t.ok((select l.side || l.amount from voucher_lines l join vouchers v on v.id = l.voucher_id where v.narration like 'Cost of Aloe gel changed%' and l.account_id = t.acc('INV_STORE')) = 'Dr60.00',
  'a new cost price revalues the stock held (120 pcs x 0.50 more)');
select t.put('pencil', public.save_product('{"name":"HB pencil","category":"School","carton_cost":10,"per_carton":100,"pc":0.2}')::text);
select t.ok((select not in_season from public.item_ranks(null) where product_id = t.get('pencil')::uuid), 'a seasonal item out of its months goes last');
select t.fails(format($$select public.delete_category('%s')$$, t.get('cat_school')), 'Move the 1 item', 'a category in use cannot be deleted');
select t.ok(public.delete_product(t.get('pencil')::uuid) = 'deleted', 'an unused item is deleted');
select public.delete_category(t.get('cat_school')::uuid);
select public.save_category(jsonb_build_object('id', (select id from categories where name = 'Accessories'), 'name', 'Brushes & tools'));
select t.ok((select category from products where id = t.get('brush')::uuid) = 'Brushes & tools', 'renaming a category moves its items');
reset role;

-- ===== shop return to the central store =====
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.put('lot_shop', (select qty::text from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('lotion')::uuid));
select t.fails(format($$select public.create_return('{"reason":"Damaged","lines":[{"product_id":"%s","qty":999}]}')$$, t.get('lotion')), 'does not have that many', 'cannot return more than the shop has');
select t.put('ret1', public.create_return(jsonb_build_object('reason', 'Damaged packaging', 'lines', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 3))))->>'id');
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('lotion')::uuid) = t.get('lot_shop')::int - 3, 'stock leaves the shop when the return is sent');
select t.put('ret2', public.create_return(jsonb_build_object('reason', 'Wrong item', 'lines', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 1))))->>'id');
select public.cancel_return(t.get('ret2')::uuid, 'Kept after all');
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('lotion')::uuid) = t.get('lot_shop')::int - 3, 'a cancelled return puts the stock back');
select t.ok((select count(*) from jsonb_array_elements(public.ledger_list())) = 3, 'shop admin sees only the shop''s own ledgers');
select t.put('cash_gom', t.shop_acc('CASH_SHOP', t.get('gom')::uuid)::text);
select t.ok((public.account_statement(t.get('cash_gom')::uuid, current_date, current_date)->>'closing')::numeric > 0, 'shop admin reads the shop cash statement');
select t.fails(format($$select public.account_statement('%s', current_date, current_date)$$, t.acc('CASH_HO')), 'not found', 'shop admin cannot read head office ledgers');
select t.fails($$select public.post_voucher('{"type":"journal","lines":[]}')$$, 'permission', 'shop admin cannot post vouchers');
reset role;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000b');
select t.put('wh_lot', (select wh_qty::text from products where id = t.get('lotion')::uuid));
select t.fails(format($$select public.receive_return('%s', '[{"product_id":"%s","qty":2}]', '')$$, t.get('ret1'), t.get('lotion')), 'arrived short', 'a short return needs a note');
select public.receive_return(t.get('ret1')::uuid, jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 2)), 'One bottle broken on the way');
select t.ok((select wh_qty from products where id = t.get('lotion')::uuid) = t.get('wh_lot')::int + 2, 'the store gets what arrived');
select t.ok((select bool_and(group_code = 'stock') from jsonb_to_recordset(public.ledger_list()) x(group_code text)), 'warehouse sees only the stock ledgers');
select t.fails($$select public.trial_balance(current_date)$$, 'permission', 'warehouse cannot open the trial balance');
reset role;

-- ===== statements and reports =====
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.ok(t.unbalanced() = 0, 'all vouchers still balance after bills, payments, returns and adjustments');
select t.ok((select l.amount from voucher_lines l join vouchers v on v.id = l.voucher_id where v.source_id = t.get('ret1')::uuid and v.source_type = 'return_in' and l.account_id = t.acc('STOCK_ADJ')) = 1,
  'the short return is booked as a loss at cost');
select t.ok((select count(*) from vouchers where source_id = t.get('ret2')::uuid and status = 'cancelled') = 1, 'the cancelled return''s voucher is cancelled');
select t.put('st', public.account_statement(t.get('sup_acc')::uuid, current_date, current_date, true)::text);
select t.ok((t.get('st')::jsonb->>'brought_forward')::numeric = -100 and (t.get('st')::jsonb->>'closing')::numeric = -111.2, 'statement with opening balance: 100 Cr brought forward, 111.20 Cr closing');
select t.ok((public.account_statement(t.get('sup_acc')::uuid, current_date, current_date, false)->>'brought_forward')::numeric = 0, 'statement without the opening balance starts at 0');
select t.put('tb', public.trial_balance(current_date, false)::text);
select t.ok((t.get('tb')::jsonb->>'total_dr')::numeric = (t.get('tb')::jsonb->>'total_cr')::numeric, 'trial balance without openings: Dr = Cr');
select t.put('tb', public.trial_balance(current_date, true)::text);
select t.ok((t.get('tb')::jsonb->>'total_dr')::numeric - (t.get('tb')::jsonb->>'total_cr')::numeric = (t.get('tb')::jsonb->>'opening_difference')::numeric
  and (t.get('tb')::jsonb->>'opening_difference')::numeric = -100, 'trial balance with openings shows the difference in opening balances');
select t.put('pl', public.profit_loss(current_date, current_date)::text);
select t.ok((t.get('pl')::jsonb->>'income')::numeric > 0 and (t.get('pl')::jsonb->>'expense')::numeric > 0, 'profit and loss has sales and costs');
select t.put('bs', public.balance_sheet(current_date)::text);
select t.ok(abs((t.get('bs')::jsonb->>'assets')::numeric - (t.get('bs')::jsonb->>'liabilities')::numeric - (t.get('bs')::jsonb->>'profit')::numeric + 100) < 0.02,
  'balance sheet: assets = liabilities + capital + profit (+ opening difference)');
select t.ok(abs((t.get('bs')::jsonb->>'profit')::numeric - ((t.get('pl')::jsonb->>'income')::numeric - (t.get('pl')::jsonb->>'expense')::numeric)) < 0.02, 'balance sheet profit = profit and loss');
select t.ok(jsonb_array_length(public.day_book(current_date, current_date)) = (select count(*) from vouchers), 'day book lists every voucher of the day');
select t.ok((select count(*) from jsonb_array_elements(public.day_book(current_date, current_date, 'sales'))) = 3, 'day book filters by voucher type');
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
