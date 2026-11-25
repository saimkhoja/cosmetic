-- QuickSales: the Admin can delete an expense in Store upkeep.
-- Deleting asks for a reason. The expense leaves the list and its payment voucher is cancelled with that reason, so
-- the money goes back into the cash or bank it was paid from. The voucher stays in Accounts as cancelled, and the
-- activity log keeps what the expense was. An old expense with no voucher found is only removed from the list.
-- Already running QuickSales? Run this file once, after 20261127000001_upkeep_edit.sql. It changes no data.

-- stop at once if the update before this one was not run
do $$ begin
  if not exists (select 1 from pg_proc where proname = 'edit_upkeep') then
    raise exception 'Run supabase/migrations/20261127000001_upkeep_edit.sql (and every earlier file) first, then this file. supabase/scripts/check_migrations.sql shows what is missing';
  end if;
end $$;

create or replace function public.delete_upkeep(p_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin'); x public.upkeep; vno text; vs text; what text; why text := btrim(coalesce(p_reason, ''));
begin
  select * into x from upkeep where id = p_id for update;
  if not found then raise exception 'Expense not found'; end if;
  if length(why) < 4 then raise exception 'Write a short reason for deleting this expense'; end if;
  select no, status into vno, vs from vouchers where id = x.voucher_id;
  -- the payment is undone: its voucher is cancelled (a voucher already cancelled in Accounts stays as it is)
  if vs = 'posted' then
    update vouchers set status = 'cancelled', cancel_reason = left('Expense deleted: ' || why, 120) where id = x.voucher_id;
  end if;
  what := format('%s, %s, %s: %s', to_char(x.date, 'DD/MM/YYYY'), x.category, x.description,
    coalesce(x.amount || ' ' || x.currency, x.amount_usd || ' USD'));
  delete from upkeep where id = p_id;
  perform app.log(u, format('Expense deleted (%s): %s. Reason: %s', coalesce('voucher ' || vno || case when vs = 'posted' then ' cancelled' else ' was already cancelled' end, 'no voucher found'), what, why));
  return jsonb_build_object('voucher', vno, 'cancelled', vs = 'posted');
end $$;

revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.delete_upkeep(uuid, text) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
