-- SIM update 2 (part 2): book keeping like Tally. Ledgers in groups, vouchers with lines in USD or FC
-- (USD is the balancing base), automatic postings from sales, receipts, bills, transfers and returns,
-- suppliers with credit terms and assigned items, bill-wise payables, statements and reports.
-- Run after part 1. Safe to run more than once.


-- ---------- chart of accounts ----------
create table if not exists public.account_groups (
  code   text primary key,
  name   text not null,
  nature text not null check (nature in ('asset','liability','equity','income','expense')),
  parent text references public.account_groups(code),
  sort   int not null default 0
);
insert into public.account_groups (code, name, nature, parent, sort) values
  ('capital','Capital Account','equity',null,10),
  ('reserves','Reserves & Surplus','equity',null,11),
  ('loans','Loans (Liability)','liability',null,20),
  ('curliab','Current Liabilities','liability',null,21),
  ('creditors','Sundry Creditors (suppliers)','liability','curliab',22),
  ('duties','Duties & Taxes','liability','curliab',23),
  ('provisions','Provisions','liability','curliab',24),
  ('fixed','Fixed Assets','asset',null,30),
  ('curassets','Current Assets','asset',null,31),
  ('cash','Cash-in-Hand','asset','curassets',32),
  ('bank','Bank Accounts','asset','curassets',33),
  ('debtors','Sundry Debtors','asset','curassets',34),
  ('stock','Stock-in-Hand','asset','curassets',35),
  ('advances','Loans & Advances (Asset)','asset','curassets',36),
  ('sales','Sales Accounts','income',null,40),
  ('dirinc','Direct Incomes','income',null,41),
  ('indinc','Indirect Incomes','income',null,42),
  ('direxp','Direct Expenses','expense',null,50),
  ('indexp','Indirect Expenses','expense',null,51)
on conflict (code) do nothing;

create table if not exists public.accounts (
  id               uuid primary key default gen_random_uuid(),
  code             text unique,                        -- set on accounts SIM posts to by itself
  name             text not null check (length(btrim(name)) between 1 and 60),
  group_code       text not null references public.account_groups(code),
  currency         text not null default 'USD' check (currency in ('USD','FC')),
  shop_id          uuid references public.shops(id),
  supplier_id      uuid,
  opening_amount   numeric(18,2) not null default 0 check (opening_amount >= 0),
  opening_side     text not null default 'Dr' check (opening_side in ('Dr','Cr')),
  opening_currency text not null default 'USD' check (opening_currency in ('USD','FC')),
  opening_rate     numeric(12,2),
  system           boolean not null default false,
  active           boolean not null default true,
  created_at       timestamptz not null default now()
);
create unique index if not exists accounts_name_key on public.accounts (lower(name));

create table if not exists public.suppliers (
  id           uuid primary key default gen_random_uuid(),
  name         text not null check (length(btrim(name)) between 1 and 60),
  contact      text not null default '',
  phone        text not null default '',
  email        text not null default '',
  address      text not null default '',
  tax_no       text not null default '',
  credit_days  int not null default 30 check (credit_days between 0 and 365),
  credit_limit numeric(18,2) not null default 0,
  currency     text not null default 'USD' check (currency in ('USD','FC')),
  notes        text not null default '',
  active       boolean not null default true,
  account_id   uuid references public.accounts(id),
  created_at   timestamptz not null default now()
);
create unique index if not exists suppliers_name_key on public.suppliers (lower(name));
create table if not exists public.supplier_items (
  supplier_id uuid not null references public.suppliers(id) on delete cascade,
  product_id  uuid not null references public.products(id) on delete cascade,
  primary key (supplier_id, product_id)
);

create table if not exists public.voucher_seq (type text primary key, n int not null default 0);
create table if not exists public.vouchers (
  id              uuid primary key default gen_random_uuid(),
  type            text not null check (type in ('opening','sales','purchase','payment','receipt','contra','journal','debit_note','credit_note','goods_in','transfer','return','adjustment')),
  no              text not null unique,
  date            date not null,
  narration       text not null default '',
  ref             text not null default '',
  source_type     text,
  source_id       uuid,
  status          text not null default 'posted' check (status in ('posted','cancelled')),
  cancel_reason   text,
  created_by_name text not null,
  created_at      timestamptz not null default now()
);
create index if not exists vouchers_date on public.vouchers (date);
create unique index if not exists vouchers_source on public.vouchers (source_type, source_id) where source_id is not null and status = 'posted';
create table if not exists public.voucher_lines (
  id         bigserial primary key,
  voucher_id uuid not null references public.vouchers(id) on delete cascade,
  account_id uuid not null references public.accounts(id),
  side       text not null check (side in ('Dr','Cr')),
  amount     numeric(18,2) not null check (amount > 0),     -- in the line's own currency
  currency   text not null check (currency in ('USD','FC')),
  rate       numeric(12,2) not null check (rate > 0),        -- FC for 1 USD on that entry
  base       numeric(18,6) not null,                         -- the same amount in USD, used for balancing and reports
  memo       text not null default '',
  bill_ref   text,
  due_date   date
);
create index if not exists voucher_lines_account on public.voucher_lines (account_id);
create index if not exists voucher_lines_voucher on public.voucher_lines (voucher_id);
create table if not exists public.bill_allocations (
  id          bigserial primary key,
  voucher_id  uuid not null references public.vouchers(id) on delete cascade,   -- payment or debit note
  bill_id     uuid not null references public.vouchers(id) on delete cascade,   -- purchase bill (or opening balance voucher)
  amount_base numeric(18,6) not null check (amount_base > 0)
);

-- goods received from suppliers (stock in now, bill entered later by the Admin)
create table if not exists public.grns (
  id               uuid primary key default gen_random_uuid(),
  no               text not null unique,
  supplier_id      uuid not null references public.suppliers(id),
  ref              text not null default '',
  note             text not null default '',
  status           text not null default 'awaiting_bill' check (status in ('awaiting_bill','billed')),
  bill_voucher_id  uuid references public.vouchers(id),
  received_by_name text not null,
  received_at      timestamptz not null default now()
);
create table if not exists public.grn_items (
  grn_id       uuid not null references public.grns(id) on delete cascade,
  product_id   uuid not null references public.products(id),
  qty          int not null check (qty > 0),
  std_cost_usd numeric(16,6) not null default 0,
  primary key (grn_id, product_id)
);

-- goods a shop sends back to the central store
create table if not exists public.shop_returns (
  id               uuid primary key default gen_random_uuid(),
  no               text not null unique,
  shop_id          uuid not null references public.shops(id),
  reason           text not null,
  status           text not null default 'pending' check (status in ('pending','received','cancelled')),
  created_by_name  text not null,
  created_at       timestamptz not null default now(),
  received_by_name text,
  received_at      timestamptz,
  received_note    text
);
create table if not exists public.return_items (
  return_id    uuid not null references public.shop_returns(id) on delete cascade,
  product_id   uuid not null references public.products(id),
  qty          int not null check (qty > 0),
  received_qty int,
  cost_usd     numeric(16,6) not null default 0,
  primary key (return_id, product_id)
);
create sequence if not exists public.grn_seq;
create sequence if not exists public.return_seq;

-- ---------- access: the books are the Admin's; others see their part through checked functions ----------
alter table public.account_groups enable row level security;
alter table public.accounts enable row level security;
alter table public.suppliers enable row level security;
alter table public.supplier_items enable row level security;
alter table public.voucher_seq enable row level security;
alter table public.vouchers enable row level security;
alter table public.voucher_lines enable row level security;
alter table public.bill_allocations enable row level security;
alter table public.grns enable row level security;
alter table public.grn_items enable row level security;
alter table public.shop_returns enable row level security;
alter table public.return_items enable row level security;
revoke all on public.account_groups, public.accounts, public.suppliers, public.supplier_items, public.voucher_seq, public.vouchers,
  public.voucher_lines, public.bill_allocations, public.grns, public.grn_items, public.shop_returns, public.return_items from anon, authenticated;
