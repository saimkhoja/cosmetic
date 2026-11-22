-- Signups from getquicksales.com: a request waits for your approval, then the provision workflow sets it up.
--   pending ──approve──► provisioning ──► active          (reject deletes the request and frees the name)
--                             └──────────► failed ──retry──► provisioning
-- Only active and suspended clients are served (tenant_config) and updated / backed up (ops/clients.mjs list).

-- one place for the address rules, used by the table and by subdomain_available()
-- Keep the reserved list in step with app/src/lib/tenant.ts (RESERVED).
create function public.subdomain_problem(s text) returns text
language sql immutable set search_path = public, pg_temp as $$
  select case
    when s is null or s !~ '^[a-z0-9]([a-z0-9-]{0,38}[a-z0-9])?$' or s ~ '--' then 'invalid'
    when s in ('www', 'app', 'api', 'admin', 'control', 'mail', 'email', 'smtp', 'ftp', 'status', 'docs', 'help', 'support',
      'billing', 'signup', 'login', 'dashboard', 'static', 'assets', 'cdn', 'dev', 'staging', 'test', 'demo',
      'approve', 'quicksales', 'getquicksales', 'shop', 'shops', 'my', 'account', 'pay', 'secure') then 'reserved'
  end
$$;
alter table public.tenants drop constraint tenants_subdomain_check;
-- rows already in the table keep their address even if it became reserved; new ones follow the rule
alter table public.tenants add constraint tenants_subdomain_check check (public.subdomain_problem(subdomain) is null) not valid;

-- a request has no database yet
alter table public.tenants alter column supabase_url drop not null, alter column anon_key drop not null;
alter table public.tenants drop constraint tenants_status_check;
alter table public.tenants add constraint tenants_status_check
  check (status in ('pending', 'provisioning', 'active', 'suspended', 'failed'));
alter table public.tenants add constraint tenants_served_check
  check (status not in ('active', 'suspended') or (supabase_url is not null and anon_key is not null));
alter table public.tenants
  add column lang        text not null default 'fr' check (lang in ('fr', 'en')),
  add column ip_hash     text,               -- a salted hash of the signup's address, only to limit repeat requests
  add column approved_at timestamptz,
  add column ready_at    timestamptz,
  add column error       text;
create index tenants_pending_idx on public.tenants (created_at) where status = 'pending';

-- the signup form: is this address free? 'ok', 'taken', 'reserved' or 'invalid'
create function public.subdomain_available(p_subdomain text) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(public.subdomain_problem(lower(btrim(p_subdomain))),
    case when exists (select 1 from public.tenants where subdomain = lower(btrim(p_subdomain))) then 'taken' else 'ok' end)
$$;

-- What the public sees of a request. Used in the emails and on the approval page.
create function public.signup_details(p_subdomain text) returns json
language sql stable security definer set search_path = public, pg_temp as $$
  select json_build_object('subdomain', t.subdomain, 'business', t.name, 'status', t.status, 'lang', t.lang,
    'name', t.contact->>'name', 'email', t.contact->>'email', 'phone', t.contact->>'phone', 'shops', (t.contact->>'shops')::int,
    'note', t.contact->>'note', 'created_at', t.created_at, 'created_epoch', floor(extract(epoch from t.created_at))::bigint,
    'error', t.error, 'url', t.supabase_url)
  from public.tenants t where t.subdomain = lower(btrim(p_subdomain))
$$;

-- A new request from the signup form (through the signup Edge Function, never straight from the browser).
-- Errors start with QS: so the function can show them in the visitor's language.
create function public.request_signup(p jsonb, p_ip_hash text) returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  sub text := lower(btrim(coalesce(p->>'subdomain', '')));
  business text := btrim(coalesce(p->>'business', ''));
  person text := btrim(coalesce(p->>'name', ''));
  mail text := lower(btrim(coalesce(p->>'email', '')));
  phone text := btrim(coalesce(p->>'phone', ''));
  note text := left(btrim(coalesce(p->>'note', '')), 500);
  lang text := case when p->>'lang' = 'en' then 'en' else 'fr' end;
  shops int;
  problem text := public.subdomain_problem(sub);
