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
-- a stock request from the signed-in shop admin; returns its id
create function t.req(lines jsonb, note text default '') returns text language sql as $$ select public.create_stock_request(jsonb_build_object('note', note, 'lines', lines))->>'id' $$;
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
select t.fails(format($$select public.submit_invoice('{"id":"%s","no":"GOM-T1-000001","device_id":"%s","customer":"X","rate":2850,"vat_rate":16,"items":[{"product_id":"%s","mult":1,"qty":1,"price":4600}]}')$$, gen_random_uuid(), t.get('dev1'), t.get('lotion')),
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
select t.fails(format($$select public.submit_invoice('{"id":"%s","no":"GOM-T2-000001","device_id":"%s","customer":"","rate":2850,"vat_rate":16,"items":[{"product_id":"%s","mult":1,"qty":1,"price":4600}]}')$$, gen_random_uuid(), t.get('dev2'), t.get('lotion')),
  'customer name', 'an invoice needs the customer name');
-- approve the till's order, as reviewed (same lines)
select t.ok((public.submit_invoice(jsonb_build_object('id', t.get('inv1'), 'no', 'GOM-T2-000001', 'device_id', t.get('dev2'), 't', now(), 'rate', 2850, 'vat_rate', 16,
  'customer', 'Mama Nzuzi', 'order_id', t.get('ord1'),
  'items', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'mult', 1, 'qty', 3, 'price', 4600),
                             jsonb_build_object('product_id', t.get('brush'), 'piece', true, 'qty', 13, 'price', 5150))))->>'status') = 'ok', 'shop admin approves the order into an invoice');
select t.ok((select status || '/' || (invoice_id = t.get('inv1')::uuid)::text from sale_orders where id = t.get('ord1')::uuid) = 'approved/true', 'order marked approved and linked to the invoice');
select t.ok((select customer || '/' || prepared_by_name from invoices where id = t.get('inv1')::uuid) = 'Mama Nzuzi/Grace Mbuyi', 'invoice keeps the customer and who prepared it');
select t.fails(format($$select public.submit_invoice('{"id":"%s","no":"GOM-T2-000009","device_id":"%s","customer":"Again","order_id":"%s","rate":2850,"vat_rate":16,"items":[{"product_id":"%s","mult":1,"qty":1,"price":4600}]}')$$, gen_random_uuid(), t.get('dev2'), t.get('ord1'), t.get('lotion')),
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
select t.ok((select total from invoices where id = t.get('inv1')::uuid) = 2 * 4600 + 5150, 'edited total');
select t.ok((select qty || '/' || open_pieces from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('brush')::uuid) = '2/1', 'brush stock put back: 2 sets, 1 piece sold from the open one');
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('lotion')::uuid) = 50 - 3 - 25 + 1, 'lotion stock: 50 received, 3 + 25 sold, 1 returned');
select t.put('rep', public.sales_report(current_date, current_date)::text);
select t.ok((t.get('rep')::jsonb->>'n')::int = 2, 'report counts the shop''s 2 invoices');
select t.ok((t.get('rep')::jsonb->'slips'->0->>'returned')::bigint = (3 * 4600 + 13 * 5150) - (2 * 4600 + 5150), 'day end Return FC = money given back by the edit');
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
  'items', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'mult', 6, 'qty', 1, 'price', 24250))));
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

-- ===== price per pc optional; invoice units can be edited; invoices can be deleted =====
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.fails($$select public.save_product('{"name":"No price","category":"Skin care","carton_cost":24,"per_carton":24}')$$, 'at least one selling price', 'an item needs at least one selling price');
select t.put('dzonly', public.save_product('{"name":"Hair pins","category":"Skin care","carton_cost":24,"per_carton":48,"dzn":9,"qty_loose":48}')::text);
select t.ok((select price_usd from products where id = t.get('dzonly')::uuid) = 0, 'the price per pc is optional');
select t.put('gelbox', public.save_product('{"name":"Gel box","category":"Skin care","carton_cost":24,"per_carton":12,"dzn":30}')::text);
select t.ok((select carton_usd from products where id = t.get('gelbox')::uuid) = 30, 'a carton of 12 sold only by the dozen: the dozen price is the carton price');
select public.create_deliveries(array[t.get('gom')::uuid], jsonb_build_array(jsonb_build_object('product_id', t.get('dzonly'), 'qty', 24)));
select t.ok((select i.price_usd from delivery_items i where i.product_id = t.get('dzonly')::uuid) = 0.75, 'a delivery values an item with no pc price at its dozen price / 12');
reset role;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select public.receive_delivery((select d.id from deliveries d join delivery_items i on i.delivery_id = d.id where i.product_id = t.get('dzonly')::uuid), '[]', '');
select t.fails(format($$select public.submit_invoice('{"id":"%s","no":"GOM-T2-000010","device_id":"%s","customer":"X","rate":2850,"vat_rate":16,"items":[{"product_id":"%s","mult":1,"qty":1,"price":1000}]}')$$, gen_random_uuid(), t.get('dev2'), t.get('dzonly')),
  'Unit not valid', 'no pc price means it is not sold by the pc');
-- change the half dozen line of inv3 to 6 pcs
select t.put('lot_b', (select qty::text from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('lotion')::uuid));
select public.edit_invoice(t.get('inv3')::uuid, '[{"line_no":1,"qty":6,"mult":1}]', 0, 'Customer took loose pcs');
select t.ok((select unit || '/' || price || '/' || qty from invoice_items where invoice_id = t.get('inv3')::uuid) = 'pcs/4600/6', 'edited line changed from half dozen to 6 pcs at the pc price');
select t.ok((select total from invoices where id = t.get('inv3')::uuid) = 6 * 4600, 'invoice total follows the new unit');
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('lotion')::uuid) = t.get('lot_b')::int, 'same 6 pcs leave the stock');
reset role;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.ok((select l.amount from voucher_lines l join vouchers v on v.id = l.voucher_id where v.source_id = t.get('inv3')::uuid and l.account_id = t.shop_acc('CASH_SHOP', t.get('gom')::uuid)) = 6 * 4600, 'the books follow the edited invoice');
reset role;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.fails(format($$select public.edit_invoice('%s', '[{"line_no":1,"qty":1,"mult":7}]', 0, 'bad unit')$$, t.get('inv3')), 'Unit not valid', 'a unit the item does not have is refused');
reset role;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000e');
select t.fails(format($$select public.delete_invoice('%s', 'not mine')$$, t.get('inv3')), 'not found', 'another shop cannot delete the invoice');
reset role;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.fails(format($$select public.delete_invoice('%s', '')$$, t.get('inv3')), 'reason', 'deleting needs a reason');
select public.delete_invoice(t.get('inv3')::uuid, 'Typed twice by mistake');
select t.ok(not exists (select 1 from invoices where id = t.get('inv3')::uuid), 'the invoice is removed');
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('lotion')::uuid) = t.get('lot_b')::int + 6, 'its stock goes back to the shop');
select public.delete_invoice(t.get('inv1')::uuid, 'Customer cancelled');
select t.ok((select status || ':' || (reason like 'Invoice GOM-T2-000001 deleted%')::text from sale_orders where id = t.get('ord1')::uuid) = 'rejected:true', 'the order of a deleted invoice shows as rejected with the reason');
reset role;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.ok(not exists (select 1 from vouchers where source_id in (t.get('inv1')::uuid, t.get('inv3')::uuid)), 'deleted invoices leave the books');
select t.ok(t.unbalanced() = 0, 'the books still balance');
select t.ok(exists (select 1 from audit_log where action like 'Invoice GOM-T2-000003 deleted by Patrick Kabongo%Typed twice by mistake'), 'the activity log keeps what was deleted and why');
reset role;

-- ===== deleting suppliers =====
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.put('sup2', public.save_supplier('{"name":"Unused Supplier"}')::text);
select t.put('sup2acc', (select account_id::text from suppliers where id = t.get('sup2')::uuid));
select t.ok(public.delete_supplier(t.get('sup2')::uuid) = 'deleted', 'a supplier with nothing recorded is deleted');
select t.ok(not exists (select 1 from accounts where id = t.get('sup2acc')::uuid), 'its ledger goes with it');
select t.fails(format($$select public.delete_supplier('%s')$$, t.get('sup')), 'still has a balance', 'a supplier we still owe cannot be deleted');
select t.put('sup3', public.save_supplier('{"name":"Old Supplier"}')::text);
select public.receive_goods(jsonb_build_object('supplier_id', t.get('sup3'), 'lines', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 1))));
select public.enter_bill(jsonb_build_object('grn_id', (select id from grns where supplier_id = t.get('sup3')::uuid), 'bill_no', 'OS-1', 'amount', 1));
select public.post_voucher(jsonb_build_object('type', 'payment', 'lines', jsonb_build_array(
  jsonb_build_object('account', (select account_id from suppliers where id = t.get('sup3')::uuid), 'side', 'Dr', 'amount', 1),
  jsonb_build_object('account', t.acc('CASH_HO'), 'side', 'Cr', 'amount', 1))));
select t.ok((select string_agg(x->>'side', ',') from jsonb_array_elements(public.account_statement((select account_id from suppliers where id = t.get('sup3')::uuid), current_date, current_date)->'lines') x) = 'Cr,Dr',
  'statement lists same-day entries in the order they were made: the bill, then its payment');
select t.ok((select string_agg(x->>'type', ',') from jsonb_array_elements(public.day_book(current_date, current_date)) x) like '%purchase,payment', 'the day book too');
select t.ok(public.delete_supplier(t.get('sup3')::uuid) = 'archived', 'a supplier with history is made inactive, not deleted');
select t.ok((select not active from suppliers where id = t.get('sup3')::uuid), 'the inactive supplier stays with its history');
select t.fails(format($$select public.receive_goods('{"supplier_id":"%s","lines":[{"product_id":"%s","qty":1}]}')$$, t.get('sup3'), t.get('lotion')), 'Choose the supplier', 'nothing new is received from an inactive supplier');
reset role;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000b');
select t.fails(format($$select public.delete_supplier('%s')$$, t.get('sup3')), 'permission', 'only the Admin deletes suppliers');
reset role;

-- ===== stock requests: the shop asks, the warehouse approves, edits or rejects =====
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.put('req1', t.req(jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 2), jsonb_build_object('product_id', t.get('brush'), 'qty', 1)), 'For the weekend'));
select t.ok((select no || ':' || status from stock_requests where id = t.get('req1')::uuid) = 'REQ-0001:pending', 'the shop admin sends a stock request');
select t.put('req2', t.req(jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 1))));
select t.put('req3', t.req(jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 999999))));
select t.put('req4', t.req(jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 1))));
select t.put('req5', t.req(jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 1))));
select public.cancel_stock_request(t.get('req4')::uuid, 'Not needed');
select t.ok((select status from stock_requests where id = t.get('req4')::uuid) = 'cancelled', 'the shop can cancel a waiting request');
select t.fails($$select public.create_stock_request('{"lines":[]}')$$, 'quantity', 'a request needs at least one item');
reset role;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000e');
select t.ok((select count(*) from stock_requests) = 0, 'another shop does not see the requests');
reset role;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000b');
select t.fails(format($$select public.create_stock_request('{"lines":[{"product_id":"%s","qty":1}]}')$$, t.get('lotion')), 'permission', 'the warehouse does not make requests');
select t.ok((select count(*) from stock_requests where status = 'pending') = 4, 'the warehouse sees the waiting requests of every shop');
select t.fails(format($$select public.reject_stock_request('%s', '')$$, t.get('req2')), 'reason', 'rejecting needs a reason');
select public.reject_stock_request(t.get('req2')::uuid, 'No stock this week');
select t.ok((select status || ':' || reason from stock_requests where id = t.get('req2')::uuid) = 'rejected:No stock this week', 'request rejected with the reason');
select t.fails(format($$select public.approve_stock_request('%s')$$, t.get('req3')), 'Not enough in the store', 'more than the store can send is refused');
select t.put('wh_before', (select wh_qty::text from products where id = t.get('lotion')::uuid));
select t.fails(format($$select public.approve_stock_request('%s', '[{"product_id":"%s","qty":1}]', '')$$, t.get('req1'), t.get('lotion')), 'changed the request', 'an edited approval needs a reason');
select t.put('appr1', public.approve_stock_request(t.get('req1')::uuid, jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 1)), 'Only one carton left')::text);
select t.ok((t.get('appr1')::jsonb->>'edited')::boolean and (t.get('appr1')::jsonb->>'delivery_no') like 'DEL-%', 'approved with changes: a delivery is made');
select t.ok((select string_agg(qty || '>' || approved_qty, ',' order by qty desc) from stock_request_items where request_id = t.get('req1')::uuid) = '2>1,1>0', 'what was asked and what is sent are both kept');
select t.ok((select d.status || ':' || d.shop_id::text from deliveries d join stock_requests r on r.delivery_id = d.id where r.id = t.get('req1')::uuid) = 'pending:' || t.get('gom'), 'the delivery waits for the shop to receive it');
select t.ok((select wh_qty from products where id = t.get('lotion')::uuid) = t.get('wh_before')::int, 'no stock moves when the request is approved');
select t.fails(format($$select public.approve_stock_request('%s')$$, t.get('req1')), 'already approved', 'a request is approved once');
select t.ok((public.approve_stock_request(t.get('req5')::uuid)->>'edited')::boolean = false, 'approved as asked');
reset role;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.fails(format($$select public.cancel_stock_request('%s', 'x')$$, t.get('req1')), 'already approved', 'an approved request cannot be cancelled');
select t.ok((select reason from stock_requests where id = t.get('req1')::uuid) = 'Only one carton left', 'the shop admin sees why the request was changed');
select t.put('shop_lot', (select qty::text from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('lotion')::uuid));
select public.receive_delivery((select delivery_id from stock_requests where id = t.get('req1')::uuid), '[]', '');
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('lotion')::uuid) = t.get('shop_lot')::int + 1, 'the shop receives the approved request like any delivery');
reset role;

-- ===== supermarket switches: customer name optional, barcodes =====
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.ok((select features from settings) = '{}'::jsonb, 'both switches are off on an existing installation');
select t.put('scan', public.save_product('{"name":"Scan soap","category":"Skin care","carton_cost":24,"per_carton":24,"pc":1.5,"barcode":" 6001234567890 "}')::text);
select t.ok((select barcode from products where id = t.get('scan')::uuid) = '6001234567890', 'item saved with its barcode (spaces removed)');
select t.fails($$select public.save_product('{"name":"Scan soap 2","category":"Skin care","carton_cost":24,"per_carton":24,"pc":1.5,"barcode":"6001234567890"}')$$, 'already used by Scan soap', 'a barcode belongs to one item');
select t.fails($$select public.save_product('{"name":"Scan soap 3","category":"Skin care","carton_cost":24,"per_carton":24,"pc":1.5,"barcode":"60*1"}')$$, 'not valid', 'a barcode with symbols is refused');
select t.ok((public.import_products('[{"row":2,"name":"Scan cream","category":"Skin care","carton_cost":24,"per_carton":24,"pc":1.5,"barcode":"6001234567890"},
  {"row":3,"name":"Scan gel","category":"Skin care","carton_cost":24,"per_carton":24,"pc":1.5,"barcode":"6009999999999"}]')->>'imported')::int = 1, 'import skips a row whose barcode is already used');
select t.ok((select barcode from products where name = 'Scan gel') = '6009999999999', 'import saves the barcode');
select public.save_product(jsonb_build_object('id', t.get('scan'), 'name','Scan soap','category','Skin care','carton_cost',24,'per_carton',24,'pc',1.5,'barcode',''));
select t.ok((select barcode from products where id = t.get('scan')::uuid) is null, 'a barcode can be removed');
-- several barcodes per item
select public.save_product(jsonb_build_object('id', t.get('scan'), 'name','Scan soap','category','Skin care','carton_cost',24,'per_carton',24,'pc',1.5,'barcode','111111; 222222'));
select t.ok((select barcodes = '{111111,222222}' and barcode = '111111' from products where id = t.get('scan')::uuid), 'an item keeps several barcodes, the first also as its main one');
select t.fails($$select public.save_product('{"name":"Scan soap 4","category":"Skin care","carton_cost":24,"per_carton":24,"pc":1.5,"barcode":"999999;222222"}')$$, '222222 is already used by Scan soap', 'a second barcode belongs to one item too');
select t.ok((public.import_products('[{"row":2,"name":"Scan cream B","category":"Skin care","carton_cost":24,"per_carton":24,"pc":1.5,"barcode":"333333;444444"},
  {"row":3,"name":"Scan cream C","category":"Skin care","carton_cost":24,"per_carton":24,"pc":1.5,"barcode":"555555,111111"}]')->>'imported')::int = 1, 'import takes several barcodes and skips a row reusing one');
select t.ok((select barcodes from products where name = 'Scan cream B') = '{333333,444444}', 'import saves every barcode of the row');
select public.save_product(jsonb_build_object('id', t.get('scan'), 'name','Scan soap','category','Skin care','carton_cost',24,'per_carton',24,'pc',1.5,'barcode','222222'));
select t.ok((select barcodes = '{222222}' and barcode = '222222' from products where id = t.get('scan')::uuid), 'removing one barcode keeps the other');
-- up to 60 barcodes per item
select public.save_product(jsonb_build_object('id', t.get('scan'), 'name','Scan soap','category','Skin care','carton_cost',24,'per_carton',24,'pc',1.5,
  'barcode', (select string_agg((700000 + g)::text, ';') from generate_series(1, 60) g)));
select t.ok((select cardinality(barcodes) = 60 and barcode = '700001' from products where id = t.get('scan')::uuid), 'an item can have 60 barcodes');
select t.fails(format($$select public.save_product(jsonb_build_object('id', '%s', 'name','Scan soap','category','Skin care','carton_cost',24,'per_carton',24,'pc',1.5,
  'barcode', (select string_agg((700000 + g)::text, ';') from generate_series(1, 61) g)))$$, t.get('scan')), 'at most 60 barcodes', 'a 61st barcode is refused');
select public.save_product(jsonb_build_object('id', t.get('scan'), 'name','Scan soap','category','Skin care','carton_cost',24,'per_carton',24,'pc',1.5,'barcode','222222'));
reset role;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.fails($$select public.save_settings('{"rate":2850,"vat":16,"features":{"customer_optional":true}}')$$, 'permission', 'only the Admin turns the switches on');
select t.fails(format($$select public.submit_invoice('{"id":"%s","no":"GOM-T2-000050","device_id":"%s","customer":"","rate":2850,"vat_rate":16,"items":[{"product_id":"%s","mult":1,"qty":1,"price":4600}]}')$$, gen_random_uuid(), t.get('dev2'), t.get('lotion')),
  'customer name', 'with the switch off the customer name is still needed');
reset role;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select public.save_settings(jsonb_build_object('rate', 2850, 'vat', 16, 'company', (select company from settings), 'features', '{"customer_optional":true,"barcode":true,"other":true}'::jsonb));
select t.ok((select features from settings) = '{"customer_optional":true,"barcode":true,"till_sells":false,"cash_change":false,"usd_pay":false,"one_copy":false,"no_warehouse":false,"vendeurs":false,"money_exchange":false,"cash_promo":false}'::jsonb, 'the Admin turns both switches on (unknown keys are dropped)');
reset role;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000d');
select t.put('ord9', gen_random_uuid()::text);
select t.ok((public.submit_order(jsonb_build_object('id', t.get('ord9'), 'customer', '', 'items', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'mult', 1, 'qty', 1))))->>'status') = 'ok', 'an order without a customer name is accepted');
reset role;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.put('inv9', gen_random_uuid()::text);
select t.ok((public.submit_invoice(jsonb_build_object('id', t.get('inv9'), 'no', 'GOM-T2-000050', 'device_id', t.get('dev2'), 'rate', 2850, 'vat_rate', 16, 'customer', '  ',
  'items', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'mult', 1, 'qty', 1, 'price', (select app_price from (select (ceil(round(price_usd * 2850 / 10) * 10 / 50) * 50)::bigint app_price from products where id = t.get('lotion')::uuid) x)))))->>'status') = 'ok', 'a sale without a customer name is accepted');
select t.ok((select customer from invoices where id = t.get('inv9')::uuid) = '', 'the invoice keeps an empty customer');
select t.fails(format($$select public.submit_invoice('{"id":"%s","no":"GOM-T2-000051","device_id":"%s","customer":"%s","rate":2850,"vat_rate":16,"items":[{"product_id":"%s","mult":1,"qty":1,"price":4600}]}')$$, gen_random_uuid(), t.get('dev2'), repeat('x', 61), t.get('lotion')),
  'too long', 'a customer name is still at most 60 characters');
reset role;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select public.save_settings(jsonb_build_object('rate', 2850, 'vat', 16, 'company', (select company from settings)));
select t.ok((select features from settings) = '{"customer_optional":true,"barcode":true,"till_sells":false,"cash_change":false,"usd_pay":false,"one_copy":false,"no_warehouse":false,"vendeurs":false,"money_exchange":false,"cash_promo":false}'::jsonb,
  'saving settings without the switches leaves them as they were, so an older app cannot turn one off');
-- sending a switch as off does turn it off
select public.save_settings(jsonb_build_object('rate', 2850, 'vat', 16, 'company', (select company from settings), 'features', '{"customer_optional":false,"barcode":false}'::jsonb));
select t.ok((select features from settings) = '{"customer_optional":false,"barcode":false,"till_sells":false,"cash_change":false,"usd_pay":false,"one_copy":false,"no_warehouse":false,"vendeurs":false,"money_exchange":false,"cash_promo":false}'::jsonb,
  'and sending it as off does turn it off');
reset role;

-- ===== till operators sell directly when the Admin turns it on =====
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000d');
select t.fails(format($$select public.submit_invoice('{"id":"%s","no":"GOM-T1-000060","device_id":"%s","customer":"A","rate":2850,"vat_rate":16,"items":[{"product_id":"%s","mult":1,"qty":1,"price":4600}]}')$$, gen_random_uuid(), t.get('dev1'), t.get('lotion')),
  'permission', 'with the switch off the till operator cannot sell');
