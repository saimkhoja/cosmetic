-- QuickSales: which database updates (migrations 10 to 22) this installation has.
-- Paste it into the Supabase SQL Editor and click Run. It only reads; it changes nothing.
-- Each "MISSING" file must be run, in order. A migration re-creates functions from the newest version it knows, so
-- after running a missing older file, run every later file again too (they are safe to run twice). For example,
-- with 14 to 17 missing: run 14, 15, 16, 17, then 18, 19, 20, 21 again.
select step, case when ok then 'done' else 'MISSING: run this file' end as status from (values
  (10, '20261018000001_supermarket.sql',      exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'settings' and column_name = 'features')),
  (11, '20261019000001_till_sells.sql',       exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'fc' and pg_get_functiondef(p.oid) like '%CDF%')),
  (12, '20261020000001_cash_change.sql',      exists (select 1 from pg_proc where proname = 'save_settings' and pg_get_functiondef(oid) like '%cash_change%')),
  (13, '20261022000001_two_rates.sql',        exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'settings' and column_name = 'book_rate')),
  (14, '20261023000001_usd_payment.sql',      exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'invoices' and column_name = 'paid_usd')),
  (15, '20261024000001_supplier_returns.sql', exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = 'supplier_returns')),
  (16, '20261025000001_one_per_carton.sql',   exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'product_fields' and pg_get_functiondef(p.oid) like '%(1 or more)%')),
  (17, '20261026000001_multi_barcodes.sql',   exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'products' and column_name = 'barcodes')),
  (18, '20261103000001_till_invoices.sql',    exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'sale_orders' and column_name = 'invoice_no')),
  (19, '20261103000002_discount_amount.sql',  exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'invoices' and column_name = 'disc_pct' and data_type = 'numeric')),
  (20, '20261103000003_carton_parts.sql',     exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'app' and p.proname = 'unit_named')),
  (21, '20261103000004_category_sales.sql',   exists (select 1 from pg_proc where proname = 'sales_report' and pg_get_functiondef(oid) like '%by_category%')),
  (22, '20261107000001_more_barcodes.sql',    exists (select 1 from pg_proc where proname = 'barcode_list' and pg_get_functiondef(oid) like '%at most 60 barcodes%'))
) as m(n, step, ok) order by n;