begin
  if problem is not null then raise exception 'QS:subdomain_%', problem; end if;
  if length(business) not between 2 and 80 then raise exception 'QS:business'; end if;
  if length(person) not between 2 and 60 then raise exception 'QS:name'; end if;
  if mail !~ '^[^@\s]+@[^@\s]+\.[a-z]{2,}$' or length(mail) > 120 then raise exception 'QS:email'; end if;
  if phone !~ '^\+?[0-9 ().-]{6,30}$' then raise exception 'QS:phone'; end if;
  begin shops := coalesce((p->>'shops')::int, 1); exception when others then raise exception 'QS:shops'; end;
  if shops not between 1 and 50 then raise exception 'QS:shops'; end if;
  -- limits against abuse: 3 open requests a day from one address, 30 a day in all
  if p_ip_hash is not null and (select count(*) from public.tenants where ip_hash = p_ip_hash and status = 'pending'
      and created_at > now() - interval '1 day') >= 3 then raise exception 'QS:too_many'; end if;
  if (select count(*) from public.tenants where status = 'pending' and created_at > now() - interval '1 day') >= 30 then
    raise exception 'QS:busy'; end if;
  begin
    insert into public.tenants (subdomain, name, status, lang, ip_hash, backup_name, contact)
    values (sub, business, 'pending', lang, p_ip_hash, null,
      jsonb_build_object('name', person, 'email', mail, 'phone', phone, 'shops', shops, 'note', note));
  exception when unique_violation then raise exception 'QS:subdomain_taken';
  end;
  return public.signup_details(sub);
end $$;

-- You approve (or retry a failed setup): the provision workflow is started by the approve Edge Function.
create function public.approve_signup(p_subdomain text) returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare st text;
begin
  select status into st from public.tenants where subdomain = p_subdomain for update;
  if st is null then raise exception 'QS:not_found'; end if;
  if st not in ('pending', 'failed') then raise exception 'QS:already_%', st; end if;
  update public.tenants set status = 'provisioning', error = null, approved_at = coalesce(approved_at, now())
  where subdomain = p_subdomain;
  return public.signup_details(p_subdomain);
end $$;

-- undo an approval whose workflow could not be started
create function public.unapprove_signup(p_subdomain text, p_error text) returns void
language sql security definer set search_path = public, pg_temp as $$
  update public.tenants set status = 'failed', error = left(p_error, 1000)
  where subdomain = p_subdomain and status = 'provisioning' and project_ref is null
$$;

-- You reject: the request is deleted and the name is free again. Only a request that has no database yet.
create function public.reject_signup(p_subdomain text) returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare d json := public.signup_details(p_subdomain);
begin
  if d is null then raise exception 'QS:not_found'; end if;
  if d->>'status' <> 'pending' and not (d->>'status' = 'failed' and (select project_ref from public.tenants where subdomain = p_subdomain) is null) then
    raise exception 'QS:already_%', d->>'status';
  end if;
  delete from public.tenants where subdomain = p_subdomain;
  return d;
end $$;

-- The provision workflow (ops/provision.mjs) reports its progress.
create function public.provision_started(p_subdomain text, p_ref text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  -- the backup folder is the subdomain, unless another client already uses that folder name (e.g. client2)
  update public.tenants t set project_ref = p_ref, backup_name = coalesce(t.backup_name,
      case when exists (select 1 from public.tenants o where o.backup_name = p_subdomain and o.subdomain <> p_subdomain)
        then left(p_subdomain, 34) || '-' || substr(md5(p_ref), 1, 5) else p_subdomain end)
  where t.subdomain = p_subdomain and t.status = 'provisioning' and (t.project_ref is null or t.project_ref = p_ref);
  if not found then raise exception 'QS:not_provisioning'; end if;
end $$;
create function public.provision_done(p_subdomain text, p_url text, p_key text) returns json
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update public.tenants set supabase_url = p_url, anon_key = p_key, status = 'active', error = null, ready_at = now()
  where subdomain = p_subdomain and status = 'provisioning';
  if not found then raise exception 'QS:not_provisioning'; end if;
  return public.signup_details(p_subdomain);
end $$;
create function public.provision_failed(p_subdomain text, p_error text) returns json
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update public.tenants set status = 'failed', error = left(p_error, 1000)
  where subdomain = p_subdomain and status = 'provisioning';
  return public.signup_details(p_subdomain);
end $$;

-- Who may call what. Functions are callable by everyone unless revoked, so revoke first, then grant.
revoke execute on function public.subdomain_problem(text), public.subdomain_available(text), public.signup_details(text),
  public.request_signup(jsonb, text), public.approve_signup(text), public.unapprove_signup(text, text), public.reject_signup(text),
  public.provision_started(text, text), public.provision_done(text, text, text), public.provision_failed(text, text)
  from public, anon, authenticated;
-- the signup form checks names as you type
grant execute on function public.subdomain_available(text) to anon, authenticated, service_role;
-- the Edge Functions (secret key)
grant execute on function public.signup_details(text), public.request_signup(jsonb, text), public.approve_signup(text),
  public.unapprove_signup(text, text), public.reject_signup(text) to service_role;
-- provision_* are called by the workflow as postgres, through the Management API
