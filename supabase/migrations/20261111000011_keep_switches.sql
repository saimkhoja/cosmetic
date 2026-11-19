-- QuickSales: saving the Settings page no longer turns off a switch the app did not send.
-- Every switch was rebuilt from the page each time it was saved, and anything missing became off. So an app that
-- did not know about a switch -- an older build still cached on a till, or a page saved before an update reached
-- that computer -- turned it off just by saving, and "Accept payment in USD" could go off on its own.
-- Now a switch the page does not send keeps the value it has. Turning one off still works: the page sends it as off.
-- Already running QuickSales? Run this file once, after 20261111000010_usd_at_till_rate.sql. It changes no data.

-- stop at once if the update before this one was not run
do $$ begin
  if not exists (select 1 from pg_proc where proname = 'sales_report' and pg_get_functiondef(oid) like '%coalesce(usd_rate, rate)%') then
    raise exception 'Run supabase/migrations/20261111000010_usd_at_till_rate.sql (and every earlier file) first, then this file. supabase/scripts/check_migrations.sql shows what is missing';
  end if;
end $$;

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
  foreach k in array array['customer_optional','barcode','till_sells','cash_change','usd_pay','one_copy','no_warehouse'] loop
    fe := fe || jsonb_build_object(k, coalesce((p->'features'->>k)::boolean, coalesce((cur->>k)::boolean, false)));
  end loop;
  br := coalesce(br, old_br);   -- an older app that does not send the internal rate keeps it as it is
  update settings set rate = r, book_rate = br, vat = v, company = c, features = fe, updated_at = now() where id = 1;
  if old <> r then perform app.log(u, format('Sales rate changed %s to %s', old, r)); end if;
  if old_br <> br then perform app.log(u, format('Internal rate changed %s to %s', old_br, br)); end if;
  if old = r and old_br = br then perform app.log(u, 'Settings updated'); end if;
end $$;

-- ---------- who may call what ----------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.save_settings(jsonb) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
