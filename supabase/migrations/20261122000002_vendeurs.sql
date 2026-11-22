-- QuickSales: vendeurs, goods on credit from the shops, and promo items.
-- A switch in Settings (Selling), off by default. With it on, the Shop Admin keeps vendeurs (resellers who take goods
-- on credit): each has a credit period in days and a credit limit in CDF.
--   - Goods on credit: at the till the Shop Admin sells to a vendeur "on credit". The invoice is in the vendeur's name,
--     the stock leaves the shop as for any sale, nothing is paid at the till, and the vendeur owes the total, due
--     after the credit period. Goods can still be given when the vendeur is overdue or over the limit: the till warns.
--   - Payments: partial or full, in CDF, taken in the shop's cash. What the vendeur owes goes down, so the credit
--     available comes back. Payments settle the oldest goods first.
--   - Promo items: given free with the goods (or on their own), picked from the shop's stock. They are not on the
--     invoice and the vendeur does not owe them; they are valued at the shop price, and leave the stock at cost as a
--     promotion expense in the books.
--   - The promo report: each month the Shop Admin sees the promo items given to each vendeur and either keeps the
--     report (its promos stay open and keep adding up) or settles it (the count starts again at zero).
-- The books: each vendeur has a ledger under Sundry Debtors. A sale on credit is Dr the vendeur (not cash); a payment
-- is Dr the shop's cash, Cr the vendeur; promo items are Dr Promotions (goods given free), Cr the shop's stock.
-- The shift end report and the day end slip count only the cash: goods on credit are left out of Collected (they show
-- as "On credit"), and the vendeurs' payments are added to it.
-- Already running QuickSales? Run this file once, after 20261122000001_net_cost.sql. It changes no data.

-- stop at once if the update before this one was not run
do $$ begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'product_costs' and column_name = 'net_cost_usd') then
    raise exception 'Run supabase/migrations/20261122000001_net_cost.sql (and every earlier file) first, then this file. supabase/scripts/check_migrations.sql shows what is missing';
  end if;
end $$;

-- ---------- tables ----------
create table if not exists public.vendeurs (
  id              uuid primary key default gen_random_uuid(),
  shop_id         uuid not null references public.shops(id),
  name            text not null check (length(btrim(name)) between 1 and 40),
  phone           text not null default '',
  address         text not null default '',
  notes           text not null default '',
  credit_days     int not null default 30 check (credit_days between 0 and 365),
  credit_limit    bigint not null default 0 check (credit_limit >= 0),      -- CDF
  opening_balance bigint not null default 0 check (opening_balance >= 0),   -- CDF already owed when the vendeur was added
  active          boolean not null default true,
  account_id      uuid references public.accounts(id),
  created_by_name text not null default '',
  created_at      timestamptz not null default now()
);
create unique index if not exists vendeurs_name_key on public.vendeurs (shop_id, lower(name));
alter table public.accounts add column if not exists vendeur_id uuid;

-- a sale on credit: the vendeur who owes it, and when
alter table public.invoices add column if not exists vendeur_id uuid references public.vendeurs(id);
alter table public.invoices add column if not exists due_date date;
create index if not exists invoices_vendeur on public.invoices (vendeur_id) where vendeur_id is not null;

create table if not exists public.vendeur_seq (kind text not null, shop_id uuid not null references public.shops(id), n int not null default 0, primary key (kind, shop_id));

create table if not exists public.vendeur_payments (
  id                uuid primary key default gen_random_uuid(),
  no                text not null unique,
  vendeur_id        uuid not null references public.vendeurs(id),
  shop_id           uuid not null references public.shops(id),
  device_id         uuid references public.devices(id),          -- the till it was taken at, if any
  amount            bigint not null check (amount > 0),          -- CDF
  rate              numeric(12,2) not null,
  note              text not null default '',
  status            text not null default 'ok' check (status in ('ok','cancelled')),
  by_name           text not null,
  at                timestamptz not null default now(),
  cancel_reason     text,
  cancelled_by_name text,
  cancelled_at      timestamptz
);
create index if not exists vendeur_payments_v on public.vendeur_payments (vendeur_id);
create index if not exists vendeur_payments_shop on public.vendeur_payments (shop_id, at);

create table if not exists public.promo_reports (
  id       uuid primary key default gen_random_uuid(),
  shop_id  uuid not null references public.shops(id),
  month    date not null,                                         -- the first day of the month reported
  status   text not null check (status in ('kept','settled')),
  n        int not null default 0,
  total    bigint not null default 0,                             -- CDF, at the shop price
  data     jsonb not null default '{}',                           -- the report as it was: each vendeur and their items
  by_name  text not null,
  at       timestamptz not null default now()
);
create index if not exists promo_reports_shop on public.promo_reports (shop_id, month);

create table if not exists public.vendeur_promos (
  id                uuid primary key default gen_random_uuid(),
  no                text not null unique,
  shop_id           uuid not null references public.shops(id),
  vendeur_id        uuid not null references public.vendeurs(id),
  invoice_id        uuid references public.invoices(id) on delete set null,   -- the goods on credit it went with, if any
  t                 timestamptz not null default now(),
  rate              numeric(12,2) not null,
  value             bigint not null default 0,                   -- CDF, at the shop price
  cost_usd          numeric(16,6) not null default 0,
  note              text not null default '',
  status            text not null default 'open' check (status in ('open','settled','cancelled')),
  report_id         uuid references public.promo_reports(id),
  by_name           text not null,
  settled_at        timestamptz,
  settled_by_name   text,
  cancel_reason     text,
  cancelled_by_name text,
  cancelled_at      timestamptz
);
create index if not exists vendeur_promos_v on public.vendeur_promos (vendeur_id);
create index if not exists vendeur_promos_shop on public.vendeur_promos (shop_id, status, t);

create table if not exists public.vendeur_promo_items (
  promo_id   uuid not null references public.vendeur_promos(id) on delete cascade,
  line_no    int not null,
  product_id uuid not null references public.products(id),
  name       text not null,
  unit       text not null,
  qty        int not null check (qty > 0),                        -- pcs (or sets)
  price      bigint not null,                                     -- CDF per pc (or set), at the shop price
  line       bigint not null,
  cost_usd   numeric(16,6) not null default 0,                    -- per pc (or set)
  primary key (promo_id, line_no)
);

-- only through the functions below
alter table public.vendeurs enable row level security;
alter table public.vendeur_seq enable row level security;
alter table public.vendeur_payments enable row level security;
alter table public.promo_reports enable row level security;
alter table public.vendeur_promos enable row level security;
alter table public.vendeur_promo_items enable row level security;
revoke all on public.vendeurs, public.vendeur_seq, public.vendeur_payments, public.promo_reports, public.vendeur_promos, public.vendeur_promo_items
  from anon, authenticated;

-- promo items leave the stock at cost as a promotion expense
insert into public.accounts (code, name, group_code, currency, system) values
  ('PROMO_EXP','Promotions (goods given free)','indexp','USD',true)
on conflict (code) do nothing;

-- an invoice on credit is never cash: an edit keeps it at nothing received
create or replace function app.trg_invoice_credit() returns trigger
language plpgsql as $$
begin
  if new.vendeur_id is not null then new.tendered := 0; new.change := 0; new.paid_cdf := 0; new.change_cdf := 0; end if;
  return new;
end $$;
drop trigger if exists invoice_credit on public.invoices;
create trigger invoice_credit before insert or update on public.invoices for each row execute function app.trg_invoice_credit();

-- ---------- helpers ----------
-- the next number of a payment (VP) or promo (PR) of a shop: GOM-VP-00001
create or replace function app.vnum(p_kind text, p_shop uuid) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare n int;
begin
  insert into vendeur_seq (kind, shop_id, n) values (p_kind, p_shop, 1)
  on conflict (kind, shop_id) do update set n = vendeur_seq.n + 1 returning vendeur_seq.n into n;
  return (select code from shops where id = p_shop) || '-' || p_kind || '-' || lpad(n::text, 5, '0');
end $$;

-- the shop price of one pc (or one set) in USD, as stock is valued at selling price
create or replace function app.pc_usd(pr public.products) returns numeric
language sql immutable as $$
  select case when pr.is_bundle or pr.price_usd > 0 then pr.price_usd
    when pr.half_dozen_usd > 0 then pr.half_dozen_usd / 6
    when pr.dozen_usd > 0 then pr.dozen_usd / 12
    when pr.carton_usd > 0 and pr.per_carton > 0 then pr.carton_usd / pr.per_carton else 0 end
$$;