revoke all on sequence public.grn_seq, public.return_seq from anon, authenticated;
grant select on public.account_groups, public.accounts, public.suppliers, public.supplier_items, public.vouchers, public.voucher_lines,
  public.bill_allocations, public.grns, public.grn_items, public.shop_returns, public.return_items to authenticated;
drop policy if exists r on public.account_groups; create policy r on public.account_groups for select to authenticated using (app.my_role() = 'admin');
drop policy if exists r on public.accounts; create policy r on public.accounts for select to authenticated using (app.my_role() = 'admin');
drop policy if exists r on public.vouchers; create policy r on public.vouchers for select to authenticated using (app.my_role() = 'admin');
drop policy if exists r on public.voucher_lines; create policy r on public.voucher_lines for select to authenticated using (app.my_role() = 'admin');
drop policy if exists r on public.bill_allocations; create policy r on public.bill_allocations for select to authenticated using (app.my_role() = 'admin');
drop policy if exists r on public.suppliers; create policy r on public.suppliers for select to authenticated using (app.my_role() in ('admin','whop'));
drop policy if exists r on public.supplier_items; create policy r on public.supplier_items for select to authenticated using (app.my_role() in ('admin','whop'));
drop policy if exists r on public.grns; create policy r on public.grns for select to authenticated using (app.my_role() in ('admin','whop'));
drop policy if exists r on public.grn_items; create policy r on public.grn_items for select to authenticated using (app.my_role() in ('admin','whop'));
drop policy if exists r on public.shop_returns; create policy r on public.shop_returns for select to authenticated
  using (app.my_role() in ('admin','whop') or (app.my_role() = 'shopadmin' and shop_id = app.my_shop()));
drop policy if exists r on public.return_items; create policy r on public.return_items for select to authenticated
  using (exists (select 1 from public.shop_returns x where x.id = return_id));

-- ---------- system ledgers ----------
insert into public.accounts (code, name, group_code, currency, system) values
  ('CASH_HO','Cash – Head office','cash','USD',true),
  ('BANK','Bank','bank','USD',true),
  ('INV_STORE','Stock – Central store','stock','USD',true),
  ('TRANSIT','Goods in transit (returns)','stock','USD',true),
  ('GRNI','Goods received, bill not entered','curliab','USD',true),
  ('VAT_OUT','VAT collected on sales','duties','FC',true),
  ('VAT_IN','VAT paid on purchases','duties','USD',true),
  ('COGS','Cost of goods sold','direxp','USD',true),
  ('PPV','Purchase price difference','direxp','USD',true),
  ('STOCK_ADJ','Stock adjustments and losses','direxp','USD',true),
  ('CAPITAL','Capital','capital','USD',true),
  ('OPENING','Opening balances','capital','USD',true),
  ('EXP_RENT','Rent','indexp','USD',true),
  ('EXP_POWER','Electricity & fuel','indexp','USD',true),
  ('EXP_SECURITY','Security','indexp','USD',true),
  ('EXP_SALARIES','Salaries','indexp','USD',true),
  ('EXP_TRANSPORT','Transport','indexp','USD',true),
  ('EXP_MAINT','Maintenance','indexp','USD',true),
  ('EXP_TAXES','Taxes & licences','indexp','USD',true),
  ('EXP_OTHER','Other expenses','indexp','USD',true)
on conflict (code) do nothing;

-- ---------- posting engine ----------
create or replace function app.acc(p_code text) returns uuid
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare a uuid;
begin
  select id into a from accounts where code = p_code;
  if a is null then raise exception 'Ledger % is missing', p_code; end if;
  return a;
end $$;

-- the shop's own ledgers, made the first time they are needed
create or replace function app.shop_acc(p_kind text, p_shop uuid) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare a uuid; c text := p_kind || ':' || p_shop; s public.shops; nm text;
begin
  select id into a from accounts where code = c;
  if a is not null then return a; end if;
  select * into s from shops where id = p_shop;
  nm := case p_kind when 'INV_SHOP' then 'Stock – ' when 'CASH_SHOP' then 'Cash – ' else 'Sales – ' end || s.name;
  if exists (select 1 from accounts where lower(name) = lower(nm)) then nm := nm || ' (' || s.code || ')'; end if;
  insert into accounts (code, name, group_code, currency, shop_id, system)
    values (c, nm, case p_kind when 'INV_SHOP' then 'stock' when 'CASH_SHOP' then 'cash' else 'sales' end,
            case p_kind when 'INV_SHOP' then 'USD' else 'FC' end, p_shop, true)
    on conflict (code) do nothing returning id into a;
  if a is null then select id into a from accounts where code = c; end if;
  return a;
end $$;

create or replace function app.next_no(p_type text) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int;
begin
  insert into voucher_seq (type, n) values (p_type, 1) on conflict (type) do update set n = voucher_seq.n + 1 returning voucher_seq.n into n;
  return (case p_type when 'opening' then 'OPN' when 'sales' then 'SAL' when 'purchase' then 'PUR' when 'payment' then 'PAY'
    when 'receipt' then 'RCT' when 'contra' then 'CTR' when 'journal' then 'JRN' when 'debit_note' then 'DBN' when 'credit_note' then 'CRN'
    when 'goods_in' then 'GIN' when 'transfer' then 'TRF' when 'return' then 'RTV' else 'ADJ' end) || '-' || lpad(n::text, 5, '0');
end $$;