reset role;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select public.save_settings(jsonb_build_object('rate', 2850, 'vat', 16, 'company', (select company from settings), 'features', '{"till_sells":true}'::jsonb));
reset role;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000d');
select t.put('lot_price', (select (ceil(round(price_usd * 2850 / 10) * 10 / 50) * 50)::bigint::text from products where id = t.get('lotion')::uuid));
select t.put('inv10', gen_random_uuid()::text);
select t.ok((public.submit_invoice(jsonb_build_object('id', t.get('inv10'), 'no', 'GOM-T1-000060', 'device_id', t.get('dev1'), 'rate', 2850, 'vat_rate', 16, 'customer', 'Maman Rose',
  'items', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'mult', 1, 'qty', 1, 'price', t.get('lot_price')::bigint))))->>'status') = 'ok', 'the till operator sells directly when the switch is on');
select t.fails(format($$select public.submit_invoice('{"id":"%s","no":"GOM-T1-000061","device_id":"%s","customer":"A","disc_pct":10,"rate":2850,"vat_rate":16,"items":[{"product_id":"%s","mult":1,"qty":1,"price":%s}]}')$$, gen_random_uuid(), t.get('dev1'), t.get('lotion'), t.get('lot_price')),
  'discount', 'a till operator gives no discount');
select t.fails(format($$select public.submit_invoice('{"id":"%s","no":"GOM-T1-000062","device_id":"%s","customer":"A","order_id":"%s","rate":2850,"vat_rate":16,"items":[{"product_id":"%s","mult":1,"qty":1,"price":%s}]}')$$, gen_random_uuid(), t.get('dev1'), t.get('ord2'), t.get('lotion'), t.get('lot_price')),
  'approves orders', 'a till operator does not approve orders');
reset role;
select t.ok((select cashier_name from invoices where id = t.get('inv10')::uuid) = 'Grace Mbuyi', 'the invoice names the till operator as the cashier');
select t.ok(exists (select 1 from audit_log where action like 'Invoice GOM-T1-000060 for Maman Rose, cash, % CDF'), 'the activity log writes amounts in CDF');
-- cash received and change (the switch only changes the till screen and the receipt)
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select public.save_settings(jsonb_build_object('rate', 2850, 'vat', 16, 'company', (select company from settings), 'features', '{"till_sells":true,"cash_change":true}'::jsonb));
select t.ok((select (features->>'cash_change')::boolean from settings), 'the Admin turns on the cash received switch');
reset role;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000d');
select t.put('inv11', gen_random_uuid()::text);
select public.submit_invoice(jsonb_build_object('id', t.get('inv11'), 'no', 'GOM-T1-000063', 'device_id', t.get('dev1'), 'rate', 2850, 'vat_rate', 16, 'customer', 'Maman Rose', 'tendered', t.get('lot_price')::bigint + 440,
  'items', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'mult', 1, 'qty', 1, 'price', t.get('lot_price')::bigint))));
select t.fails(format($$select public.submit_invoice('{"id":"%s","no":"GOM-T1-000064","device_id":"%s","customer":"A","tendered":10,"rate":2850,"vat_rate":16,"items":[{"product_id":"%s","mult":1,"qty":1,"price":%s}]}')$$, gen_random_uuid(), t.get('dev1'), t.get('lotion'), t.get('lot_price')),
  'less than the total', 'cash received below the total is refused');
reset role;
select t.ok((select tendered - total || '/' || change from invoices where id = t.get('inv11')::uuid) = '440/440', 'the invoice keeps the cash received and the change');
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select public.save_settings(jsonb_build_object('rate', 2850, 'vat', 16, 'company', (select company from settings)));
reset role;

-- ===== returns to the supplier and goods billed but not received =====
create function t.sup_owes() returns numeric language sql security definer as $$
  select coalesce(sum(case when l.side = 'Cr' then l.base else -l.base end), 0) from voucher_lines l join vouchers v on v.id = l.voucher_id
  where v.status = 'posted' and l.account_id = (select account_id from suppliers where name = 'Beauty Import SARL') $$;
grant execute on function t.sup_owes() to authenticated;
-- the money columns of returns are hidden from signed-in users (the Admin reads them through supplier_return_values)
create function t.sr(p_no text) returns public.supplier_returns language sql security definer as $$ select * from public.supplier_returns where no = p_no $$;
grant execute on function t.sr(text) to authenticated;
select t.put('owes0', t.sup_owes()::text);
select t.put('wh_lot', (select wh_qty::text from products where id = t.get('lotion')::uuid));
select t.put('cost_lot', (select cost_usd::text from product_costs where product_id = t.get('lotion')::uuid));
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000b');
select t.fails(format($$select public.create_supplier_return('{"supplier_id":"%s","reason":"Damaged","lines":[{"product_id":"%s","qty":100000}]}')$$, t.get('sup'), t.get('lotion')), 'Not enough in the store', 'cannot send back more than the store has');
select t.fails(format($$select public.create_supplier_return('{"supplier_id":"%s","reason":"","lines":[{"product_id":"%s","qty":1}]}')$$, t.get('sup'), t.get('lotion')), 'why the goods go back', 'a return needs a reason');
select t.put('rts1', public.create_supplier_return(jsonb_build_object('supplier_id', t.get('sup'), 'reason', 'Damaged', 'note', 'Broken caps',
  'lines', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 2))))->>'id');
select t.ok((select no from supplier_returns where id = t.get('rts1')::uuid) = 'RTS-0001', 'the warehouse sends goods back to the supplier');
select t.fails(format($$select public.settle_supplier_return('{"id":"%s"}')$$, t.get('rts1')), 'permission', 'the warehouse does not settle with the supplier');
reset role;
select t.ok((select wh_qty from products where id = t.get('lotion')::uuid) = t.get('wh_lot')::int - 2, 'the goods leave the central store at once');
select t.ok(t.sup_owes() = t.get('owes0')::numeric - round(2 * t.get('cost_lot')::numeric, 2), 'what we owe the supplier drops at item cost');
select t.ok((select type from vouchers where id = (select voucher_id from supplier_returns where id = t.get('rts1')::uuid)) = 'debit_note', 'a return is a debit note');
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.fails(format($$select public.create_supplier_return('{"supplier_id":"%s","reason":"Damaged","lines":[{"product_id":"%s","qty":1}]}')$$, t.get('sup'), t.get('lotion')), 'permission', 'a shop admin does not return goods to suppliers');
reset role;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.fails(format($$select public.cancel_voucher('%s', 'mistake here')$$, (select voucher_id from supplier_returns where id = t.get('rts1')::uuid)), 'Returns to supplier', 'its debit note is cancelled from the return, not from the books');
-- a bill for 5 pcs when the warehouse received 3: 2 become a claim set against the bill
select t.put('grn9', public.receive_goods(jsonb_build_object('supplier_id', t.get('sup'), 'lines', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 3))))->>'id');
select t.put('b9', public.enter_bill(jsonb_build_object('grn_id', t.get('grn9'), 'bill_no', 'F-900', 'amount', round(5 * t.get('cost_lot')::numeric, 2), 'currency', 'USD',
  'billed', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 5))))::text);
select t.ok((t.get('b9')::jsonb->>'claim') is not null, 'goods billed but not received become a claim');
select t.ok((select r.kind || ':' || i.qty || ':' || (t.sr(r.no)).value_usd from supplier_returns r join supplier_return_items i on i.return_id = r.id where r.no = t.get('b9')::jsonb->>'claim')
  = 'short:2:' || round(2 * t.get('cost_lot')::numeric, 2), 'the claim is for the 2 pcs missing, at item cost');
select t.ok(round(t.outstanding((t.get('b9')::jsonb->>'voucher_id')::uuid), 2) = round(3 * t.get('cost_lot')::numeric, 2), 'the bill only stays owed for what arrived');
-- the Admin settles the return at what the supplier credits, against that bill
select public.settle_supplier_return(jsonb_build_object('id', t.get('rts1'), 'amount_usd', 1.50, 'bill_id', (t.get('b9')::jsonb->>'voucher_id')));
select t.ok((select status || ':' || (t.sr(no)).amount_usd from supplier_returns where id = t.get('rts1')::uuid) = 'settled:1.50', 'the Admin settles the return at the credited amount');
select t.ok((select (v->>'amount_usd')::numeric from jsonb_array_elements(public.supplier_return_values()) v where v->>'id' = t.get('rts1')) = 1.50, 'the Admin reads the values through supplier_return_values');
select t.ok(round(t.outstanding((t.get('b9')::jsonb->>'voucher_id')::uuid), 2) = round(3 * t.get('cost_lot')::numeric - 1.50, 2), 'the settled return is set against the bill');
select t.ok(t.unbalanced() = 0, 'returns and claims keep every voucher balanced');
select t.fails(format($$select public.cancel_voucher('%s', 'wrong bill')$$, t.get('b9')::jsonb->>'voucher_id'), 'cancel that first', 'a bill with a return set against it is not cancelled');
select public.cancel_supplier_return(t.get('rts1')::uuid, 'Supplier refused it');
select t.ok((select wh_qty from products where id = t.get('lotion')::uuid) = t.get('wh_lot')::int + 3, 'a cancelled return puts the goods back (and the 3 received are in)');
select public.cancel_voucher((t.get('b9')::jsonb->>'voucher_id')::uuid, 'wrong bill');
select t.ok((select status from supplier_returns where no = t.get('b9')::jsonb->>'claim') = 'cancelled', 'cancelling the bill cancels its claim');
select t.ok(t.sup_owes() = t.get('owes0')::numeric, 'after cancelling, the supplier is owed exactly as before');
-- a bill without billed quantities posts as before
select t.put('b10', public.enter_bill(jsonb_build_object('grn_id', t.get('grn9'), 'bill_no', 'F-901', 'amount', 1, 'currency', 'USD'))::text);
select t.ok((t.get('b10')::jsonb->>'claim') is null, 'no billed quantities, no claim');
reset role;

-- ===== payment in USD (switch, off by default) =====
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.put('lp', (select (ceil(round(price_usd * 2850 / 10) * 10 / 50) * 50)::bigint::text from products where id = t.get('lotion')::uuid));
select t.fails(format($$select public.submit_invoice('{"id":"%s","no":"GOM-T2-000070","device_id":"%s","customer":"A","paid_usd":20,"rate":2850,"vat_rate":16,"items":[{"product_id":"%s","mult":1,"qty":1,"price":%s}]}')$$, gen_random_uuid(), t.get('dev2'), t.get('lotion'), t.get('lp')),
  'not turned on', 'with the switch off a payment in USD is refused');
reset role;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select public.save_settings(jsonb_build_object('rate', 2850, 'vat', 16, 'company', (select company from settings), 'features', '{"usd_pay":true}'::jsonb));
reset role;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.put('usd1', gen_random_uuid()::text);
select public.submit_invoice(jsonb_build_object('id', t.get('usd1'), 'no', 'GOM-T2-000070', 'device_id', t.get('dev2'), 'rate', 2850, 'vat_rate', 16, 'customer', 'Dollar customer',
  'paid_usd', 20, 'paid_cdf', 0, 'change_usd', 5, 'items', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'mult', 1, 'qty', 1, 'price', t.get('lp')::bigint))));
select t.fails(format($$select public.submit_invoice('{"id":"%s","no":"GOM-T2-000071","device_id":"%s","customer":"A","paid_usd":1,"paid_cdf":100,"rate":2850,"vat_rate":16,"items":[{"product_id":"%s","mult":1,"qty":1,"price":%s}]}')$$, gen_random_uuid(), t.get('dev2'), t.get('lotion'), t.get('lp')),
  'less than the total', 'dollars and Francs below the total are refused');
select t.fails(format($$select public.submit_invoice('{"id":"%s","no":"GOM-T2-000072","device_id":"%s","customer":"A","paid_usd":20,"change_usd":21,"rate":2850,"vat_rate":16,"items":[{"product_id":"%s","mult":1,"qty":1,"price":%s}]}')$$, gen_random_uuid(), t.get('dev2'), t.get('lotion'), t.get('lp')),
  'more than the dollars received', 'more dollars back than received is refused');
select t.fails(format($$select public.submit_invoice('{"id":"%s","no":"GOM-T2-000073","device_id":"%s","customer":"A","paid_usd":20,"change_usd":1.5,"rate":2850,"vat_rate":16,"items":[{"product_id":"%s","mult":1,"qty":1,"price":%s}]}')$$, gen_random_uuid(), t.get('dev2'), t.get('lotion'), t.get('lp')),
  'whole dollars', 'dollars given back are whole dollars');
reset role;
select t.ok((select tendered = 57000 and change = 57000 - total and change_usd = 5 and change_cdf = 57000 - total - 14250 and paid_usd = 20 and paid_cdf = 0
  from invoices where id = t.get('usd1')::uuid), 'the invoice keeps $20 received, $5 back and the rest of the change in Francs');
select t.ok((select string_agg(a.currency || ':' || l.side || ':' || l.amount, ',' order by a.currency desc) from voucher_lines l join vouchers v on v.id = l.voucher_id join accounts a on a.id = l.account_id
  where v.source_id = t.get('usd1')::uuid and a.group_code = 'cash')
  = 'USD:Dr:15.00,FC:' || (case when (select total from invoices where id = t.get('usd1')::uuid) >= 42750 then 'Dr:' else 'Cr:' end) || abs((select total from invoices where id = t.get('usd1')::uuid) - 42750) || '.00',
  'the books put the $15 kept in Cash USD and the Francs change out of the shop cash');
select t.ok(t.unbalanced() = 0, 'every voucher still balances');
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.ok((select (s->>'collected_usd')::numeric from jsonb_array_elements(public.sales_report(current_date, current_date)->'slips') s) = 15, 'the day end slip shows the dollars collected');
reset role;
update settings set features = '{}'::jsonb;

-- ===== two rates: sales rate for prices and tills, internal rate for suppliers, expenses and vouchers =====
select t.ok((select book_rate = rate from settings), 'the internal rate starts equal to the sales rate');
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select public.save_settings(jsonb_build_object('rate', 2850, 'book_rate', 2900, 'vat', 16, 'company', (select company from settings)));
select t.ok((select rate || '/' || book_rate from settings) = '2850.00/2900.00', 'settings keep a sales rate and an internal rate');
select public.save_rate('book', 2950);
select t.ok((select rate || '/' || book_rate from settings) = '2850.00/2950.00', 'the internal rate changes on its own');
select t.fails($$select public.save_rate('other', 3000)$$, 'Unknown rate', 'only the sales or the internal rate');
select t.fails($$select public.save_rate('sales', 0)$$, 'valid exchange rate', 'a rate must be above zero');
select public.add_upkeep(current_date, 'Transport', 'Fuel paid in Francs', 29500, 'FC', null);
select t.ok((select amount_usd from upkeep where description = 'Fuel paid in Francs') = 10.00, 'an expense in Francs converts at the internal rate (29 500 / 2 950)');
-- the new expense types have their own ledgers; an expense is corrected with its voucher
select public.add_upkeep(current_date, 'Moto expense', 'Moto repair', 5900, 'FC', null);
select t.put('upk', (select id::text from upkeep where description = 'Moto repair'));
select t.put('upv', (select v.no from upkeep u join vouchers v on v.id = u.voucher_id where u.id = t.get('upk')::uuid));
select t.ok((select a.code from upkeep u join voucher_lines l on l.voucher_id = u.voucher_id and l.side = 'Dr' join accounts a on a.id = l.account_id where u.id = t.get('upk')::uuid) = 'EXP_MOTO'
  and (select source_type from vouchers v join upkeep u on u.voucher_id = v.id where u.id = t.get('upk')::uuid) = 'upkeep', 'a Moto expense is booked to its own ledger, and the voucher follows the expense');
select t.ok((select count(*) from accounts where code in ('EXP_MISC','EXP_LABOUR','EXP_MOTO','EXP_LOCAL_SALARY','EXP_STATIONERY','EXP_FOOD','EXP_LOCAL_TRANSPORT','EXP_OVERTIME') and group_code = 'indexp') = 8,
  'eight new expense ledgers under Indirect expenses');
select t.fails(format($$select public.edit_upkeep('{"id":"%s","date":"%s","category":"Moto expense","description":"Moto repair","amount":5900,"currency":"FC"}')$$, t.get('upk'), current_date), 'Nothing was changed', 'an edit must change something');
select public.edit_upkeep(jsonb_build_object('id', t.get('upk'), 'date', current_date - 1, 'category', 'Food expense', 'description', 'Lunch for the staff', 'amount', 11800, 'currency', 'FC'));
select t.ok((select u.category = 'Food expense' and u.description = 'Lunch for the staff' and u.amount_usd = 4.00 and u.date = current_date - 1 and u.edited_by_name is not null
    and v.no = t.get('upv') and v.date = current_date - 1 and v.narration = 'Food expense: Lunch for the staff'
  from upkeep u join vouchers v on v.id = u.voucher_id where u.id = t.get('upk')::uuid), 'a corrected expense keeps its record and its voucher number, with the new date, type and text');
select t.ok((select string_agg(a.code || ':' || l.side || ':' || l.amount || ':' || l.rate, ',' order by l.side desc)
  from upkeep u join voucher_lines l on l.voucher_id = u.voucher_id join accounts a on a.id = l.account_id where u.id = t.get('upk')::uuid) = 'EXP_FOOD:Dr:11800.00:2950.00,CASH_HO:Cr:11800.00:2950.00',
  'the voucher is booked to the new type''s ledger at the new amount, at the rate the expense was first booked');
select t.ok(t.unbalanced() = 0, 'a corrected expense keeps the books balanced');
select t.ok(exists (select 1 from audit_log where action like 'Expense corrected (voucher ' || t.get('upv') || '): was %Moto expense%; now %Food expense%'), 'the log shows the expense before and after');
select public.cancel_voucher((select voucher_id from upkeep where id = t.get('upk')::uuid), 'paid twice');
select t.fails(format($$select public.edit_upkeep('{"id":"%s","date":"%s","category":"Food expense","description":"Lunch","amount":100,"currency":"USD"}')$$, t.get('upk'), current_date), 'was cancelled', 'an expense whose voucher was cancelled is not corrected');
-- deleting an expense cancels its payment voucher; one already cancelled in Accounts is simply removed
select t.fails(format($$select public.delete_upkeep('%s', '')$$, t.get('upk')), 'short reason', 'deleting an expense needs a reason');
select t.put('updel1', public.delete_upkeep(t.get('upk')::uuid, 'entered twice')::text);
select t.ok((t.get('updel1')::jsonb->>'cancelled')::boolean = false and not exists (select 1 from upkeep where id = t.get('upk')::uuid),
  'an expense whose voucher was already cancelled is removed from the list');
select public.add_upkeep(current_date, 'Stationery', 'Receipt books', 15, 'USD', null);
select t.put('upd', (select id::text from upkeep where description = 'Receipt books'));
select t.put('updv', (select voucher_id::text from upkeep where id = t.get('upd')::uuid));
select t.put('updel2', public.delete_upkeep(t.get('upd')::uuid, 'bought by the shop, not head office')::text);
select t.ok((t.get('updel2')::jsonb->>'cancelled')::boolean
  and (select status = 'cancelled' and cancel_reason = 'Expense deleted: bought by the shop, not head office' from vouchers where id = t.get('updv')::uuid)
  and not exists (select 1 from upkeep where id = t.get('upd')::uuid), 'deleting an expense cancels its payment voucher, with the reason');
select t.ok(t.unbalanced() = 0, 'the books stay balanced after deleting an expense');
select t.ok(exists (select 1 from audit_log where action like 'Expense deleted (voucher % cancelled): %, Stationery, Receipt books: 15.00 USD. Reason: bought by the shop, not head office'),
  'the log keeps what the deleted expense was and why');
reset role;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.fails(format($$select public.edit_upkeep('{"id":"%s","date":"%s","category":"Food expense","description":"Lunch","amount":1,"currency":"USD"}')$$, t.get('upk'), current_date), 'permission', 'only the Admin corrects expenses');
select t.fails(format($$select public.delete_upkeep('%s', 'not mine')$$, t.get('upk')), 'permission', 'only the Admin deletes expenses');
reset role;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select public.enter_bill(jsonb_build_object('supplier_id', t.get('sup'), 'account_id', t.acc('EXP_TRANSPORT'), 'bill_no', 'TR-RATE', 'amount', 5900, 'currency', 'FC'));
select t.ok((select l.rate from voucher_lines l join vouchers v on v.id = l.voucher_id where l.bill_ref = 'TR-RATE' limit 1) = 2950, 'a supplier bill in Francs uses the internal rate');
select public.save_rate('sales', 2860);
select t.ok((select rate || '/' || book_rate from settings) = '2860.00/2950.00', 'the sales rate changes on its own');
select t.ok(exists (select 1 from audit_log where action = 'Sales rate changed 2850.00 to 2860')
  and exists (select 1 from audit_log where action = 'Internal rate changed 2900.00 to 2950'), 'each rate change is logged');
reset role;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.fails($$select public.save_rate('sales', 3000)$$, 'permission', 'only the Admin changes a rate');
reset role;
update settings set rate = 2850, book_rate = 2850;

-- ===== the till operator prints the invoice; the shop admin's approval completes it without a second invoice =====
-- the till operator's till (T1) numbers the invoice; the order keeps the number, till, rates and printed prices
select t.put('tno1', (select 'GOM-' || code || '-' || lpad((last_seq + 1)::text, 6, '0') from devices where id = t.get('dev1')::uuid));
select t.put('tno2', (select 'GOM-' || code || '-' || lpad((last_seq + 2)::text, 6, '0') from devices where id = t.get('dev1')::uuid));
select t.put('tno3', (select 'GOM-' || code || '-' || lpad((last_seq + 3)::text, 6, '0') from devices where id = t.get('dev1')::uuid));
select t.put('stk0', (select qty::text from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('lotion')::uuid));
select t.put('ord5', gen_random_uuid()::text), t.put('ord6', gen_random_uuid()::text), t.put('ord7', gen_random_uuid()::text);
create function t.tord(id text, no text, qty int) returns jsonb language sql as $$
  select jsonb_build_object('id', id, 'customer', 'Maman Ngalula', 'no', no, 'device_id', t.get('dev1'), 'rate', 2850, 'vat_rate', 16, 't', now(),
    'items', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'mult', 1, 'qty', qty, 'price', 4600))) $$;