-- what a vendeur owes, what is due and overdue, and the credit left. Payments settle the oldest goods first.
create or replace function app.vendeur_state(vd public.vendeurs) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare tz text; today date; paid bigint; rest bigint; bal bigint; r record; items jsonb := '[]'; od bigint := 0; oldest date; ow bigint; lp public.vendeur_payments;
begin
  select settings.tz into tz from settings where id = 1;
  today := (now() at time zone tz)::date;
  select coalesce(sum(amount), 0) into paid from vendeur_payments where vendeur_id = vd.id and status = 'ok';
  rest := paid;
  for r in
    select null::uuid as id, 'Opening balance'::text as no, (vd.created_at at time zone tz)::date as d,
      (vd.created_at at time zone tz)::date + vd.credit_days as due, vd.opening_balance::bigint as amt, vd.created_at as t
    where vd.opening_balance > 0
    union all
    select i.id, i.no, (i.t at time zone tz)::date, coalesce(i.due_date, (i.t at time zone tz)::date + vd.credit_days), i.total, i.t
    from invoices i where i.vendeur_id = vd.id and i.total > 0
    order by t, no
  loop
    if rest >= r.amt then rest := rest - r.amt; continue; end if;
    ow := r.amt - rest; rest := 0;
    items := items || jsonb_build_object('invoice_id', r.id, 'no', r.no, 'date', r.d, 'due', r.due, 'amount', r.amt, 'owed', ow,
      'days_overdue', greatest(today - r.due, 0));
    if oldest is null or r.due < oldest then oldest := r.due; end if;
    if r.due < today then od := od + ow; end if;
  end loop;
  bal := vd.opening_balance + coalesce((select sum(total) from invoices where vendeur_id = vd.id), 0) - paid;
  select * into lp from vendeur_payments where vendeur_id = vd.id and status = 'ok' order by at desc limit 1;
  return jsonb_build_object('balance', bal, 'available', vd.credit_limit - bal, 'over_limit', bal > vd.credit_limit,
    'overdue', od > 0, 'overdue_amount', od, 'oldest_due', oldest,
    'days_overdue', case when oldest is not null and oldest < today then today - oldest else 0 end,
    'open', items,
    'last_payment', case when lp.id is not null then jsonb_build_object('no', lp.no, 'at', lp.at, 'amount', lp.amount) end,
    'promo_open', (select coalesce(sum(value), 0) from vendeur_promos where vendeur_id = vd.id and status = 'open'),
    'promo_open_n', (select count(*) from vendeur_promos where vendeur_id = vd.id and status = 'open'));
end $$;