-- writes one voucher. lines: [{account|code, side, amount, currency, rate, memo, bill_ref, due_date}].
-- A voucher for the same source (an invoice, a receipt...) is rewritten in place, keeping its number.
create or replace function app.post(p_type text, p_date date, p_narr text, p_ref text, p_src_type text, p_src uuid, p_lines jsonb, p_by text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare vid uuid; l jsonb; acc uuid; amt numeric; cur text; r numeric; dr numeric := 0; cr numeric := 0; b numeric; def_rate numeric;
begin
  select rate into def_rate from settings where id = 1;
  if p_src is not null then
    select id into vid from vouchers where source_type = p_src_type and source_id = p_src and status = 'posted';
  end if;
  if vid is null then
    insert into vouchers (type, no, date, narration, ref, source_type, source_id, created_by_name)
      values (p_type, app.next_no(p_type), p_date, left(coalesce(p_narr,''), 200), left(coalesce(p_ref,''), 60), p_src_type, p_src, p_by) returning id into vid;
  else
    update vouchers set date = p_date, narration = left(coalesce(p_narr,''), 200), ref = left(coalesce(p_ref,''), 60) where id = vid;
    delete from voucher_lines where voucher_id = vid;
  end if;
  for l in select * from jsonb_array_elements(p_lines) loop
    amt := round(app.num(l->>'amount'), 2);
    if amt is null or amt = 0 then continue; end if;
    if amt < 0 then raise exception 'Amounts must be positive'; end if;
    acc := coalesce((l->>'account')::uuid, app.acc(l->>'code'));
    if not exists (select 1 from accounts where id = acc and active) then raise exception 'One of the ledgers is not active'; end if;
    cur := coalesce(l->>'currency', 'USD');
    if cur not in ('USD','FC') then raise exception 'Currency must be USD or FC'; end if;
    r := coalesce(app.num(l->>'rate'), def_rate);
    if r <= 0 then raise exception 'Exchange rate must be above zero'; end if;
    b := case when cur = 'USD' then amt else amt / r end;
    if l->>'side' not in ('Dr','Cr') then raise exception 'Each line must be Dr or Cr'; end if;
    insert into voucher_lines (voucher_id, account_id, side, amount, currency, rate, base, memo, bill_ref, due_date)
      values (vid, acc, l->>'side', amt, cur, r, b, left(coalesce(l->>'memo',''), 120), nullif(l->>'bill_ref',''), (l->>'due_date')::date);
    if l->>'side' = 'Dr' then dr := dr + b; else cr := cr + b; end if;
  end loop;
  if dr = 0 and cr = 0 then
    -- nothing to book: drop an empty voucher that was just made for this source
    delete from vouchers where id = vid and not exists (select 1 from voucher_lines where voucher_id = vid);
    return null;
  end if;
  if abs(dr - cr) > 0.011 then raise exception 'Debit and credit are not equal (Dr % USD, Cr % USD)', round(dr, 2), round(cr, 2); end if;
  return vid;
end $$;

-- sale: Dr shop cash (FC), Cr shop sales and VAT (FC); Dr cost of goods sold, Cr shop stock (USD at cost)
create or replace function app.post_invoice(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare i public.invoices; cost numeric; tz text;
begin
  select * into i from invoices where id = p_id;
  if i.id is null or i.total <= 0 then return; end if;
  select settings.tz into tz from settings where id = 1;
  select coalesce(sum(cost_usd * qty), 0) into cost from invoice_items where invoice_id = p_id;
  perform app.post('sales', (i.t at time zone tz)::date, 'Invoice ' || i.no || coalesce(', ' || nullif(i.customer, ''), ''), i.no, 'invoice', i.id,
    jsonb_build_array(
      jsonb_build_object('account', app.shop_acc('CASH_SHOP', i.shop_id), 'side', 'Dr', 'amount', i.total, 'currency', 'FC', 'rate', i.rate),
      jsonb_build_object('account', app.shop_acc('SALES_SHOP', i.shop_id), 'side', 'Cr', 'amount', i.ht, 'currency', 'FC', 'rate', i.rate),
      jsonb_build_object('code', 'VAT_OUT', 'side', 'Cr', 'amount', i.vat, 'currency', 'FC', 'rate', i.rate),
      jsonb_build_object('code', 'COGS', 'side', 'Dr', 'amount', round(cost, 2), 'currency', 'USD', 'memo', 'Cost of goods sold'),
      jsonb_build_object('account', app.shop_acc('INV_SHOP', i.shop_id), 'side', 'Cr', 'amount', round(cost, 2), 'currency', 'USD', 'memo', 'Cost of goods sold')),
    i.cashier_name);
end $$;
create or replace function app.trg_invoice() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$ begin perform app.post_invoice(new.id); return new; end $$;
drop trigger if exists invoice_books on public.invoices;
create trigger invoice_books after update of total, gross, disc, vat, ht on public.invoices for each row execute function app.trg_invoice();

-- delivery received by a shop: Dr shop stock, Cr central store stock, at cost
create or replace function app.trg_delivery() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v numeric; tz text;
begin
  if new.status = 'received' and old.status = 'pending' then
    select settings.tz into tz from settings where id = 1;
    select coalesce(sum(coalesce(i.received_qty, i.qty) * coalesce(c.cost_usd, 0)), 0) into v
      from delivery_items i left join product_costs c on c.product_id = i.product_id where i.delivery_id = new.id;
    perform app.post('transfer', (coalesce(new.received_at, now()) at time zone tz)::date, 'Delivery ' || new.no || ' received by ' || (select name from shops where id = new.shop_id),
      new.no, 'delivery', new.id,
      jsonb_build_array(jsonb_build_object('account', app.shop_acc('INV_SHOP', new.shop_id), 'side', 'Dr', 'amount', round(v, 2)),
                        jsonb_build_object('code', 'INV_STORE', 'side', 'Cr', 'amount', round(v, 2))),
      coalesce(new.received_by_name, 'system'));
  end if;
  return new;
end $$;
drop trigger if exists delivery_books on public.deliveries;
create trigger delivery_books after update of status on public.deliveries for each row execute function app.trg_delivery();

create or replace function app.after_opening_stock(p_product uuid, p_qty int, u public.profiles) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v numeric; pr public.products;
begin
  if p_qty <= 0 then return; end if;
  select * into pr from products where id = p_product;
  select p_qty * cost_usd into v from product_costs where product_id = p_product;
  perform app.post('opening', current_date, 'Opening stock: ' || p_qty || ' ' || pr.stock_unit || ' ' || pr.name, pr.sku, null, null,
    jsonb_build_array(jsonb_build_object('code', 'INV_STORE', 'side', 'Dr', 'amount', round(coalesce(v,0), 2)),
                      jsonb_build_object('code', 'OPENING', 'side', 'Cr', 'amount', round(coalesce(v,0), 2))), u.name);
end $$;

-- a new cost price revalues the stock already held, so the stock ledgers keep matching the items
create or replace function app.trg_cost() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare d numeric := new.cost_usd - old.cost_usd; pr public.products; lines jsonb := '[]'; total numeric := 0; v numeric; s record; v_by text;
begin
  if d = 0 then return new; end if;
  select * into pr from products where id = new.product_id;
  select coalesce((select name from profiles where id = auth.uid()), 'system') into v_by;
  v := round(pr.wh_qty * d, 2);
  if v <> 0 then
    lines := lines || jsonb_build_array(jsonb_build_object('code', 'INV_STORE', 'side', case when v > 0 then 'Dr' else 'Cr' end, 'amount', abs(v)));
    total := total + v;
  end if;
  for s in select shop_id, qty from shop_stock where product_id = new.product_id and qty <> 0 loop
    v := round(s.qty * d, 2);
    if v <> 0 then
      lines := lines || jsonb_build_array(jsonb_build_object('account', app.shop_acc('INV_SHOP', s.shop_id), 'side', case when v > 0 then 'Dr' else 'Cr' end, 'amount', abs(v)));
      total := total + v;
    end if;
  end loop;
  if total <> 0 or jsonb_array_length(lines) > 0 then
    lines := lines || jsonb_build_array(jsonb_build_object('code', 'STOCK_ADJ', 'side', case when total > 0 then 'Cr' else 'Dr' end, 'amount', abs(total)));
    perform app.post('adjustment', current_date, format('Cost of %s changed from %s to %s per %s: stock revalued', pr.name, app.usd(old.cost_usd), app.usd(new.cost_usd), pr.stock_unit),
      pr.sku, null, null, lines, v_by);
  end if;
  return new;
end $$;
drop trigger if exists cost_books on public.product_costs;
create trigger cost_books after update of cost_usd on public.product_costs for each row execute function app.trg_cost();

create or replace function app.item_used_elsewhere(p_id uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from grn_items where product_id = p_id) or exists (select 1 from return_items where product_id = p_id)
$$;

-- signed balance in USD of a ledger: Dr positive
create or replace function app.opening_base(a public.accounts) returns numeric
language sql immutable as $$
  select (case when a.opening_side = 'Dr' then 1 else -1 end) *
    case when a.opening_currency = 'USD' then a.opening_amount else a.opening_amount / nullif(coalesce(a.opening_rate, 1), 0) end
$$;

-- ---------- suppliers ----------
create or replace function public.save_supplier(p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); sid uuid := (p->>'id')::uuid; n text := btrim(coalesce(p->>'name','')); s public.suppliers;
  aid uuid; oa numeric := coalesce(app.num(p->>'opening_amount'), 0); ocur text := coalesce(p->>'opening_currency', 'USD');
  orate numeric := app.num(p->>'opening_rate'); oside text := coalesce(p->>'opening_side', 'Cr');
begin
  if n = '' then raise exception 'Enter the supplier name'; end if;
  if exists (select 1 from suppliers where lower(name) = lower(n) and id is distinct from sid) then raise exception 'Supplier "%" already exists', n; end if;
  if coalesce(app.num(p->>'credit_days'), 30) < 0 or coalesce(app.num(p->>'credit_days'), 30) > 365 then raise exception 'Credit days must be 0 to 365'; end if;
  if oa < 0 then raise exception 'Opening balance cannot be negative; choose Dr or Cr'; end if;
  if ocur = 'FC' and coalesce(orate, 0) <= 0 then select rate into orate from settings where id = 1; end if;
  if sid is null then
    if exists (select 1 from accounts where lower(name) = lower(n)) then raise exception 'A ledger called "%" already exists', n; end if;
    insert into accounts (name, group_code, currency, opening_amount, opening_side, opening_currency, opening_rate, system)
      values (n, 'creditors', coalesce(p->>'currency','USD'), oa, oside, ocur, orate, false) returning id into aid;
    insert into suppliers (name, contact, phone, email, address, tax_no, credit_days, credit_limit, currency, notes, account_id)
      values (n, coalesce(p->>'contact',''), coalesce(p->>'phone',''), coalesce(p->>'email',''), coalesce(p->>'address',''), coalesce(p->>'tax_no',''),
        coalesce(app.num(p->>'credit_days'), 30)::int, coalesce(app.num(p->>'credit_limit'), 0), coalesce(p->>'currency','USD'), coalesce(p->>'notes',''), aid)
      returning id into sid;
    update accounts set supplier_id = sid where id = aid;
    perform app.log(u, 'Added supplier ' || n);
  else
    select * into s from suppliers where id = sid for update;
    if not found then raise exception 'Supplier not found'; end if;
    if exists (select 1 from accounts where lower(name) = lower(n) and id <> s.account_id) then raise exception 'A ledger called "%" already exists', n; end if;
    update suppliers set name = n, contact = coalesce(p->>'contact',''), phone = coalesce(p->>'phone',''), email = coalesce(p->>'email',''),
      address = coalesce(p->>'address',''), tax_no = coalesce(p->>'tax_no',''), credit_days = coalesce(app.num(p->>'credit_days'), 30)::int,
      credit_limit = coalesce(app.num(p->>'credit_limit'), 0), currency = coalesce(p->>'currency','USD'), notes = coalesce(p->>'notes',''),
      active = coalesce((p->>'active')::boolean, active) where id = sid;
    update accounts set name = n, currency = coalesce(p->>'currency','USD'), opening_amount = oa, opening_side = oside, opening_currency = ocur, opening_rate = orate
      where id = s.account_id;
    perform app.log(u, 'Updated supplier ' || n);
  end if;
  if p ? 'items' then
    delete from supplier_items where supplier_id = sid;
    insert into supplier_items (supplier_id, product_id) select sid, (x)::uuid from jsonb_array_elements_text(p->'items') x
      where exists (select 1 from products where id = (x)::uuid) on conflict do nothing;
  end if;
  return sid;
end $$;

-- ---------- goods in from a supplier (warehouse) and the bill (Admin) ----------
create or replace function public.receive_goods(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin','whop'); sup public.suppliers; gid uuid; gno text; v numeric; n int;
begin
  select * into sup from suppliers where id = (p->>'supplier_id')::uuid and active;
  if not found then raise exception 'Choose the supplier'; end if;
  if not exists (select 1 from app.lines(p->'lines')) then raise exception 'Enter a quantity for at least one item'; end if;
  if (select count(*) from products where active and id in (select product_id from app.lines(p->'lines'))) <> (select count(*) from app.lines(p->'lines')) then
    raise exception 'One of the items was not found';
  end if;
  gno := 'GRN-' || lpad(nextval('grn_seq')::text, 4, '0');
  insert into grns (no, supplier_id, ref, note, received_by_name) values (gno, sup.id, left(btrim(coalesce(p->>'ref','')), 60), left(btrim(coalesce(p->>'note','')), 120), u.name)
    returning id into gid;
  insert into grn_items (grn_id, product_id, qty, std_cost_usd)
    select gid, l.product_id, l.qty, coalesce(c.cost_usd, 0) from app.lines(p->'lines') l left join product_costs c on c.product_id = l.product_id;
  update products pr set wh_qty = pr.wh_qty + l.qty, updated_at = now() from app.lines(p->'lines') l where pr.id = l.product_id;
  insert into purchases (product_id, qty, supplier, by_id, by_name) select l.product_id, l.qty, sup.name || ' ' || gno, u.id, u.name from app.lines(p->'lines') l;
  select sum(qty * std_cost_usd), sum(qty) into v, n from grn_items where grn_id = gid;
  perform app.post('goods_in', current_date, gno || ' from ' || sup.name || coalesce(', ' || nullif(btrim(p->>'ref'), ''), ''), gno, 'grn', gid,
    jsonb_build_array(jsonb_build_object('code', 'INV_STORE', 'side', 'Dr', 'amount', round(v, 2)),
                      jsonb_build_object('code', 'GRNI', 'side', 'Cr', 'amount', round(v, 2))), u.name);
  perform app.log(u, format('Received %s from %s: %s units, waiting for the bill', gno, sup.name, n));
  return jsonb_build_object('id', gid, 'no', gno);
end $$;

-- the supplier's bill: for goods received (GRN), or a direct bill against any ledger (transport, services...)
create or replace function public.enter_bill(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); g public.grns; sup public.suppliers; cur text := coalesce(p->>'currency', 'USD');
  r numeric := app.num(p->>'rate'); amt numeric := app.num(p->>'amount'); vat numeric := coalesce(app.num(p->>'vat'), 0);
  bdate date := coalesce((p->>'bill_date')::date, current_date); due date; bno text := btrim(coalesce(p->>'bill_no','')); std numeric := 0;
  base_total numeric; diff numeric; lines jsonb; vid uuid; debit uuid := (p->>'account_id')::uuid;
begin
  if (p->>'grn_id') is not null then
    select * into g from grns where id = (p->>'grn_id')::uuid for update;
    if not found then raise exception 'Goods receipt not found'; end if;
    if g.status <> 'awaiting_bill' then raise exception 'The bill for % was already entered', g.no; end if;
    select * into sup from suppliers where id = g.supplier_id;
    select coalesce(sum(qty * std_cost_usd), 0) into std from grn_items where grn_id = g.id;
  else
    select * into sup from suppliers where id = (p->>'supplier_id')::uuid;
    if not found then raise exception 'Choose the supplier'; end if;
    if debit is null or not exists (select 1 from accounts where id = debit and active) then raise exception 'Choose what the bill is for (the ledger to charge)'; end if;
  end if;
  if bno = '' then raise exception 'Enter the supplier''s bill number'; end if;
  if amt is null or amt <= 0 then raise exception 'Enter the bill amount'; end if;
  if vat < 0 then raise exception 'VAT cannot be negative'; end if;
  if cur not in ('USD','FC') then raise exception 'Currency must be USD or FC'; end if;
  r := coalesce(r, (select rate from settings where id = 1));
  if r <= 0 then raise exception 'Exchange rate must be above zero'; end if;
  due := coalesce((p->>'due_date')::date, bdate + sup.credit_days);
  base_total := case when cur = 'USD' then amt + vat else (amt + vat) / r end;
  lines := jsonb_build_array(jsonb_build_object('account', sup.account_id, 'side', 'Cr', 'amount', amt + vat, 'currency', cur, 'rate', r,
             'bill_ref', bno, 'due_date', due, 'memo', 'Bill ' || bno),
           jsonb_build_object('code', 'VAT_IN', 'side', 'Dr', 'amount', vat, 'currency', cur, 'rate', r, 'memo', 'VAT on bill ' || bno));
  if g.id is not null then
    -- goods valued at their item cost go to GRNI; the difference with the bill goes to purchase price difference
    diff := (base_total - case when cur = 'USD' then vat else vat / r end) - round(std, 2);
    lines := lines || jsonb_build_array(jsonb_build_object('code', 'GRNI', 'side', 'Dr', 'amount', round(std, 2), 'memo', g.no),
      jsonb_build_object('code', 'PPV', 'side', case when diff >= 0 then 'Dr' else 'Cr' end, 'amount', round(abs(diff), 2), 'memo', 'Bill vs item cost, ' || g.no));
  else
    lines := lines || jsonb_build_array(jsonb_build_object('account', debit, 'side', 'Dr', 'amount', amt, 'currency', cur, 'rate', r, 'memo', coalesce(p->>'narration','')));
  end if;
  vid := app.post('purchase', bdate, 'Bill ' || bno || ' from ' || sup.name || coalesce(', ' || g.no, '') || coalesce(', ' || nullif(btrim(p->>'narration'), ''), ''),
    bno, 'bill', coalesce(g.id, gen_random_uuid()), lines, u.name);
  if g.id is not null then update grns set status = 'billed', bill_voucher_id = vid where id = g.id; end if;
  perform app.log(u, format('Bill %s from %s entered: %s %s, due %s', bno, sup.name, amt + vat, cur, due));
  return jsonb_build_object('voucher_id', vid, 'due_date', due);
end $$;

-- ---------- manual vouchers: payment, receipt, contra, journal, debit/credit note ----------
create or replace function public.post_voucher(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); t text := p->>'type'; vid uuid; a jsonb; bill public.vouchers; outst numeric; cashbank int; nonc int;
  vdate date := coalesce((p->>'date')::date, current_date);
begin
  if t not in ('payment','receipt','contra','journal','debit_note','credit_note') then raise exception 'Choose the voucher type'; end if;
  if jsonb_typeof(p->'lines') <> 'array' or jsonb_array_length(p->'lines') < 2 then raise exception 'A voucher needs at least two lines'; end if;
  select count(*) filter (where ac.group_code in ('cash','bank')), count(*) filter (where ac.group_code not in ('cash','bank')) into cashbank, nonc
    from jsonb_array_elements(p->'lines') l join accounts ac on ac.id = (l->>'account')::uuid;
  if t = 'contra' and nonc > 0 then raise exception 'A contra voucher only moves money between cash and bank ledgers'; end if;
  if t = 'payment' and not exists (select 1 from jsonb_array_elements(p->'lines') l join accounts ac on ac.id = (l->>'account')::uuid where l->>'side' = 'Cr' and ac.group_code in ('cash','bank')) then
    raise exception 'A payment is paid from a cash or bank ledger (Cr)';
  end if;
  if t = 'receipt' and not exists (select 1 from jsonb_array_elements(p->'lines') l join accounts ac on ac.id = (l->>'account')::uuid where l->>'side' = 'Dr' and ac.group_code in ('cash','bank')) then
    raise exception 'A receipt goes into a cash or bank ledger (Dr)';
  end if;
  vid := app.post(t, vdate, p->>'narration', p->>'ref', null, null, p->'lines', u.name);
  if vid is null then raise exception 'Enter the amounts'; end if;
  -- bill-wise: which supplier bills this payment (or debit note) settles
  for a in select * from jsonb_array_elements(coalesce(p->'allocations','[]')) loop
    select * into bill from vouchers where id = (a->>'bill_id')::uuid and status = 'posted';
    if not found then raise exception 'Bill not found'; end if;
    select app.bill_outstanding(bill.id) into outst;
    if app.num(a->>'amount') > outst + 0.01 then raise exception 'More than the % still due on bill %', round(outst, 2), bill.ref; end if;
    insert into bill_allocations (voucher_id, bill_id, amount_base) values (vid, bill.id, app.num(a->>'amount'));
  end loop;
  perform app.log(u, format('%s %s posted: %s', initcap(replace(t, '_', ' ')), (select no from vouchers where id = vid), coalesce(p->>'narration','')));
  return jsonb_build_object('id', vid, 'no', (select no from vouchers where id = vid));
end $$;

create or replace function public.cancel_voucher(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); v public.vouchers;
begin
  select * into v from vouchers where id = p_id and status = 'posted' for update;
  if not found then raise exception 'Voucher not found'; end if;
  if length(btrim(coalesce(p_reason,''))) < 4 then raise exception 'Write a short reason'; end if;
  if v.type not in ('payment','receipt','contra','journal','debit_note','credit_note','purchase') then
    raise exception 'This voucher was made by SIM from % and follows it; correct the source instead', v.source_type;
  end if;
  if v.type = 'purchase' and exists (select 1 from bill_allocations where bill_id = p_id) then raise exception 'This bill is already (partly) paid; cancel the payment first'; end if;
  update vouchers set status = 'cancelled', cancel_reason = btrim(p_reason) where id = p_id;
  delete from bill_allocations where voucher_id = p_id;
  update grns set status = 'awaiting_bill', bill_voucher_id = null where bill_voucher_id = p_id;
  perform app.log(u, format('Voucher %s cancelled: %s', v.no, btrim(p_reason)));
end $$;

-- ---------- ledgers ----------
create or replace function public.save_account(p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); aid uuid := (p->>'id')::uuid; a public.accounts; n text := btrim(coalesce(p->>'name',''));
  g text := p->>'group_code'; oa numeric := coalesce(app.num(p->>'opening_amount'), 0); ocur text := coalesce(p->>'opening_currency','USD'); orate numeric := app.num(p->>'opening_rate');
begin
  if n = '' then raise exception 'Enter the ledger name'; end if;
  if exists (select 1 from accounts where lower(name) = lower(n) and id is distinct from aid) then raise exception 'A ledger called "%" already exists', n; end if;
  if oa < 0 then raise exception 'Opening balance cannot be negative; choose Dr or Cr'; end if;
  if ocur = 'FC' and coalesce(orate,0) <= 0 then select rate into orate from settings where id = 1; end if;
  if aid is null then
    if not exists (select 1 from account_groups where code = g) then raise exception 'Choose the group'; end if;
    if g = 'creditors' then raise exception 'Suppliers are added under Suppliers, which also makes their ledger'; end if;
    insert into accounts (name, group_code, currency, opening_amount, opening_side, opening_currency, opening_rate)
      values (n, g, coalesce(p->>'currency','USD'), oa, coalesce(p->>'opening_side','Dr'), ocur, orate) returning id into aid;
    perform app.log(u, 'Added ledger ' || n);
  else
    select * into a from accounts where id = aid for update;
    if not found then raise exception 'Ledger not found'; end if;
    if a.supplier_id is not null then raise exception 'Edit this ledger from the supplier'; end if;
    update accounts set name = n, group_code = case when a.system then a.group_code else coalesce(g, a.group_code) end, currency = coalesce(p->>'currency', a.currency),
      opening_amount = oa, opening_side = coalesce(p->>'opening_side','Dr'), opening_currency = ocur, opening_rate = orate,
      active = case when a.system then true else coalesce((p->>'active')::boolean, a.active) end where id = aid;
    perform app.log(u, 'Updated ledger ' || n);
  end if;
  return aid;
end $$;

create or replace function public.delete_account(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); a public.accounts;
begin
  select * into a from accounts where id = p_id;
  if not found then raise exception 'Ledger not found'; end if;
  if a.system or a.supplier_id is not null then raise exception 'This ledger is used by SIM and cannot be deleted'; end if;
  if exists (select 1 from voucher_lines where account_id = p_id) then raise exception 'This ledger has entries; make it inactive instead'; end if;
  delete from accounts where id = p_id;
  perform app.log(u, 'Deleted ledger ' || a.name);
end $$;

-- ---------- stock adjustment (physical count in the central store) ----------
create or replace function public.adjust_stock(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); pr public.products; counted int := app.int_or_raise(p->>'counted', 'Counted quantity'); delta int; v numeric;
  reason text := btrim(coalesce(p->>'reason',''));
begin
  select * into pr from products where id = (p->>'product_id')::uuid and active for update;
  if not found then raise exception 'Item not found'; end if;
  if length(reason) < 4 then raise exception 'Write a short reason'; end if;
  delta := counted - pr.wh_qty;
  if delta = 0 then raise exception 'The store already has % %', counted, pr.stock_unit; end if;
  update products set wh_qty = counted, updated_at = now() where id = pr.id;
  select abs(delta) * cost_usd into v from product_costs where product_id = pr.id;
  perform app.post('adjustment', current_date, format('Stock count %s: %s to %s %s, %s', pr.name, pr.wh_qty, counted, pr.stock_unit, reason), pr.sku, null, null,
    jsonb_build_array(jsonb_build_object('code', 'INV_STORE', 'side', case when delta > 0 then 'Dr' else 'Cr' end, 'amount', round(coalesce(v,0), 2)),
                      jsonb_build_object('code', 'STOCK_ADJ', 'side', case when delta > 0 then 'Cr' else 'Dr' end, 'amount', round(coalesce(v,0), 2))), u.name);
  perform app.log(u, format('Stock of %s in the central store set from %s to %s: %s', pr.name, pr.wh_qty, counted, reason));
end $$;

-- ---------- shop returns to the central store ----------
create or replace function public.create_return(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); rid uuid; rno text; short text; v numeric; reason text := btrim(coalesce(p->>'reason',''));
begin
  if length(reason) < 4 then raise exception 'Write why the goods go back'; end if;
  if not exists (select 1 from app.lines(p->'lines')) then raise exception 'Enter a quantity for at least one item'; end if;
  select string_agg(pr.name || ' (' || coalesce(st.qty,0) || ' in shop)', ', ') into short from app.lines(p->'lines') l join products pr on pr.id = l.product_id
    left join shop_stock st on st.shop_id = u.shop_id and st.product_id = l.product_id where coalesce(st.qty, 0) < l.qty;
  if short is not null then raise exception 'The shop does not have that many: %', short; end if;
  rno := 'RET-' || lpad(nextval('return_seq')::text, 4, '0');
  insert into shop_returns (no, shop_id, reason, created_by_name) values (rno, u.shop_id, reason, u.name) returning id into rid;
  insert into return_items (return_id, product_id, qty, cost_usd)
    select rid, l.product_id, l.qty, coalesce(c.cost_usd, 0) from app.lines(p->'lines') l left join product_costs c on c.product_id = l.product_id;
  update shop_stock s set qty = s.qty - l.qty from app.lines(p->'lines') l where s.shop_id = u.shop_id and s.product_id = l.product_id;
  select sum(qty * cost_usd) into v from return_items where return_id = rid;
  perform app.post('return', current_date, rno || ' sent back by ' || (select name from shops where id = u.shop_id) || ': ' || reason, rno, 'return_out', rid,
    jsonb_build_array(jsonb_build_object('code', 'TRANSIT', 'side', 'Dr', 'amount', round(v, 2)),
                      jsonb_build_object('account', app.shop_acc('INV_SHOP', u.shop_id), 'side', 'Cr', 'amount', round(v, 2))), u.name);
  perform app.log(u, format('Return %s sent to the central store: %s', rno, reason));
  return jsonb_build_object('id', rid, 'no', rno);
end $$;

create or replace function public.cancel_return(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin','admin'); x public.shop_returns;
begin
  select * into x from shop_returns where id = p_id and (u.role = 'admin' or shop_id = u.shop_id) for update;
  if not found then raise exception 'Return not found'; end if;
  if x.status <> 'pending' then raise exception 'Return % was already %', x.no, x.status; end if;
  if length(btrim(coalesce(p_reason,''))) < 4 then raise exception 'Write a short reason'; end if;
  update shop_stock s set qty = s.qty + i.qty from return_items i where i.return_id = p_id and s.shop_id = x.shop_id and s.product_id = i.product_id;
  update shop_returns set status = 'cancelled', received_note = btrim(p_reason) where id = p_id;
  update vouchers set status = 'cancelled', cancel_reason = 'Return cancelled: ' || btrim(p_reason) where source_type = 'return_out' and source_id = p_id and status = 'posted';
  perform app.log(u, format('Return %s cancelled: %s', x.no, btrim(p_reason)));
end $$;

create or replace function public.receive_return(p_id uuid, p_lines jsonb, p_note text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin','whop'); x public.shop_returns; sent int; got int; vgot numeric; vshort numeric; bad text; note text := btrim(coalesce(p_note,''));
begin
  select * into x from shop_returns where id = p_id for update;
  if not found then raise exception 'Return not found'; end if;
  if x.status <> 'pending' then raise exception 'Return % was already %', x.no, x.status; end if;
  if exists (select 1 from jsonb_array_elements(coalesce(p_lines,'[]')) e where coalesce(e->>'qty','') !~ '^\d{1,7}$') then raise exception 'Quantities must be whole numbers'; end if;
  update return_items i set received_qty = coalesce((select (e->>'qty')::int from jsonb_array_elements(p_lines) e where (e->>'product_id')::uuid = i.product_id), i.qty)
    where i.return_id = p_id;
  select string_agg(pr.name, ', ') into bad from return_items i join products pr on pr.id = i.product_id where i.return_id = p_id and i.received_qty > i.qty;
  if bad is not null then raise exception 'You cannot receive more than was sent: %', bad; end if;
  select sum(qty), sum(received_qty), sum(received_qty * cost_usd), sum((qty - received_qty) * cost_usd) into sent, got, vgot, vshort from return_items where return_id = p_id;
  if got < sent and length(note) < 4 then raise exception 'Some items arrived short. Write a short note saying what happened'; end if;
  update products pr set wh_qty = pr.wh_qty + i.received_qty, updated_at = now() from return_items i where i.return_id = p_id and pr.id = i.product_id;
  update shop_returns set status = 'received', received_at = now(), received_by_name = u.name, received_note = nullif(note, '') where id = p_id;
  perform app.post('return', current_date, x.no || ' received in the central store' || coalesce(', ' || nullif(note, ''), ''), x.no, 'return_in', p_id,
    jsonb_build_array(jsonb_build_object('code', 'INV_STORE', 'side', 'Dr', 'amount', round(vgot, 2)),
                      jsonb_build_object('code', 'STOCK_ADJ', 'side', 'Dr', 'amount', round(vshort, 2), 'memo', 'Short on return ' || x.no),
                      jsonb_build_object('code', 'TRANSIT', 'side', 'Cr', 'amount', round(vgot, 2) + round(vshort, 2))), u.name);
  perform app.log(u, format('Return %s received: %s of %s units%s', x.no, got, sent, coalesce(', ' || nullif(note, ''), '')));
  return jsonb_build_object('sent', sent, 'received', got);
end $$;

-- ---------- expenses (upkeep) are now payment vouchers ----------
drop function if exists public.add_upkeep(date, text, text, numeric);
create or replace function public.add_upkeep(p_date date, p_category text, p_desc text, p_amount numeric, p_currency text default 'USD', p_from uuid default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); acc uuid; usd numeric; r numeric;
begin
  if p_date is null or p_date > current_date + 1 then raise exception 'Choose a date'; end if;
  if length(btrim(coalesce(p_desc,''))) = 0 then raise exception 'Describe the expense'; end if;
  if coalesce(p_amount,0) <= 0 then raise exception 'Enter an amount above zero'; end if;
  if coalesce(p_currency,'USD') not in ('USD','FC') then raise exception 'Currency must be USD or FC'; end if;
  select rate into r from settings where id = 1;
  usd := case when p_currency = 'FC' then p_amount / r else p_amount end;
  acc := app.acc(case btrim(p_category) when 'Rent' then 'EXP_RENT' when 'Electricity & fuel' then 'EXP_POWER' when 'Security' then 'EXP_SECURITY'
    when 'Salaries' then 'EXP_SALARIES' when 'Transport' then 'EXP_TRANSPORT' when 'Maintenance' then 'EXP_MAINT' when 'Taxes & licences' then 'EXP_TAXES' else 'EXP_OTHER' end);
  if p_from is not null and not exists (select 1 from accounts where id = p_from and group_code in ('cash','bank') and active) then raise exception 'Pay from a cash or bank ledger'; end if;
  insert into upkeep (date, category, description, amount_usd, by_name) values (p_date, left(btrim(p_category),40), left(btrim(p_desc),80), round(usd, 2), u.name);
  perform app.post('payment', p_date, btrim(p_category) || ': ' || btrim(p_desc), '', null, null,
    jsonb_build_array(jsonb_build_object('account', acc, 'side', 'Dr', 'amount', p_amount, 'currency', coalesce(p_currency,'USD'), 'rate', r),
                      jsonb_build_object('account', coalesce(p_from, app.acc('CASH_HO')), 'side', 'Cr', 'amount', p_amount, 'currency', coalesce(p_currency,'USD'), 'rate', r)), u.name);
  perform app.log(u, format('Expense %s: %s %s', btrim(p_category), p_amount, coalesce(p_currency,'USD')));
end $$;

-- ---------- reports ----------
create or replace function app.bill_outstanding(p_bill uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce((select sum(l.base) from voucher_lines l join accounts a on a.id = l.account_id where l.voucher_id = p_bill and l.side = 'Cr' and a.group_code = 'creditors'), 0)
       - coalesce((select sum(amount_base) from bill_allocations ba join vouchers v on v.id = ba.voucher_id where ba.bill_id = p_bill and v.status = 'posted'), 0)
$$;

-- who may read a ledger's statement: Admin any; warehouse the stock ledgers; shop admin their shop's ledgers
create or replace function app.can_read_account(a public.accounts, u public.profiles) returns boolean
language sql stable as $$
  select coalesce(u.role = 'admin' or (u.role = 'whop' and a.group_code = 'stock') or (u.role = 'shopadmin' and a.shop_id = u.shop_id), false)
$$;

create or replace function public.account_statement(p_account uuid, p_from date, p_to date, p_opening boolean default true) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin','whop','shopadmin'); a public.accounts; bf numeric := 0; res jsonb;
begin
  select * into a from accounts where id = p_account;
  if not found or not app.can_read_account(a, u) then raise exception 'Ledger not found'; end if;
  if p_from > p_to then select p_to, p_from into p_from, p_to; end if;
  if p_opening then
    bf := app.opening_base(a) + coalesce((select sum(case when l.side = 'Dr' then l.base else -l.base end) from voucher_lines l join vouchers v on v.id = l.voucher_id
      where l.account_id = a.id and v.status = 'posted' and v.date < p_from), 0);
  end if;
  select jsonb_build_object(
    'account', jsonb_build_object('id', a.id, 'name', a.name, 'group', (select name from account_groups where code = a.group_code), 'currency', a.currency,
      'opening_amount', a.opening_amount, 'opening_side', a.opening_side, 'opening_currency', a.opening_currency),
    'from', p_from, 'to', p_to, 'with_opening', p_opening, 'brought_forward', round(bf, 2),
    'lines', coalesce((select jsonb_agg(x order by x.date, x.no, x.id) from (
       select l.id, v.date, v.no, v.type, v.narration, l.memo, l.side, l.amount, l.currency, l.rate, round(l.base, 2) as base, l.bill_ref, l.due_date
       from voucher_lines l join vouchers v on v.id = l.voucher_id
       where l.account_id = a.id and v.status = 'posted' and v.date between p_from and p_to) x), '[]'),
    'total_dr', round(coalesce((select sum(l.base) from voucher_lines l join vouchers v on v.id = l.voucher_id where l.account_id = a.id and v.status = 'posted' and l.side = 'Dr' and v.date between p_from and p_to), 0), 2),
    'total_cr', round(coalesce((select sum(l.base) from voucher_lines l join vouchers v on v.id = l.voucher_id where l.account_id = a.id and v.status = 'posted' and l.side = 'Cr' and v.date between p_from and p_to), 0), 2)
  ) into res;
  return res || jsonb_build_object('closing', round(bf + (res->>'total_dr')::numeric - (res->>'total_cr')::numeric, 2));
end $$;

-- the ledgers a user may open a statement for, with their balance in USD
create or replace function public.ledger_list() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin','whop','shopadmin');
begin
  return coalesce((select jsonb_agg(x order by x.sort, x.name) from (
    select a.id, a.code, a.name, a.group_code, g.name as group_name, g.nature, g.sort, a.currency, a.system, a.active, a.supplier_id, a.shop_id,
      a.opening_amount, a.opening_side, a.opening_currency, a.opening_rate,
      round(app.opening_base(a) + coalesce((select sum(case when l.side = 'Dr' then l.base else -l.base end) from voucher_lines l join vouchers v on v.id = l.voucher_id
        where l.account_id = a.id and v.status = 'posted'), 0), 2) as balance
    from accounts a join account_groups g on g.code = a.group_code where app.can_read_account(a, u)) x), '[]');
end $$;

create or replace function public.trial_balance(p_as_of date, p_opening boolean default true) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); rows jsonb; diff numeric;
begin
  select coalesce(jsonb_agg(x order by x.sort, x.name), '[]') into rows from (
    select a.id, a.name, g.name as group_name, g.nature, g.sort,
      round((case when p_opening then app.opening_base(a) else 0 end) + coalesce((select sum(case when l.side = 'Dr' then l.base else -l.base end) from voucher_lines l
        join vouchers v on v.id = l.voucher_id where l.account_id = a.id and v.status = 'posted' and v.date <= p_as_of), 0), 2) as balance
    from accounts a join account_groups g on g.code = a.group_code) x where x.balance <> 0;
  select coalesce(sum(app.opening_base(a)), 0) into diff from accounts a;
  return jsonb_build_object('as_of', p_as_of, 'with_opening', p_opening, 'rows', rows,
    'total_dr', (select coalesce(sum((r->>'balance')::numeric), 0) from jsonb_array_elements(rows) r where (r->>'balance')::numeric > 0),
    'total_cr', (select coalesce(-sum((r->>'balance')::numeric), 0) from jsonb_array_elements(rows) r where (r->>'balance')::numeric < 0),
    'opening_difference', case when p_opening then round(diff, 2) else 0 end);
end $$;

create or replace function public.profit_loss(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); rows jsonb;
begin
  select coalesce(jsonb_agg(x order by x.sort, x.name), '[]') into rows from (
    select a.name, g.name as group_name, g.code as group_code, g.nature, g.sort,
      round(coalesce(sum(case when (g.nature = 'income') = (l.side = 'Cr') then l.base else -l.base end), 0), 2) as amount
    from accounts a join account_groups g on g.code = a.group_code
    join voucher_lines l on l.account_id = a.id join vouchers v on v.id = l.voucher_id and v.status = 'posted' and v.date between p_from and p_to
    where g.nature in ('income','expense') group by a.id, a.name, g.name, g.code, g.nature, g.sort) x where x.amount <> 0;
  return jsonb_build_object('from', p_from, 'to', p_to, 'rows', rows,
    'income', (select coalesce(sum((r->>'amount')::numeric), 0) from jsonb_array_elements(rows) r where r->>'nature' = 'income'),
    'expense', (select coalesce(sum((r->>'amount')::numeric), 0) from jsonb_array_elements(rows) r where r->>'nature' = 'expense'),
    'gross_income', (select coalesce(sum((r->>'amount')::numeric), 0) from jsonb_array_elements(rows) r where r->>'group_code' in ('sales','dirinc')),
    'direct_expense', (select coalesce(sum((r->>'amount')::numeric), 0) from jsonb_array_elements(rows) r where r->>'group_code' = 'direxp'));
end $$;

create or replace function public.balance_sheet(p_as_of date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); rows jsonb; profit numeric;
begin
  select coalesce(jsonb_agg(x order by x.sort, x.name), '[]') into rows from (
    select a.name, g.name as group_name, g.nature, g.sort,
      round(app.opening_base(a) + coalesce((select sum(case when l.side = 'Dr' then l.base else -l.base end) from voucher_lines l join vouchers v on v.id = l.voucher_id
        where l.account_id = a.id and v.status = 'posted' and v.date <= p_as_of), 0), 2) as balance
    from accounts a join account_groups g on g.code = a.group_code where g.nature in ('asset','liability','equity')) x where x.balance <> 0;
  select round(coalesce(sum(case when l.side = 'Cr' then l.base else -l.base end), 0), 2) into profit from voucher_lines l
    join vouchers v on v.id = l.voucher_id and v.status = 'posted' and v.date <= p_as_of
    join accounts a on a.id = l.account_id join account_groups g on g.code = a.group_code where g.nature in ('income','expense');
  return jsonb_build_object('as_of', p_as_of, 'rows', rows, 'profit', profit,
    'assets', (select coalesce(sum((r->>'balance')::numeric), 0) from jsonb_array_elements(rows) r where r->>'nature' = 'asset'),
    'liabilities', (select coalesce(-sum((r->>'balance')::numeric), 0) from jsonb_array_elements(rows) r where r->>'nature' in ('liability','equity')));
end $$;

create or replace function public.day_book(p_from date, p_to date, p_type text default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin');
begin
  return coalesce((select jsonb_agg(x order by x.date, x.no) from (
    select v.id, v.no, v.type, v.date, v.narration, v.ref, v.status, v.cancel_reason, v.created_by_name, v.source_type,
      (select jsonb_agg(jsonb_build_object('account', a.name, 'side', l.side, 'amount', l.amount, 'currency', l.currency, 'rate', l.rate, 'base', round(l.base, 2), 'memo', l.memo) order by l.side desc, l.id)
        from voucher_lines l join accounts a on a.id = l.account_id where l.voucher_id = v.id) as lines
    from vouchers v where v.date between p_from and p_to and (p_type is null or v.type = p_type) limit 2000) x), '[]');
end $$;

-- money owed to suppliers, bill by bill, with due dates and ageing
create or replace function public.payables(p_as_of date default current_date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin');
begin
  return coalesce((select jsonb_agg(s order by s.name) from (
    select sp.id, sp.name, sp.credit_days, sp.phone,
      round(-(app.opening_base(a) + coalesce((select sum(case when l.side = 'Dr' then l.base else -l.base end) from voucher_lines l join vouchers v on v.id = l.voucher_id
        where l.account_id = a.id and v.status = 'posted' and v.date <= p_as_of), 0)), 2) as balance,
      coalesce((select jsonb_agg(b order by b.due_date) from (
        select v.id, v.no, v.date, l.bill_ref, l.due_date, round(l.base, 2) as amount, l.amount as original, l.currency,
          round(app.bill_outstanding(v.id), 2) as outstanding, (p_as_of - l.due_date) as days_overdue
        from voucher_lines l join vouchers v on v.id = l.voucher_id
        where l.account_id = a.id and v.status = 'posted' and l.side = 'Cr' and v.type = 'purchase' and v.date <= p_as_of) b where b.outstanding > 0.005), '[]') as bills
    from suppliers sp join accounts a on a.id = sp.account_id) s), '[]');
end $$;

-- ---------- existing data: shop ledgers and the stock already on hand ----------
do $$
declare s record; store numeric; shops_v numeric := 0; lines jsonb := '[]';
begin
  for s in select id from shops loop
    perform app.shop_acc('INV_SHOP', s.id); perform app.shop_acc('CASH_SHOP', s.id); perform app.shop_acc('SALES_SHOP', s.id);
  end loop;
  if not exists (select 1 from vouchers) then
    select coalesce(sum(p.wh_qty * c.cost_usd), 0) into store from products p join product_costs c on c.product_id = p.id where p.active and p.wh_qty > 0;
    if store > 0 then lines := lines || jsonb_build_array(jsonb_build_object('code', 'INV_STORE', 'side', 'Dr', 'amount', round(store, 2))); end if;
    for s in select st.shop_id, sum(st.qty * c.cost_usd) v from shop_stock st join product_costs c on c.product_id = st.product_id where st.qty > 0 group by st.shop_id loop
      lines := lines || jsonb_build_array(jsonb_build_object('account', app.shop_acc('INV_SHOP', s.shop_id), 'side', 'Dr', 'amount', round(s.v, 2)));
      shops_v := shops_v + round(s.v, 2);
    end loop;
    if store + shops_v > 0 then
      lines := lines || jsonb_build_array(jsonb_build_object('code', 'OPENING', 'side', 'Cr', 'amount', round(store, 2) + shops_v));
      perform app.post('opening', current_date, 'Opening stock at cost when the books started', '', null, null, lines, 'system');
    end if;
  end if;
end $$;

-- new shops get their ledgers at once
create or replace function app.trg_shop() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin perform app.shop_acc('INV_SHOP', new.id); perform app.shop_acc('CASH_SHOP', new.id); perform app.shop_acc('SALES_SHOP', new.id); return new; end $$;
drop trigger if exists shop_books on public.shops;
create trigger shop_books after insert on public.shops for each row execute function app.trg_shop();

-- ---------- who may call what ----------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
revoke execute on function public.receive_stock(uuid, int, int, text) from authenticated;
grant execute on function public.save_supplier(jsonb), public.receive_goods(jsonb), public.enter_bill(jsonb), public.post_voucher(jsonb),
  public.cancel_voucher(uuid, text), public.save_account(jsonb), public.delete_account(uuid), public.adjust_stock(jsonb),
  public.create_return(jsonb), public.cancel_return(uuid, text), public.receive_return(uuid, jsonb, text),
  public.add_upkeep(date, text, text, numeric, text, uuid), public.account_statement(uuid, date, date, boolean), public.ledger_list(),
  public.trial_balance(date, boolean), public.profit_loss(date, date), public.balance_sheet(date), public.day_book(date, date, text),
  public.payables(date) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