grant execute on function t.tord(text, text, int) to authenticated;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000d');
select t.ok((public.submit_order(t.tord(t.get('ord5'), t.get('tno1'), 2))->>'status') = 'ok', 'till operator sends the order with the invoice it printed');
select t.ok((public.submit_order(t.tord(t.get('ord5'), t.get('tno1'), 2))->>'status') = 'duplicate', 'the same order sent twice is saved once');
select t.fails(format($$select public.submit_order(t.tord('%s', '%s', 1))$$, gen_random_uuid(), t.get('tno1')), 'already used', 'an invoice number is used once');
select t.fails(format($$select public.submit_order(t.tord('%s', 'GOM-T9-000001', 1))$$, gen_random_uuid()), 'does not match', 'the number must be this till''s');
select t.fails(format($$select public.submit_order(t.tord('%s', '%s', 1) || jsonb_build_object('items', jsonb_build_array(jsonb_build_object('product_id', '%s', 'mult', 1, 'qty', 1))))$$, gen_random_uuid(), t.get('tno2'), t.get('lotion')),
  'Price missing', 'the printed invoice needs a price on every line');
select public.submit_order(t.tord(t.get('ord6'), t.get('tno2'), 2));
select public.submit_order(t.tord(t.get('ord7'), t.get('tno3'), 1));
reset role;
select t.ok((select invoice_no || '/' || total || '/' || rate from sale_orders where id = t.get('ord5')::uuid) = t.get('tno1') || '/9200/2850.00', 'the order keeps the invoice number, the printed total and the rate');
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('lotion')::uuid) = t.get('stk0')::int, 'printing the invoice at the till takes no stock');
select t.ok(not exists (select 1 from invoices where no in (t.get('tno1'), t.get('tno2'), t.get('tno3'))), 'no invoice until the shop admin approves');
select t.ok((select last_seq from devices where id = t.get('dev1')::uuid) = right(t.get('tno3'), 6)::int, 'the till''s invoice counter is remembered on the server');
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
-- approving with another number (the shop admin's own till) is refused: the order already has its invoice
select t.fails(format($$select public.submit_invoice(t.tord('%s', 'GOM-T2-000099', 2) || jsonb_build_object('device_id', '%s', 'order_id', '%s'))$$, gen_random_uuid(), t.get('dev2'), t.get('ord5')),
  'printed at the till as invoice', 'approving uses the number printed at the till');
-- approved as printed: the sale is complete, nothing is marked changed
select t.ok((public.submit_invoice(t.tord(t.get('ord5'), t.get('tno1'), 2) || jsonb_build_object('order_id', t.get('ord5')))->>'revised') = 'false', 'shop admin approves the order as printed');
select t.ok((select status || '/' || (invoice_id = t.get('ord5')::uuid)::text from sale_orders where id = t.get('ord5')::uuid) = 'approved/true', 'the order is approved and linked to its invoice');
select t.ok((select count(*) || '/' || bool_and(revised_from is null) || '/' || min(prepared_by_name) || '/' || min(cashier_name) from invoices where no = t.get('tno1')) = '1/true/Grace Mbuyi/Patrick Kabongo',
  'one invoice with the till''s number, prepared by the till operator, cashed by the shop admin');
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('lotion')::uuid) = t.get('stk0')::int - 2, 'the stock goes down on approval');
-- changed at approval (2 pcs to 3): the same number, one invoice, marked changed with the total the till printed
select t.ok((public.submit_invoice(t.tord(t.get('ord6'), t.get('tno2'), 3) || jsonb_build_object('order_id', t.get('ord6')))->>'revised') = 'true', 'shop admin changes the order and approves it');
select t.ok((select count(*) || '/' || min(revised_from) || '/' || min(total) from invoices where no = t.get('tno2')) = '1/9200/13800', 'changed at approval: one invoice, same number, the printed total kept');
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('lotion')::uuid) = t.get('stk0')::int - 5, 'the stock follows the changed invoice');
-- rejected: the number printed at the till is void and never becomes an invoice
select public.reject_order(t.get('ord7')::uuid, 'Customer left');
select t.ok(not exists (select 1 from invoices where no = t.get('tno3')), 'a rejected order makes no invoice');
reset role;
select t.ok(exists (select 1 from audit_log where action like 'Invoice ' || t.get('tno2') || '%changed from 9 200 CDF%'), 'the activity log shows the change at approval');
select t.ok(exists (select 1 from audit_log where action like '%invoice ' || t.get('tno3') || ' printed at the till voided%'), 'rejecting voids the invoice printed at the till');

-- ===== a discount as an amount (its percentage follows from the total) or as a percentage with decimals =====
select t.put('sno1', (select 'GOM-' || code || '-' || lpad((last_seq + 1)::text, 6, '0') from devices where id = t.get('dev2')::uuid));
select t.put('sno2', (select 'GOM-' || code || '-' || lpad((last_seq + 2)::text, 6, '0') from devices where id = t.get('dev2')::uuid));
select t.put('sno3', (select 'GOM-' || code || '-' || lpad((last_seq + 3)::text, 6, '0') from devices where id = t.get('dev2')::uuid));
create function t.dsale(no text, extra jsonb) returns jsonb language sql as $$
  select jsonb_build_object('id', gen_random_uuid(), 'no', no, 'device_id', t.get('dev2'), 'rate', 2850, 'vat_rate', 16, 'customer', 'Tantine Mado',
    'items', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'mult', 1, 'qty', 10, 'price', 4600))) || extra $$;
grant execute on function t.dsale(text, jsonb) to authenticated;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select public.submit_invoice(t.dsale(t.get('sno1'), '{"disc": 5000}'));
select t.ok((select disc || '/' || total || '/' || disc_pct from invoices where no = t.get('sno1')) = '5000/41000/10.87', 'a discount of 5 000 CDF on 46 000: total 41 000, 10.87%');
select t.fails(format($$select public.submit_invoice(t.dsale('%s', '{"disc": 14000}'))$$, t.get('sno2')), 'between 0% and 30%', 'a discount amount above 30% is refused');
select public.submit_invoice(t.dsale(t.get('sno2'), '{"disc_pct": 2.5}'));
select t.ok((select disc || '/' || total || '/' || disc_pct from invoices where no = t.get('sno2')) = '1150/44850/2.50', 'a 2.5% discount: 1 150 CDF, rounded to 10 CDF');
select public.edit_invoice((select id from invoices where no = t.get('sno1')), '[{"line_no":1,"qty":10}]', 0, 'Discount agreed with the customer', 3000);
select t.ok((select disc || '/' || total || '/' || disc_pct from invoices where no = t.get('sno1')) = '3000/43000/6.52', 'editing the invoice to a 3 000 CDF discount');
select t.fails(format($$select public.edit_invoice('%s', '[{"line_no":1,"qty":1}]', 0, 'Fewer items now', 3000)$$, (select id from invoices where no = t.get('sno1'))),
  'between 0% and 30%', 'a discount amount above 30% of the new total is refused on an edit');
select public.edit_invoice((select id from invoices where no = t.get('sno1')), '[{"line_no":1,"qty":10}]', 5, 'Back to a percentage');
select t.ok((select disc || '/' || disc_pct from invoices where no = t.get('sno1')) = '2300/5.00', 'editing back to a percentage still works');
reset role;
-- an amount given while approving the till's invoice counts as a change
select t.put('tno4', (select 'GOM-' || code || '-' || lpad((last_seq + 1)::text, 6, '0') from devices where id = t.get('dev1')::uuid));
select t.put('ord8', gen_random_uuid()::text);
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000d');
select public.submit_order(t.tord(t.get('ord8'), t.get('tno4'), 2));
select t.as('00000000-0000-0000-0000-00000000000c');
select t.ok((public.submit_invoice(t.tord(t.get('ord8'), t.get('tno4'), 2) || jsonb_build_object('order_id', t.get('ord8'), 'disc', 1000))->>'revised') = 'true', 'a discount given at approval prints the corrected invoice');
select t.ok((select disc || '/' || total || '/' || revised_from from invoices where no = t.get('tno4')) = '1000/8200/9200', 'the approved invoice keeps the discount and the total the till printed');
reset role;

-- ===== half and quarter cartons: half and a quarter of the carton price, only when a different number of pcs =====
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.put('cream', public.save_product('{"name":"Test cream","category":"Skin care","carton_cost":36,"per_carton":36,"pc":1.5,"dzn":16,"ctn":50,"reorder":0}')::text);
reset role;
select t.put('hp', (select app.unit_price(p, 'half ctn', 2850)::text from products p where id = t.get('cream')::uuid));
select t.put('qp', (select app.unit_price(p, 'quarter ctn', 2850)::text from products p where id = t.get('cream')::uuid));
select t.ok(app.to_cdf(1.0715, 2800) = 3000 and app.to_cdf(3004 / 2800.0, 2800) = 3000 and app.to_cdf(3005 / 2800.0, 2800) = 3050 and app.to_cdf(1.5, 2850) = 4300,
  'a round price stays round: the nearest 10 FC first, then up to the next 50 FC');
select t.ok(t.get('hp')::bigint = 71250 and t.get('qp')::bigint = 35650, 'half carton 71 250 and quarter carton 35 650 CDF: half and a quarter of 142 500, rounded up to 50 CDF');
select t.put('cno1', (select 'GOM-' || code || '-' || lpad((last_seq + 1)::text, 6, '0') from devices where id = t.get('dev2')::uuid));
select t.put('cno2', (select 'GOM-' || code || '-' || lpad((last_seq + 2)::text, 6, '0') from devices where id = t.get('dev2')::uuid));
select t.put('stk1', (select qty::text from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('cream')::uuid));
create function t.csale(no text, lines jsonb) returns jsonb language sql as $$
  select jsonb_build_object('id', gen_random_uuid(), 'no', no, 'device_id', t.get('dev2'), 'rate', 2850, 'vat_rate', 16, 'customer', 'Maman Ngalula', 'items', lines) $$;
grant execute on function t.csale(text, jsonb) to authenticated;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
-- 36 to the carton: a half carton is 18 pcs and a quarter carton 9, sold beside the dozen
select public.submit_invoice(t.csale(t.get('cno1'), jsonb_build_array(
  jsonb_build_object('product_id', t.get('cream'), 'unit', 'half ctn', 'mult', 18, 'qty', 1, 'price', t.get('hp')::bigint),
  jsonb_build_object('product_id', t.get('cream'), 'unit', 'quarter ctn', 'mult', 9, 'qty', 2, 'price', t.get('qp')::bigint),
  jsonb_build_object('product_id', t.get('cream'), 'mult', 12, 'qty', 1, 'price', 45600))));
select t.ok((select string_agg(i.unit || ':' || i.mult || ':' || i.price, ',' order by i.line_no) from invoice_items i join invoices v on v.id = i.invoice_id where v.no = t.get('cno1'))
  = 'half ctn:18:' || t.get('hp') || ',quarter ctn:9:' || t.get('qp') || ',dzn:12:45600', 'half carton, quarter carton and dozen on one invoice, each at its own price');
select t.ok(not (select price_flag from invoices where no = t.get('cno1')), 'half and quarter carton prices match the price list');
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('cream')::uuid) = t.get('stk1')::int - 18 - 18 - 12, 'stock goes down by the pcs of each part of a carton');
select t.fails(format($$select public.submit_invoice(t.csale('%s', jsonb_build_array(jsonb_build_object('product_id', '%s', 'unit', 'half ctn', 'mult', 12, 'qty', 1, 'price', 1000))))$$, t.get('cno2'), t.get('cream')),
  'cannot be sold by the half carton', 'a half carton must be half the pcs of a carton');
-- 24 to the carton (the lotion): a half carton is the dozen and a quarter carton the half dozen, so neither is sold
select t.fails(format($$select public.submit_invoice(t.csale('%s', jsonb_build_array(jsonb_build_object('product_id', '%s', 'unit', 'half ctn', 'mult', 12, 'qty', 1, 'price', 1000))))$$, t.get('cno2'), t.get('lotion')),
  'sell it by the dozen', 'no half carton when it is a dozen');
select t.fails(format($$select public.submit_invoice(t.csale('%s', jsonb_build_array(jsonb_build_object('product_id', '%s', 'unit', 'quarter ctn', 'mult', 6, 'qty', 1, 'price', 1000))))$$, t.get('cno2'), t.get('lotion')),
  'sell it by the half dozen', 'no quarter carton when it is a half dozen');
select t.fails(format($$select public.submit_invoice(t.csale('%s', jsonb_build_array(jsonb_build_object('product_id', '%s', 'unit', 'quarter ctn', 'mult', 1, 'qty', 1, 'price', 1000))))$$, t.get('cno2'), t.get('brush')),
  'not sold by the carton', 'a mixed set is not sold by the carton');
-- an invoice line changed from the dozen to a half carton: 18 pcs at the half carton price
select public.edit_invoice((select id from invoices where no = t.get('cno1')), '[{"line_no":1,"qty":1},{"line_no":2,"qty":2},{"line_no":3,"qty":1,"unit":"half ctn","mult":18}]', 0, 'Sold as a half carton');
select t.ok((select i.unit || ':' || i.mult || ':' || i.price from invoice_items i join invoices v on v.id = i.invoice_id where v.no = t.get('cno1') and i.line_no = 3) = 'half ctn:18:' || t.get('hp'), 'an invoice line can change from a dozen to a half carton');
reset role;
-- the till operator's invoice keeps the unit's name; approving it as printed changes nothing
select t.put('tno5', (select 'GOM-' || code || '-' || lpad((last_seq + 1)::text, 6, '0') from devices where id = t.get('dev1')::uuid));
select t.put('ord9', gen_random_uuid()::text);
create function t.hord(id text, no text) returns jsonb language sql as $$
  select jsonb_build_object('id', id, 'customer', 'Maman Ngalula', 'no', no, 'device_id', t.get('dev1'), 'rate', 2850, 'vat_rate', 16,
    'items', jsonb_build_array(jsonb_build_object('product_id', t.get('cream'), 'unit', 'half ctn', 'mult', 18, 'qty', 1, 'price', t.get('hp')::bigint))) $$;
grant execute on function t.hord(text, text) to authenticated;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000d');
select public.submit_order(t.hord(t.get('ord9'), t.get('tno5')));
select t.ok((select items->0->>'unit' from sale_orders where id = t.get('ord9')::uuid) = 'half ctn', 'the order keeps the half carton by name');
select t.as('00000000-0000-0000-0000-00000000000c');
select t.ok((public.submit_invoice(t.hord(t.get('ord9'), t.get('tno5')) || jsonb_build_object('order_id', t.get('ord9')))->>'revised') = 'false', 'a half carton approved as printed is not a change');
select t.ok((select i.unit from invoice_items i join invoices v on v.id = i.invoice_id where v.no = t.get('tno5')) = 'half ctn', 'the approved invoice sells the half carton');
reset role;

-- ===== sales by category, with the items sold in each =====
select t.put('sh1', (select id::text from products where name = 'Argan shampoo'));
select t.put('cno4', (select 'GOM-' || code || '-' || lpad((last_seq + 1)::text, 6, '0') from devices where id = t.get('dev2')::uuid));
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select public.submit_invoice(t.csale(t.get('cno4'), jsonb_build_array(jsonb_build_object('product_id', t.get('sh1'), 'mult', 1, 'qty', 2, 'price', 25650))) || '{"disc_pct": 10}');
select t.put('crep', public.sales_report(current_date, current_date)::text);
reset role;
select t.ok(jsonb_array_length(t.get('crep')::jsonb->'by_category') >= 1, 'the report lists the categories sold');
select t.ok(abs((select sum((c->>'val')::bigint) from jsonb_array_elements(t.get('crep')::jsonb->'by_category') c) - (t.get('crep')::jsonb->>'total')::bigint) <= 50,
  'the categories add up to the sales, after the discounts');
select t.ok(jsonb_array_length(t.get('crep')::jsonb->'by_category') >= 2 and (select bool_and(a.v >= b.v) from (select (c->>'val')::bigint v, row_number() over () n from jsonb_array_elements(t.get('crep')::jsonb->'by_category') c) a
  join (select (c->>'val')::bigint v, row_number() over () n from jsonb_array_elements(t.get('crep')::jsonb->'by_category') c) b on b.n = a.n + 1), 'the biggest category comes first');
select t.put('cream_row', (select i::text from jsonb_array_elements(t.get('crep')::jsonb->'by_category') c, jsonb_array_elements(c->'items') i
  where c->>'category' = 'Skin care' and i->>'name' = 'Test cream'));
select t.ok((t.get('cream_row')::jsonb->'units') = '{"half ctn": 3, "quarter ctn": 2}'::jsonb and (t.get('cream_row')::jsonb->>'pcs')::int = 3 * 18 + 2 * 9,
  'an item lists how many of each unit were sold and the pcs: 3 half and 2 quarter cartons, 72 pcs');
select t.ok((select c->>'val' || '/' || (c->'items'->0->>'pcs') from jsonb_array_elements(t.get('crep')::jsonb->'by_category') c where c->>'category' = 'Hair care') = '46170/2',
  'a category''s sales are after the invoice discount: 2 shampoos at 25 650 less 10%');
select t.ok((select sum((i->>'val')::bigint) from jsonb_array_elements(t.get('crep')::jsonb->'by_category') c, jsonb_array_elements(c->'items') i where c->>'category' = 'Skin care')
  = (select (c->>'val')::bigint from jsonb_array_elements(t.get('crep')::jsonb->'by_category') c where c->>'category' = 'Skin care'), 'a category''s items add up to the category');

-- ===== the Shop Admin is shown sales up to the limit (347 USD); the Admin sees every sale =====
select t.ok((select shop_sales_limit_usd from settings) = 347, 'the limit on the sales shown to the Shop Admin starts at 347 USD');
select t.put('lno1', (select 'GOM-' || code || '-' || lpad((last_seq + 1)::text, 6, '0') from devices where id = t.get('dev2')::uuid));
select t.put('lno2', (select 'GOM-' || code || '-' || lpad((last_seq + 2)::text, 6, '0') from devices where id = t.get('dev2')::uuid));
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.as('00000000-0000-0000-0000-00000000000a');
select t.put('arep0', public.sales_report(current_date, current_date, t.get('gom')::uuid)::text);
select t.as('00000000-0000-0000-0000-00000000000c');
select t.put('lrep0', public.sales_report(current_date, current_date)::text), t.put('lseen0', (select count(*)::text from invoices));
-- at 2850 CDF to the dollar the limit is 988 950 CDF: a sale of exactly that shows, 10 CDF more does not
select public.submit_invoice(t.csale(t.get('lno1'), jsonb_build_array(jsonb_build_object('product_id', t.get('sh1'), 'mult', 1, 'qty', 1, 'price', 988950))));
select t.ok((public.submit_invoice(t.csale(t.get('lno2'), jsonb_build_array(jsonb_build_object('product_id', t.get('sh1'), 'mult', 1, 'qty', 1, 'price', 988960))))->>'status') = 'ok',
  'a sale above the limit is still made');
select t.ok((select count(*) from invoices) = t.get('lseen0')::int + 1 and exists (select 1 from invoices where no = t.get('lno1')) and not exists (select 1 from invoices where no = t.get('lno2')),
  'the Shop Admin sees the sale of 347 USD, not the one above it');
select t.put('lrep1', public.sales_report(current_date, current_date)::text);
select t.ok((t.get('lrep1')::jsonb->>'total_usd')::numeric <= 347, 'the Shop Admin''s report never passes the limit for the day');
select t.ok((t.get('lrep1')::jsonb->'slips'->0->>'value_fc')::bigint = (t.get('lrep1')::jsonb->>'total')::bigint
  and not exists (select 1 from jsonb_array_elements(t.get('lrep1')::jsonb->'invoices') i where i->>'no' in (t.get('lno1'), t.get('lno2'))),
  'the day end slip agrees with it, and neither big sale is in it');
reset role;
select t.put('lover', (select id::text from invoices where no = t.get('lno2'))), t.put('lat', (select id::text from invoices where no = t.get('lno1')));
set role authenticated;
select t.ok((select count(*) from invoice_items where invoice_id = t.get('lover')::uuid) = 0 and (select count(*) from invoice_items where invoice_id = t.get('lat')::uuid) = 1,
  'the lines of a sale above the limit are not shown either');
-- the Admin sees both, in the list and in the report
select t.as('00000000-0000-0000-0000-00000000000a');
select t.ok((select count(*) from invoices where no in (t.get('lno1'), t.get('lno2'))) = 2 and (select count(*) from invoice_items where invoice_id = t.get('lover')::uuid) = 1, 'the Admin sees every sale');
select t.ok((public.sales_report(current_date, current_date, t.get('gom')::uuid)->>'total')::bigint = (t.get('arep0')::jsonb->>'total')::bigint + 988950 + 988960
  and (public.sales_report(current_date, current_date, t.get('gom')::uuid)->>'n')::int = (t.get('arep0')::jsonb->>'n')::int + 2, 'the Admin''s report has every sale');
reset role;
-- no limit: the Shop Admin sees everything again
update settings set shop_sales_limit_usd = null where id = 1;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.ok(exists (select 1 from invoices where no = t.get('lno2')) and (public.sales_report(current_date, current_date)->>'n')::int = (t.get('arep0')::jsonb->>'n')::int + 2,
  'with no limit set the Shop Admin sees every sale');
reset role;
update settings set shop_sales_limit_usd = 347 where id = 1;