-- promo items to a vendeur: from the shop's stock, valued at the shop price, booked at cost as a promotion expense
create or replace function app.add_promo(u public.profiles, vd public.vendeurs, p_invoice uuid, p_lines jsonb, p_rate numeric, p_note text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare pid uuid := gen_random_uuid(); pno text; x jsonb; pr public.products; q int; ln int := 0; price bigint; cost numeric;
  val bigint := 0; cst numeric := 0; have int; tz text;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Choose the promo items'; end if;
  if jsonb_array_length(p_lines) > 100 then raise exception 'At most 100 promo lines at a time'; end if;
  if p_rate is null or p_rate <= 0 then raise exception 'Exchange rate is missing'; end if;
  pno := app.vnum('PR', vd.shop_id);
  insert into vendeur_promos (id, no, shop_id, vendeur_id, invoice_id, rate, note, by_name)
    values (pid, pno, vd.shop_id, vd.id, p_invoice, p_rate, left(btrim(coalesce(p_note, '')), 120), u.name);
  for x in select * from jsonb_array_elements(p_lines) loop
    ln := ln + 1;
    select * into pr from products where id = (x->>'product_id')::uuid and active;
    if not found then raise exception 'Unknown promo item on line %', ln; end if;
    q := app.int_or_raise(x->>'qty', 'Promo quantity');
    if q < 1 then raise exception 'Promo quantities must be 1 or more'; end if;
    select qty into have from shop_stock where shop_id = vd.shop_id and product_id = pr.id for update;
    if coalesce(have, 0) < q then
      raise exception 'Not enough % in the shop for the promo: % % in stock', pr.name, greatest(coalesce(have, 0), 0), pr.stock_unit;
    end if;
    price := app.to_cdf(app.pc_usd(pr), p_rate);
    cost := coalesce((select cost_usd from product_costs where product_id = pr.id), 0);
    insert into vendeur_promo_items (promo_id, line_no, product_id, name, unit, qty, price, line, cost_usd)
      values (pid, ln, pr.id, pr.name, pr.stock_unit, q, price, price * q, cost);
    perform app.take(vd.shop_id, pr.id, q, 1, false, pr.pieces_per_set);
    val := val + price * q; cst := cst + cost * q;
  end loop;
  update vendeur_promos set value = val, cost_usd = cst where id = pid;
  select settings.tz into tz from settings where id = 1;
  perform app.post('journal', (now() at time zone tz)::date, format('Promo items %s given to vendeur %s', pno, vd.name), pno, 'promo', pid,
    jsonb_build_array(
      jsonb_build_object('code', 'PROMO_EXP', 'side', 'Dr', 'amount', round(cst, 2), 'currency', 'USD', 'memo', 'Promo items at cost'),
      jsonb_build_object('account', app.shop_acc('INV_SHOP', vd.shop_id), 'side', 'Cr', 'amount', round(cst, 2), 'currency', 'USD', 'memo', 'Promo items at cost')),
    u.name);
  return jsonb_build_object('id', pid, 'no', pno, 'value', val, 'n', ln);
end $$;

-- the promo items of a shop still open at the end of a month (those of earlier months that were kept included):
-- each item and how many were given out, all vendeurs together. No vendeur names, no costs. n and value are kept for
-- the activity log and the report's record, not shown.
create or replace function app.promo_open(p_shop uuid, p_month date) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  with z as (select tz from settings where id = 1),
  pr as (
    select p.*, (p.t at time zone (select tz from z))::date as d from vendeur_promos p
    where p.shop_id = p_shop and p.status = 'open' and (p.t at time zone (select tz from z))::date < (p_month + interval '1 month')::date
  ), it as (
    select i.product_id, min(i.name) as name, min(i.unit) as unit, sum(i.qty) as qty, coalesce(sum(i.qty) filter (where pr.d < p_month), 0) as carried
    from pr join vendeur_promo_items i on i.promo_id = pr.id group by i.product_id
  )
  select jsonb_build_object('month', p_month,
    'n', (select count(*) from pr), 'value', (select coalesce(sum(value), 0) from pr),
    'pcs', (select coalesce(sum(qty), 0) from it), 'carried_pcs', (select coalesce(sum(carried), 0) from it),
    'items', (select coalesce(jsonb_agg(jsonb_build_object('name', name, 'unit', unit, 'qty', qty, 'carried', carried) order by lower(name)), '[]') from it))
$$;

-- ---------- settings: the Vendeurs switch ----------
create or replace function public.save_settings(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); r numeric := app.num(p->>'rate'); v numeric := app.num(p->>'vat'); old numeric; c jsonb := '{}'; k text;
  br numeric := app.num(p->>'book_rate'); old_br numeric;
  fe jsonb := '{}'; cur jsonb;
begin
  if r is null or r <= 0 then raise exception 'Enter a valid exchange rate'; end if;
  if v is null or v < 0 or v > 30 then raise exception 'VAT must be between 0 and 30'; end if;
  if br is not null and br <= 0 then raise exception 'Enter a valid internal rate'; end if;
  foreach k in array array['name','address','phone','email','rccm','idnat','nif','footer'] loop
    c := c || jsonb_build_object(k, left(btrim(coalesce(p->'company'->>k, '')), 80));
  end loop;
  select rate, book_rate, coalesce(features, '{}'::jsonb) into old, old_br, cur from settings where id = 1 for update;
  -- a switch the app did not send keeps the value it has. Turning one off still works, because the app sends it as
  -- false; but an app that knows nothing about a switch can no longer turn it off by saving the page.
  foreach k in array array['customer_optional','barcode','till_sells','cash_change','usd_pay','one_copy','no_warehouse','vendeurs'] loop
    fe := fe || jsonb_build_object(k, coalesce((p->'features'->>k)::boolean, coalesce((cur->>k)::boolean, false)));
  end loop;
  br := coalesce(br, old_br);   -- an older app that does not send the internal rate keeps it as it is
  update settings set rate = r, book_rate = br, vat = v, company = c, features = fe, updated_at = now() where id = 1;
  if old <> r then perform app.log(u, format('Sales rate changed %s to %s', old, r)); end if;
  if old_br <> br then perform app.log(u, format('Internal rate changed %s to %s', old_br, br)); end if;
  if old = r and old_br = br then perform app.log(u, 'Settings updated'); end if;
end $$;

-- ---------- the sale: on credit to a vendeur ----------
create or replace function public.submit_invoice(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin','till'); iid uuid := (p->>'id')::uuid; ex public.invoices; dv public.devices; s public.shops;
  cashier public.profiles; seq int; r numeric := app.num(p->>'rate'); vr numeric := app.num(p->>'vat_rate'); dp numeric; t timestamptz;
  da bigint := app.num(p->>'disc')::bigint;
  it jsonb; pr public.products; pc public.product_costs; ln int := 0; q int; mult int; piece boolean; price bigint; cur bigint; unit text; cost numeric;
  v_gross bigint := 0; v_disc bigint; v_total bigint; v_vat bigint; tend bigint; flag boolean := false;
  cust text := btrim(coalesce(p->>'customer','')); o public.sale_orders; oid uuid := (p->>'order_id')::uuid;
  pusd numeric := round(coalesce(app.num(p->>'paid_usd'), 0), 2); cusd numeric := coalesce(app.num(p->>'change_usd'), 0); pcdf bigint; ccdf bigint; ur numeric;
  sold text; printed text; revised boolean := false;
  vid uuid := nullif(p->>'vendeur_id', '')::uuid; vd public.vendeurs; v_due date; before jsonb; v_promo jsonb;
begin
  if iid is null then raise exception 'Invoice id is missing'; end if;
  select * into ex from invoices where id = iid;
  if found then
    if ex.shop_id <> u.shop_id then raise exception 'Invoice id already used'; end if;
    return jsonb_build_object('status', 'duplicate', 'no', ex.no);
  end if;
  -- a till operator sells only when the Admin turned the switch on, and never approves orders
  if u.role = 'till' then
    if not app.feature('till_sells') then raise exception 'You do not have permission for this action'; end if;
    if oid is not null then raise exception 'Only the shop admin approves orders'; end if;
    -- a discount from a till operator needs the Discount passcode from the Admin (checked below, once the amount is known)
  end if;
  -- goods on credit to a vendeur: the shop admin only, with Vendeurs turned on; the invoice is in the vendeur's name
  if vid is not null then
    if u.role <> 'shopadmin' then raise exception 'Only the shop admin gives goods on credit'; end if;
    if not app.feature('vendeurs') then raise exception 'Vendeurs (goods on credit) are not turned on in Settings'; end if;
    select * into vd from vendeurs where id = vid and shop_id = u.shop_id for update;
    if not found then raise exception 'Vendeur not found'; end if;
    if not vd.active then raise exception 'Vendeur % is inactive', vd.name; end if;
    if pusd > 0 or cusd > 0 then raise exception 'Goods on credit are not paid at the till'; end if;
    cust := vd.name;
    before := app.vendeur_state(vd);
  end if;
  perform app.check_customer(cust);
  select * into dv from devices where id = (p->>'device_id')::uuid and shop_id = u.shop_id for update;
  if not found then raise exception 'This till is not registered for your shop'; end if;
  select * into s from shops where id = u.shop_id;
  if coalesce(p->>'no','') !~ ('^' || s.code || '-' || dv.code || '-\d{6}$') then raise exception 'Invoice number does not match this till'; end if;
  seq := right(p->>'no', 6)::int;
  if oid is not null then
    select * into o from sale_orders where id = oid and shop_id = u.shop_id for update;
    if not found then raise exception 'The order being approved was not found'; end if;
    if o.status <> 'pending' then raise exception 'The order for % was already %', o.customer, o.status; end if;
    -- the invoice the till operator printed keeps its number: approving it never makes a second one
    if o.invoice_no is not null and (p->>'no' is distinct from o.invoice_no or dv.id is distinct from o.device_id) then
      raise exception 'This order was printed at the till as invoice %. Approve it with that number', o.invoice_no;
    end if;
  end if;
  select * into cashier from profiles where id = coalesce((p->>'cashier_id')::uuid, u.id) and shop_id = u.shop_id and role = 'shopadmin';
  if cashier.id is null then cashier := u; end if;
  if r is null or r <= 0 then raise exception 'Exchange rate is missing'; end if;
  if vr is null or vr < 0 or vr > 30 then raise exception 'VAT rate is not valid'; end if;
  -- the discount is a percentage, or an amount in CDF ("disc") whose percentage follows from the total
  dp := round(coalesce(app.num(p->>'disc_pct'), 0), 2);
  if dp < 0 or dp > 30 or da < 0 then raise exception 'Discount must be between 0%% and 30%%'; end if;
  t := coalesce((p->>'t')::timestamptz, now());
  if t > now() + interval '10 minutes' then t := now(); end if;
  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'The sale has no items'; end if;
  insert into invoices (id, no, shop_id, device_id, cashier_id, cashier_name, t, rate, vat_rate, gross, disc_pct, disc, total, vat, ht, tendered, customer, order_id, prepared_by_name)
    values (iid, p->>'no', s.id, dv.id, cashier.id, cashier.name, t, r, vr, 0, dp, 0, 0, 0, 0, 0, cust, oid, o.created_by_name);
  for it in select * from jsonb_array_elements(p->'items') loop
    ln := ln + 1;
    select * into pr from products where id = (it->>'product_id')::uuid;
    if not found then raise exception 'Unknown item on line %', ln; end if;
    select * into pc from product_costs where product_id = pr.id;
    q := app.int_or_raise(it->>'qty', 'Quantity'); if q < 1 then raise exception 'Quantity must be 1 or more'; end if;
    price := app.num(it->>'price')::bigint; if price is null or price <= 0 then raise exception 'Price missing on line %', ln; end if;
    piece := coalesce((it->>'piece')::boolean, false); mult := coalesce(app.num(it->>'mult'), 1)::int;
    unit := app.unit_named(pr, it->>'unit', mult, piece);
    if piece then mult := 0; cost := coalesce(pc.cost_usd,0) / greatest(pr.pieces_per_set,1);
    else cost := coalesce(pc.cost_usd,0) * mult; end if;
    cur := app.unit_price(pr, unit, r);
    if price <> cur then flag := true; end if;
    insert into invoice_items (invoice_id, line_no, product_id, name, unit, mult, piece, qty, price, line, cost_usd)
      values (iid, ln, pr.id, pr.name, unit, mult, piece, q, price, price * q, cost);
    v_gross := v_gross + price * q;
    perform app.take(s.id, pr.id, q, mult, piece, pr.pieces_per_set);
  end loop;
  if da is not null then
    if da * 100 > v_gross * 30 then raise exception 'Discount must be between 0%% and 30%%'; end if;
    v_disc := da; dp := case when v_gross > 0 then round(da * 100.0 / v_gross, 2) else 0 end;
  else
    v_disc := (round(v_gross * dp / 1000.0) * 10)::bigint;
  end if;
  if v_disc > 0 and u.role = 'till' then perform app.use_discount(u, p->>'discount_token', iid); end if;
  v_total := v_gross - v_disc; v_vat := round(v_total * vr / (100 + vr))::bigint;
  -- payment: Francs only, or (with "Accept payment in USD" on) dollars and Francs at the sale's rate
  if pusd < 0 or cusd < 0 or coalesce(app.num(p->>'paid_cdf'), 0) < 0 then raise exception 'Amounts received cannot be negative'; end if;
  if cusd <> trunc(cusd) then raise exception 'Dollars given back must be whole dollars'; end if;
  if (pusd > 0 or cusd > 0) and not app.feature('usd_pay') then raise exception 'Payment in USD is not turned on'; end if;
  -- dollars are worth the INTERNAL rate here, not the sales rate: what the shop gives for a dollar over the counter.
  -- The till sends the rate it used, so a sale made offline keeps the rate of its moment.
  ur := coalesce(app.num(p->>'usd_rate'), (select book_rate from settings where id = 1), r);
  if ur is null or ur <= 0 then raise exception 'Exchange rate for dollars is missing'; end if;
  if vid is not null then
    -- on credit: nothing is paid at the till; the vendeur owes the total, due after their credit days
    if pusd > 0 or cusd > 0 then raise exception 'Goods on credit are not paid at the till'; end if;
    tend := 0; pcdf := 0; ccdf := 0;
    v_due := (t at time zone (select tz from settings where id = 1))::date + vd.credit_days;
  else
    if pusd > 0 then
      pcdf := coalesce(app.num(p->>'paid_cdf'), 0)::bigint;
      tend := pcdf + round(pusd * ur)::bigint;
    else
      tend := coalesce(app.num(p->>'tendered')::bigint, v_total);
      pcdf := tend;
    end if;
    if tend < v_total then raise exception 'Cash received is less than the total'; end if;
    if cusd > pusd then raise exception 'Dollars given back cannot be more than the dollars received'; end if;
    if round(cusd * ur) > tend - v_total then raise exception 'Dollars given back are more than the change'; end if;
    ccdf := (tend - v_total) - round(cusd * ur)::bigint;
  end if;
  -- changed at approval: other lines, quantities, units or prices than printed, or another discount
  if o.invoice_no is not null then
    select string_agg(ii.product_id::text || ':' || ii.unit || ':' || ii.mult || ':' || ii.piece || ':' || ii.qty || ':' || ii.price, ','
      order by ii.product_id::text, ii.unit, ii.mult, ii.piece, ii.qty, ii.price)
      into sold from invoice_items ii where ii.invoice_id = iid;
    -- the unit by name (a half carton can be as many pcs as a dozen); orders saved before it was kept get it from mult
    select string_agg(y.pid || ':' || y.un || ':' || y.m || ':' || y.pc || ':' || y.q || ':' || y.pr, ',' order by y.pid, y.un, y.m, y.pc, y.q, y.pr)
      into printed from (select x->>'product_id' pid, coalesce(x->>'unit', app.unit_of(px, (x->>'mult')::int, (x->>'piece')::boolean)) un,
        (x->>'mult')::int m, (x->>'piece')::boolean pc, (x->>'qty')::int q, (x->>'price')::bigint pr
        from jsonb_array_elements(o.items) x join products px on px.id = (x->>'product_id')::uuid) y;
    revised := v_disc is distinct from coalesce(o.disc, 0) or v_total is distinct from o.total or sold is distinct from printed;
  end if;
  update invoices set gross = v_gross, disc_pct = dp, disc = v_disc, total = v_total, vat = v_vat, ht = v_total - v_vat, tendered = tend, change = case when vid is null then tend - v_total else 0 end, vendeur_id = vid, due_date = v_due,
    paid_usd = pusd, paid_cdf = pcdf, change_usd = cusd::int, change_cdf = ccdf, usd_rate = ur, price_flag = flag,
    revised_from = case when revised then o.total end
    where id = iid;
  update devices set last_seq = greatest(last_seq, seq) where id = dv.id;
  if oid is not null then
    update sale_orders set status = 'approved', reviewed_by_name = cashier.name, reviewed_at = now(), invoice_id = iid where id = oid;
  end if;
  -- promo items given with the goods: from the shop's stock, not on the invoice
  if vid is not null and jsonb_typeof(p->'promo') = 'array' and jsonb_array_length(p->'promo') > 0 then
    v_promo := app.add_promo(u, vd, iid, p->'promo', r, p->>'promo_note');
  end if;
  perform app.log(u, format('Invoice %s for %s, %s, %s%s%s', p->>'no', coalesce(nullif(cust, ''), 'walk-in'),
    case when vid is null then 'cash' else format('on credit, due %s%s', to_char(v_due, 'DD/MM/YYYY'),
      case when (before->>'balance')::bigint + v_total > vd.credit_limit then format(', over the credit limit of %s', app.fc(vd.credit_limit)) else '' end
      || case when (before->>'overdue')::boolean then format(', %s overdue', app.fc((before->>'overdue_amount')::bigint)) else '' end
      || case when v_promo is not null then format(', promo items %s (%s)', app.fc((v_promo->>'value')::bigint), v_promo->>'no') else '' end) end,
    app.fc(v_total), case when v_disc > 0 then format(', discount %s (%s%%)', app.fc(v_disc), trim_scale(dp)) else '' end,
    case when oid is not null then ' (order from ' || o.created_by_name || ' approved' || case when revised then ', changed from ' || app.fc(o.total) else '' end || ')' else '' end));
  return jsonb_build_object('status', 'ok', 'no', p->>'no', 'total', v_total, 'price_flag', flag, 'revised', revised, 'due_date', v_due, 'promo', v_promo,
    'vendeur', case when vid is not null then app.vendeur_state(vd) end);
end $$;

-- ---------- the books: a sale on credit is owed by the vendeur ----------
create or replace function app.post_invoice(p_id uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare i public.invoices; cost numeric; tz text; nusd numeric; ur numeric; fc bigint; cash jsonb; diff numeric := 0;
begin
  select * into i from invoices where id = p_id;
  if i.id is null or i.total <= 0 then return; end if;
  select settings.tz into tz from settings where id = 1;
  select coalesce(sum(cost_usd * qty), 0) into cost from invoice_items where invoice_id = p_id;
  -- the dollars kept, and the rate they were taken at (sales made before this update used the sales rate)
  ur := coalesce(i.usd_rate, i.rate);
  nusd := coalesce(i.paid_usd, 0) - coalesce(i.change_usd, 0);
  if i.vendeur_id is not null then
    cash := jsonb_build_array(jsonb_build_object('account', (select account_id from vendeurs where id = i.vendeur_id), 'side', 'Dr', 'amount', i.total,
      'currency', 'FC', 'rate', i.rate, 'memo', 'On credit' || coalesce(', due ' || to_char(i.due_date, 'DD/MM/YYYY'), '')));
  elsif coalesce(i.paid_usd, 0) = 0 then
    cash := jsonb_build_array(jsonb_build_object('account', app.shop_acc('CASH_SHOP', i.shop_id), 'side', 'Dr', 'amount', i.total, 'currency', 'FC', 'rate', i.rate));
  else
    -- the Francs that went with the dollars: the sale less what the dollars were taken for
    fc := i.total - round(nusd * ur)::bigint;
    cash := jsonb_build_array(
      jsonb_build_object('account', app.shop_acc('CASH_SHOP_USD', i.shop_id), 'side', case when nusd >= 0 then 'Dr' else 'Cr' end, 'amount', abs(nusd), 'currency', 'USD', 'memo', 'Paid in USD'),
      jsonb_build_object('account', app.shop_acc('CASH_SHOP', i.shop_id), 'side', case when fc >= 0 then 'Dr' else 'Cr' end, 'amount', abs(fc), 'currency', 'FC', 'rate', i.rate));
    -- a dollar taken in for less than the sales rate leaves the shop better off by the difference: that is the
    -- exchange gain, and booking it keeps the sale, the drawer and the books all right
    diff := round(nusd * (i.rate - ur) / i.rate, 2);
    if abs(diff) >= 0.005 then
      cash := cash || jsonb_build_array(jsonb_build_object('code', 'FX_GAIN', 'side', case when diff > 0 then 'Cr' else 'Dr' end,
        'amount', abs(diff), 'currency', 'USD', 'memo', 'Exchange on dollars'));
    end if;
  end if;
  perform app.post('sales', (i.t at time zone tz)::date, 'Invoice ' || i.no || coalesce(', ' || nullif(i.customer, ''), ''), i.no, 'invoice', i.id,
    cash || jsonb_build_array(
      jsonb_build_object('account', app.shop_acc('SALES_SHOP', i.shop_id), 'side', 'Cr', 'amount', i.ht, 'currency', 'FC', 'rate', i.rate),
      jsonb_build_object('code', 'VAT_OUT', 'side', 'Cr', 'amount', i.vat, 'currency', 'FC', 'rate', i.rate),
      jsonb_build_object('code', 'COGS', 'side', 'Dr', 'amount', round(cost, 2), 'currency', 'USD', 'memo', 'Cost of goods sold'),
      jsonb_build_object('account', app.shop_acc('INV_SHOP', i.shop_id), 'side', 'Cr', 'amount', round(cost, 2), 'currency', 'USD', 'memo', 'Cost of goods sold')),
    i.cashier_name);
end $$;

-- ---------- the shift end report and the day end slip: cash only ----------
create or replace function app.shift_slip(p_shop uuid, p_device uuid, p_from timestamptz, p_to timestamptz) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  with inv as (
    select i.*, coalesce((select e.from_total from invoice_edits e where e.invoice_id = i.id order by e.at, e.id limit 1), i.total) as first_total
    from invoices i
    where i.shop_id = p_shop and (p_device is null or i.device_id = p_device) and i.received_at > p_from and i.received_at <= p_to
  ), ed as (
    select e.from_total, e.to_total from invoice_edits e join invoices i on i.id = e.invoice_id
    where i.shop_id = p_shop and (p_device is null or i.device_id = p_device) and e.at > p_from and e.at <= p_to and i.vendeur_id is null
  ), vp as (
    -- cash paid by vendeurs for goods taken on credit (in the combined report, and in the till's own when taken there)
    select amount from vendeur_payments
    where shop_id = p_shop and status = 'ok' and (p_device is null or device_id = p_device) and at > p_from and at <= p_to
  ), x as (
    select (select count(*) from inv) n,
      (select coalesce(sum(total), 0) from inv) value_fc,
      (select coalesce(sum(total / coalesce(usd_rate, rate)), 0) from inv) value_usd,   -- the dollars the sales are worth at the till's rate
      (select coalesce(sum(first_total), 0) from inv where vendeur_id is null) + (select coalesce(sum(greatest(0, to_total - from_total)), 0) from ed)
        + (select coalesce(sum(amount), 0) from vp) collected,
      (select coalesce(sum(total), 0) from inv where vendeur_id is not null) on_credit,
      (select coalesce(sum(amount), 0) from vp) vendeur_paid,
      (select coalesce(sum(greatest(0, from_total - to_total)), 0) from ed) returned,
      (select coalesce(sum(paid_usd - change_usd), 0) from inv) collected_usd,
      (select coalesce(sum(round((paid_usd - change_usd) * coalesce(usd_rate, rate))), 0) from inv) usd_in_cdf
  )
  select jsonb_build_object('shop_id', s.id, 'shop_name', s.name, 'code', s.code, 'n', x.n, 'value_fc', x.value_fc, 'value_usd', x.value_usd,
    'collected', x.collected, 'returned', x.returned, 'collected_usd', x.collected_usd, 'collected_cdf', (x.collected - x.usd_in_cdf)::bigint,
    'on_credit', x.on_credit, 'vendeur_paid', x.vendeur_paid)
  from shops s, x where s.id = p_shop
$$;

create or replace function public.shift_end_report(p_code text, p_action text default 'close', p_device uuid default null, p_day date default null, p_shift uuid default null) returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); err text; tz text; dv public.devices; today date; prev timestamptz; fr timestamptz; t2 timestamptz := now();
  sc public.shift_closes; n int; sl jsonb; what text; dsum jsonb; vpaid bigint;
begin
  if p_action not in ('close', 'reprint', 'day') then raise exception 'Unknown report'; end if;
  if p_device is not null then
    select * into dv from devices where id = p_device and shop_id = u.shop_id;
    if not found then raise exception 'This till is not in your shop'; end if;
  end if;
  err := app.check_passcode(u, 'day_end', p_code);
  if err is not null then return jsonb_build_object('ok', false, 'error', err); end if;
  select settings.tz into tz from settings where id = 1;
  today := (now() at time zone tz)::date;
  what := coalesce('Till ' || dv.code, 'all tills');

  if p_action = 'reprint' then
    select * into sc from shift_closes where id = p_shift and shop_id = u.shop_id;
    if not found then raise exception 'That shift end report was not found'; end if;
    select code into what from devices where id = sc.device_id;
    perform app.log(u, format('Shift end report %s of %s (%s) printed again', sc.shift_no, to_char(sc.day, 'DD/MM/YYYY'), coalesce('Till ' || what, 'all tills')));
    return jsonb_build_object('ok', true, 'slip', sc.slip, 'shift_no', sc.shift_no, 'from', sc.from_at, 'to', sc.to_at, 'till', what, 'reprint', true);
  end if;

  if p_action = 'day' then
    if p_day is null then raise exception 'Choose the day'; end if;
    select coalesce(sum(amount), 0) into vpaid from vendeur_payments
      where shop_id = u.shop_id and status = 'ok' and (p_device is null or device_id = p_device) and (at at time zone tz)::date = p_day;
    with inv as (
      select i.*,
        case when i.vendeur_id is not null then 0 else coalesce((select e.from_total from invoice_edits e where e.invoice_id = i.id order by e.at, e.id limit 1), i.total)
          + (select coalesce(sum(greatest(0, to_total - from_total)),0) from invoice_edits where invoice_id = i.id) end as col,
        case when i.vendeur_id is not null then 0 else (select coalesce(sum(greatest(0, from_total - to_total)),0) from invoice_edits where invoice_id = i.id) end as ret
      from invoices i
      where i.shop_id = u.shop_id and (p_device is null or i.device_id = p_device) and (i.t at time zone tz)::date = p_day
    )
    select jsonb_build_object('shop_id', s.id, 'shop_name', s.name, 'code', s.code, 'n', count(inv.id),
        'value_fc', coalesce(sum(inv.total),0), 'value_usd', coalesce(sum(inv.total / coalesce(inv.usd_rate, inv.rate)),0),
        'collected', coalesce(sum(inv.col),0) + vpaid, 'returned', coalesce(sum(inv.ret),0),
        'collected_usd', coalesce(sum(inv.paid_usd - inv.change_usd),0),
        'collected_cdf', (coalesce(sum(inv.col - round((inv.paid_usd - inv.change_usd) * coalesce(inv.usd_rate, inv.rate))),0) + vpaid)::bigint,
        'on_credit', coalesce(sum(inv.total) filter (where inv.vendeur_id is not null),0), 'vendeur_paid', vpaid)
      into sl from shops s left join inv on inv.shop_id = s.id where s.id = u.shop_id group by s.id, s.name, s.code;
    perform app.log(u, format('Day end report of %s (%s) printed with the passcode', to_char(p_day, 'DD/MM/YYYY'), what));
    return jsonb_build_object('ok', true, 'slip', sl, 'day', p_day, 'till', dv.code);
  end if;

  -- close today's shift: one at a time per shop, so two prints at once never make the same shift twice
  perform 1 from shops where id = u.shop_id for update;
  select max(to_at) into prev from shift_closes where shop_id = u.shop_id and device_id is not distinct from p_device;
  -- the first shift starts at the start of the day; after that, where the last one ended (even on an earlier day,
  -- so the sales of a shift that was never printed are not lost)
  fr := coalesce(prev, (today::timestamp at time zone tz));
  sl := app.shift_slip(u.shop_id, p_device, fr, t2);
  select count(*) + 1 into n from shift_closes where shop_id = u.shop_id and device_id is not distinct from p_device and day = today;
  -- From the second shift of the day, the slip also carries the day so far: today's shift slips added up, line by
  -- line, with this one. It is the slips themselves that are added, not the sales counted again, so every line agrees
  -- with the slips the cashier already holds -- even when an invoice of an earlier shift was corrected since: the
  -- correction is in the shift it was made in, as money given back. It is kept inside the slip, so a shift printed
  -- again shows the day as it stood when that shift was printed.
  if n > 1 then
    select jsonb_build_object(
        'n',             (coalesce(sum((slip->>'n')::numeric), 0) + (sl->>'n')::numeric)::int,
        'value_fc',      (coalesce(sum((slip->>'value_fc')::numeric), 0) + (sl->>'value_fc')::numeric)::bigint,
        'value_usd',      coalesce(sum((slip->>'value_usd')::numeric), 0) + (sl->>'value_usd')::numeric,
        'collected',     (coalesce(sum((slip->>'collected')::numeric), 0) + (sl->>'collected')::numeric)::bigint,
        'returned',      (coalesce(sum((slip->>'returned')::numeric), 0) + (sl->>'returned')::numeric)::bigint,
        'collected_usd',  coalesce(sum((slip->>'collected_usd')::numeric), 0) + (sl->>'collected_usd')::numeric,
        'collected_cdf', (coalesce(sum((slip->>'collected_cdf')::numeric), 0) + (sl->>'collected_cdf')::numeric)::bigint,
        'on_credit',     (coalesce(sum((slip->>'on_credit')::numeric), 0) + coalesce((sl->>'on_credit')::numeric, 0))::bigint,
        'vendeur_paid',  (coalesce(sum((slip->>'vendeur_paid')::numeric), 0) + coalesce((sl->>'vendeur_paid')::numeric, 0))::bigint,
        'from', min(from_at), 'shifts', n)
      into dsum
      from shift_closes where shop_id = u.shop_id and device_id is not distinct from p_device and day = today;
    sl := sl || jsonb_build_object('day', dsum);
  end if;
  insert into shift_closes (shop_id, device_id, day, shift_no, from_at, to_at, slip, closed_by, closed_by_name)
    values (u.shop_id, p_device, today, n, fr, t2, sl, u.id, u.name) returning * into sc;
  perform app.log(u, format('Shift end report %s of %s (%s) printed, %s invoices, %s; a new shift starts', n, to_char(today, 'DD/MM/YYYY'), what, sl->>'n', app.fc((sl->>'value_fc')::bigint)));
  return jsonb_build_object('ok', true, 'slip', sl, 'shift_no', n, 'from', fr, 'to', t2, 'till', dv.code, 'id', sc.id);
end $$;

create or replace function public.sales_report(p_from date, p_to date, p_shop uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin','shopadmin'); sid uuid; tz text; lim numeric; res jsonb;
  keep uuid[] := '{}'; seen int := 0; acc numeric := 0; cur date; r record;
begin
  if p_from is null or p_to is null then raise exception 'Choose the dates'; end if;
  if p_from > p_to then select p_to, p_from into p_from, p_to; end if;
  sid := case when u.role = 'shopadmin' then u.shop_id else p_shop end;
  -- The Shop Admin's figures stop at the shop's daily limit: the day's sales are taken in the order they were made
  -- and counted while they still fit under it, so the total, the list, the categories and the cashiers all agree.
  -- The Admin has no limit, and the shift end report (its own function) always has every sale.
  select settings.tz, case when u.role = 'shopadmin' then settings.shop_sales_limit_usd end into tz, lim from settings where id = 1;
  if lim is not null then
    for r in select i.id, (i.t at time zone tz)::date as d, i.total / nullif(i.rate, 0) as usd from invoices i
      where (sid is null or i.shop_id = sid) and (i.t at time zone tz)::date between p_from and p_to
      order by (i.t at time zone tz)::date, i.t, i.id
    loop
      seen := seen + 1;
      if cur is distinct from r.d then cur := r.d; acc := 0; end if;
      if acc + coalesce(r.usd, 0) <= lim then acc := acc + coalesce(r.usd, 0); keep := keep || r.id; end if;
    end loop;
  end if;
  with inv as (
    select i.*, (i.t at time zone tz)::date as day,
      (select coalesce(sum(qty),0) from invoice_items where invoice_id = i.id) as q,
      (select coalesce(sum(cost_usd * qty),0) from invoice_items where invoice_id = i.id) as cogs,
      case when i.vendeur_id is not null then 0 else coalesce((select e.from_total from invoice_edits e where e.invoice_id = i.id order by e.at, e.id limit 1), i.total)
        + (select coalesce(sum(greatest(0, to_total - from_total)),0) from invoice_edits where invoice_id = i.id) end as col,
      case when i.vendeur_id is not null then 0 else (select coalesce(sum(greatest(0, from_total - to_total)),0) from invoice_edits where invoice_id = i.id) end as ret,
      exists (select 1 from invoice_edits where invoice_id = i.id) as edited
    from invoices i
    where (sid is null or i.shop_id = sid) and (i.t at time zone tz)::date between p_from and p_to
      and (lim is null or i.id = any(keep))
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'shop_id', sid,
    -- true when sales were left out to stay under the limit, so the screen can say the figures stop there
    'capped', lim is not null and seen > coalesce(array_length(keep, 1), 0),
    'n', (select count(*) from inv),
    'total', (select coalesce(sum(total),0) from inv),
    -- sales in dollars: what they are worth at the rate the till takes dollars, so the figure matches the cash
    'total_usd', (select coalesce(sum(total / coalesce(usd_rate, rate)),0) from inv),
    'disc', (select coalesce(sum(disc),0) from inv),
    'vat', (select coalesce(sum(vat),0) from inv),
    'items', (select coalesce(sum(q),0) from inv),
    'edited', (select count(*) from inv where edited),
    -- gross profit: the margin of each invoice (sales, VAT included, less the cost of the goods) less the VAT rate on that margin
    'profit_usd', case when u.role = 'admin' then (select coalesce(sum((total / rate - cogs) * (1 - vat_rate / 100)),0) from inv) end,
    'by_day', (select coalesce(jsonb_agg(bd order by bd.day), '[]') from (select day, count(*) n, sum(q) q, sum(disc) d, sum(total) v from inv group by day) bd),
    'top', (select coalesce(jsonb_agg(x order by x.val desc), '[]') from (
        select ii.name, sum(ii.qty) qty, sum(ii.line) val from invoice_items ii join inv on inv.id = ii.invoice_id group by ii.product_id, ii.name order by 3 desc limit 15) x),
    -- sales by category (the item's category now), each with its items: the amount after the invoice's discount,
    -- the pcs sold (pieces of a mixed set apart) and how many of each unit
    'by_category', (select coalesce(jsonb_agg(jsonb_build_object('category', bc.cat, 'val', bc.val, 'pcs', bc.pcs, 'items', bc.items) order by bc.val desc, bc.cat), '[]') from (
        select bi.cat, sum(bi.val)::bigint val, sum(bi.pcs)::bigint pcs,
          jsonb_agg(jsonb_build_object('product_id', bi.product_id, 'name', bi.name, 'val', bi.val, 'pcs', bi.pcs, 'pieces', bi.pieces, 'units', bi.units)
            order by bi.val desc, bi.name) items
        from (
          select bu.cat, bu.product_id, min(bu.name) name, sum(bu.val)::bigint val, sum(bu.pcs)::bigint pcs, sum(bu.pieces)::bigint pieces,
            jsonb_object_agg(bu.unit, bu.qty) units
          from (
            select coalesce(nullif(btrim(p.category), ''), 'No category') cat, ii.product_id, min(ii.name) name, ii.unit, sum(ii.qty) qty,
              coalesce(round(sum(ii.line * inv.total::numeric / nullif(inv.gross, 0))), 0) val,
              sum(case when ii.piece then 0 else ii.qty * ii.mult end) pcs, sum(case when ii.piece then ii.qty else 0 end) pieces
            from invoice_items ii join inv on inv.id = ii.invoice_id join products p on p.id = ii.product_id
            group by 1, 2, 4) bu
          group by bu.cat, bu.product_id) bi
        group by bi.cat) bc),
    'by_cashier', (select coalesce(jsonb_agg(c order by c.v desc), '[]') from (select cashier_name as name, sum(total) v from inv group by cashier_name) c),
    'slips', (select coalesce(jsonb_agg(sl order by sl.shop_name), '[]') from (
        select s.id as shop_id, s.name as shop_name, s.code, count(inv.id) n, coalesce(sum(inv.total),0) value_fc, coalesce(sum(inv.total / coalesce(inv.usd_rate, inv.rate)),0) value_usd,
          coalesce(sum(inv.col),0) + vp.paid collected, coalesce(sum(inv.ret),0) returned,
          coalesce(sum(inv.paid_usd - inv.change_usd),0) collected_usd,
          (coalesce(sum(inv.col - round((inv.paid_usd - inv.change_usd) * coalesce(inv.usd_rate, inv.rate))),0) + vp.paid)::bigint collected_cdf,
          coalesce(sum(inv.total) filter (where inv.vendeur_id is not null),0) on_credit, vp.paid vendeur_paid
        from shops s left join inv on inv.shop_id = s.id
          -- cash paid by vendeurs for goods taken on credit
          left join lateral (select coalesce(sum(x.amount), 0)::bigint paid from vendeur_payments x
            where x.shop_id = s.id and x.status = 'ok' and (x.at at time zone tz)::date between p_from and p_to) vp on true
        where (sid is null and s.active) or s.id = sid group by s.id, s.name, s.code, vp.paid) sl),
    'invoices', (select coalesce(jsonb_agg(v order by v.t desc), '[]') from (
        select id, no, t, shop_id, cashier_name, customer, q as items, disc, total, edited from inv order by t desc limit 300) v)
  ) into res;
  return res;
end $$;

-- ---------- vendeurs ----------
create or replace function public.save_vendeur(p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin','admin'); vid uuid := nullif(p->>'id', '')::uuid; v public.vendeurs; s public.shops; sid uuid;
  n text := btrim(regexp_replace(coalesce(p->>'name', ''), '\s+', ' ', 'g'));
  cd numeric := app.num(p->>'credit_days'); lim numeric := app.num(p->>'credit_limit'); ob numeric := coalesce(app.num(p->>'opening_balance'), 0);
  aname text; aid uuid; r numeric; chg text[] := '{}';
begin
  if u.role = 'shopadmin' and not app.feature('vendeurs') then raise exception 'Vendeurs (goods on credit) are not turned on in Settings'; end if;
  sid := case when u.role = 'shopadmin' then u.shop_id else nullif(p->>'shop_id', '')::uuid end;
  if vid is not null then
    select * into v from vendeurs where id = vid for update;
    if not found or (u.role = 'shopadmin' and v.shop_id <> u.shop_id) then raise exception 'Vendeur not found'; end if;
    sid := v.shop_id;
  end if;
  select * into s from shops where id = sid;
  if not found then raise exception 'Choose the shop'; end if;
  if n = '' then raise exception 'Enter the vendeur name'; end if;
  if length(n) > 40 then raise exception 'Vendeur name is too long (40 characters at most)'; end if;
  if cd is null or cd < 0 or cd > 365 or cd <> trunc(cd) then raise exception 'Credit period must be 0 to 365 days'; end if;
  if lim is null or lim <= 0 or lim <> trunc(lim) then raise exception 'Enter the credit limit in CDF'; end if;
  if ob < 0 or ob <> trunc(ob) then raise exception 'Opening balance must be a whole amount of 0 or more'; end if;
  if exists (select 1 from vendeurs where shop_id = sid and lower(name) = lower(n) and id is distinct from vid) then
    raise exception 'A vendeur called "%" already exists in this shop', n;
  end if;
  aname := 'Vendeur ' || n || ' (' || s.code || ')';
  if exists (select 1 from accounts where lower(name) = lower(aname) and id is distinct from v.account_id) then
    raise exception 'A ledger called "%" already exists', aname;
  end if;
  select rate into r from settings where id = 1;
  if vid is null then
    insert into accounts (name, group_code, currency, shop_id, opening_amount, opening_side, opening_currency, opening_rate)
      values (aname, 'debtors', 'FC', sid, ob, 'Dr', 'FC', r) returning id into aid;
    insert into vendeurs (shop_id, name, phone, address, notes, credit_days, credit_limit, opening_balance, account_id, created_by_name)
      values (sid, n, left(btrim(coalesce(p->>'phone', '')), 30), left(btrim(coalesce(p->>'address', '')), 80), left(btrim(coalesce(p->>'notes', '')), 200),
        cd::int, lim::bigint, ob::bigint, aid, u.name)
      returning id into vid;
    update accounts set vendeur_id = vid where id = aid;
    perform app.log(u, format('Added vendeur %s (%s): credit %s days, limit %s%s', n, s.name, cd::int, app.fc(lim::bigint),
      case when ob > 0 then ', opening balance ' || app.fc(ob::bigint) else '' end));
  else
    if v.credit_limit <> lim then chg := chg || format('limit %s to %s', app.fc(v.credit_limit), app.fc(lim::bigint)); end if;
    if v.credit_days <> cd then chg := chg || format('credit %s to %s days', v.credit_days, cd::int); end if;
    if v.opening_balance <> ob then chg := chg || format('opening balance %s to %s', app.fc(v.opening_balance), app.fc(ob::bigint)); end if;
    if v.active <> coalesce((p->>'active')::boolean, v.active) then chg := chg || case when (p->>'active')::boolean then 'made active' else 'made inactive' end; end if;
    update vendeurs set name = n, phone = left(btrim(coalesce(p->>'phone', '')), 30), address = left(btrim(coalesce(p->>'address', '')), 80),
      notes = left(btrim(coalesce(p->>'notes', '')), 200), credit_days = cd::int, credit_limit = lim::bigint, opening_balance = ob::bigint,
      active = coalesce((p->>'active')::boolean, active)
      where id = vid;
    update accounts set name = aname, opening_amount = ob, opening_currency = 'FC', opening_side = 'Dr', opening_rate = coalesce(opening_rate, r) where id = v.account_id;
    perform app.log(u, format('Updated vendeur %s%s', n, case when cardinality(chg) > 0 then ': ' || array_to_string(chg, ', ') else '' end));
  end if;
  return vid;
end $$;

-- a vendeur with nothing recorded is deleted with its ledger; one with goods, payments or promos keeps its history
-- and is made inactive instead, once it owes nothing
create or replace function public.delete_vendeur(p_id uuid) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin','admin'); v public.vendeurs; st jsonb;
begin
  select * into v from vendeurs where id = p_id for update;
  if not found or (u.role = 'shopadmin' and v.shop_id <> u.shop_id) then raise exception 'Vendeur not found'; end if;
  st := app.vendeur_state(v);
  if (st->>'balance')::bigint <> 0 then raise exception 'Vendeur % still owes %. Take the payment first', v.name, app.fc((st->>'balance')::bigint); end if;
  if exists (select 1 from invoices where vendeur_id = v.id) or exists (select 1 from vendeur_payments where vendeur_id = v.id)
     or exists (select 1 from vendeur_promos where vendeur_id = v.id) or exists (select 1 from voucher_lines where account_id = v.account_id) then
    update vendeurs set active = false where id = v.id;
    perform app.log(u, format('Vendeur %s made inactive (its history is kept)', v.name));
    return 'inactive';
  end if;
  delete from vendeurs where id = v.id;
  delete from accounts where id = v.account_id;
  perform app.log(u, format('Deleted vendeur %s', v.name));
  return 'deleted';
end $$;

-- the vendeurs of the Shop Admin's shop (the Admin: of one shop, or every shop), with what each owes
create or replace function public.vendeur_list(p_shop uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin','admin'); sid uuid;
begin
  if u.role = 'shopadmin' and not app.feature('vendeurs') then raise exception 'Vendeurs (goods on credit) are not turned on in Settings'; end if;
  sid := case when u.role = 'shopadmin' then u.shop_id else p_shop end;
  return (select coalesce(jsonb_agg((to_jsonb(v) - 'account_id') || jsonb_build_object('shop_name', s.name) || app.vendeur_state(v)
      order by v.active desc, lower(v.name)), '[]')
    from vendeurs v join shops s on s.id = v.shop_id where sid is null or v.shop_id = sid);
end $$;

-- a payment from a vendeur, partial or full, in CDF into the shop's cash
create or replace function public.vendeur_pay(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); v public.vendeurs; st jsonb; amt numeric := app.num(p->>'amount'); r numeric; tz text;
  pid uuid := gen_random_uuid(); pno text; dev uuid := nullif(p->>'device_id', '')::uuid; bal bigint;
begin
  if not app.feature('vendeurs') then raise exception 'Vendeurs (goods on credit) are not turned on in Settings'; end if;
  select * into v from vendeurs where id = (p->>'vendeur_id')::uuid and shop_id = u.shop_id for update;
  if not found then raise exception 'Vendeur not found'; end if;
  if amt is null or amt <= 0 or amt <> trunc(amt) then raise exception 'Enter the amount paid in CDF'; end if;
  st := app.vendeur_state(v); bal := (st->>'balance')::bigint;
  if bal <= 0 then raise exception 'Vendeur % owes nothing', v.name; end if;
  if amt > bal then raise exception 'Vendeur % owes only %', v.name, app.fc(bal); end if;
  if dev is not null and not exists (select 1 from devices where id = dev and shop_id = u.shop_id) then dev := null; end if;
  select rate, settings.tz into r, tz from settings where id = 1;
  pno := app.vnum('VP', v.shop_id);
  insert into vendeur_payments (id, no, vendeur_id, shop_id, device_id, amount, rate, note, by_name)
    values (pid, pno, v.id, v.shop_id, dev, amt::bigint, r, left(btrim(coalesce(p->>'note', '')), 120), u.name);
  perform app.post('receipt', (now() at time zone tz)::date, format('Payment %s from vendeur %s', pno, v.name), pno, 'vendeur_payment', pid,
    jsonb_build_array(
      jsonb_build_object('account', app.shop_acc('CASH_SHOP', v.shop_id), 'side', 'Dr', 'amount', amt, 'currency', 'FC', 'rate', r),
      jsonb_build_object('account', v.account_id, 'side', 'Cr', 'amount', amt, 'currency', 'FC', 'rate', r, 'memo', nullif(btrim(coalesce(p->>'note', '')), ''))),
    u.name);
  perform app.log(u, format('Payment %s from vendeur %s: %s, %s left to pay', pno, v.name, app.fc(amt::bigint), app.fc(bal - amt::bigint)));
  return jsonb_build_object('id', pid, 'no', pno, 'amount', amt::bigint, 'at', now(), 'by_name', u.name, 'vendeur', v.name, 'before', bal,
    'state', app.vendeur_state(v));
end $$;

create or replace function public.cancel_vendeur_payment(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin','admin'); x public.vendeur_payments;
begin
  select * into x from vendeur_payments where id = p_id for update;
  if not found or (u.role = 'shopadmin' and x.shop_id <> u.shop_id) then raise exception 'Payment not found'; end if;
  if x.status <> 'ok' then raise exception 'Payment % is already cancelled', x.no; end if;
  if length(btrim(coalesce(p_reason, ''))) < 4 then raise exception 'Write a short reason for cancelling this payment'; end if;
  update vendeur_payments set status = 'cancelled', cancel_reason = left(btrim(p_reason), 120), cancelled_by_name = u.name, cancelled_at = now() where id = p_id;
  update vouchers set status = 'cancelled', cancel_reason = left('Payment cancelled: ' || btrim(p_reason), 120)
    where source_type = 'vendeur_payment' and source_id = p_id and status = 'posted';
  perform app.log(u, format('Payment %s from vendeur %s (%s) cancelled: %s', x.no, (select name from vendeurs where id = x.vendeur_id), app.fc(x.amount), btrim(p_reason)));
end $$;

-- a vendeur's statement in CDF: goods on credit, payments and the running balance; the promo items apart
create or replace function public.vendeur_statement(p_id uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin','admin'); v public.vendeurs; tz text; bf bigint; res jsonb;
begin
  select * into v from vendeurs where id = p_id;
  if not found or (u.role = 'shopadmin' and v.shop_id <> u.shop_id) then raise exception 'Vendeur not found'; end if;
  if p_from is null or p_to is null then raise exception 'Choose the dates'; end if;
  if p_from > p_to then select p_to, p_from into p_from, p_to; end if;
  select settings.tz into tz from settings where id = 1;
  with l as (
    select v.created_at as t, (v.created_at at time zone tz)::date as d, ''::text as no, 'Opening balance'::text as what, v.opening_balance::bigint as dr, 0::bigint as cr,
      null::date as due, null::uuid as invoice_id
    where v.opening_balance > 0
    union all
    select i.t, (i.t at time zone tz)::date, i.no,
      'Goods on credit, ' || (select coalesce(sum(qty), 0) from invoice_items where invoice_id = i.id) || ' items'
        || case when exists (select 1 from invoice_edits where invoice_id = i.id) then ' (changed)' else '' end,
      i.total, 0, i.due_date, i.id
    from invoices i where i.vendeur_id = v.id
    union all
    select x.at, (x.at at time zone tz)::date, x.no, 'Payment' || coalesce(', ' || nullif(x.note, ''), ''), 0, x.amount, null, null
    from vendeur_payments x where x.vendeur_id = v.id and x.status = 'ok'
  )
  select jsonb_build_object(
    'vendeur', (to_jsonb(v) - 'account_id') || jsonb_build_object('shop_name', (select name from shops where id = v.shop_id)),
    'from', p_from, 'to', p_to,
    'brought_forward', (select coalesce(sum(dr - cr), 0) from l where d < p_from),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('date', d, 'no', no, 'what', what, 'dr', dr, 'cr', cr, 'due', due, 'invoice_id', invoice_id) order by t, no), '[]')
              from l where d between p_from and p_to),
    'total_dr', (select coalesce(sum(dr), 0) from l where d between p_from and p_to),
    'total_cr', (select coalesce(sum(cr), 0) from l where d between p_from and p_to),
    'closing', (select coalesce(sum(dr - cr), 0) from l where d <= p_to),
    'promos', (select coalesce(jsonb_agg(jsonb_build_object('id', pr.id, 'no', pr.no, 'date', (pr.t at time zone tz)::date, 'value', pr.value, 'status', pr.status,
        'note', pr.note, 'invoice', (select no from invoices where id = pr.invoice_id),
        'items', (select jsonb_agg(jsonb_build_object('name', i.name, 'unit', i.unit, 'qty', i.qty, 'line', i.line) order by i.line_no) from vendeur_promo_items i where i.promo_id = pr.id))
        order by pr.t), '[]')
      from vendeur_promos pr where pr.vendeur_id = v.id and pr.status <> 'cancelled' and (pr.t at time zone tz)::date between p_from and p_to),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'no', x.no, 'at', x.at, 'amount', x.amount, 'note', x.note, 'status', x.status, 'by_name', x.by_name,
        'cancel_reason', x.cancel_reason) order by x.at desc), '[]')
      from vendeur_payments x where x.vendeur_id = v.id and (x.at at time zone tz)::date between p_from and p_to),
    'state', app.vendeur_state(v)
  ) into res;
  return res;
end $$;

-- promo items on their own (without goods on credit)
create or replace function public.give_promo(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); v public.vendeurs; r numeric; res jsonb;
begin
  if not app.feature('vendeurs') then raise exception 'Vendeurs (goods on credit) are not turned on in Settings'; end if;
  select * into v from vendeurs where id = (p->>'vendeur_id')::uuid and shop_id = u.shop_id for update;
  if not found then raise exception 'Vendeur not found'; end if;
  if not v.active then raise exception 'Vendeur % is inactive', v.name; end if;
  select rate into r from settings where id = 1;
  res := app.add_promo(u, v, null, p->'lines', r, p->>'note');
  perform app.log(u, format('Promo items %s given to vendeur %s: %s, %s lines', res->>'no', v.name, app.fc((res->>'value')::bigint), res->>'n'));
  return res;
end $$;

-- a promo given by mistake, before it is settled: its items go back into the shop's stock
create or replace function public.cancel_promo(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); x public.vendeur_promos; it record;
begin
  select * into x from vendeur_promos where id = p_id and shop_id = u.shop_id for update;
  if not found then raise exception 'Promo not found'; end if;
  if x.status = 'settled' then raise exception 'Promo % is in a settled report and cannot be cancelled', x.no; end if;
  if x.status = 'cancelled' then raise exception 'Promo % is already cancelled', x.no; end if;
  if length(btrim(coalesce(p_reason, ''))) < 4 then raise exception 'Write a short reason for cancelling this promo'; end if;
  for it in select i.*, pr.pieces_per_set from vendeur_promo_items i join products pr on pr.id = i.product_id where i.promo_id = p_id loop
    perform app.give_back(x.shop_id, it.product_id, it.qty, 1, false, it.pieces_per_set);
  end loop;
  update vendeur_promos set status = 'cancelled', cancel_reason = left(btrim(p_reason), 120), cancelled_by_name = u.name, cancelled_at = now() where id = p_id;
  update vouchers set status = 'cancelled', cancel_reason = left('Promo cancelled: ' || btrim(p_reason), 120)
    where source_type = 'promo' and source_id = p_id and status = 'posted';
  perform app.log(u, format('Promo %s to vendeur %s (%s) cancelled, items back in stock: %s', x.no, (select name from vendeurs where id = x.vendeur_id), app.fc(x.value), btrim(p_reason)));
end $$;

-- the promo report of a month: the promo items still open at its end, by vendeur, and the reports already kept or settled
create or replace function public.promo_report(p_month date default null, p_shop uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin','admin'); sid uuid; m date; tz text;
begin
  if u.role = 'shopadmin' and not app.feature('vendeurs') then raise exception 'Vendeurs (goods on credit) are not turned on in Settings'; end if;
  sid := case when u.role = 'shopadmin' then u.shop_id else p_shop end;
  if sid is null then raise exception 'Choose the shop'; end if;
  select settings.tz into tz from settings where id = 1;
  m := date_trunc('month', coalesce(p_month, (now() at time zone tz)::date))::date;
  return app.promo_open(sid, m) || jsonb_build_object('shop_id', sid, 'shop_name', (select name from shops where id = sid),
    -- open promos given before this month's start that no report has settled yet
    'oldest_open', (select min((t at time zone tz)::date) from vendeur_promos where shop_id = sid and status = 'open'),
    'reports', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'month', r.month, 'status', r.status, 'n', r.n, 'total', r.total, 'by_name', r.by_name, 'at', r.at, 'data', r.data)
        order by r.at desc), '[]') from (select * from promo_reports where shop_id = sid order by at desc limit 36) r));
