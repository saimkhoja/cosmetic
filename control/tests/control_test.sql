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


-- ===== signups (20261123000001_signups.sql) =====
grant usage on schema t to service_role;
grant execute on all functions in schema t to service_role;
create function t.req(sub text, ip text default 'ip1', extra jsonb default '{}') returns json language sql as $$
  select public.request_signup(jsonb_build_object('subdomain', sub, 'business', 'Boutique ' || sub, 'name', 'Marie K',
    'email', sub || '@example.com', 'phone', '+243 81 000 0000', 'shops', 2, 'lang', 'en') || extra, ip) $$;
grant execute on function t.req(text, text, jsonb) to service_role;

set role anon;
select t.ok(public.subdomain_available('sapcongo') = 'taken', 'availability: a client''s name is taken');
select t.ok(public.subdomain_available(' FreeShop ') = 'ok', 'availability: a free name, case and spaces ignored');
select t.ok(public.subdomain_available('www') = 'reserved' and public.subdomain_available('approve') = 'reserved', 'availability: reserved names');
select t.ok(public.subdomain_available('bad_name') = 'invalid' and public.subdomain_available('') = 'invalid', 'availability: invalid names');
select t.fails($$select public.request_signup('{}', null)$$, 'permission denied', 'the public cannot file a request directly');
select t.fails($$select public.approve_signup('sapcongo')$$, 'permission denied', 'the public cannot approve');
select t.fails($$select public.reject_signup('sapcongo')$$, 'permission denied', 'the public cannot reject');
select t.fails($$select public.signup_details('sapcongo')$$, 'permission denied', 'the public cannot read a request');
select t.fails($$select public.provision_done('sapcongo', 'https://x.supabase.co', 'k')$$, 'permission denied', 'the public cannot mark a setup done');
reset role;

set role service_role;
select t.ok((t.req('boutique-marie')->>'status') = 'pending', 'a request is saved as pending');
select t.ok((public.signup_details('boutique-marie')->>'email') = 'boutique-marie@example.com'
  and (public.signup_details('boutique-marie')->>'shops')::int = 2 and public.signup_details('boutique-marie')->>'lang' = 'en', 'its details are kept');
select t.fails($$select t.req('boutique-marie')$$, 'QS:subdomain_taken', 'a name already asked for is taken');
select t.fails($$select t.req('sapcongo')$$, 'QS:subdomain_taken', 'a client''s name is taken');
select t.fails($$select t.req('admin')$$, 'QS:subdomain_reserved', 'a reserved name is refused');
select t.fails($$select t.req('Bad Name')$$, 'QS:subdomain_invalid', 'an invalid name is refused');
select t.fails($$select t.req('okname', 'ip9', '{"email":"not-an-email"}')$$, 'QS:email', 'a bad email is refused');
select t.fails($$select t.req('okname', 'ip9', '{"phone":"call me"}')$$, 'QS:phone', 'a bad phone is refused');
select t.fails($$select t.req('okname', 'ip9', '{"business":"x"}')$$, 'QS:business', 'a business name is needed');
select t.fails($$select t.req('okname', 'ip9', '{"shops":"many"}')$$, 'QS:shops', 'shops must be a number');
select t.fails($$select t.req('okname', 'ip9', '{"shops":0}')$$, 'QS:shops', 'at least one shop');
select t.req('second-req'); select t.req('third-req');
select t.fails($$select t.req('fourth-req')$$, 'QS:too_many', 'a fourth open request in a day from one address is refused');
select t.ok((t.req('fourth-req', 'ip2')->>'status') = 'pending', 'another address can still ask');
reset role;
select t.ok(public.tenant_config('boutique-marie') is null, 'a pending request is not served');
select t.fails($$update public.tenants set status = 'active' where subdomain = 'boutique-marie'$$, 'tenants_served_check', 'a client cannot be active without a database');

-- approve, set up, done
set role service_role;
select t.ok((public.approve_signup('boutique-marie')->>'status') = 'provisioning', 'approving starts the setup');
select t.fails($$select public.approve_signup('boutique-marie')$$, 'QS:already_provisioning', 'approving twice does nothing');
select t.fails($$select public.reject_signup('boutique-marie')$$, 'QS:already_provisioning', 'a request being set up cannot be rejected');
reset role;
select public.provision_started('boutique-marie', 'mariereffffffffffffff');
select t.ok((select project_ref = 'mariereffffffffffffff' and backup_name = 'boutique-marie' from public.tenants where subdomain = 'boutique-marie'), 'the new project and backup folder are recorded');
select t.fails($$select public.provision_started('boutique-marie', 'otherrefffffffffffff')$$, 'QS:not_provisioning', 'a second project is never recorded over the first');
select t.ok((public.provision_done('boutique-marie', 'https://mariereffffffffffffff.supabase.co', 'sb_publishable_mmmmmmmmmmmmmmmmmmmm')->>'status') = 'active', 'a finished setup is active');
select t.ok((public.tenant_config('boutique-marie')->>'url') = 'https://mariereffffffffffffff.supabase.co', 'and is served at its address');
select t.ok((select approved_at is not null and ready_at is not null from public.tenants where subdomain = 'boutique-marie'), 'approval and ready times are kept');

-- a failed setup, then a retry
set role service_role;
select public.approve_signup('second-req');
reset role;
select t.ok((public.provision_failed('second-req', 'pooler not ready')->>'status') = 'failed', 'a failed setup is marked failed with the reason');
select t.ok((public.signup_details('second-req')->>'error') = 'pooler not ready', 'the reason is kept');
set role service_role;
select t.ok((public.approve_signup('second-req')->>'status') = 'provisioning', 'a failed setup can be retried');
select t.ok(public.signup_details('second-req')->>'error' is null, 'a retry clears the old reason');
reset role;

-- a workflow that could not start
set role service_role;
select public.unapprove_signup('second-req', 'GitHub said 401');
select t.ok((public.signup_details('second-req')->>'status') = 'failed', 'an approval whose workflow did not start is marked failed');
-- reject
select t.ok((public.reject_signup('third-req')->>'subdomain') = 'third-req', 'rejecting returns what was rejected');
select t.ok(public.signup_details('third-req') is null and public.subdomain_available('third-req') = 'ok', 'a rejected name is free again');
select t.fails($$select public.reject_signup('sapcongo')$$, 'QS:already_active', 'a working client can never be rejected');
reset role;

-- a signup whose name is another client's backup folder gets a folder of its own
set role service_role;
select t.req('client2', 'ip7');
select public.approve_signup('client2');
reset role;
select public.provision_started('client2', 'clienttworefffffffff');
select t.ok((select backup_name ~ '^client2-[0-9a-f]{5}$' from public.tenants where subdomain = 'client2'), 'a name that is another client''s backup folder gets its own folder');

\echo 'control: all tests passed'
