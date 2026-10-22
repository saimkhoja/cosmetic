-- SIM go-live reset: clears everything from setup and testing so the business starts from today.
-- Run it ONCE, by hand, in the Supabase SQL Editor of the installation that goes live. It is not a
-- migration and never runs on its own.
--
-- Clears:  invoices, orders, deliveries, goods in, returns, stock requests, upkeep, supplier bills,
--          payments and every voucher; the stock in the central store and in every shop; the opening
--          balances of the ledgers and suppliers; the registered tills (they register again as T1, T2...
--          and invoice numbers restart at 000001). Voucher, delivery, goods in, return and request
--          numbers restart too.
-- Keeps:   items (names, categories, units, prices, cost prices, barcodes, archived items), categories,
--          suppliers and the items they supply, ledger names, shops, logins and passwords, settings
--          (company details, rate, VAT, switches) and the activity log.
--
-- Before: back up the database, and check every till shows nothing waiting to send.
-- After:  on each till PC clear the SIM site's data once and sign in again while online.
-- All of it runs as one transaction: it either completes or changes nothing.

begin;

-- sales, orders, stock movements and the books
truncate table
  public.invoice_items, public.invoice_edits, public.invoices, public.sale_orders,
  public.delivery_items, public.delivery_edits, public.deliveries,
  public.stock_request_items, public.stock_requests,
  public.return_items, public.shop_returns,
  public.grn_items, public.grns, public.purchases, public.upkeep,
  public.bill_allocations, public.voucher_lines, public.vouchers,
  public.devices;

-- stock: every item stays in the catalogue and in every shop, at 0
update public.products set wh_qty = 0 where wh_qty <> 0;
update public.shop_stock set qty = 0, open_pieces = 0 where qty <> 0 or open_pieces <> 0;

-- the books start empty: opening balances are entered again under Accounts
update public.accounts set opening_amount = 0, opening_side = 'Dr', opening_currency = 'USD', opening_rate = null where opening_amount <> 0 or opening_rate is not null;
update public.voucher_seq set n = 0;

-- document numbers start again (item codes keep counting)
alter sequence public.delivery_seq restart;
alter sequence public.grn_seq restart;
alter sequence public.return_seq restart;
alter sequence public.stock_request_seq restart;

insert into public.audit_log (username, action)
values ('system', 'Data reset for go-live: sales, stock and books cleared; items, logins and settings kept');

commit;

-- check: the first four should be 0, the rest are what was kept
select (select count(*) from public.invoices)                          as invoices,
       (select count(*) from public.vouchers)                          as vouchers,
       (select coalesce(sum(wh_qty), 0) from public.products)          as store_stock,
       (select coalesce(sum(qty), 0) from public.shop_stock)           as shop_stock,
       (select count(*) from public.products)                          as items_kept,
       (select count(*) from public.profiles)                          as logins_kept,
       (select count(*) from public.shops)                             as shops_kept,
       (select count(*) from public.suppliers)                         as suppliers_kept;