end $$;

-- keep the month's report (its promos stay open and keep adding up) or settle it (they are closed, the count starts again)
create or replace function public.close_promo_report(p_month date, p_action text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); m date; d jsonb; rid uuid; tz text; mname text;
begin
  if not app.feature('vendeurs') then raise exception 'Vendeurs (goods on credit) are not turned on in Settings'; end if;
  if p_action not in ('keep', 'settle') then raise exception 'Choose keep or settle'; end if;
  if p_month is null then raise exception 'Choose the month'; end if;
  select settings.tz into tz from settings where id = 1;
  m := date_trunc('month', p_month)::date;
  if m > (now() at time zone tz)::date then raise exception 'That month has not started yet'; end if;
  mname := to_char(m, 'FMMonth YYYY');
  perform 1 from shops where id = u.shop_id for update;   -- one report at a time per shop
  d := app.promo_open(u.shop_id, m);
  if (d->>'n')::int = 0 then raise exception 'There are no open promo items up to the end of %', mname; end if;
  if p_action = 'keep' then
    update promo_reports set n = (d->>'n')::int, total = (d->>'value')::bigint, data = d, by_name = u.name, at = now()
      where shop_id = u.shop_id and month = m and status = 'kept' returning id into rid;
    if rid is null then
      insert into promo_reports (shop_id, month, status, n, total, data, by_name)
        values (u.shop_id, m, 'kept', (d->>'n')::int, (d->>'value')::bigint, d, u.name) returning id into rid;
    end if;
    perform app.log(u, format('Promo report of %s kept: %s promos, %s, still open', mname, d->>'n', app.fc((d->>'value')::bigint)));
  else
    insert into promo_reports (shop_id, month, status, n, total, data, by_name)
      values (u.shop_id, m, 'settled', (d->>'n')::int, (d->>'value')::bigint, d, u.name) returning id into rid;
    update vendeur_promos set status = 'settled', report_id = rid, settled_at = now(), settled_by_name = u.name
      where shop_id = u.shop_id and status = 'open' and (t at time zone tz)::date < (m + interval '1 month')::date;
    -- the report kept for this month is replaced by the settled one
    delete from promo_reports where shop_id = u.shop_id and month = m and status = 'kept';
    perform app.log(u, format('Promo report of %s settled: %s promos, %s; the promo count starts again at zero', mname, d->>'n', app.fc((d->>'value')::bigint)));
  end if;
  return (select to_jsonb(r) from promo_reports r where r.id = rid);
end $$;

-- ---------- who may call what ----------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.save_settings(jsonb), public.submit_invoice(jsonb), public.shift_end_report(text, text, uuid, date, uuid),
  public.sales_report(date, date, uuid), public.save_vendeur(jsonb), public.delete_vendeur(uuid), public.vendeur_list(uuid),
  public.vendeur_pay(jsonb), public.cancel_vendeur_payment(uuid, text), public.vendeur_statement(uuid, date, date),
  public.give_promo(jsonb), public.cancel_promo(uuid, text), public.promo_report(date, uuid), public.close_promo_report(date, text) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
