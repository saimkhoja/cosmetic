-- SIM: a fourth switch in Settings (off by default): the cashier enters the cash received, the till
-- shows the change and the receipt prints both. Invoices already keep the cash received (tendered)
-- and the change, so only the settings learn the new switch.
-- Already running SIM? Run this file once, after 20261019000001_till_sells.sql; it keeps your data.

create or replace function public.save_settings(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); r numeric := app.num(p->>'rate'); v numeric := app.num(p->>'vat'); old numeric; c jsonb := '{}'; k text;
  fe jsonb := '{}';
begin
  if r is null or r <= 0 then raise exception 'Enter a valid exchange rate'; end if;
  if v is null or v < 0 or v > 30 then raise exception 'VAT must be between 0 and 30'; end if;
  foreach k in array array['name','address','phone','email','rccm','idnat','nif','footer'] loop
    c := c || jsonb_build_object(k, left(btrim(coalesce(p->'company'->>k, '')), 80));
  end loop;
  foreach k in array array['customer_optional','barcode','till_sells','cash_change'] loop
    fe := fe || jsonb_build_object(k, coalesce((p->'features'->>k)::boolean, false));
  end loop;
  select rate into old from settings where id = 1 for update;
  update settings set rate = r, vat = v, company = c, features = fe, updated_at = now() where id = 1;
  perform app.log(u, case when old <> r then format('Exchange rate changed %s to %s', old, r) else 'Settings updated' end);
end $$;

-- ---------- who may call what ----------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.save_settings(jsonb) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
