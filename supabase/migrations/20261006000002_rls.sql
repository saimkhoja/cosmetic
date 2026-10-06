-- Who may read what. Clients never write tables directly: every change goes through
-- the checked functions in the next migration.

-- the signed-in user's own profile, if the account is active (bypasses RLS on purpose)
create or replace function app.me() returns public.profiles
language sql stable security definer set search_path = public, pg_temp as $$
  select p.* from public.profiles p where p.id = auth.uid() and p.active
$$;
create or replace function app.my_role() returns public.app_role
language sql stable security definer set search_path = public, pg_temp as $$
  select role from public.profiles where id = auth.uid() and active
$$;
create or replace function app.my_shop() returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select shop_id from public.profiles where id = auth.uid() and active
$$;

grant usage on schema app to authenticated, service_role;
grant execute on function app.me(), app.my_role(), app.my_shop() to authenticated, service_role;

-- start from nothing, then grant reads table by table
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke execute on functions from anon, authenticated, public;

grant select on public.settings, public.shops, public.profiles, public.products, public.product_costs,
  public.shop_stock, public.purchases, public.deliveries, public.delivery_items, public.delivery_edits,
  public.devices, public.invoices, public.invoice_items, public.invoice_edits, public.upkeep, public.audit_log
  to authenticated;

alter table public.settings       enable row level security;
alter table public.shops          enable row level security;
alter table public.profiles       enable row level security;
alter table public.products       enable row level security;
alter table public.product_costs  enable row level security;
alter table public.shop_stock     enable row level security;
alter table public.purchases      enable row level security;
alter table public.deliveries     enable row level security;
alter table public.delivery_items enable row level security;
alter table public.delivery_edits enable row level security;
alter table public.devices        enable row level security;
alter table public.invoices       enable row level security;
alter table public.invoice_items  enable row level security;
alter table public.invoice_edits  enable row level security;
alter table public.upkeep         enable row level security;
alter table public.audit_log      enable row level security;

create policy read_settings on public.settings for select to authenticated using (app.my_role() is not null);
create policy read_shops    on public.shops    for select to authenticated using (app.my_role() is not null);
create policy read_profiles on public.profiles for select to authenticated using (id = auth.uid() or app.my_role() = 'admin');
create policy read_products on public.products for select to authenticated using (app.my_role() is not null);
create policy read_costs    on public.product_costs for select to authenticated using (app.my_role() = 'admin');

create policy read_shop_stock on public.shop_stock for select to authenticated
  using (app.my_role() in ('admin','whop') or shop_id = app.my_shop());
create policy read_purchases on public.purchases for select to authenticated
  using (app.my_role() in ('admin','whop'));

create policy read_deliveries on public.deliveries for select to authenticated
  using (app.my_role() in ('admin','whop') or (app.my_role() = 'shopadmin' and shop_id = app.my_shop()));
create policy read_delivery_items on public.delivery_items for select to authenticated
  using (exists (select 1 from public.deliveries d where d.id = delivery_id));
create policy read_delivery_edits on public.delivery_edits for select to authenticated
  using (exists (select 1 from public.deliveries d where d.id = delivery_id));

create policy read_devices on public.devices for select to authenticated
  using (app.my_role() = 'admin' or shop_id = app.my_shop());

-- the till operator sells but has no invoice list
create policy read_invoices on public.invoices for select to authenticated
  using (app.my_role() = 'admin' or (app.my_role() = 'shopadmin' and shop_id = app.my_shop()));
create policy read_invoice_items on public.invoice_items for select to authenticated
  using (exists (select 1 from public.invoices i where i.id = invoice_id));
create policy read_invoice_edits on public.invoice_edits for select to authenticated
  using (exists (select 1 from public.invoices i where i.id = invoice_id));

create policy read_upkeep on public.upkeep    for select to authenticated using (app.my_role() = 'admin');
create policy read_audit  on public.audit_log for select to authenticated using (app.my_role() = 'admin');
