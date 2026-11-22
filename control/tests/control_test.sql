-- Control project tests: control/tests/run.sh
\set ON_ERROR_STOP 1
\set QUIET 1
\pset tuples_only on
\pset format unaligned
set client_min_messages = notice;

create schema t;
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
grant usage on schema t to anon, authenticated;
grant execute on all functions in schema t to anon, authenticated;

insert into public.tenants (subdomain, name, supabase_url, anon_key, project_ref, backup_name, contact) values
  ('sapcongo', 'SAP Congo', 'https://abcdefghijklmnopqrst.supabase.co', 'sb_publishable_aaaaaaaaaaaaaaaaaaaa', 'abcdefghijklmnopqrst', 'client2', '{"phone":"+243 000"}'),
  ('closed',   'Closed Ltd', 'https://bbbbbbbbbbbbbbbbbbbb.supabase.co', 'sb_publishable_bbbbbbbbbbbbbbbbbbbb', null, null, '{}');
insert into public.tenants (subdomain, name, supabase_url, anon_key, status) values
  ('newshop', 'New Shop', 'https://cccccccccccccccccccc.supabase.co', 'sb_publishable_cccccccccccccccccccc', 'provisioning');
update public.tenants set status = 'suspended' where subdomain = 'closed';

-- addresses the table refuses
select t.fails($$insert into public.tenants (subdomain, name, supabase_url, anon_key) values ('www', 'X Co', 'https://x.supabase.co', 'sb_publishable_xxxxxxxxxxxxxxxxxxxx')$$, 'tenants_subdomain_check', 'www is reserved');
select t.fails($$insert into public.tenants (subdomain, name, supabase_url, anon_key) values ('Shop', 'X Co', 'https://x.supabase.co', 'sb_publishable_xxxxxxxxxxxxxxxxxxxx')$$, 'tenants_subdomain_check', 'capitals are refused');
select t.fails($$insert into public.tenants (subdomain, name, supabase_url, anon_key) values ('a.b', 'X Co', 'https://x.supabase.co', 'sb_publishable_xxxxxxxxxxxxxxxxxxxx')$$, 'tenants_subdomain_check', 'one label only');
select t.fails($$insert into public.tenants (subdomain, name, supabase_url, anon_key) values ('a--b', 'X Co', 'https://x.supabase.co', 'sb_publishable_xxxxxxxxxxxxxxxxxxxx')$$, 'tenants_subdomain_check', 'no double hyphen');
select t.fails($$insert into public.tenants (subdomain, name, supabase_url, anon_key) values ('-ab', 'X Co', 'https://x.supabase.co', 'sb_publishable_xxxxxxxxxxxxxxxxxxxx')$$, 'tenants_subdomain_check', 'no leading hyphen');
select t.fails($$insert into public.tenants (subdomain, name, supabase_url, anon_key) values ('okshop', 'X Co', 'http://x.supabase.co', 'sb_publishable_xxxxxxxxxxxxxxxxxxxx')$$, 'supabase_url_check', 'the URL must be https');
select t.fails($$insert into public.tenants (subdomain, name, supabase_url, anon_key) values ('okshop', 'X Co', 'https://x.supabase.co/', 'sb_publishable_xxxxxxxxxxxxxxxxxxxx')$$, 'supabase_url_check', 'the URL has no trailing slash');
select t.fails($$insert into public.tenants (subdomain, name, supabase_url, anon_key, backup_name) values ('okshop', 'X Co', 'https://x.supabase.co', 'sb_publishable_xxxxxxxxxxxxxxxxxxxx', 'client2')$$, 'duplicate', 'two clients cannot share a backup folder');
select t.ok((select updated_at > created_at from public.tenants where subdomain = 'closed'), 'a change moves updated_at');

-- what the public app (anon) can and cannot do
set role anon;
select t.ok(public.tenant_config('sapcongo')::jsonb = '{"name":"SAP Congo","url":"https://abcdefghijklmnopqrst.supabase.co","anon_key":"sb_publishable_aaaaaaaaaaaaaaaaaaaa","status":"active"}'::jsonb, 'anon gets the URL and public key for one address');
select t.ok(public.tenant_config('  SapCongo ')->>'name' = 'SAP Congo', 'the address is matched without case or spaces');
select t.ok(public.tenant_config('closed')->>'status' = 'suspended', 'a suspended client says so');
select t.ok(public.tenant_config('newshop') is null, 'a client still being set up is not served');
select t.ok(public.tenant_config('nobody') is null, 'an unknown address gets nothing');
select t.ok(public.tenant_config('%') is null, 'no wildcard matching');
select t.ok(not (public.tenant_config('sapcongo')::jsonb ? 'contact') and not (public.tenant_config('sapcongo')::jsonb ? 'project_ref'), 'contacts and project refs are not handed out');
select t.fails('select * from public.tenants', 'permission denied', 'anon cannot list the clients');
select t.fails($$update public.tenants set status = 'active'$$, 'permission denied', 'anon cannot change a client');
select t.fails($$insert into public.tenants (subdomain, name, supabase_url, anon_key) values ('evil', 'Evil', 'https://evil.example', 'sb_publishable_xxxxxxxxxxxxxxxxxxxx')$$, 'permission denied', 'anon cannot add a client');
reset role;
set role authenticated;
select t.fails('select * from public.tenants', 'permission denied', 'a signed-in user cannot list the clients either');
reset role;

\echo 'control: all tests passed'