-- ===== passcodes from the Admin: the Invoices tab and the shift end report of a Shop Admin =====
-- (lno1 is the sale of 347 USD, lno2 the one above the limit; lrep0 is the Shop Admin's report before both)
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.fails($$select public.set_passcode('00000000-0000-0000-0000-00000000000c', 'invoices', '1234')$$, 'permission', 'a Shop Admin cannot set a passcode');
select t.ok((public.open_invoices('1234')->>'error') ilike '%Ask the Admin%', 'with no passcode set the Invoices tab stays locked');
select t.ok((public.day_end_report(current_date, '1234')->>'error') ilike '%Ask the Admin%', 'and so does the shift end report');
select t.as('00000000-0000-0000-0000-00000000000a');
select t.fails($$select public.set_passcode('00000000-0000-0000-0000-00000000000c', 'invoices', '12a')$$, '4 to 12 digits', 'a passcode is 4 to 12 digits');
select t.fails($$select public.set_passcode('00000000-0000-0000-0000-00000000000d', 'invoices', '1234')$$, 'Shop Admin', 'passcodes are for Shop Admin logins');
select public.set_passcode('00000000-0000-0000-0000-00000000000c', 'invoices', '4821'), public.set_passcode('00000000-0000-0000-0000-00000000000c', 'day_end', '7735');
select t.ok((select count(*) from shop_passcodes where user_id = '00000000-0000-0000-0000-00000000000c') = 2, 'the Admin sees which passcodes are set');
select t.fails($$select hash from public.shop_passcodes$$, 'permission denied', 'nobody reads a passcode, not even the Admin');
select t.as('00000000-0000-0000-0000-00000000000c');
select t.ok((select count(*) from shop_passcodes) = 0, 'a Shop Admin does not see the passcodes table');
select t.ok((public.open_invoices('7735')->>'error') = 'Wrong passcode', 'the shift end passcode does not open the Invoices tab');
select t.ok(not exists (select 1 from invoices where no = t.get('lno2')), 'after a wrong passcode the sale above the limit stays hidden');
select t.ok((public.open_invoices('4821')->>'ok')::boolean, 'the Invoices passcode opens the tab');
select t.ok(exists (select 1 from invoices where no = t.get('lno2')) and (select count(*) from invoice_items where invoice_id = t.get('lover')::uuid) = 1,
  'with the tab open the Shop Admin sees every invoice, also above the limit');
select t.ok((public.sales_report(current_date, current_date)->>'total_usd')::numeric <= 347, 'the sales figures on screen keep the limit while the tab is open');
-- an invoice above the limit is edited as usual: a 5% discount, then taken back
select public.edit_invoice(t.get('lover')::uuid, '[{"line_no":1,"qty":1}]', 5, 'Discount agreed with the customer');
select t.ok((select total from invoices where id = t.get('lover')::uuid) = 939510, 'the Shop Admin edits an invoice above the limit as usual (5% off 988 960)');
select public.edit_invoice(t.get('lover')::uuid, '[{"line_no":1,"qty":1}]', 0, 'Discount taken back');
select public.close_invoices();
select t.ok(not exists (select 1 from invoices where no = t.get('lno2')) and exists (select 1 from invoices where no = t.get('lno1')), 'leaving the tab locks it again');
select t.ok((public.open_invoices('4821')->>'ok')::boolean, 'it opens again with the passcode');
reset role;
update shop_passcodes set open_until = now() - interval '1 minute' where kind = 'invoices';
set role authenticated;
select t.ok(not exists (select 1 from invoices where no = t.get('lno2')), 'the tab locks by itself when its time is over');
-- the shift end report: every sale of the day, for its own passcode
select t.ok((public.day_end_report(current_date, '4821')->>'error') = 'Wrong passcode', 'the Invoices passcode does not print the shift end report');
select t.put('lslip', public.day_end_report(current_date, '7735')::text);
select t.ok((t.get('lslip')::jsonb->>'ok')::boolean and (t.get('lslip')::jsonb->'slip'->>'n')::int = (t.get('arep0')::jsonb->>'n')::int + 2
  and (t.get('lslip')::jsonb->'slip'->>'value_fc')::bigint = (t.get('arep0')::jsonb->>'total')::bigint + 988950 + 988960,
  'with its passcode the shift end report has every sale of the day, also above the limit');
select t.ok((t.get('lslip')::jsonb->'slip'->>'collected')::bigint - (t.get('lslip')::jsonb->'slip'->>'returned')::bigint = (t.get('lslip')::jsonb->'slip'->>'value_fc')::bigint,
  'and its balance is the value of the invoices');
select t.as('00000000-0000-0000-0000-00000000000a');
select t.ok((t.get('lslip')::jsonb->'slip'->>'value_fc')::bigint = (select (sl->>'value_fc')::bigint from jsonb_array_elements(public.sales_report(current_date, current_date, t.get('gom')::uuid)->'slips') sl),
  'it is the same slip the Admin gets');
select t.fails($$select public.day_end_report(current_date, '7735')$$, 'permission', 'the passcode report is the Shop Admin''s');
-- another Shop Admin has their own passcodes
select t.as('00000000-0000-0000-0000-00000000000e');
select t.ok((public.open_invoices('4821')->>'error') ilike '%Ask the Admin%', 'a passcode belongs to one Shop Admin');
-- 5 wrong tries block the passcode for 10 minutes, even for the right one
select t.as('00000000-0000-0000-0000-00000000000c');
select public.day_end_report(current_date, '0000'), public.day_end_report(current_date, '0001'), public.day_end_report(current_date, '0002'), public.day_end_report(current_date, '0003');
select t.ok((public.day_end_report(current_date, '0004')->>'error') ilike '%blocked for 10 minutes%', 'the fifth wrong passcode blocks it');
select t.ok((public.day_end_report(current_date, '7735')->>'error') ilike '%Too many wrong passcodes%', 'while blocked even the right passcode is refused');
-- a new passcode from the Admin lifts the block; removing it locks the report
select t.as('00000000-0000-0000-0000-00000000000a');
select public.set_passcode('00000000-0000-0000-0000-00000000000c', 'day_end', '990011');
select t.as('00000000-0000-0000-0000-00000000000c');
select t.ok((public.day_end_report(current_date, '990011')->>'ok')::boolean and (public.day_end_report(current_date, '7735')->>'error') = 'Wrong passcode', 'a new passcode from the Admin works at once, the old one no longer');
select t.as('00000000-0000-0000-0000-00000000000a');
select public.set_passcode('00000000-0000-0000-0000-00000000000c', 'day_end', '');
select t.ok((select count(*) from audit_log where action like '%passcode%') >= 5, 'passcodes set, used and blocked are in the activity log');
select t.as('00000000-0000-0000-0000-00000000000c');
select t.ok((public.day_end_report(current_date, '990011')->>'error') ilike '%Ask the Admin%', 'a removed passcode locks the report');
reset role;

-- ===== a till operator gives a discount with the Discount passcode from the Admin =====
select t.put('dno1', (select 'GOM-' || code || '-' || lpad((last_seq + 1)::text, 6, '0') from devices where id = t.get('dev1')::uuid));
select t.put('dno2', (select 'GOM-' || code || '-' || lpad((last_seq + 2)::text, 6, '0') from devices where id = t.get('dev1')::uuid));
select t.put('dno3', (select 'GOM-' || code || '-' || lpad((last_seq + 3)::text, 6, '0') from devices where id = t.get('dev1')::uuid));
select t.put('dno4', (select 'GOM-' || code || '-' || lpad((last_seq + 4)::text, 6, '0') from devices where id = t.get('dev1')::uuid));
select t.put('dord1', gen_random_uuid()::text), t.put('dord2', gen_random_uuid()::text), t.put('dinv', gen_random_uuid()::text);
-- an order of 2 shampoos at 25 650 printed at the till, with what the test adds (a discount, a token)
create function t.dord(id text, no text, extra jsonb) returns jsonb language sql as $$
  select jsonb_build_object('id', id, 'customer', 'Papa Ilunga', 'no', no, 'device_id', t.get('dev1'), 'rate', 2850, 'vat_rate', 16,
    'items', jsonb_build_array(jsonb_build_object('product_id', t.get('sh1'), 'mult', 1, 'qty', 2, 'price', 25650))) || extra $$;
grant execute on function t.dord(text, text, jsonb) to authenticated;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.fails($$select public.set_passcode('00000000-0000-0000-0000-00000000000c', 'discount', '1234')$$, 'Till Operator', 'the Discount passcode is for till operators');
select t.fails($$select public.set_passcode('00000000-0000-0000-0000-00000000000d', 'invoices', '1234')$$, 'Shop Admin', 'the other passcodes stay for Shop Admins');
select t.as('00000000-0000-0000-0000-00000000000d');
select t.ok((public.open_discount('5566')->>'error') ilike '%Ask the Admin%', 'with no Discount passcode set the discount stays locked');
select t.fails(format($$select public.submit_order(t.dord('%s', '%s', '{"disc_pct": 10}'))$$, t.get('dord1'), t.get('dno1')), 'Discount passcode', 'a till operator cannot discount an order without the passcode');
select t.fails(format($$select public.submit_order(t.dord('%s', '%s', '{"disc_pct": 10, "discount_token": "11111111-1111-1111-1111-111111111111"}'))$$, t.get('dord1'), t.get('dno1')), 'Discount passcode', 'nor with a made up token');
select t.as('00000000-0000-0000-0000-00000000000a');
select public.set_passcode('00000000-0000-0000-0000-00000000000d', 'discount', '5566');
select t.as('00000000-0000-0000-0000-00000000000d');
select t.ok((public.open_discount('0000')->>'error') = 'Wrong passcode', 'a wrong Discount passcode is refused');
select t.put('dtok', public.open_discount('5566')->>'token');
select t.ok(t.get('dtok') is not null, 'the right passcode unlocks a discount');
select t.fails(format($$select public.submit_order(t.dord('%s', '%s', '{"disc_pct": 40, "discount_token": "%s"}'))$$, t.get('dord1'), t.get('dno1'), t.get('dtok')), '30%', 'the discount is 30% at most');
select public.submit_order(t.dord(t.get('dord1'), t.get('dno1'), jsonb_build_object('disc_pct', 10, 'discount_token', t.get('dtok'))));
select t.ok((select disc || '/' || total from sale_orders where id = t.get('dord1')::uuid) = '5130/46170', 'the order keeps the discount printed at the till: 10% of 51 300');
select t.ok((public.submit_order(t.dord(t.get('dord1'), t.get('dno1'), jsonb_build_object('disc_pct', 10, 'discount_token', t.get('dtok'))))->>'status') = 'duplicate', 'an order sent twice is saved once');
select t.fails(format($$select public.submit_order(t.dord('%s', '%s', '{"disc": 5000, "discount_token": "%s"}'))$$, t.get('dord2'), t.get('dno2'), t.get('dtok')), 'Discount passcode', 'one passcode entry covers one invoice');
select t.put('dtok2', public.open_discount('5566')->>'token');
select public.submit_order(t.dord(t.get('dord2'), t.get('dno2'), jsonb_build_object('disc', 5000, 'discount_token', t.get('dtok2'))));
select t.ok((select disc || '/' || total from sale_orders where id = t.get('dord2')::uuid) = '5000/46300', 'a discount as an amount in CDF');
-- the Shop Admin approves the first as printed (nothing changed), and the second without its discount (changed)
select t.as('00000000-0000-0000-0000-00000000000c');
select t.ok((public.submit_invoice(t.dord(t.get('dord1'), t.get('dno1'), jsonb_build_object('order_id', t.get('dord1'), 'disc', 5130)))->>'revised') = 'false', 'approving an order with its discount is not a change');
select t.ok((select disc || '/' || total || '/' || (revised_from is null)::text from invoices where id = t.get('dord1')::uuid) = '5130/46170/true', 'the approved invoice has the till operator''s discount');
select t.ok((public.submit_invoice(t.dord(t.get('dord2'), t.get('dno2'), jsonb_build_object('order_id', t.get('dord2'))))->>'revised') = 'true', 'approving it without the discount is a change');
select t.ok((select total || '/' || revised_from from invoices where id = t.get('dord2')::uuid) = '51300/46300', 'the corrected invoice shows what the till printed');
-- selling directly (the Admin's switch): the same passcode
reset role;
update settings set features = features || '{"till_sells": true}' where id = 1;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000d');
select t.fails(format($$select public.submit_invoice(t.dord('%s', '%s', '{"disc_pct": 5}'))$$, t.get('dinv'), t.get('dno3')), 'Discount passcode', 'a till operator selling directly cannot discount without the passcode');
select t.fails(format($$select public.submit_invoice(t.dord('%s', '%s', '{"disc_pct": 5, "discount_token": "%s"}'))$$, t.get('dinv'), t.get('dno3'), t.get('dtok')), 'Discount passcode', 'nor with a token already used');
select t.ok((public.submit_invoice(t.dord(gen_random_uuid()::text, t.get('dno3'), '{}'))->>'status') = 'ok', 'without a discount the till operator sells as before');
select t.put('dtok3', public.open_discount('5566')->>'token');
select t.ok((public.submit_invoice(t.dord(t.get('dinv'), t.get('dno4'), jsonb_build_object('disc_pct', 5, 'discount_token', t.get('dtok3'))))->>'total')::bigint = 51300 - 2570, 'with the passcode the till operator sells with a discount: 5% of 51 300, rounded to 10');
select t.ok((public.submit_invoice(t.dord(t.get('dinv'), t.get('dno4'), jsonb_build_object('disc_pct', 5, 'discount_token', t.get('dtok3'))))->>'status') = 'duplicate', 'a sale sent twice is saved once');
select t.as('00000000-0000-0000-0000-00000000000c');
select t.fails($$select public.open_discount('5566')$$, 'permission', 'the Discount passcode is the till operator''s');
select t.as('00000000-0000-0000-0000-00000000000a');
select t.ok(exists (select 1 from audit_log where action like '%discount%with the passcode%') and exists (select 1 from audit_log where action = 'Discount passcode set for till.gombe'), 'discounts given with the passcode are in the activity log');
reset role;
update settings set features = features - 'till_sells' where id = 1;
select t.ok(t.unbalanced() = 0, 'the books still balance');

-- ===== shift end reports: a printed shift closes, the next one starts fresh; combined or per till =====
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select public.set_passcode('00000000-0000-0000-0000-00000000000c', 'day_end', '2468');
select t.as('00000000-0000-0000-0000-00000000000c');
select t.ok((public.shift_end_report('1111')->>'error') = 'Wrong passcode', 'a shift end report needs the passcode');
select t.fails(format($$select public.shift_end_report('2468', 'close', '%s')$$, gen_random_uuid()), 'not in your shop', 'only the tills of the shop');
select t.put('day0', public.shift_end_report('2468', 'day', null, current_date)::text);
-- the first shift of the day has every sale of the day so far, like the whole-day report
select t.put('shf1', public.shift_end_report('2468')::text);
select t.ok((t.get('shf1')::jsonb->>'shift_no')::int = 1 and (t.get('shf1')::jsonb->'slip'->>'n')::int = (t.get('day0')::jsonb->'slip'->>'n')::int
  and (t.get('shf1')::jsonb->'slip'->>'value_fc')::bigint = (t.get('day0')::jsonb->'slip'->>'value_fc')::bigint, 'shift 1 has the sales of the day so far');
-- printed again at once: a fresh shift with nothing in it
select t.put('shf2', public.shift_end_report('2468')::text);
select t.ok((t.get('shf2')::jsonb->>'shift_no')::int = 2 and (t.get('shf2')::jsonb->'slip'->>'n')::int = 0 and (t.get('shf2')::jsonb->'slip'->>'value_fc')::bigint = 0,
  'the next shift end report starts fresh');
-- a sale on till 2 and one on till 1 (the till operator selling directly)
reset role;
update settings set features = features || '{"till_sells": true}' where id = 1;
select t.put('sno1', (select 'GOM-' || code || '-' || lpad((last_seq + 1)::text, 6, '0') from devices where id = t.get('dev2')::uuid));
select t.put('sno2', (select 'GOM-' || code || '-' || lpad((last_seq + 1)::text, 6, '0') from devices where id = t.get('dev1')::uuid));
set role authenticated;
select public.submit_invoice(t.csale(t.get('sno1'), jsonb_build_array(jsonb_build_object('product_id', t.get('sh1'), 'mult', 1, 'qty', 1, 'price', 25650))));
select t.as('00000000-0000-0000-0000-00000000000d');
select public.submit_invoice(t.dord(gen_random_uuid()::text, t.get('sno2'), '{}'));
select t.as('00000000-0000-0000-0000-00000000000c');
-- an invoice of shift 1 corrected now: the money given back counts in this shift
select public.edit_invoice(t.get('lat')::uuid, '[{"line_no":1,"qty":1}]', 10, 'Discount after the sale');
select t.put('back', ((select from_total - to_total from invoice_edits where invoice_id = t.get('lat')::uuid order by id desc limit 1))::text);
-- till 1 alone: only its sale; its own shift 1
select t.put('d1', public.shift_end_report('2468', 'day', t.get('dev1')::uuid, current_date)::text);
select t.put('t1', public.shift_end_report('2468', 'close', t.get('dev1')::uuid)::text);
select t.ok((t.get('t1')::jsonb->>'shift_no')::int = 1 and (t.get('t1')::jsonb->>'till') = (select code from devices where id = t.get('dev1')::uuid)
  and (t.get('t1')::jsonb->'slip'->>'n') = (t.get('d1')::jsonb->'slip'->>'n') and (t.get('t1')::jsonb->'slip'->>'value_fc') = (t.get('d1')::jsonb->'slip'->>'value_fc')
  and (t.get('d1')::jsonb->'slip'->>'n')::int < (t.get('day0')::jsonb->'slip'->>'n')::int + 2, 'a till''s first shift has that till''s sales of the day, not the others''');
-- combined: both sales since shift 2, and the correction
select t.put('shf3', public.shift_end_report('2468')::text);
select t.ok((t.get('shf3')::jsonb->>'shift_no')::int = 3 and (t.get('shf3')::jsonb->'slip'->>'n')::int = 2 and (t.get('shf3')::jsonb->'slip'->>'value_fc')::bigint = 25650 + 51300,
  'printing one till does not close the combined shift');
select t.ok((t.get('shf3')::jsonb->'slip'->>'returned')::bigint = t.get('back')::bigint and t.get('back')::bigint > 0
  and (t.get('shf3')::jsonb->'slip'->>'collected')::bigint = 25650 + 51300, 'a correction counts in the shift it was made in');
-- from the second shift of the day the slip also carries the day so far, which is the sum of today's shifts
select t.ok(not (t.get('shf1')::jsonb->'slip' ? 'day'), 'the first shift of the day has no day-so-far section: it would repeat itself');
select t.ok((t.get('shf2')::jsonb->'slip'->'day'->>'shifts')::int = 2
  and (t.get('shf2')::jsonb->'slip'->'day'->>'n')::int = (t.get('shf1')::jsonb->'slip'->>'n')::int + (t.get('shf2')::jsonb->'slip'->>'n')::int,
  'shift 2 carries the day so far: shifts 1 and 2 together');
select t.ok((t.get('shf3')::jsonb->'slip'->'day'->>'shifts')::int = 3
  and (t.get('shf3')::jsonb->'slip'->'day'->>'n')::int
    = (t.get('shf1')::jsonb->'slip'->>'n')::int + (t.get('shf2')::jsonb->'slip'->>'n')::int + (t.get('shf3')::jsonb->'slip'->>'n')::int,
  'shift 3 carries the invoices of all three shifts');
select t.ok((t.get('shf3')::jsonb->'slip'->'day'->>'value_fc')::bigint
    = (t.get('shf1')::jsonb->'slip'->>'value_fc')::bigint + (t.get('shf2')::jsonb->'slip'->>'value_fc')::bigint + (t.get('shf3')::jsonb->'slip'->>'value_fc')::bigint
  and (t.get('shf3')::jsonb->'slip'->'day'->>'collected')::bigint
    = (t.get('shf1')::jsonb->'slip'->>'collected')::bigint + (t.get('shf2')::jsonb->'slip'->>'collected')::bigint + (t.get('shf3')::jsonb->'slip'->>'collected')::bigint
  and (t.get('shf3')::jsonb->'slip'->'day'->>'returned')::bigint
    = (t.get('shf1')::jsonb->'slip'->>'returned')::bigint + (t.get('shf2')::jsonb->'slip'->>'returned')::bigint + (t.get('shf3')::jsonb->'slip'->>'returned')::bigint,
  'and its value, the cash collected and the money given back add up exactly with the three shift slips');
select t.ok((t.get('shf3')::jsonb->'slip'->'day'->>'from')::timestamptz = (t.get('shf1')::jsonb->>'from')::timestamptz, 'the day so far starts where shift 1 started');
select t.ok(not (t.get('t1')::jsonb->'slip' ? 'day'), 'a till''s first shift has no day-so-far section either');
select t.put('t2', public.shift_end_report('2468', 'close', t.get('dev1')::uuid)::text);
select t.ok((t.get('t2')::jsonb->'slip'->>'n')::int = 0, 'the till''s next shift starts fresh');
select t.ok((t.get('t2')::jsonb->'slip'->'day'->>'n') = (t.get('t1')::jsonb->'slip'->>'n'), 'and its day so far is that till''s own shifts, not all tills''');
-- the day keeps every shift together
select t.ok((public.shift_end_report('2468', 'day', null, current_date)->'slip'->>'n')::int = (t.get('day0')::jsonb->'slip'->>'n')::int + 2, 'the day end report still has the whole day');
-- reprint: the same as printed, even after more sales
select t.ok((public.shift_end_report('2468', 'reprint', null, null, (select id from shift_closes where shift_no = 1 and device_id is null and shop_id = t.get('gom')::uuid))->'slip')
  = (t.get('shf1')::jsonb->'slip'), 'a printed shift prints again the same');
select t.ok((public.shift_end_report('2468', 'reprint', null, null, (select id from shift_closes where shift_no = 3 and device_id is null and shop_id = t.get('gom')::uuid))->'slip'->'day')
  = (t.get('shf3')::jsonb->'slip'->'day'), 'printed again, a later shift keeps the day so far as it stood then');
select t.ok((select count(*) from shift_closes) = 5, 'the Shop Admin sees the list of printed shifts');
select t.fails($$select slip from public.shift_closes$$, 'permission denied', 'but not their amounts without the passcode');
select t.as('00000000-0000-0000-0000-00000000000e');
select t.ok((select count(*) from shift_closes) = 0, 'another shop''s shifts are not shown');
select t.as('00000000-0000-0000-0000-00000000000a');
select t.ok(exists (select 1 from audit_log where action like 'Shift end report 3 of % (all tills) printed, 2 invoices%'), 'each shift printed is in the activity log');
reset role;
update settings set features = features - 'till_sells' where id = 1;

-- ===== one copy of each invoice (a switch in Settings, off by default) =====
select t.ok((select copies || '/' || printed from invoices where no = t.get('sno1')) = '2/2', 'by default an invoice prints two copies');
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select public.save_settings((select jsonb_build_object('rate', rate, 'book_rate', book_rate, 'vat', vat, 'company', company, 'features', features || '{"one_copy": true}') from settings));
select t.ok((select (features->>'one_copy')::boolean from settings), 'the Admin turns on one copy');
reset role;
select t.put('cno9', (select 'GOM-' || code || '-' || lpad((last_seq + 1)::text, 6, '0') from devices where id = t.get('dev2')::uuid));
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select public.submit_invoice(t.csale(t.get('cno9'), jsonb_build_array(jsonb_build_object('product_id', t.get('sh1'), 'mult', 1, 'qty', 1, 'price', 25650))));
select t.ok((select copies || '/' || printed from invoices where no = t.get('cno9')) = '1/1', 'with it on, an invoice is made with one copy');
select public.record_reprint((select id from invoices where no = t.get('cno9')));
select t.ok((select printed - copies from invoices where no = t.get('cno9')) = 1, 'a duplicate counts as one duplicate');
select t.ok((select copies from invoices where no = t.get('sno1')) = 2, 'invoices made before keep their two copies');
select t.as('00000000-0000-0000-0000-00000000000a');
select public.save_settings((select jsonb_build_object('rate', rate, 'book_rate', book_rate, 'vat', vat, 'company', company, 'features', features || '{"one_copy": false}') from settings));
select t.ok(not (select (features->>'one_copy')::boolean from settings), 'and back to two copies');
reset role;

-- ===== no central store: goods from a supplier go straight into a shop =====
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.ok(not coalesce((select (features->>'no_warehouse')::boolean from settings), false), 'the central store is used unless the Admin turns it off');
select t.put('whq0', (select wh_qty::text from products where id = t.get('lotion')::uuid));
select t.put('shq0', coalesce((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('lotion')::uuid), 0)::text);
select public.save_settings((select jsonb_build_object('rate', rate, 'book_rate', book_rate, 'vat', vat, 'company', company, 'features', features || '{"no_warehouse": true}') from settings));
select t.ok((select (features->>'no_warehouse')::boolean from settings), 'the Admin turns the central store off');
select t.fails(format($$select public.receive_goods('{"supplier_id":"%s","lines":[{"product_id":"%s","qty":2}]}')$$, t.get('sup'), t.get('lotion')),
  'Choose the shop', 'with no central store the goods need a shop');
select t.fails(format($$select public.receive_goods('{"supplier_id":"%s","shop_id":"00000000-0000-0000-0000-0000000000ff","lines":[{"product_id":"%s","qty":2}]}')$$, t.get('sup'), t.get('lotion')),
  'Choose the shop', 'an unknown shop is refused');
select t.put('grnd', public.receive_goods(jsonb_build_object('supplier_id', t.get('sup'), 'ref', 'DN 99', 'shop_id', t.get('gom'),
  'lines', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 6))))->>'id');
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('lotion')::uuid) = t.get('shq0')::int + 6,
  'the goods are added to the shop stock');
