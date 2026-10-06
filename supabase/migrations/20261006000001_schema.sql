-- SIM Smart Invoice Management: core schema
-- Money: USD as numeric, Francs (FC) as whole bigint. Stock counted in pcs (or sets for mixed sets).

create extension if not exists pgcrypto;
create schema if not exists app;

create type public.app_role as enum ('admin','whop','shopadmin','till');

create table public.settings (
  id          int primary key default 1 check (id = 1),
  rate        numeric(12,2) not null default 2850 check (rate > 0),
  vat         numeric(5,2)  not null default 16 check (vat >= 0 and vat <= 30),
  tz          text not null default 'Africa/Kinshasa',
  company     jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now()
);
insert into public.settings (id) values (1);

create table public.shops (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique check (code ~ '^[A-Z]{3}$'),
  name       text not null check (length(name) between 2 and 60),
  address    text not null default '',
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.profiles (
  id                   uuid primary key references auth.users(id) on delete cascade,
  username             text not null unique check (username ~ '^[a-z0-9._-]{3,30}$'),
  name                 text not null check (length(name) between 2 and 60),
  role                 public.app_role not null,
  shop_id              uuid references public.shops(id),
  active               boolean not null default true,
  must_change_password boolean not null default true,
  created_at           timestamptz not null default now(),
  check ((role in ('admin','whop') and shop_id is null) or (role in ('shopadmin','till') and shop_id is not null))
);

create sequence public.sku_seq start 101;
create table public.products (
  id             uuid primary key default gen_random_uuid(),
  sku            text not null unique,
  name           text not null check (length(name) between 1 and 60),
  category       text not null check (length(category) between 1 and 30),
  stock_unit     text not null check (stock_unit in ('pcs','set')),
  is_bundle      boolean not null default false,
  per_carton     int not null default 0,
  pieces_per_set int not null default 0,
  price_usd      numeric(12,4) not null check (price_usd > 0),   -- per pc, or per set
  dozen_usd      numeric(12,4) not null default 0,
  carton_usd     numeric(12,4) not null default 0,
  piece_usd      numeric(12,4) not null default 0,
  reorder        int not null default 0 check (reorder >= 0),
  wh_qty         int not null default 0,
  active         boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create unique index products_name_key on public.products (lower(name));

-- cost is admin-only, kept apart from products so other roles never receive it
create table public.product_costs (
  product_id      uuid primary key references public.products(id) on delete cascade,
  carton_cost_usd numeric(12,4) not null default 0,
  cost_usd        numeric(16,6) not null default 0          -- per pc, or per set
);

create table public.shop_stock (
  shop_id     uuid not null references public.shops(id),
  product_id  uuid not null references public.products(id) on delete cascade,
  qty         int not null default 0,
  open_pieces int not null default 0,                       -- pieces sold from an open mixed set
  primary key (shop_id, product_id)
);

create table public.purchases (
  id         bigserial primary key,
  product_id uuid not null references public.products(id) on delete cascade,
  qty        int not null check (qty > 0),
  supplier   text not null default '',
  by_id      uuid,
  by_name    text not null,
  at         timestamptz not null default now()
);

create sequence public.delivery_seq;
create table public.deliveries (
  id              uuid primary key default gen_random_uuid(),
  no              text not null unique,
  shop_id         uuid not null references public.shops(id),
  rate            numeric(12,2) not null,
  created_by      uuid,
  created_by_name text not null,
  created_at      timestamptz not null default now(),
  edited_at       timestamptz
);
create table public.delivery_items (
  delivery_id uuid not null references public.deliveries(id) on delete cascade,
  product_id  uuid not null references public.products(id),
  qty         int not null check (qty > 0),
  price_usd   numeric(12,4) not null,
  primary key (delivery_id, product_id)
);
create table public.delivery_edits (
  id          bigserial primary key,
  delivery_id uuid not null references public.deliveries(id) on delete cascade,
  at          timestamptz not null default now(),
  by_name     text not null,
  reason      text not null,
  from_shop   uuid not null,
  from_qty    int not null,
  to_qty      int not null
);

-- each till (browser) gets a code so invoice numbers made offline never clash
create table public.devices (
  id            uuid primary key default gen_random_uuid(),
  shop_id       uuid not null references public.shops(id),
  code          text not null,
  last_seq      int not null default 0,
  registered_by text not null,
  created_at    timestamptz not null default now(),
  unique (shop_id, code)
);

create table public.invoices (
  id           uuid primary key,                         -- made on the till, so a re-sent sale is saved once
  no           text not null unique,
  shop_id      uuid not null references public.shops(id),
  device_id    uuid not null references public.devices(id),
  cashier_id   uuid not null,
  cashier_name text not null,
  t            timestamptz not null,                     -- time of sale on the till
  received_at  timestamptz not null default now(),
  rate         numeric(12,2) not null,
  vat_rate     numeric(5,2) not null,
  gross        bigint not null,
  disc_pct     int not null default 0 check (disc_pct between 0 and 30),
  disc         bigint not null default 0,
  total        bigint not null,
  vat          bigint not null,
  ht           bigint not null,
  tendered     bigint not null,
  change       bigint not null default 0,
  printed      int not null default 2,
  price_flag   boolean not null default false            -- a price differed from the price list when synced
);
create index invoices_shop_t on public.invoices (shop_id, t desc);
create table public.invoice_items (
  invoice_id uuid not null references public.invoices(id) on delete cascade,
  line_no    int not null,
  product_id uuid not null references public.products(id),
  name       text not null,
  unit       text not null,
  mult       int not null,
  piece      boolean not null default false,
  qty        int not null check (qty > 0),
  price      bigint not null,
  line       bigint not null,
  cost_usd   numeric(16,6) not null default 0,
  primary key (invoice_id, line_no)
);
create table public.invoice_edits (
  id         bigserial primary key,
  invoice_id uuid not null references public.invoices(id) on delete cascade,
  at         timestamptz not null default now(),
  by_id      uuid,
  by_name    text not null,
  reason     text not null,
  from_total bigint not null,
  to_total   bigint not null
);

create table public.upkeep (
  id          uuid primary key default gen_random_uuid(),
  date        date not null,
  category    text not null,
  description text not null,
  amount_usd  numeric(12,2) not null check (amount_usd > 0),
  by_name     text not null,
  at          timestamptz not null default now()
);

create table public.audit_log (
  id       bigserial primary key,
  at       timestamptz not null default now(),
  user_id  uuid,
  username text not null,
  action   text not null
);
create index audit_log_at on public.audit_log (at desc);
