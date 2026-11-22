-- QuickSales control project: the list of clients and where each one's database is.
-- This is a separate Supabase project from every client's; it holds no shop data.
-- The app asks it one question, tenant_config(subdomain), and gets back the client's Supabase URL and its public
-- (anon / publishable) key, the same two values a one-client build has in VITE_SUPABASE_URL / VITE_SUPABASE_ANON_KEY.
-- Never store a client's service_role / secret key or database password here.

create table public.tenants (
  subdomain    text primary key,
  name         text not null check (length(btrim(name)) between 2 and 80),
  supabase_url text not null check (supabase_url ~ '^https://[a-z0-9.-]+$'),
  anon_key     text not null check (length(anon_key) between 20 and 2000),
  project_ref  text check (project_ref ~ '^[a-z0-9]{10,40}$'),          -- for the Supabase management API (migrations, backups)
  backup_name  text unique check (backup_name ~ '^[a-z0-9-]{2,40}$'),   -- folder in the backup bucket, e.g. client2
  status       text not null default 'active' check (status in ('provisioning', 'active', 'suspended')),
  contact      jsonb not null default '{}'::jsonb,                      -- who signed up: name, phone, email
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  -- one label: letters, digits, single hyphens inside; not a name the site keeps for itself.
  -- Keep the reserved list in step with app/src/lib/tenant.ts (RESERVED).
  constraint tenants_subdomain_check check (
    subdomain ~ '^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$' and subdomain !~ '--'
    and subdomain not in ('www', 'app', 'api', 'admin', 'control', 'mail', 'email', 'smtp', 'ftp', 'status', 'docs', 'help', 'support',
      'billing', 'signup', 'login', 'dashboard', 'static', 'assets', 'cdn', 'dev', 'staging', 'test', 'demo'))
);

create function public.tenants_touch() returns trigger language plpgsql set search_path = public, pg_temp as $$
begin new.updated_at := now(); return new; end $$;
create trigger tenants_touch before update on public.tenants for each row execute function public.tenants_touch();

-- Nobody reads the table through the API: the list of clients and their contacts stay private.
-- Only you, in the dashboard / SQL editor (postgres) or with the secret key (service_role), see it.
alter table public.tenants enable row level security;
revoke all on public.tenants from anon, authenticated;
revoke execute on function public.tenants_touch() from public, anon, authenticated;

-- The one thing the public app may ask: where is the database for this address?
-- Answers only for one exact subdomain (no listing), and nothing for a client still being set up.
create function public.tenant_config(p_subdomain text) returns json
language sql stable security definer set search_path = public, pg_temp as $$
  select json_build_object('name', t.name, 'url', t.supabase_url, 'anon_key', t.anon_key, 'status', t.status)
  from public.tenants t
  where t.subdomain = lower(btrim(p_subdomain)) and t.status in ('active', 'suspended')
$$;
revoke execute on function public.tenant_config(text) from public;
grant execute on function public.tenant_config(text) to anon, authenticated, service_role;
