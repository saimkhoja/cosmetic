-- Control project: which migrations it has. Used by ops/migrate.sh the first time it sees the control project
-- (set up by hand in the SQL Editor), like supabase/scripts/check_migrations.sql for a client.
select step, case when ok then 'done' else 'MISSING: run this file' end as status from (values
  ('20261122000001_tenants.sql', to_regclass('public.tenants') is not null and to_regprocedure('public.tenant_config(text)') is not null)
) as m(step, ok);