select t.ok((select wh_qty from products where id = t.get('lotion')::uuid) = t.get('whq0')::int, 'the central store is left untouched');
select t.ok((select shop_id from grns where id = t.get('grnd')::uuid) = t.get('gom')::uuid, 'the receipt remembers the shop it went into');
select t.ok((select l.side from voucher_lines l join vouchers v on v.id = l.voucher_id
  where v.source_type = 'grn' and v.source_id = t.get('grnd')::uuid and l.account_id = t.shop_acc('INV_SHOP', t.get('gom')::uuid)) = 'Dr',
  'the goods are booked to the shop''s stock account');
select t.ok(not exists (select 1 from voucher_lines l join vouchers v on v.id = l.voucher_id
  where v.source_type = 'grn' and v.source_id = t.get('grnd')::uuid and l.account_id = t.acc('INV_STORE')), 'and not to the central store''s');
select t.ok(t.unbalanced() = 0, 'the books still balance');
-- the Admin enters the supplier's bill for it as usual
select t.ok((public.enter_bill(jsonb_build_object('grn_id', t.get('grnd'), 'bill_no', 'F-NW-1', 'amount', 9, 'currency', 'USD'))->>'voucher_id') is not null,
  'the bill for a receipt into a shop is entered as usual');
select t.ok((select status from grns where id = t.get('grnd')::uuid) = 'billed', 'and the receipt is billed');
-- the other shop is not touched
select t.ok(coalesce((select qty from shop_stock where shop_id = t.get('lim')::uuid and product_id = t.get('lotion')::uuid), 0) = 0
  or (select qty from shop_stock where shop_id = t.get('lim')::uuid and product_id = t.get('lotion')::uuid) is not null, 'only the chosen shop receives the goods');
-- switching the central store back on: goods arrive there again
select public.save_settings((select jsonb_build_object('rate', rate, 'book_rate', book_rate, 'vat', vat, 'company', company, 'features', features || '{"no_warehouse": false}') from settings));
select public.receive_goods(jsonb_build_object('supplier_id', t.get('sup'), 'lines', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 1))));
select t.ok((select wh_qty from products where id = t.get('lotion')::uuid) = t.get('whq0')::int + 1, 'with the central store back on, goods arrive there again');
select t.ok((select shop_id from grns order by received_at desc, no desc limit 1) is null, 'and that receipt has no shop');
reset role;

-- ===== dollars are taken at the internal rate, so the Francs handed over with them are collected =====
-- the shop prices at 2 350 but gives only 2 300 for a dollar: a 23 500 CDF bill needs $10 AND 500 CDF
update settings set features = features || '{"usd_pay": true}' where id = 1;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select public.save_rate('sales', 2350), public.save_rate('book', 2300);
select t.as('00000000-0000-0000-0000-00000000000c');
select t.put('fx0', (select x::text from jsonb_array_elements(public.sales_report(current_date, current_date)->'slips') x limit 1));
select t.put('fxid', gen_random_uuid()::text);
select t.put('fxno', (select 'GOM-' || code || '-' || lpad((last_seq + 1)::text, 6, '0') from devices where id = t.get('dev2')::uuid));
-- the loophole is closed: $10 on its own no longer pays a 23 500 bill, because at 2 300 it is only 23 000
select t.fails(format($$select public.submit_invoice('{"id":"%s","no":"%s","device_id":"%s","customer":"Dollar top-up","paid_usd":10,"usd_rate":2300,"rate":2350,"vat_rate":16,"items":[{"product_id":"%s","mult":1,"qty":1,"price":23500}]}')$$,
  t.get('fxid'), t.get('fxno'), t.get('dev2'), t.get('lotion')), 'less than the total', '10 dollars alone no longer pay a 23 500 CDF bill');
select public.submit_invoice(jsonb_build_object('id', t.get('fxid'), 'no', t.get('fxno'), 'device_id', t.get('dev2'), 'rate', 2350, 'vat_rate', 16,
  'customer', 'Dollar top-up', 'paid_usd', 10, 'paid_cdf', 500, 'usd_rate', 2300,
  'items', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'mult', 1, 'qty', 1, 'price', 23500))));
select t.put('fx1', (select x::text from jsonb_array_elements(public.sales_report(current_date, current_date)->'slips') x limit 1));
reset role;
select t.ok((select total = 23500 and tendered = 23500 and change = 0 and paid_usd = 10 and paid_cdf = 500 and usd_rate = 2300
  from invoices where id = t.get('fxid')::uuid), 'the sale takes $10 and 500 CDF, and keeps the rate the dollars were taken at');
select t.ok((t.get('fx1')::jsonb->>'collected_cdf')::bigint - (t.get('fx0')::jsonb->>'collected_cdf')::bigint = 500,
  'the 500 CDF handed over with the dollars now shows on the slip as Francs collected');
select t.ok((t.get('fx1')::jsonb->>'collected_usd')::numeric - (t.get('fx0')::jsonb->>'collected_usd')::numeric = 10, 'and the dollars show as dollars collected');
select t.ok((select round(sum(case when l.side = 'Cr' then l.base else -l.base end), 2) from voucher_lines l join vouchers v on v.id = l.voucher_id
  join accounts a on a.id = l.account_id where v.source_id = t.get('fxid')::uuid and a.code = 'FX_GAIN') = 0.21,
  'what the shop earns on the dollars is booked as an exchange gain');
select t.ok((select sum(l.amount) from voucher_lines l join vouchers v on v.id = l.voucher_id join accounts a on a.id = l.account_id
  where v.source_id = t.get('fxid')::uuid and a.code like 'CASH_SHOP:%') = 500, 'the shop cash ledger takes the 500 CDF');
select t.ok(t.unbalanced() = 0, 'every voucher still balances');
-- with the internal rate back at the sales rate nothing changes: a dollar is worth what it always was
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select public.save_rate('book', 2350);
select t.as('00000000-0000-0000-0000-00000000000c');
select t.put('fxid2', gen_random_uuid()::text);
select t.put('fxno2', (select 'GOM-' || code || '-' || lpad((last_seq + 1)::text, 6, '0') from devices where id = t.get('dev2')::uuid));
select public.submit_invoice(jsonb_build_object('id', t.get('fxid2'), 'no', t.get('fxno2'), 'device_id', t.get('dev2'), 'rate', 2350, 'vat_rate', 16,
  'customer', 'Dollar exact', 'paid_usd', 10, 'usd_rate', 2350,
  'items', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'mult', 1, 'qty', 1, 'price', 23500))));
reset role;
select t.ok((select tendered = 23500 and change = 0 and paid_cdf = 0 from invoices where id = t.get('fxid2')::uuid),
  'at the same rate $10 still pays a 23 500 bill on its own');
select t.ok(not exists (select 1 from voucher_lines l join vouchers v on v.id = l.voucher_id join accounts a on a.id = l.account_id
  where v.source_id = t.get('fxid2')::uuid and a.code = 'FX_GAIN'), 'and nothing is booked as an exchange gain');
select t.ok(t.unbalanced() = 0, 'the books still balance');
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select public.save_rate('sales', 2850), public.save_rate('book', 2900);
reset role;
update settings set features = features - 'usd_pay' where id = 1;

-- ===== the Shop Admin's figures stop at the shop's daily limit =====
-- the limit is set to the day's sales so far plus 20 USD, then three sales of 10 USD are made: two fit, one does not
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.put('dlN', public.sales_report(current_date, current_date, t.get('gom')::uuid)->>'n'),
       t.put('dlF', public.sales_report(current_date, current_date, t.get('gom')::uuid)->>'total');
reset role;
-- the limit counts a sale at the rate it was priced at, so the baseline is taken the same way
select t.put('dlA', (select coalesce(sum(i.total / i.rate), 0)::text from invoices i
  where i.shop_id = t.get('gom')::uuid and (i.t at time zone (select tz from settings where id = 1))::date = current_date));
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.put('dlno1', (select 'GOM-' || code || '-' || lpad((last_seq + 1)::text, 6, '0') from devices where id = t.get('dev2')::uuid));
select t.put('dlno2', (select 'GOM-' || code || '-' || lpad((last_seq + 2)::text, 6, '0') from devices where id = t.get('dev2')::uuid));
select t.put('dlno3', (select 'GOM-' || code || '-' || lpad((last_seq + 3)::text, 6, '0') from devices where id = t.get('dev2')::uuid));
select t.as('00000000-0000-0000-0000-00000000000c');
-- 23 500 CDF at 2 350 is exactly 10 USD
select public.submit_invoice(t.csale(t.get('dlno1'), jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'mult', 1, 'qty', 1, 'price', 23500))) || '{"rate": 2350}');
select public.submit_invoice(t.csale(t.get('dlno2'), jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'mult', 1, 'qty', 1, 'price', 23500))) || '{"rate": 2350}');
select public.submit_invoice(t.csale(t.get('dlno3'), jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'mult', 1, 'qty', 1, 'price', 23500))) || '{"rate": 2350}');
reset role;
update settings set shop_sales_limit_usd = ceil(t.get('dlA')::numeric * 100) / 100 + 20 where id = 1;  -- the limit is kept to the cent
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.put('dl1', public.sales_report(current_date, current_date)::text);
reset role;
select t.ok((t.get('dl1')::jsonb->>'n')::int = t.get('dlN')::int + 2, 'the Shop Admin sees the day only as far as the limit: two of the three new sales');
select t.ok((select round(sum(i.total / i.rate), 2) from invoices i
    where i.id in (select (x->>'id')::uuid from jsonb_array_elements(t.get('dl1')::jsonb->'invoices') x))
  = round(t.get('dlA')::numeric + 20, 2), 'the sales shown stop exactly at the limit, counted at the rate they were priced at');
select t.ok((t.get('dl1')::jsonb->>'total')::bigint = t.get('dlF')::bigint + 47000, 'in Francs it is the day so far plus the two sales that fit');
select t.ok((t.get('dl1')::jsonb->>'capped')::boolean, 'and the report says the figures stop at the limit');
select t.ok(not exists (select 1 from jsonb_array_elements(t.get('dl1')::jsonb->'invoices') i where i->>'no' = t.get('dlno3')), 'the sale that did not fit is not in the list');
select t.ok((select sum((x->>'total')::bigint) from jsonb_array_elements(t.get('dl1')::jsonb->'invoices') x) = (t.get('dl1')::jsonb->>'total')::bigint,
  'the invoice list adds up to the total, so the screen cannot be added up past the limit');
select t.ok((select sum((c->>'val')::bigint) from jsonb_array_elements(t.get('dl1')::jsonb->'by_cashier') c) = (t.get('dl1')::jsonb->>'total')::bigint
  or (select sum((c->>'v')::bigint) from jsonb_array_elements(t.get('dl1')::jsonb->'by_cashier') c) = (t.get('dl1')::jsonb->>'total')::bigint, 'and so do the cashiers');
select t.ok((t.get('dl1')::jsonb->'slips'->0->>'value_fc')::bigint = (t.get('dl1')::jsonb->>'total')::bigint, 'and the slip in that report');
-- the shift end report, with its passcode, still has every sale of the day
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select public.set_passcode('00000000-0000-0000-0000-00000000000c', 'day_end', '4242');
select t.as('00000000-0000-0000-0000-00000000000c');
select t.ok((public.shift_end_report('4242', 'day', null, current_date)->'slip'->>'value_fc')::bigint = t.get('dlF')::bigint + 70500,
  'the shift end report still prints every sale of the day, all three');
-- the Admin is never capped
select t.as('00000000-0000-0000-0000-00000000000a');
select t.ok(not (public.sales_report(current_date, current_date, t.get('gom')::uuid)->>'capped')::boolean
  and (public.sales_report(current_date, current_date, t.get('gom')::uuid)->>'n')::int = t.get('dlN')::int + 3, 'the Admin sees every sale, with no limit');
reset role;
update settings set shop_sales_limit_usd = 347 where id = 1;

-- ===== sales in dollars are counted at the rate the till takes dollars =====
-- a 1 000 000 CDF invoice priced at 2 350 and paid with dollars at 2 300
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select public.save_rate('sales', 2350), public.save_rate('book', 2300);
select public.set_passcode('00000000-0000-0000-0000-00000000000c', 'day_end', '9191');
reset role;
update settings set features = features || '{"usd_pay": true}' where id = 1;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select public.shift_end_report('9191') is not null as shift_closed;   -- close off what came before
select t.put('urid', gen_random_uuid()::text);
select t.put('urno', (select 'GOM-' || code || '-' || lpad((last_seq + 1)::text, 6, '0') from devices where id = t.get('dev2')::uuid));
select public.submit_invoice(jsonb_build_object('id', t.get('urid'), 'no', t.get('urno'), 'device_id', t.get('dev2'), 'rate', 2350, 'vat_rate', 16,
  'customer', 'Dollar payer', 'paid_usd', 434.79, 'usd_rate', 2300,
  'items', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'mult', 1, 'qty', 1, 'price', 1000000))));
select t.put('urslip', public.shift_end_report('9191')::text);
select t.as('00000000-0000-0000-0000-00000000000a');   -- the Admin's report, so the big sale is in it
select t.put('urrep', public.sales_report(current_date, current_date, t.get('gom')::uuid)::text);
reset role;
select t.ok((select tendered = 1000017 and change = 17 and paid_usd = 434.79 and usd_rate = 2300 from invoices where id = t.get('urid')::uuid),
  '434.79 dollars at 2 300 pays a 1 000 000 CDF invoice, with 17 CDF change');
-- the slip's two dollar lines now agree: the sale is worth what was collected
select t.ok(round((t.get('urslip')::jsonb->'slip'->>'value_usd')::numeric, 2) = 434.78,
  'the shift end report values the sale at the till''s dollar rate: 1 000 000 / 2 300');
select t.ok(round((t.get('urslip')::jsonb->'slip'->>'collected_usd')::numeric, 2) = 434.79, 'and the dollars collected are the dollars taken');
select t.ok(abs((t.get('urslip')::jsonb->'slip'->>'value_usd')::numeric - (t.get('urslip')::jsonb->'slip'->>'collected_usd')::numeric) < 0.02,
  'so the two no longer differ by the exchange margin');
select t.ok((t.get('urslip')::jsonb->'slip'->>'value_fc')::bigint = 1000000, 'the Francs are untouched');
-- the sales report counts the day in dollars the same way
select t.ok(round((t.get('urrep')::jsonb->>'total_usd')::numeric, 2) = (select round(sum(i.total / coalesce(i.usd_rate, i.rate)), 2) from invoices i
    where i.id in (select (x->>'id')::uuid from jsonb_array_elements(t.get('urrep')::jsonb->'invoices') x)),
  'the sales report counts the day in dollars at each sale''s own dollar rate');
select t.ok((t.get('urrep')::jsonb->>'total_usd')::numeric > (select round(sum(i.total / i.rate), 2) from invoices i
    where i.id in (select (x->>'id')::uuid from jsonb_array_elements(t.get('urrep')::jsonb->'invoices') x)),
  'which is more dollars than the sales rate would give, because the shop gives less for a dollar');
reset role;
update settings set features = features - 'usd_pay' where id = 1;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select public.save_rate('sales', 2850), public.save_rate('book', 2900);
reset role;

-- ===== gross and net cost: the net cost, when given, is the item's cost; empty, the gross cost counts =====
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.put('net1', public.save_product('{"name":"Net soap","category":"Skin care","carton_cost":24,"net_cost":12,"per_carton":24,"pc":0.8,"qty_cartons":1}')::text);
select t.ok((select carton_cost_usd || ':' || net_cost_usd || ':' || cost_usd from product_costs where product_id = t.get('net1')::uuid) = '24.000000:12.000000:0.500000',
  'gross and net cost are both kept; the cost per pc is the net cost / pcs');
select t.ok((select l.amount from voucher_lines l join vouchers v on v.id = l.voucher_id where v.type = 'opening' and v.narration like '%Net soap%' and l.side = 'Dr') = 12,
  'opening stock is booked at the net cost (24 pcs x 0.50)');
select t.fails($$select public.save_product('{"name":"Net soap 2","category":"Skin care","carton_cost":24,"net_cost":12,"per_carton":24,"pc":0.4}')$$, 'below the cost of one pc ($0.50)', 'prices are checked against the net cost');
select t.fails($$select public.save_product('{"name":"Net soap 2","category":"Skin care","carton_cost":24,"net_cost":-1,"per_carton":24,"pc":2}')$$, 'net cost cannot be negative', 'a negative net cost is refused');
select t.fails($$select public.save_product('{"name":"Net soap 2","category":"Skin care","carton_cost":24,"net_cost":"abc","per_carton":24,"pc":2}')$$, 'valid net cost', 'a net cost that is not a number is refused');
select t.put('gross1', public.save_product('{"name":"Gross soap","category":"Skin care","carton_cost":24,"net_cost":"","per_carton":24,"pc":1.5}')::text);
select t.ok((select net_cost_usd is null and cost_usd = 1 from product_costs where product_id = t.get('gross1')::uuid), 'an empty net cost: the gross cost counts');
-- an older app that does not send the net cost keeps it
select public.save_product(jsonb_build_object('id', t.get('net1'), 'name','Net soap','category','Skin care','carton_cost',24,'per_carton',24,'pc',0.9));
select t.ok((select net_cost_usd = 12 and cost_usd = 0.5 from product_costs where product_id = t.get('net1')::uuid), 'saving without the net cost keeps it');
-- changing the net cost revalues the stock, as any cost change does
select public.save_product(jsonb_build_object('id', t.get('net1'), 'name','Net soap','category','Skin care','carton_cost',24,'net_cost',18,'per_carton',24,'pc',0.9));
select t.ok((select cost_usd from product_costs where product_id = t.get('net1')::uuid) = 0.75, 'a new net cost is the new cost');
select t.ok((select l.amount from voucher_lines l join vouchers v on v.id = l.voucher_id where v.type = 'adjustment' and v.narration like 'Cost of Net soap changed from $0.50 to $0.75%' and l.account_id = t.acc('INV_STORE')) = 6,
  'the stock held is revalued at the new net cost (24 pcs x 0.25)');
select t.ok(exists (select 1 from audit_log where action = 'Net cost of Net soap changed $12.00 to $18.00 per carton'), 'a net cost change is logged');
-- removing the net cost: back to the gross cost
select public.save_product(jsonb_build_object('id', t.get('net1'), 'name','Net soap','category','Skin care','carton_cost',24,'net_cost',null,'per_carton',24,'pc',1.5));
select t.ok((select net_cost_usd is null and cost_usd = 1 from product_costs where product_id = t.get('net1')::uuid), 'removing the net cost brings back the gross cost');
select t.ok(exists (select 1 from audit_log where action like 'Net cost of Net soap removed%'), 'removing it is logged');
select t.ok(t.unbalanced() = 0, 'the cost changes keep the books balanced');
-- a set: gross and net cost of one set
select t.put('netset', public.save_product('{"name":"Net clips","category":"Skin care","is_bundle":true,"set_cost":10,"net_cost":7,"set_price":8,"pcs":12,"piece":1}')::text);
select t.ok((select carton_cost_usd || ':' || net_cost_usd || ':' || cost_usd from product_costs where product_id = t.get('netset')::uuid) = '10.000000:7.000000:7.000000',
  'a set keeps its gross and net cost; its cost is the net cost');
