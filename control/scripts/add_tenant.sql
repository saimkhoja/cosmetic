-- Adds a client to the control project, or updates one. Until signup does this by itself (step 3),
-- run it in the CONTROL project's SQL Editor after filling in the five values. See control/README.md.
-- The values come from the CLIENT's Supabase project: Settings → API (Project URL and the anon / publishable key).
-- Never paste the service_role / secret key here.
insert into public.tenants (subdomain, name, supabase_url, anon_key, project_ref, backup_name)
values (
  'sapcongo',                               -- the address: sapcongo.getquicksales.com
  'SAP Congo',                              -- the business name (shown in the browser tab)
  'https://YOUR-PROJECT-REF.supabase.co',   -- the client's Project URL, no trailing slash
  'YOUR-ANON-OR-PUBLISHABLE-KEY',           -- the client's public key
  'YOUR-PROJECT-REF',                       -- the part before .supabase.co
  'client2'                                 -- the client's folder in the backup bucket
)
on conflict (subdomain) do update set
  name = excluded.name, supabase_url = excluded.supabase_url, anon_key = excluded.anon_key,
  project_ref = excluded.project_ref, backup_name = excluded.backup_name;

-- To switch a client off (the site then shows "switched off"; tills that are open keep going until restarted):
--   update public.tenants set status = 'suspended' where subdomain = 'sapcongo';
-- And back on:
--   update public.tenants set status = 'active' where subdomain = 'sapcongo';

select subdomain, name, supabase_url, status from public.tenants order by created_at;
