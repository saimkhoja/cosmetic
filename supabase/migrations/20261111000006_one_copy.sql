-- QuickSales: print one copy of each invoice instead of two.
-- A switch in Settings → Till options, off by default: invoices print two copies (customer and shop) as before.
-- With it on, each invoice prints once, the customer copy, at every till (sales, approvals and the invoices a till
-- operator prints for an order). A duplicate printed later from Invoices is unchanged. Each invoice remembers how
-- many copies it printed with, so the Invoices list counts duplicates right whichever way the switch was.
-- Already running QuickSales? Run this file once, after 20261111000005_shifts.sql, BEFORE the new app goes live.

-- stop at once if the update before this one was not run
do $$ begin
  if not exists (select 1 from information_schema.tables where table_schema = 'public' and table_name = 'shift_closes') then
    raise exception 'Run supabase/migrations/20261111000005_shifts.sql (and every earlier file) first, then this file. supabase/scripts/check_migrations.sql shows what is missing';
  end if;
end $$;

-- how many copies the invoice printed with when it was made (1 or 2); invoices from before have 2
alter table public.invoices add column if not exists copies smallint not null default 2 check (copies in (1, 2));
create or replace function app.trg_invoice_copies() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  new.copies := case when app.feature('one_copy') then 1 else 2 end;
  new.printed := new.copies;
  return new;
end $$;
drop trigger if exists invoice_copies on public.invoices;
create trigger invoice_copies before insert on public.invoices for each row execute function app.trg_invoice_copies();

-- the switch is saved with the others
create or replace function public.save_settings(p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); r numeric := app.num(p->>'rate'); v numeric := app.num(p->>'vat'); old numeric; c jsonb := '{}'; k text;
  br numeric := app.num(p->>'book_rate'); old_br numeric;
  fe jsonb := '{}';
begin
  if r is null or r <= 0 then raise exception 'Enter a valid exchange rate'; end if;
  if v is null or v < 0 or v > 30 then raise exception 'VAT must be between 0 and 30'; end if;
  if br is not null and br <= 0 then raise exception 'Enter a valid internal rate'; end if;
  foreach k in array array['name','address','phone','email','rccm','idnat','nif','footer'] loop
    c := c || jsonb_build_object(k, left(btrim(coalesce(p->'company'->>k, '')), 80));
  end loop;
  foreach k in array array['customer_optional','barcode','till_sells','cash_change','usd_pay','one_copy'] loop
    fe := fe || jsonb_build_object(k, coalesce((p->'features'->>k)::boolean, false));
  end loop;
  select rate, book_rate into old, old_br from settings where id = 1 for update;
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