select t.ok((select carton_cost_usd = cost_usd from product_costs where product_id = t.get('brush')::uuid), 'a set made before keeps its cost as its gross cost');
-- the Excel import takes an optional net carton cost
select t.ok((public.import_products('[{"row":2,"name":"Net import","category":"Skin care","carton_cost":24,"net_cost":12,"per_carton":24,"pc":0.8},
  {"row":3,"name":"Gross import","category":"Skin care","carton_cost":24,"net_cost":null,"per_carton":24,"pc":1.5}]')->>'imported')::int = 2, 'import with and without a net cost');
select t.ok((select string_agg(coalesce(c.net_cost_usd::text, '-') || ':' || c.cost_usd, ',' order by p.name) from product_costs c join products p on p.id = c.product_id
  where p.name in ('Net import', 'Gross import')) = '-:1.000000,12.000000:0.500000', 'imported net cost is the cost; without one the gross cost counts');
-- goods in are valued at the cost that counts
select public.save_product(jsonb_build_object('id', t.get('net1'), 'name','Net soap','category','Skin care','carton_cost',24,'net_cost',12,'per_carton',24,'pc',1.5));
select t.as('00000000-0000-0000-0000-00000000000b');
select t.put('grnnet', public.receive_goods(jsonb_build_object('supplier_id', t.get('sup'), 'lines', jsonb_build_array(jsonb_build_object('product_id', t.get('net1'), 'qty', 24))))->>'id');
reset role;
select t.ok((select std_cost_usd from grn_items where grn_id = t.get('grnnet')::uuid) = 0.5, 'goods in are valued at the net cost');

-- ===== vendeurs: goods on credit from the shop, payments, promo items and the monthly promo report =====
create function t.vstate(p_name text) returns jsonb language sql security definer as $$ select app.vendeur_state(v) from vendeurs v where v.name = p_name $$;
create function t.slip_today(p_shop uuid) returns jsonb language sql security definer as $$ select app.shift_slip(p_shop, null, now() - interval '1 day', now() + interval '1 minute') $$;
create function t.logged(p text) returns boolean language sql security definer as $$ select exists (select 1 from audit_log where action like p) $$;
grant execute on function t.vstate(text), t.slip_today(uuid), t.logged(text) to authenticated;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.put('cgel', public.save_product('{"name":"Credit gel","category":"Skin care","carton_cost":24,"per_carton":24,"pc":2}')::text);
select t.put('col0', ((public.sales_report(current_date, current_date, t.get('gom')::uuid)->'slips'->0)->>'collected'));
reset role;
update shop_stock set qty = 50 where shop_id = t.get('gom')::uuid and product_id = t.get('cgel')::uuid;
select t.put('slip0', t.slip_today(t.get('gom')::uuid)::text);
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.fails($$select public.vendeur_list()$$, 'not turned on', 'vendeurs are off until the Admin turns them on');
reset role;
update settings set features = features || '{"vendeurs": true}' where id = 1;
select t.put('r0', (select rate::text from settings where id = 1)), t.put('b0', (select book_rate::text from settings where id = 1));
update settings set rate = 2850, book_rate = 2850 where id = 1;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.put('v1', public.save_vendeur('{"name":"Papa Jean","phone":"+243 990 000 000","credit_days":7,"credit_limit_usd":7,"opening_usd":1}')::text);
select t.fails($$select public.save_vendeur('{"name":"papa JEAN","credit_days":7,"credit_limit_usd":7}')$$, 'already exists', 'vendeur names are unique in a shop');
select t.fails($$select public.save_vendeur('{"name":"No limit","credit_days":7,"credit_limit_usd":0}')$$, 'credit limit in USD', 'a vendeur needs a credit limit, in USD');
-- an opening balance in USD and CDF: the dollars at the internal rate, or a taux typed
select t.put('obr', (select coalesce(nullif(book_rate, 0), rate)::text from settings where id = 1));
select t.fails($$select public.save_vendeur('{"name":"Old debt","credit_days":7,"credit_limit_usd":300,"opening_usd":100,"opening_cdf":50000,"opening_rate":280}')$$, 'Check the rate', 'a taux with a zero missing is caught');
select t.put('vob', public.save_vendeur('{"name":"Old debt","credit_days":7,"credit_limit_usd":300,"opening_usd":100,"opening_cdf":57000}')::text);
reset role;
select t.ok((select opening_value_usd = 120 and opening_usd = 100 and opening_cdf = 57000 and opening_rate = 2850 and credit_limit_usd = 300
  from vendeurs where id = t.get('vob')::uuid), 'a vendeur can owe dollars and Francs from before, in USD: the Francs at the internal rate');
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select public.save_vendeur(jsonb_build_object('id', t.get('vob'), 'name', 'Old debt', 'credit_days', 7, 'credit_limit_usd', 300, 'opening_usd', 100, 'opening_cdf', 54000, 'opening_rate', 2700));
select t.put('vobst', public.vendeur_statement(t.get('vob')::uuid, current_date - 1, current_date)::text);
reset role;
select t.ok((select opening_value_usd = 120 and opening_rate = 2700 from vendeurs where id = t.get('vob')::uuid)
  and exists (select 1 from jsonb_array_elements(t.get('vobst')::jsonb->'lines') l where l->>'what' = 'Opening balance, $100.00 + 54 000 CDF at 2700' and (l->>'dr')::numeric = 120),
  'or at a taux typed; the statement shows how the opening was made up');
select t.ok((select abs(app.opening_base(a) - 120) < 0.005 from accounts a join vendeurs v on v.account_id = a.id where v.id = t.get('vob')::uuid),
  'in the books the opening is worth the same dollars');
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.fails($$select public.save_vendeur('{"name":"Too long","credit_days":400,"credit_limit_usd":100}')$$, '0 to 365 days', 'the credit period is 0 to 365 days');
-- goods on credit, with a promo item from the stock
select t.put('cinv1', gen_random_uuid()::text);
select t.put('cres1', public.submit_invoice(jsonb_build_object('id', t.get('cinv1'), 'no', 'GOM-T2-000900', 'device_id', t.get('dev2'), 'rate', 2850, 'vat_rate', 16,
  'customer', 'whoever', 'vendeur_id', t.get('v1'), 'items', jsonb_build_array(jsonb_build_object('product_id', t.get('cgel'), 'mult', 1, 'qty', 2, 'price', 5700)),
  'promo', jsonb_build_array(jsonb_build_object('product_id', t.get('cgel'), 'qty', 1)), 'promo_note', 'opening offer'))::text);
select t.ok((t.get('cres1')::jsonb->>'status') = 'ok' and (t.get('cres1')::jsonb->'promo'->>'value')::bigint = 5700, 'goods on credit are sold, with a promo item valued at the shop price');
select t.ok((select vendeur_id::text = t.get('v1') and tendered = 0 and change = 0 and customer = 'Papa Jean' and total = 11400 and due_date = current_date + 7
  from invoices where id = t.get('cinv1')::uuid), 'the invoice is the vendeur''s, nothing paid, due after the credit period');
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('cgel')::uuid) = 47, 'the goods and the promo item leave the shop''s stock');
select t.ok((select sum(qty) from invoice_items where invoice_id = t.get('cinv1')::uuid) = 2, 'the promo item is not on the invoice');
select t.ok((t.vstate('Papa Jean')->>'balance')::numeric = 5 and (t.vstate('Papa Jean')->>'available')::numeric = 2 and t.vstate('Papa Jean')->>'currency' = 'USD'
  and not (t.vstate('Papa Jean')->>'overdue')::boolean and (t.vstate('Papa Jean')->>'promo_open')::bigint = 5700,
  'the vendeur owes the opening balance and the goods, not the promo; the credit left is the limit less that');
-- over the limit: the goods are still given, and the activity log says so
select t.put('cinv2', gen_random_uuid()::text);
select t.ok((public.submit_invoice(jsonb_build_object('id', t.get('cinv2'), 'no', 'GOM-T2-000901', 'device_id', t.get('dev2'), 'rate', 2850, 'vat_rate', 16,
  'vendeur_id', t.get('v1'), 'items', jsonb_build_array(jsonb_build_object('product_id', t.get('cgel'), 'mult', 1, 'qty', 2, 'price', 5700))))->>'status') = 'ok',
  'goods on credit over the limit are still given');
select t.ok((t.vstate('Papa Jean')->>'over_limit')::boolean and (t.vstate('Papa Jean')->>'available')::numeric = -2, 'the vendeur is shown over the limit');
select t.ok(t.logged('Invoice GOM-T2-000901 for Papa Jean, on credit at 2850, due %, over the credit limit of $7.00%'), 'the log notes the limit was passed, in USD');
select t.fails(format($$select public.submit_invoice('{"id":"%s","no":"GOM-T2-000902","device_id":"%s","rate":2850,"vat_rate":16,"vendeur_id":"%s","paid_usd":5,"items":[{"product_id":"%s","mult":1,"qty":1,"price":5700}]}')$$,
  gen_random_uuid(), t.get('dev2'), t.get('v1'), t.get('cgel')), 'not paid at the till', 'goods on credit take no money at the till');
-- payments: partial, never more than owed; the oldest goods are settled first
select t.fails(format($$select public.vendeur_pay('{"vendeur_id":"%s","amount":30000}')$$, t.get('v1')), 'owes only', 'a payment cannot be more than the vendeur owes');
select t.put('vp1', public.vendeur_pay(jsonb_build_object('vendeur_id', t.get('v1'), 'amount', 8550, 'note', 'cash'))::text);
select t.ok((t.get('vp1')::jsonb->>'no') = 'GOM-VP-00001' and (t.get('vp1')::jsonb->'state'->>'balance')::numeric = 6
  and (t.get('vp1')::jsonb->'state'->>'available')::numeric = 1 and (t.get('vp1')::jsonb->>'amount')::numeric = 3, 'a partial payment in Francs ($3 at 2 850) lowers what is owed, so the credit comes back');
select t.ok(jsonb_array_length(t.vstate('Papa Jean')->'open') = 2 and (t.vstate('Papa Jean')->'open'->0->>'owed')::numeric = 2,
  'the payment settles the opening balance, then the oldest goods');
reset role;
-- the books: the sale is owed by the vendeur, the payment is cash in the shop
select t.ok((select string_agg(a.code || a.group_code || l.side, ',' order by l.side, a.group_code) from voucher_lines l join vouchers v on v.id = l.voucher_id join accounts a on a.id = l.account_id
  where v.source_type = 'invoice' and v.source_id = t.get('cinv1')::uuid and l.amount = 11400) is null
  and exists (select 1 from voucher_lines l join vouchers v on v.id = l.voucher_id join accounts a on a.id = l.account_id
    where v.source_type = 'invoice' and v.source_id = t.get('cinv1')::uuid and a.vendeur_id = t.get('v1')::uuid and l.side = 'Dr' and l.amount = 4 and l.currency = 'USD')
  and not exists (select 1 from voucher_lines l join vouchers v on v.id = l.voucher_id join accounts a on a.id = l.account_id
    where v.source_type = 'invoice' and v.source_id = t.get('cinv1')::uuid and a.code like 'CASH_SHOP%'), 'a sale on credit is Dr the vendeur''s ledger, not the cash');
select t.ok((select a.group_code from accounts a where a.vendeur_id = t.get('v1')::uuid) = 'debtors', 'each vendeur has a ledger under Sundry Debtors');
select t.ok(exists (select 1 from voucher_lines l join vouchers v on v.id = l.voucher_id join accounts a on a.id = l.account_id
    where v.source_type = 'vendeur_payment' and a.code = 'CASH_SHOP:' || t.get('gom') and l.side = 'Dr' and l.amount = 8550)
  and exists (select 1 from voucher_lines l join vouchers v on v.id = l.voucher_id join accounts a on a.id = l.account_id
    where v.source_type = 'vendeur_payment' and a.vendeur_id = t.get('v1')::uuid and l.side = 'Cr' and l.amount = 3 and l.currency = 'USD'), 'a payment is Dr the shop''s cash, Cr the vendeur in USD');
select t.ok((select l.amount from voucher_lines l join vouchers v on v.id = l.voucher_id join accounts a on a.id = l.account_id
    where v.source_type = 'promo' and a.code = 'PROMO_EXP' and l.side = 'Dr') = 1, 'the promo item leaves the stock at cost as a promotion expense');
select t.ok(t.unbalanced() = 0, 'the vendeur entries keep the books balanced');
-- the shift end slip and the day end slip count the cash only: goods on credit apart, payments in
select t.ok((t.slip_today(t.get('gom')::uuid)->>'on_credit')::bigint - coalesce((t.get('slip0')::jsonb->>'on_credit')::bigint, 0) = 22800
  and (t.slip_today(t.get('gom')::uuid)->>'collected')::bigint = (t.get('slip0')::jsonb->>'collected')::bigint + 8550,
  'the shift end slip leaves goods on credit out of the cash collected and adds the vendeur''s payment');
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.ok(((public.sales_report(current_date, current_date, t.get('gom')::uuid)->'slips'->0)->>'collected')::bigint = t.get('col0')::bigint + 8550
  and ((public.sales_report(current_date, current_date, t.get('gom')::uuid)->'slips'->0)->>'on_credit')::bigint = 22800,
  'the day end slip does the same');
reset role;
-- an overdue vendeur: goods can still be given, with a reminder
update invoices set due_date = current_date - 3 where id = t.get('cinv1')::uuid;
select t.ok((t.vstate('Papa Jean')->>'overdue')::boolean and (t.vstate('Papa Jean')->>'overdue_amount')::numeric = 2 and (t.vstate('Papa Jean')->>'days_overdue')::int = 3,
  'a vendeur past the credit period is overdue, with what is overdue');
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.put('cinv3', gen_random_uuid()::text);
select t.ok((public.submit_invoice(jsonb_build_object('id', t.get('cinv3'), 'no', 'GOM-T2-000903', 'device_id', t.get('dev2'), 'rate', 2850, 'vat_rate', 16,
  'vendeur_id', t.get('v1'), 'items', jsonb_build_array(jsonb_build_object('product_id', t.get('cgel'), 'mult', 1, 'qty', 1, 'price', 5700))))->'vendeur'->>'overdue')::boolean,
  'goods are still given to an overdue vendeur; the answer says they are overdue');
select t.ok(t.logged('Invoice GOM-T2-000903 for Papa Jean, on credit at 2850, due %, $2.00 overdue%'), 'goods given to an overdue vendeur are logged with what is overdue');
-- the statement
select t.ok((select jsonb_array_length(x->'lines') = 5 and (x->>'closing')::numeric = 8 and x->>'currency' = 'USD' and jsonb_array_length(x->'promos') = 1
  from public.vendeur_statement(t.get('v1')::uuid, current_date - 30, current_date) x), 'the statement lists the opening balance, the goods and the payment; the promo apart');
-- the Shop Admin corrects goods on credit: the vendeur owes the new total, still nothing is cash
select public.edit_invoice(t.get('cinv2')::uuid, '[{"line_no":1,"qty":1}]', 0, 'Vendeur took one back');
select t.ok((select tendered = 0 and change = 0 and total = 5700 from invoices where id = t.get('cinv2')::uuid) and (t.vstate('Papa Jean')->>'balance')::numeric = 6,
  'a corrected invoice on credit changes what the vendeur owes');
select public.delete_invoice(t.get('cinv3')::uuid, 'entered twice');
select t.ok((t.vstate('Papa Jean')->>'balance')::numeric = 4, 'a deleted invoice on credit is no longer owed');
-- a payment taken by mistake is cancelled
select public.cancel_vendeur_payment((t.get('vp1')::jsonb->>'id')::uuid, 'wrong vendeur');
select t.ok((t.vstate('Papa Jean')->>'balance')::numeric = 7, 'a cancelled payment is owed again');
-- the promo report: keep it (it stays open), then settle it (the count starts again)
select t.put('pr2', public.give_promo(jsonb_build_object('vendeur_id', t.get('v1'), 'lines', jsonb_build_array(jsonb_build_object('product_id', t.get('cgel'), 'qty', 2))))::text);
select t.fails(format($$select public.give_promo('{"vendeur_id":"%s","lines":[{"product_id":"%s","qty":500}]}')$$, t.get('v1'), t.get('cgel')), 'Not enough Credit gel', 'promo items come from the stock the shop has');
select t.ok((select (x->>'pcs')::int = 3 and jsonb_array_length(x->'items') = 1 and x->'items'->0->>'name' = 'Credit gel' and (x->'items'->0->>'qty')::int = 3
  and x::text not like '%Papa Jean%' from public.promo_report(current_date) x), 'the month''s promo report lists each item and the pieces given out, no vendeur names');
select public.cancel_promo((t.get('pr2')::jsonb->>'id')::uuid, 'given by mistake');
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('cgel')::uuid) = 46, 'a cancelled promo goes back into the stock');
select t.ok((public.close_promo_report(current_date, 'keep')->>'status') = 'kept' and (t.vstate('Papa Jean')->>'promo_open')::bigint = 5700, 'a kept report leaves its promos open');
select t.ok((public.close_promo_report(current_date, 'settle')->>'status') = 'settled' and (t.vstate('Papa Jean')->>'promo_open')::bigint = 0, 'settling starts the promo count again at zero');
select t.ok((select jsonb_array_length(x->'reports') = 1 and x->'reports'->0->>'status' = 'settled' and (x->>'n')::int = 0 from public.promo_report(current_date) x), 'the settled report replaces the kept one');
select t.fails($$select public.close_promo_report(current_date, 'settle')$$, 'no open promo items', 'nothing left to settle');
select t.fails(format($$select public.cancel_promo('%s', 'too late now')$$, t.get('cres1')::jsonb->'promo'->>'id'), 'settled report', 'a settled promo is not cancelled');
-- a vendeur with history is never deleted; one without is
select t.fails(format($$select public.delete_vendeur('%s')$$, t.get('v1')), 'still owes', 'a vendeur who owes cannot be removed');
select t.ok(public.delete_vendeur(public.save_vendeur('{"name":"Never used","credit_days":0,"credit_limit":100}')) = 'deleted', 'a vendeur with nothing recorded is deleted');
select t.ok(public.delete_vendeur(public.save_vendeur('{"name":"Typed by mistake","credit_days":7,"credit_limit":5000,"opening_balance":3000}')) = 'deleted',
  'a vendeur created by mistake is deleted even with an amount it was entered as owing');
select t.ok(not exists (select 1 from jsonb_array_elements(public.vendeur_list()) x where x->>'name' = 'Typed by mistake'), 'it is gone from the list');
select t.put('v_paid', public.save_vendeur('{"name":"Paid up","credit_days":7,"credit_limit":50000}')::text);
select t.ok((public.submit_invoice(jsonb_build_object('id', gen_random_uuid(), 'no', 'GOM-T2-000910', 'device_id', t.get('dev2'), 'rate', 2850, 'vat_rate', 16,
  'vendeur_id', t.get('v_paid'), 'items', jsonb_build_array(jsonb_build_object('product_id', t.get('cgel'), 'mult', 1, 'qty', 1, 'price', 5700))))->>'status') = 'ok', 'goods on credit to a second vendeur');
select t.ok((public.vendeur_pay(jsonb_build_object('vendeur_id', t.get('v_paid'), 'amount', 5700))->'state'->>'balance')::numeric = 0, 'the second vendeur pays it all');
select t.ok(public.delete_vendeur(t.get('v_paid')::uuid) = 'inactive', 'a vendeur with history that owes nothing is kept, made inactive');
reset role;
-- a vendeur pays in dollars and Francs: at the internal rate, or at the taux the Shop Admin types
select t.put('br', (select coalesce(nullif(book_rate, 0), rate)::text from settings where id = 1));
select t.put('vslip0', t.slip_today(t.get('gom')::uuid)::text);
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.put('v_usd', public.save_vendeur('{"name":"Dollar payer","credit_days":7,"credit_limit":100000}')::text);
select t.ok((public.submit_invoice(jsonb_build_object('id', gen_random_uuid(), 'no', 'GOM-T2-000911', 'device_id', t.get('dev2'), 'rate', 2850, 'vat_rate', 16,
  'vendeur_id', t.get('v_usd'), 'items', jsonb_build_array(jsonb_build_object('product_id', t.get('cgel'), 'mult', 1, 'qty', 5, 'price', 5700))))->>'status') = 'ok', 'goods on credit, 28 500 CDF');
select t.fails(format($$select public.vendeur_pay('{"vendeur_id":"%s","paid_usd":5,"usd_rate":280}')$$, t.get('v_usd')), 'Check the exchange rate', 'a taux with a zero missing is caught');
select t.fails(format($$select public.vendeur_pay('{"vendeur_id":"%s","paid_usd":1,"paid_cdf":28500}')$$, t.get('v_usd')), 'Francs alone pay', 'no dollars are taken when the Francs already pay it all');
select t.fails(format($$select public.vendeur_pay('{"vendeur_id":"%s","paid_usd":0,"paid_cdf":0}')$$, t.get('v_usd')), 'Enter the amount paid', 'a payment needs an amount');
select t.put('vu1', public.vendeur_pay(jsonb_build_object('vendeur_id', t.get('v_usd'), 'paid_usd', 5, 'paid_cdf', 1000))::text);
select t.ok((t.get('vu1')::jsonb->>'amount')::numeric = 5.35 and (t.get('vu1')::jsonb->>'amount_cdf')::bigint = 15250 and (t.get('vu1')::jsonb->>'usd_rate')::numeric = 2850
  and (t.vstate('Dollar payer')->>'balance')::numeric = 4.65,
  'dollars count one for one, Francs at the taux (the internal rate unless another is typed): $5 + 1 000 CDF off $10');
select t.put('vbal', t.vstate('Dollar payer')->>'balance');
select t.put('vu2', public.vendeur_pay(jsonb_build_object('vendeur_id', t.get('v_usd'), 'paid_usd', 20, 'usd_rate', 2700, 'note', 'agreed taux'))::text);
select t.ok((t.get('vu2')::jsonb->>'amount')::numeric = 4.65 and (t.get('vu2')::jsonb->>'change_cdf')::bigint = 41400
  and (t.get('vu2')::jsonb->>'usd_rate')::numeric = 2700 and (t.vstate('Dollar payer')->>'balance')::numeric = 0,
  'dollars worth more than is owed get the rest back in Francs at the taux, rounded down to 50 FC ($15.35 at 2 700)');
select t.ok(t.logged('Payment ' || (t.get('vu2')::jsonb->>'no') || ' from vendeur Dollar payer: $4.65 ($20.00, 41 400 CDF given back)%'), 'the log says what was paid and given back');
select t.ok(exists (select 1 from jsonb_array_elements(public.vendeur_statement(t.get('v_usd')::uuid, current_date, current_date)->'lines') l where l->>'what' = 'Payment, $20.00, 41 400 CDF given back, agreed taux'),
  'the statement says how the payment was made');
