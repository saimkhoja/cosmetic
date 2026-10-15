-- SIM update 3b: statements and the day book list entries of the same day in the order they were
-- entered (a bill before the payment that settles it), so the running balance reads correctly.
-- Run after file 7. Safe to run more than once.

create or replace function public.account_statement(p_account uuid, p_from date, p_to date, p_opening boolean default true) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin','whop','shopadmin'); a public.accounts; bf numeric := 0; res jsonb;
begin
  select * into a from accounts where id = p_account;
  if not found or not app.can_read_account(a, u) then raise exception 'Ledger not found'; end if;
  if p_from > p_to then select p_to, p_from into p_from, p_to; end if;
  if p_opening then
    bf := app.opening_base(a) + coalesce((select sum(case when l.side = 'Dr' then l.base else -l.base end) from voucher_lines l join vouchers v on v.id = l.voucher_id
      where l.account_id = a.id and v.status = 'posted' and v.date < p_from), 0);
  end if;
  select jsonb_build_object(
    'account', jsonb_build_object('id', a.id, 'name', a.name, 'group', (select name from account_groups where code = a.group_code), 'currency', a.currency,
      'opening_amount', a.opening_amount, 'opening_side', a.opening_side, 'opening_currency', a.opening_currency),
    'from', p_from, 'to', p_to, 'with_opening', p_opening, 'brought_forward', round(bf, 2),
    'lines', coalesce((select jsonb_agg(x order by x.date, x.created_at, x.id) from (
       select l.id, v.date, v.created_at, v.no, v.type, v.narration, l.memo, l.side, l.amount, l.currency, l.rate, round(l.base, 2) as base, l.bill_ref, l.due_date
       from voucher_lines l join vouchers v on v.id = l.voucher_id
       where l.account_id = a.id and v.status = 'posted' and v.date between p_from and p_to) x), '[]'),
    'total_dr', round(coalesce((select sum(l.base) from voucher_lines l join vouchers v on v.id = l.voucher_id where l.account_id = a.id and v.status = 'posted' and l.side = 'Dr' and v.date between p_from and p_to), 0), 2),
    'total_cr', round(coalesce((select sum(l.base) from voucher_lines l join vouchers v on v.id = l.voucher_id where l.account_id = a.id and v.status = 'posted' and l.side = 'Cr' and v.date between p_from and p_to), 0), 2)
  ) into res;
  return res || jsonb_build_object('closing', round(bf + (res->>'total_dr')::numeric - (res->>'total_cr')::numeric, 2));
end $$;

create or replace function public.day_book(p_from date, p_to date, p_type text default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin');
begin
  return coalesce((select jsonb_agg(x order by x.date, x.created_at, x.no) from (
    select v.id, v.no, v.type, v.date, v.created_at, v.narration, v.ref, v.status, v.cancel_reason, v.created_by_name, v.source_type,
      (select jsonb_agg(jsonb_build_object('account', a.name, 'side', l.side, 'amount', l.amount, 'currency', l.currency, 'rate', l.rate, 'base', round(l.base, 2), 'memo', l.memo) order by l.side desc, l.id)
        from voucher_lines l join accounts a on a.id = l.account_id where l.voucher_id = v.id) as lines
    from vouchers v where v.date between p_from and p_to and (p_type is null or v.type = p_type) limit 2000) x), '[]');
end $$;

revoke execute on all functions in schema public from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.account_statement(uuid, date, date, boolean), public.day_book(date, date, text) to authenticated;
