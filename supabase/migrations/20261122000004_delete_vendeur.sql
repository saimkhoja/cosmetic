-- QuickSales: a vendeur created by mistake can be deleted.
-- A vendeur with nothing recorded (no goods on credit, no payments, no promo items) is deleted with its ledger, even
-- when an "already owes" amount was typed when it was added: that amount is only a figure on the vendeur, nothing was
-- given against it. A vendeur with history is never deleted: once it owes nothing it is made inactive instead, keeping
-- its statement; while it still owes, it can be neither.
-- Already running QuickSales? Run this file once, after 20261122000003_shop_stock_in.sql. It changes no data.

-- stop at once if the update before this one was not run
do $$ begin
  if not exists (select 1 from pg_proc where proname = 'stock_in_shops') then
    raise exception 'Run supabase/migrations/20261122000003_shop_stock_in.sql (and every earlier file) first, then this file. supabase/scripts/check_migrations.sql shows what is missing';
  end if;
end $$;

create or replace function public.delete_vendeur(p_id uuid) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin','admin'); v public.vendeurs; st jsonb;
begin
  select * into v from vendeurs where id = p_id for update;
  if not found or (u.role = 'shopadmin' and v.shop_id <> u.shop_id) then raise exception 'Vendeur not found'; end if;
  -- created by mistake: nothing was ever recorded for it, so it goes completely (an opening amount included)
  if not exists (select 1 from invoices where vendeur_id = v.id) and not exists (select 1 from vendeur_payments where vendeur_id = v.id)
     and not exists (select 1 from vendeur_promos where vendeur_id = v.id) and not exists (select 1 from voucher_lines where account_id = v.account_id) then
    delete from vendeurs where id = v.id;
    delete from accounts where id = v.account_id;
    perform app.log(u, format('Deleted vendeur %s (%s)%s', v.name, (select name from shops where id = v.shop_id),
      case when v.opening_balance > 0 then format(', with the %s it was entered as owing', app.fc(v.opening_balance)) else '' end));
    return 'deleted';
  end if;
  -- with history: kept, made inactive once it owes nothing
  st := app.vendeur_state(v);
  if (st->>'balance')::bigint <> 0 then
    raise exception 'Vendeur % has goods or payments recorded and still owes %. Take the payment first; it is then made inactive, keeping its history', v.name, app.fc((st->>'balance')::bigint);
  end if;
  update vendeurs set active = false where id = v.id;
  perform app.log(u, format('Vendeur %s made inactive (its history is kept)', v.name));
  return 'inactive';
end $$;

-- ---------- who may call what ----------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.delete_vendeur(uuid) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