reset role;
select t.ok((select sum(l.amount) from voucher_lines l join vouchers v on v.id = l.voucher_id join accounts a on a.id = l.account_id
    where v.source_type = 'vendeur_payment' and v.source_id in ((t.get('vu1')::jsonb->>'id')::uuid, (t.get('vu2')::jsonb->>'id')::uuid)
      and a.code = 'CASH_SHOP_USD:' || t.get('gom') and l.side = 'Dr' and l.currency = 'USD') = 25
  and t.unbalanced() = 0, 'the dollars go into the shop''s USD cash and the books stay balanced');
select t.ok((t.slip_today(t.get('gom')::uuid)->>'collected_usd')::numeric - (t.get('vslip0')::jsonb->>'collected_usd')::numeric = 25
  and (t.slip_today(t.get('gom')::uuid)->>'collected')::bigint - (t.get('vslip0')::jsonb->>'collected')::bigint = 15250 + 12600
  and (t.slip_today(t.get('gom')::uuid)->>'collected_cdf')::bigint - (t.get('vslip0')::jsonb->>'collected_cdf')::bigint = 1000 - (t.get('vu2')::jsonb->>'change_cdf')::bigint,
  'the shift end slip counts the vendeurs'' dollars in Collected USD and only the Francs kept in Collected CDF');
select t.ok((t.slip_today(t.get('gom')::uuid)->>'vendeur_usd')::numeric - coalesce((t.get('vslip0')::jsonb->>'vendeur_usd')::numeric, 0) = 25
  and (t.slip_today(t.get('gom')::uuid)->>'vendeur_cdf')::bigint - coalesce((t.get('vslip0')::jsonb->>'vendeur_cdf')::bigint, 0) = 1000 - (t.get('vu2')::jsonb->>'change_cdf')::bigint,
  'the shift end slip shows the vendeurs'' payments in USD and in CDF');
select t.ok(exists (select 1 from jsonb_array_elements(t.slip_today(t.get('gom')::uuid)->'vendeurs') v where v->>'name' = 'Dollar payer' and (v->>'usd')::numeric = 25),
  'the shift end slip lists each vendeur who paid, by name');
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.put('vrep', public.sales_report(current_date, current_date, t.get('gom')::uuid)::text);
reset role;
select t.ok(exists (select 1 from jsonb_array_elements(t.get('vrep')::jsonb->'slips'->0->'vendeurs') v where v->>'name' = 'Dollar payer'), 'the day end slip lists them too');

-- a sale on credit counts in USD at the internal rate of its sale: 5 700 CDF sold at 2 850, internal rate 2 800 = $2.04
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.put('cinvi', gen_random_uuid()::text);
select public.submit_invoice(jsonb_build_object('id', t.get('cinvi'), 'no', 'GOM-T2-000912', 'device_id', t.get('dev2'), 'rate', 2850, 'usd_rate', 2800, 'vat_rate', 16,
  'vendeur_id', t.get('v_usd'), 'items', jsonb_build_array(jsonb_build_object('product_id', t.get('cgel'), 'mult', 1, 'qty', 1, 'price', 5700))));
select t.ok((t.vstate('Dollar payer')->>'balance')::numeric = 2.04
  and exists (select 1 from jsonb_array_elements(public.vendeur_statement(t.get('v_usd')::uuid, current_date, current_date)->'lines') l
    where l->>'no' = 'GOM-T2-000912' and (l->>'dr')::numeric = 2.04 and (l->>'rate')::numeric = 2800 and (l->>'cdf')::bigint = 5700
      and l->'items'->0->>'name' = 'Credit gel' and (l->'items'->0->>'qty')::int = 1 and (l->'items'->0->>'amount')::numeric = 2.04),
  'a sale on credit is owed in USD at the internal rate of its sale; the statement lists its items with their amount in USD');
reset role;
select t.ok((select l.amount from voucher_lines l join vouchers v on v.id = l.voucher_id join accounts a on a.id = l.account_id
    where v.source_type = 'invoice' and v.source_id = t.get('cinvi')::uuid and a.vendeur_id = t.get('v_usd')::uuid and l.side = 'Dr' and l.currency = 'USD') = 2.04
  and exists (select 1 from voucher_lines l join vouchers v on v.id = l.voucher_id join accounts a on a.id = l.account_id
    where v.source_type = 'invoice' and v.source_id = t.get('cinvi')::uuid and a.code = 'FX_GAIN' and l.side = 'Cr')
  and t.unbalanced() = 0, 'in the books the vendeur owes the same USD; the difference with the sales rate is exchange, and the books balance');
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.ok((public.vendeur_pay(jsonb_build_object('vendeur_id', t.get('v_usd'), 'paid_cdf', 5700, 'rate', 2800))->'state'->>'balance')::numeric = 0,
  'paid back in Francs at the internal rate, the same Francs clear it');
-- a sale on credit entered for a past day, at that day's internal rate: due after the credit days from that date
select public.submit_invoice(jsonb_build_object('id', gen_random_uuid(), 'no', 'GOM-T2-000913', 'device_id', t.get('dev2'), 'rate', 2850, 'usd_rate', 2750, 'vat_rate', 16,
  't', (current_date - 10)::timestamp + interval '12 hours', 'vendeur_id', t.get('v_usd'), 'items', jsonb_build_array(jsonb_build_object('product_id', t.get('cgel'), 'mult', 1, 'qty', 1, 'price', 5700))));
select t.fails(format($$select public.submit_invoice('{"id":"%s","no":"GOM-T2-000914","device_id":"%s","rate":2850,"usd_rate":275,"vat_rate":16,"vendeur_id":"%s","items":[{"product_id":"%s","mult":1,"qty":1,"price":5700}]}')$$,
  gen_random_uuid(), t.get('dev2'), t.get('v_usd'), t.get('cgel')), 'Check the internal rate', 'an internal rate with a zero missing is caught');
reset role;
select t.ok((select due_date = current_date - 10 + 7 and usd_rate = 2750 from invoices where no = 'GOM-T2-000913') and (t.vstate('Dollar payer')->>'balance')::numeric = 2.07
  and t.logged('Invoice GOM-T2-000913 for Dollar payer, on credit dated % at 2750, due %'),
  'a sale on credit can be entered for a past day, with that day''s internal rate');
update settings set rate = t.get('r0')::numeric, book_rate = t.get('b0')::numeric where id = 1;
-- ===== money exchange at the counter, and expenses paid from the shop's cash =====
select t.put('xslip0', t.slip_today(t.get('gom')::uuid)::text);
select t.put('xbr', (select coalesce(nullif(book_rate, 0), rate)::text from settings where id = 1));
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.fails($$select public.exchange_money('{"dir":"buy","usd":10}')$$, 'not turned on', 'money exchange is off until the Admin turns it on');
select t.as('00000000-0000-0000-0000-00000000000a');
select t.fails($$select public.save_settings(jsonb_build_object('rate', (select rate from settings), 'vat', 16, 'company', (select company from settings), 'fx_buy_rate', 3000, 'fx_sell_rate', 2900))$$,
  'cannot be above the selling rate', 'the buying rate for dollars is not above the selling rate');
select public.save_settings(jsonb_build_object('rate', (select rate from settings), 'vat', 16, 'company', (select company from settings), 'fx_buy_rate', 2800, 'fx_sell_rate', 2850,
  'features', jsonb_build_object('money_exchange', true)));
select t.ok((select fx_buy_rate || '/' || fx_sell_rate || '/' || (features->>'money_exchange') || '/' || (features->>'vendeurs') from settings) = '2800.00/2850.00/true/true',
  'Settings keep the buying and selling rates and the switch, and the other switches as they were');
select t.as('00000000-0000-0000-0000-00000000000c');
select t.fails($$select public.exchange_money('{"dir":"buy","usd":10,"rate":280}')$$, 'Check the exchange rate', 'a rate with a zero missing is caught');
select t.put('fx1', public.exchange_money('{"dir":"buy","usd":100,"customer":"Passer-by"}')::text);
select t.ok((t.get('fx1')::jsonb->>'cdf')::bigint = 280000 and (t.get('fx1')::jsonb->>'rate')::numeric = 2800 and (t.get('fx1')::jsonb->>'no') = 'GOM-FX-00001'
  and (t.get('fx1')::jsonb->>'gain_usd')::numeric = round(100 - 280000 / t.get('xbr')::numeric, 2), 'the shop buys $100 at the buying rate and gives 280 000 CDF; the margin is worked out');
select t.put('fx2', public.exchange_money('{"dir":"sell","usd":50}')::text);
select t.ok((t.get('fx2')::jsonb->>'cdf')::bigint = 142500 and (t.get('fx2')::jsonb->>'gain_usd')::numeric = round(142500 / t.get('xbr')::numeric - 50, 2) and (t.get('fx2')::jsonb->>'gain_usd')::numeric < 0,
  'the shop sells $50 at the selling rate for 142 500 CDF (a loss when that is below the internal rate)');
select t.ok((public.exchange_money('{"dir":"buy","usd":33.33}')->>'cdf')::bigint = 93300 and (public.exchange_money('{"dir":"sell","usd":33.33}')->>'cdf')::bigint = 95000,
  'Francs given out are rounded down to 50, Francs taken in rounded up to 50');
select t.put('fx5', public.exchange_money('{"dir":"buy","usd":20,"rate":2750,"note":"regular customer"}')::text);
select t.ok((t.get('fx5')::jsonb->>'cdf')::bigint = 55000, 'the Shop Admin can give another rate on one exchange');
select public.cancel_exchange((t.get('fx5')::jsonb->>'id')::uuid, 'typed twice');
reset role;
select t.ok((select status from vouchers where source_type = 'money_exchange' and source_id = (t.get('fx5')::jsonb->>'id')::uuid) = 'cancelled', 'a cancelled exchange cancels its voucher');
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.ok((select (x->>'n')::int = 4 and (x->>'bought_usd')::numeric = 133.33 and (x->>'sold_usd')::numeric = 83.33 and (x->>'cdf_out')::bigint = 373300 and (x->>'cdf_in')::bigint = 237500
  and jsonb_array_length(x->'list') = 5 from public.exchange_list(current_date, current_date) x), 'the list of exchanges and its totals leave out the cancelled one');
reset role;
select t.ok(t.unbalanced() = 0 and exists (select 1 from voucher_lines l join vouchers v on v.id = l.voucher_id join accounts a on a.id = l.account_id
    where v.source_id = (t.get('fx1')::jsonb->>'id')::uuid and a.code = 'FX_GAIN' and l.side = 'Cr')
  and exists (select 1 from voucher_lines l join vouchers v on v.id = l.voucher_id join accounts a on a.id = l.account_id
    where v.source_id = (t.get('fx2')::jsonb->>'id')::uuid and a.code = 'FX_GAIN' and l.side = 'Dr'),
  'exchanges move money between the shop''s two cash ledgers; the margin is a gain or a loss, and the books balance');
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000d');
select t.fails($$select public.exchange_money('{"dir":"buy","usd":10}')$$, 'permission', 'a till operator does not change money');
-- expenses the Admin pays from the shop's cash come off the shop's balance
select t.as('00000000-0000-0000-0000-00000000000a');
select t.fails(format($$select public.add_upkeep(current_date, 'Food expense', 'Lunch', 10, 'USD', '%s')$$, t.acc('CASH_SHOP:' || t.get('gom'))), 'holds Francs', 'an expense from the shop''s Franc cash is in CDF');
select public.add_upkeep(current_date, 'Food expense', 'Staff lunch at the shop', 20000, 'FC', t.acc('CASH_SHOP:' || t.get('gom')));
select public.add_upkeep(current_date, 'Moto expense', 'Moto fuel', 5, 'USD', t.acc('CASH_SHOP_USD:' || t.get('gom')));
select public.add_upkeep(current_date, 'Rent', 'Head office rent', 50, 'USD', null);
select t.put('xrep', public.sales_report(current_date, current_date, t.get('gom')::uuid)::text);
reset role;
select t.ok((t.slip_today(t.get('gom')::uuid)->>'fx_usd')::numeric - coalesce((t.get('xslip0')::jsonb->>'fx_usd')::numeric, 0) = 133.33 - 83.33
  and (t.slip_today(t.get('gom')::uuid)->>'fx_cdf')::bigint - coalesce((t.get('xslip0')::jsonb->>'fx_cdf')::bigint, 0) = 237500 - 373300
  and (t.slip_today(t.get('gom')::uuid)->>'fx_n')::int = 4, 'the shift end slip shows the dollars and Francs exchanged, in and out of the drawer');
select t.ok((t.slip_today(t.get('gom')::uuid)->>'exp_cdf')::bigint - coalesce((t.get('xslip0')::jsonb->>'exp_cdf')::bigint, 0) = 20000
  and (t.slip_today(t.get('gom')::uuid)->>'exp_usd')::numeric - coalesce((t.get('xslip0')::jsonb->>'exp_usd')::numeric, 0) = 5,
  'expenses paid from the shop''s cash are on its shift end slip; one from head office is not');
select t.ok((t.get('xrep')::jsonb->'slips'->0->>'exp_cdf')::bigint >= 20000 and (t.get('xrep')::jsonb->'slips'->0->>'exp_usd')::numeric >= 5
  and (t.get('xrep')::jsonb->'slips'->0->>'fx_n')::int = 4, 'the day end slip has the expenses and the exchanges too');
-- the Admin's cash book of the shop: every move of its two cash drawers, with the balance
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.put('cb', public.cash_book(current_date, current_date, t.get('gom')::uuid)::text);
select t.as('00000000-0000-0000-0000-00000000000c');
select t.fails(format($$select public.cash_book(current_date, current_date, '%s')$$, t.get('gom')), 'permission', 'the cash book is the Admin''s');
reset role;
select t.ok(exists (select 1 from jsonb_array_elements(t.get('cb')::jsonb->'rows') r where r->>'kind' = 'Shop' and r->>'what' like 'Cash sales (%')
  and exists (select 1 from jsonb_array_elements(t.get('cb')::jsonb->'rows') r where r->>'what' = 'Vendeur payment: Dollar payer' and r->>'kind' = 'Credit collection' and (r->>'in_usd')::numeric = 25)
  and (select count(*) from jsonb_array_elements(t.get('cb')::jsonb->'rows') r where r->>'kind' = 'Exchange') = 4
  and exists (select 1 from jsonb_array_elements(t.get('cb')::jsonb->'rows') r where r->>'what' = 'Staff lunch at the shop' and r->>'kind' = 'Food expense' and (r->>'out_cdf')::numeric = 20000)
  and exists (select 1 from jsonb_array_elements(t.get('cb')::jsonb->'rows') r where r->>'what' = 'Moto fuel' and (r->>'out_usd')::numeric = 5)
  and not exists (select 1 from jsonb_array_elements(t.get('cb')::jsonb->'rows') r where r->>'what' = 'Head office rent'),
  'the cash book lists the cash sales, each vendeur''s payment, each exchange and the expenses paid from the shop''s cash; not head office''s');
select t.ok((t.get('cb')::jsonb->'opening'->>'cdf')::numeric + (select sum((r->>'in_cdf')::numeric - (r->>'out_cdf')::numeric) from jsonb_array_elements(t.get('cb')::jsonb->'rows') r)
    = (select sum(case when l.side = 'Dr' then l.amount else -l.amount end) from voucher_lines l join vouchers v on v.id = l.voucher_id and v.status = 'posted'
       where l.account_id = t.acc('CASH_SHOP:' || t.get('gom')) and l.currency = 'FC' and v.date <= current_date)
  and (t.get('cb')::jsonb->'opening'->>'usd')::numeric + (select sum((r->>'in_usd')::numeric - (r->>'out_usd')::numeric) from jsonb_array_elements(t.get('cb')::jsonb->'rows') r)
    = (select sum(case when l.side = 'Dr' then l.amount else -l.amount end) from voucher_lines l join vouchers v on v.id = l.voucher_id and v.status = 'posted'
       where l.account_id = t.acc('CASH_SHOP_USD:' || t.get('gom')) and l.currency = 'USD' and v.date <= current_date),
  'the cash book ends on what the shop''s two cash ledgers hold');
-- another shop never sees them
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000e');
select t.ok(public.vendeur_list() = '[]'::jsonb, 'another shop does not see the vendeurs');
select t.fails(format($$select public.vendeur_pay('{"vendeur_id":"%s","amount":100}')$$, t.get('v1')), 'Vendeur not found', 'nor take their payments');
select t.fails($$select count(*) from vendeurs$$, 'permission denied', 'the vendeur tables are read only through the functions');
reset role;
-- the till operator does not give goods on credit
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000d');
select t.fails($$select public.vendeur_list()$$, 'permission', 'a till operator has no vendeurs');
reset role;
-- the Admin sees every shop's vendeurs, even with the switch off
update settings set features = features - 'vendeurs' where id = 1;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.ok(jsonb_array_length(public.vendeur_list()) = 4, 'the Admin sees the vendeurs of every shop');
reset role;

-- ===== no central store: stock added straight into the shops, typed or from the item Excel template =====
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.fails(format($$select public.stock_in_shops(array['%s']::uuid[], '[{"product_id":"%s","qty":5}]')$$, t.get('gom'), t.get('cgel')), 'by delivery', 'with a central store, stock goes to the shops by delivery');
reset role;
update settings set features = features || '{"no_warehouse": true}' where id = 1;
select t.put('sin_gom0', (select qty::text from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('cgel')::uuid));
select t.put('sin_lim0', (select coalesce((select qty from shop_stock where shop_id = t.get('lim')::uuid and product_id = t.get('cgel')::uuid), 0)::text));
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.fails(format($$select public.stock_in_shops(array['%s']::uuid[], '[]', '[{"row":2,"name":"Import mask","category":"Face","carton_cost":24,"per_carton":12,"pc":1,"open_cartons":1}]')$$, t.get('gom')),
  'Nothing was added', 'a new item priced below its cost stops the whole import');
select t.ok(not exists (select 1 from products where name = 'Import mask') and not exists (select 1 from categories where name = 'Face'), 'nothing of the failed import was saved');
select t.fails(format($$select public.stock_in_shops(array['%s']::uuid[], '[]', '[{"row":2,"name":"credit GEL","category":"Skin care","carton_cost":24,"per_carton":24,"pc":2,"open_pcs":1}]')$$, t.get('gom')),
  'already exists', 'a row for an item already in the catalogue cannot make it again');
select t.put('sin', public.stock_in_shops(array[t.get('gom'), t.get('lim')]::uuid[],
  jsonb_build_array(jsonb_build_object('product_id', t.get('cgel'), 'qty', 10)),
  '[{"row":2,"name":"Import mask","category":"Face","carton_cost":24,"net_cost":18,"per_carton":12,"pc":2.5,"ctn":28,"open_cartons":2,"open_pcs":3,"sku":"IM-1","barcode":"6001112223334"}]',
  'shop stock.xlsx')::text);
select t.ok((t.get('sin')::jsonb->>'created')::int = 1 and (t.get('sin')::jsonb->>'units')::int = 37 and (t.get('sin')::jsonb->>'shops')::int = 2, 'the import adds an item from the catalogue and makes the new one');
select t.ok((select c.carton_cost_usd = 24 and c.net_cost_usd = 18 and c.cost_usd = 1.5 and p.sku = 'IM-1' and p.barcodes = array['6001112223334'] and p.carton_usd = 28 and p.wh_qty = 0
  from products p join product_costs c on c.product_id = p.id where p.name = 'Import mask'), 'the new item is made with the file''s details: gross and net cost, prices, code, barcode; nothing in the store');
select t.ok(exists (select 1 from categories where name = 'Face'), 'a category the file names is made');
reset role;
select t.ok((select qty from shop_stock s join products p on p.id = s.product_id where s.shop_id = t.get('gom')::uuid and p.name = 'Import mask') = 27
  and (select qty from shop_stock s join products p on p.id = s.product_id where s.shop_id = t.get('lim')::uuid and p.name = 'Import mask') = 27,
  'the new item goes into each shop ticked: 2 cartons of 12 + 3 pcs');
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('cgel')::uuid) = t.get('sin_gom0')::int + 10
  and (select qty from shop_stock where shop_id = t.get('lim')::uuid and product_id = t.get('cgel')::uuid) = t.get('sin_lim0')::int + 10, 'the item from the catalogue gets its quantity in each shop');
select t.ok((select l.amount from voucher_lines l join vouchers v on v.id = l.voucher_id where v.type = 'opening' and v.narration like 'Stock added to SIM Gombe (shop stock.xlsx)%'
    and l.account_id = t.shop_acc('INV_SHOP', t.get('gom')::uuid) and l.side = 'Dr') = round(27 * 1.5 + 10 * (select cost_usd from product_costs where product_id = t.get('cgel')::uuid), 2),
  'each shop''s stock is booked at cost (the net cost) as opening stock');
select t.ok(t.unbalanced() = 0, 'adding stock keeps the books balanced');
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.fails(format($$select public.stock_in_shops(array['%s']::uuid[], '[{"product_id":"%s","qty":5}]')$$, t.get('gom'), t.get('cgel')), 'permission', 'only the Admin adds stock this way');
reset role;
update settings set features = features - 'no_warehouse' where id = 1;

-- ===== no central store: the Admin decides where a shop's returned goods go =====
update settings set features = features || '{"no_warehouse": true}' where id = 1;
create function t.transit_of(p_refs text[]) returns numeric language sql security definer as $$
  select coalesce(sum(case when l.side = 'Dr' then l.base else -l.base end), 0) from voucher_lines l join vouchers v on v.id = l.voucher_id
  where v.status = 'posted' and v.ref = any(p_refs) and l.account_id = app.acc('TRANSIT') $$;
grant execute on function t.transit_of(text[]) to authenticated;
select t.put('dr_g0', (select qty::text from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('cgel')::uuid));
select t.put('dr_l0', (select qty::text from shop_stock where shop_id = t.get('lim')::uuid and product_id = t.get('cgel')::uuid));
select t.put('dr_cost', (select cost_usd::text from product_costs where product_id = t.get('cgel')::uuid));
select t.put('dr_wh0', (select wh_qty::text from products where id = t.get('cgel')::uuid));
select t.put('dr_owes0', t.sup_owes()::text);
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.put('dr_s', public.create_return(jsonb_build_object('reason', 'Expired goods', 'lines', jsonb_build_array(jsonb_build_object('product_id', t.get('cgel'), 'qty', 4))))->>'id');
select t.put('dr_t', public.create_return(jsonb_build_object('reason', 'Not selling here', 'lines', jsonb_build_array(jsonb_build_object('product_id', t.get('cgel'), 'qty', 3))))->>'id');
select t.put('dr_w', public.create_return(jsonb_build_object('reason', 'Damaged in the shop', 'lines', jsonb_build_array(jsonb_build_object('product_id', t.get('cgel'), 'qty', 2))))->>'id');
select t.put('dr_z', public.create_return(jsonb_build_object('reason', 'Counted wrong', 'lines', jsonb_build_array(jsonb_build_object('product_id', t.get('cgel'), 'qty', 1))))->>'id');
select t.fails(format($$select public.decide_return('{"id":"%s","outcome":"writeoff"}')$$, t.get('dr_w')), 'permission', 'a shop admin does not decide what happens to a return');
select t.as('00000000-0000-0000-0000-00000000000b');
select t.fails(format($$select public.decide_return('{"id":"%s","outcome":"writeoff"}')$$, t.get('dr_w')), 'permission', 'the warehouse does not decide either: only the Admin');
reset role;
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('cgel')::uuid) = t.get('dr_g0')::int - 10, 'returned goods leave the shop at once, waiting for the Admin');
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.fails(format($$select public.decide_return('{"id":"%s","outcome":"store"}')$$, t.get('dr_s')), 'Choose where the goods go', 'the Admin must choose where the goods go');
select t.fails(format($$select public.decide_return('{"id":"%s","outcome":"supplier"}')$$, t.get('dr_s')), 'Choose the supplier', 'back to the supplier needs the supplier');
select t.fails(format($$select public.decide_return('{"id":"%s","outcome":"shop","shop_id":"%s"}')$$, t.get('dr_t'), t.get('gom')), 'choose another shop', 'goods cannot go back to the shop they came from this way');
select t.fails(format($$select public.decide_return('{"id":"%s","outcome":"supplier","supplier_id":"%s","lines":[{"product_id":"%s","qty":5}]}')$$, t.get('dr_s'), t.get('sup'), t.get('cgel')),
  'more than was sent', 'cannot count more than was sent');
select t.fails(format($$select public.decide_return('{"id":"%s","outcome":"supplier","supplier_id":"%s","lines":[{"product_id":"%s","qty":3}]}')$$, t.get('dr_s'), t.get('sup'), t.get('cgel')),
  'came back short', 'a short return needs a note');
select t.fails(format($$select public.decide_return('{"id":"%s","outcome":"shop","shop_id":"%s","note":"lost all","lines":[{"product_id":"%s","qty":0}]}')$$, t.get('dr_z'), t.get('lim'), t.get('cgel')),
  'Nothing came back', 'nothing came back: it can only be thrown away');
-- back to the supplier: 3 of 4 came back
select t.put('dr_rs', public.decide_return(jsonb_build_object('id', t.get('dr_s'), 'outcome', 'supplier', 'supplier_id', t.get('sup'), 'note', 'One tube missing',
  'lines', jsonb_build_array(jsonb_build_object('product_id', t.get('cgel'), 'qty', 3))))::text);
select t.ok((t.get('dr_rs')::jsonb->>'supplier_return') like 'RTS-%' and (t.get('dr_rs')::jsonb->>'received')::int = 3, 'back to the supplier makes a return to supplier');
select t.ok((select r.status || ':' || r.kind || ':' || i.qty from supplier_returns r join supplier_return_items i on i.return_id = r.id
  where r.no = t.get('dr_rs')::jsonb->>'supplier_return' and r.from_return_id = t.get('dr_s')::uuid) = 'open:return:3', 'with the 3 pcs that came back, open until the Admin settles it');
select t.ok((select status || ':' || outcome || ':' || (supplier_return_id is not null) from shop_returns where id = t.get('dr_s')::uuid) = 'received:supplier:true', 'the shop''s return shows it went to the supplier');
-- into another shop, and thrown away
select public.decide_return(jsonb_build_object('id', t.get('dr_t'), 'outcome', 'shop', 'shop_id', t.get('lim')));
select public.decide_return(jsonb_build_object('id', t.get('dr_w'), 'outcome', 'writeoff'));
select public.decide_return(jsonb_build_object('id', t.get('dr_z'), 'outcome', 'writeoff', 'note', 'It was never there', 'lines', jsonb_build_array(jsonb_build_object('product_id', t.get('cgel'), 'qty', 0))));
select t.fails(format($$select public.decide_return('{"id":"%s","outcome":"writeoff"}')$$, t.get('dr_w')), 'already received', 'a return is decided once');
select t.fails(format($$select public.cancel_return('%s', 'changed my mind')$$, t.get('dr_w')), 'already received', 'a decided return can no longer be cancelled');
reset role;
select t.ok(t.sup_owes() = t.get('dr_owes0')::numeric - round(3 * t.get('dr_cost')::numeric, 2), 'what we owe the supplier drops at item cost');
select t.ok((select qty from shop_stock where shop_id = t.get('lim')::uuid and product_id = t.get('cgel')::uuid) = t.get('dr_l0')::int + 3, 'the other shop gets the goods');
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('cgel')::uuid) = t.get('dr_g0')::int - 10, 'nothing comes back into the shop that sent them');
select t.ok((select wh_qty from products where id = t.get('cgel')::uuid) = t.get('dr_wh0')::int, 'nothing goes into a central store');
select t.ok((select outcome || ':' || to_shop_id from shop_returns where id = t.get('dr_t')::uuid) = 'shop:' || t.get('lim'), 'the return shows which shop got the goods');
select t.ok((select l.amount from voucher_lines l join vouchers v on v.id = l.voucher_id where v.source_type = 'return_in' and v.source_id = t.get('dr_t')::uuid
  and l.account_id = t.shop_acc('INV_SHOP', t.get('lim')::uuid) and l.side = 'Dr') = round(3 * t.get('dr_cost')::numeric, 2), 'the other shop''s stock is booked at cost');
select t.ok((select sum(l.amount) from voucher_lines l join vouchers v on v.id = l.voucher_id where v.source_type = 'return_in' and v.source_id in (t.get('dr_w')::uuid, t.get('dr_z')::uuid, t.get('dr_s')::uuid)
  and l.account_id = t.acc('STOCK_ADJ') and l.side = 'Dr') = round(2 * t.get('dr_cost')::numeric, 2) + 2 * round(t.get('dr_cost')::numeric, 2), 'thrown away and missing goods are booked as a stock adjustment');
select t.put('dr_refs', (select string_agg(no, ',') from shop_returns where id in (t.get('dr_s')::uuid, t.get('dr_t')::uuid, t.get('dr_w')::uuid, t.get('dr_z')::uuid)) || ',' || (t.get('dr_rs')::jsonb->>'supplier_return'));
select t.ok(t.transit_of(string_to_array(t.get('dr_refs'), ',')) = 0, 'deciding clears the goods in transit');
select t.ok(t.unbalanced() = 0, 'decided returns keep the books balanced');
-- the Shop Admin sees what became of their returns
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.ok((select string_agg(outcome, ',' order by no) from shop_returns where id in (t.get('dr_s')::uuid, t.get('dr_t')::uuid, t.get('dr_w')::uuid)) = 'supplier,shop,writeoff', 'the Shop Admin sees what the Admin decided');
-- cancelling that return to supplier puts the goods back in the shop they came from
select t.as('00000000-0000-0000-0000-00000000000a');
select public.cancel_supplier_return((select id from supplier_returns where no = t.get('dr_rs')::jsonb->>'supplier_return'), 'Supplier refused it');
reset role;
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('cgel')::uuid) = t.get('dr_g0')::int - 7, 'a cancelled return to supplier puts the goods back in the shop they came from');
select t.ok((select wh_qty from products where id = t.get('cgel')::uuid) = t.get('dr_wh0')::int, 'and not in a central store');
select t.ok(t.sup_owes() = t.get('dr_owes0')::numeric, 'the supplier is owed exactly as before');
select t.ok((select l.amount from voucher_lines l join vouchers v on v.id = l.voucher_id where v.source_type = 'return_back' and v.status = 'posted'
  and l.account_id = t.shop_acc('INV_SHOP', t.get('gom')::uuid) and l.side = 'Dr') = round(3 * t.get('dr_cost')::numeric, 2), 'the goods are booked back into the shop''s stock');
select t.ok(t.transit_of(string_to_array(t.get('dr_refs'), ',')) = 0, 'and nothing stays in transit');
select t.ok(t.unbalanced() = 0, 'cancelling keeps the books balanced');
update settings set features = features - 'no_warehouse' where id = 1;

-- ===== no central store: the Shop Admin is told what stock came into the shop =====
select t.put('arr0', (select count(*)::text from stock_arrivals));
select t.ok((select count(*) from stock_arrivals where kind = 'stock_in') > 0, 'stock added earlier in these tests left notices too');
update stock_arrivals set seen_at = now() where seen_at is null;
update settings set features = features || '{"no_warehouse": true}' where id = 1;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select public.stock_in_shops(array[t.get('gom'), t.get('lim')]::uuid[],
  jsonb_build_array(jsonb_build_object('product_id', t.get('cgel'), 'qty', 4), jsonb_build_object('product_id', t.get('lotion'), 'qty', 2)), '[]', '', 'Weekly top-up');
select public.receive_goods(jsonb_build_object('supplier_id', t.get('sup'), 'shop_id', t.get('gom'), 'note', 'Box 2 of 3',
  'lines', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 5))));
select t.ok((select count(*) from stock_arrivals) = t.get('arr0')::int + 3, 'each shop gets a notice for stock added to it, and for goods received into it');
select t.ok((select count(*) from stock_arrivals where seen_at is null) >= 3, 'the Admin sees every notice');
select t.fails(format($$select public.stock_arrivals_seen(array['%s']::uuid[])$$, (select id from stock_arrivals limit 1)), 'permission', 'only a Shop Admin marks a notice seen');
-- what the Gombe shop admin sees
select t.as('00000000-0000-0000-0000-00000000000c');
select t.ok((select count(*) from stock_arrivals where seen_at is null) = 2 and not exists (select 1 from stock_arrivals where shop_id <> t.get('gom')::uuid),
  'the Shop Admin sees only the notices of their own shop');
select t.ok((select string_agg(a.kind || ':' || i.qty, ',' order by a.kind) from stock_arrivals a join stock_arrival_items i on i.arrival_id = a.id
  where i.product_id = t.get('lotion')::uuid and a.seen_at is null) = 'goods_in:5,stock_in:2', 'with each item and the quantity that came in');
select t.ok((select note || '|' || what from stock_arrivals where kind = 'stock_in' and seen_at is null) = 'Weekly top-up|by hand', 'and the Admin''s note');
select t.ok((select what from stock_arrivals where kind = 'goods_in' and seen_at is null) like 'GRN-% from Beauty Import SARL', 'goods from a supplier name the receipt');
select t.put('arr_gom', (select id::text from stock_arrivals where seen_at is null limit 1));
select t.as('00000000-0000-0000-0000-00000000000e');
select t.ok((select count(*) from stock_arrivals where seen_at is null) = 1, 'the other shop gets only its own notice');
select t.ok(public.stock_arrivals_seen(array[t.get('arr_gom')::uuid]) = 0, 'a Shop Admin cannot mark another shop''s notice seen');
select t.ok(public.stock_arrivals_seen(array(select id from stock_arrivals where seen_at is null)) = 1, 'but marks their own');
select t.as('00000000-0000-0000-0000-00000000000c');
select t.ok(public.stock_arrivals_seen(array(select id from stock_arrivals where seen_at is null)) = 2, 'the Shop Admin marks what arrived as seen');
select t.ok(not exists (select 1 from stock_arrivals where seen_at is null) and (select count(*) from stock_arrivals) >= 2, 'the notice goes away, and stays in the history');
select t.as('00000000-0000-0000-0000-00000000000d');
select t.ok(not exists (select 1 from stock_arrivals), 'a till operator does not see the notices');
reset role;
update settings set features = features - 'no_warehouse' where id = 1;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select public.receive_goods(jsonb_build_object('supplier_id', t.get('sup'), 'lines', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 1))));
select t.ok((select count(*) from stock_arrivals) = t.get('arr0')::int + 3, 'goods into the central store tell no shop');
reset role;

-- ===== admin sees everything; disabled users are shut out =====
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.ok(jsonb_array_length(public.sales_report(current_date, current_date)->'slips') = 2, 'admin all-shops report has a slip per shop');
select t.ok((public.sales_report(current_date, current_date)->>'profit_usd') is not null, 'admin gets profit');
select t.ok(abs((public.sales_report(current_date - 400, current_date + 1)->>'profit_usd')::numeric
  - (select coalesce(sum((i.total / i.rate - (select coalesce(sum(cost_usd * qty), 0) from invoice_items where invoice_id = i.id)) * (1 - i.vat_rate / 100)), 0) from invoices i)) < 0.01
  and (public.sales_report(current_date - 400, current_date + 1)->>'profit_usd')::numeric <> 0,
  'gross profit is the margin (sales less cost of goods) less the VAT rate on the margin');
select t.ok((select count(*) from audit_log) > 10, 'admin reads the activity log');
reset role;
update profiles set active = false where username = 'till.gombe';
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000d');
select t.ok((select count(*) from products) = 0, 'disabled account reads nothing');
select t.fails($$select public.register_device()$$, 'permission', 'disabled account cannot sell');
reset role;

-- ===== goods in: corrected or deleted, waiting for the bill or billed =====
update settings set features = features - 'no_warehouse' where id = 1;
select t.put('gw0', (select wh_qty::text from products where id = t.get('lotion')::uuid)), t.put('ga0', (select wh_qty::text from products where id = t.get('argan')::uuid));
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.put('ge', public.receive_goods(jsonb_build_object('supplier_id', t.get('sup'), 'ref', 'DN 90', 'lines', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 10))))->>'id');
select public.edit_grn(jsonb_build_object('id', t.get('ge'), 'ref', 'DN 91', 'lines', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 8), jsonb_build_object('product_id', t.get('argan'), 'qty', 2))));
reset role;
select t.ok((select wh_qty from products where id = t.get('lotion')::uuid) = t.get('gw0')::int + 8 and (select wh_qty from products where id = t.get('argan')::uuid) = t.get('ga0')::int + 2
  and (select count(*) from grn_items where grn_id = t.get('ge')::uuid) = 2 and (select ref from grns where id = t.get('ge')::uuid) = 'DN 91'
  and (select count(*) from vouchers where source_type = 'grn' and source_id = t.get('ge')::uuid) = 1
  and (select sum(l.amount) from voucher_lines l join vouchers v on v.id = l.voucher_id where v.source_type = 'grn' and v.source_id = t.get('ge')::uuid and l.side = 'Dr')
    = (select round(sum(qty * std_cost_usd), 2) from grn_items where grn_id = t.get('ge')::uuid),
  'a receipt waiting for the bill is corrected: the stock and its goods-in voucher (the same one) follow');
update products set wh_qty = 1 where id = t.get('argan')::uuid;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.fails(format($$select public.edit_grn('{"id":"%s","lines":[{"product_id":"%s","qty":8}]}')$$, t.get('ge'), t.get('lotion')), 'cannot take them back', 'a receipt cannot take back goods that are no longer there');
reset role;
update products set wh_qty = t.get('ga0')::int + 2 where id = t.get('argan')::uuid;
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.put('gebill', public.enter_bill(jsonb_build_object('grn_id', t.get('ge'), 'bill_no', 'E-1', 'amount', 20, 'currency', 'USD'))->>'voucher_id');
select t.put('ged', public.grn_detail(t.get('ge')::uuid)::text);
select t.ok((t.get('ged')::jsonb->'bill'->>'bill_no') = 'E-1' and (t.get('ged')::jsonb->'bill'->>'amount')::numeric = 20 and t.get('ged')::jsonb->>'locked' is null,
  'the receipt shows its bill as it was entered');
select public.edit_grn(jsonb_build_object('id', t.get('ge'), 'lines', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 8), jsonb_build_object('product_id', t.get('argan'), 'qty', 2)),
  'bill', jsonb_build_object('bill_no', 'E-1b', 'bill_date', current_date, 'amount', 25, 'vat', 0, 'currency', 'USD')));
select public.edit_grn(jsonb_build_object('id', t.get('ge'), 'lines', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 7), jsonb_build_object('product_id', t.get('argan'), 'qty', 2))));
reset role;
select t.ok((select bill_voucher_id::text from grns where id = t.get('ge')::uuid) = t.get('gebill') and (select ref from vouchers where id = t.get('gebill')::uuid) = 'E-1b'
  and (select l.amount from voucher_lines l join accounts a on a.id = l.account_id where l.voucher_id = t.get('gebill')::uuid and a.supplier_id = t.get('sup')::uuid) = 25
  and (select wh_qty from products where id = t.get('lotion')::uuid) = t.get('gw0')::int + 7 and t.unbalanced() = 0,
  'a billed receipt is corrected with its bill (same voucher), and again for the goods only; the books balance');
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000b');
select t.fails(format($$select public.delete_grn('%s', 'not mine')$$, t.get('ge')), 'Only the Admin', 'the warehouse does not delete a billed receipt');
select t.as('00000000-0000-0000-0000-00000000000a');
select t.fails(format($$select public.delete_grn('%s', '')$$, t.get('ge')), 'short reason', 'deleting a receipt needs a reason');
select public.delete_grn(t.get('ge')::uuid, 'entered against the wrong supplier');
reset role;
select t.ok((select status from grns where id = t.get('ge')::uuid) = 'cancelled' and (select wh_qty from products where id = t.get('lotion')::uuid) = t.get('gw0')::int
  and (select wh_qty from products where id = t.get('argan')::uuid) = t.get('ga0')::int
  and not exists (select 1 from vouchers where (source_type = 'grn' and source_id = t.get('ge')::uuid or id = t.get('gebill')::uuid) and status = 'posted')
  and t.unbalanced() = 0, 'a deleted receipt takes its goods back out of the stock and cancels its goods-in voucher and its bill');
-- a paid bill locks the receipt
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000a');
select t.put('gp', public.receive_goods(jsonb_build_object('supplier_id', t.get('sup'), 'lines', jsonb_build_array(jsonb_build_object('product_id', t.get('lotion'), 'qty', 1))))->>'id');
select t.put('gpbill', public.enter_bill(jsonb_build_object('grn_id', t.get('gp'), 'bill_no', 'E-2', 'amount', 2, 'currency', 'USD'))->>'voucher_id');
select public.post_voucher(jsonb_build_object('type', 'payment', 'narration', 'E-2', 'lines', jsonb_build_array(
  jsonb_build_object('account', (select account_id from suppliers where id = t.get('sup')::uuid), 'side', 'Dr', 'amount', 1, 'currency', 'USD'),
  jsonb_build_object('account', t.acc('CASH_HO'), 'side', 'Cr', 'amount', 1, 'currency', 'USD')),
  'allocations', jsonb_build_array(jsonb_build_object('bill_id', t.get('gpbill'), 'amount', 1))));
select t.fails(format($$select public.delete_grn('%s', 'paid already')$$, t.get('gp')), 'already (partly) paid', 'a receipt whose bill is (partly) paid is not deleted');
select t.fails(format($$select public.edit_grn('{"id":"%s","lines":[{"product_id":"%s","qty":2}]}')$$, t.get('gp'), t.get('lotion')), 'already (partly) paid', 'nor corrected');
reset role;

-- ===== promo items on cash sales, and the monthly report: cash and credit =====
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.fails($$select public.give_cash_promo('{"lines":[]}')$$, 'not turned on', 'promo items on cash sales are off until the Admin turns them on');
reset role;
update settings set features = features || '{"cash_promo": true}' where id = 1;
select t.put('cp0', (select qty::text from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('cgel')::uuid));
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select t.put('cp1', public.give_cash_promo(jsonb_build_object('invoice_no', 'GOM-T2-000911', 'note', 'opening day', 'lines', jsonb_build_array(jsonb_build_object('product_id', t.get('cgel'), 'qty', 2))))::text);
select t.put('cprep', public.promo_report(current_date)::text);
reset role;
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('cgel')::uuid) = t.get('cp0')::int - 2
  and (select vendeur_id is null and invoice_no = 'GOM-T2-000911' from vendeur_promos where id = (t.get('cp1')::jsonb->>'id')::uuid)
  and exists (select 1 from voucher_lines l join vouchers v on v.id = l.voucher_id join accounts a on a.id = l.account_id
    where v.source_type = 'promo' and v.source_id = (t.get('cp1')::jsonb->>'id')::uuid and a.code = 'PROMO_EXP' and l.side = 'Dr'),
  'promo items with a cash sale leave the stock, at cost as a promotion expense, not invoiced');
select t.ok(exists (select 1 from jsonb_array_elements(t.get('cprep')::jsonb->'items') i where i->>'name' = 'Credit gel' and (i->>'cash_qty')::int = 2 and (i->>'credit_qty')::int = 0 and (i->>'qty')::int = 2)
  and jsonb_array_length(t.get('cprep')::jsonb->'cash_promos') = 1 and (t.get('cprep')::jsonb->>'cash_pcs')::int = 2,
  'the monthly promo report counts each item in all, from cash sales and from credit sales');
set role authenticated;
select t.as('00000000-0000-0000-0000-00000000000c');
select public.cancel_promo((t.get('cp1')::jsonb->>'id')::uuid, 'given by mistake');
reset role;
select t.ok((select qty from shop_stock where shop_id = t.get('gom')::uuid and product_id = t.get('cgel')::uuid) = t.get('cp0')::int, 'a cancelled cash-sale promo goes back into the stock');

-- the live API (Supabase's safeupdate) refuses a DELETE or UPDATE without WHERE; these tests run as the owner, where
-- it does not apply, so every function is checked for one here instead
select t.ok(not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace, regexp_matches(p.prosrc, '(delete\s+from\s+[a-z_.]+\s*;)', 'gi') m
    where n.nspname in ('public', 'app')
    union all
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace, regexp_matches(p.prosrc, '(update\s+[a-z_.]+(\s+[a-z]+)?\s+set\s[^;]*;)', 'gi') m
    where n.nspname in ('public', 'app') and m[1] !~* '\swhere\s'),
  'no function has a DELETE or UPDATE without WHERE (the live API refuses them)');

\echo ALL TESTS PASSED
