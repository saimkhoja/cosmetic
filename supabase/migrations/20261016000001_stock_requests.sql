-- SIM update 4: the shop admin asks the central store for stock; the warehouse reviews the request
-- against its own stock and approves it (as asked or edited) or rejects it. An approved request
-- becomes a normal delivery, which the shop admin receives as before.
-- Run after the earlier files. Safe to run more than once.

create sequence if not exists public.stock_request_seq;
create table if not exists public.stock_requests (
  id               uuid primary key default gen_random_uuid(),
  no               text not null unique,
  shop_id          uuid not null references public.shops(id),
  note             text not null default '',
  status           text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  created_by       uuid,
  created_by_name  text not null,
  created_at       timestamptz not null default now(),
  reviewed_by_name text,
  reviewed_at      timestamptz,
  reason           text,
  delivery_id      uuid references public.deliveries(id)
);
create index if not exists stock_requests_shop_status on public.stock_requests (shop_id, status, created_at);
create table if not exists public.stock_request_items (
  request_id   uuid not null references public.stock_requests(id) on delete cascade,
  product_id   uuid not null references public.products(id),
  qty          int not null check (qty >= 0),        -- asked for (0 for an item the warehouse added)
  approved_qty int,
  primary key (request_id, product_id)
);
alter table public.stock_requests enable row level security;
alter table public.stock_request_items enable row level security;
revoke all on public.stock_requests, public.stock_request_items from anon, authenticated;
revoke all on sequence public.stock_request_seq from anon, authenticated;
grant select on public.stock_requests, public.stock_request_items to authenticated;
drop policy if exists r on public.stock_requests;
create policy r on public.stock_requests for select to authenticated
  using (app.my_role() in ('admin','whop') or (app.my_role() = 'shopadmin' and shop_id = app.my_shop()));
drop policy if exists r on public.stock_request_items;
create policy r on public.stock_request_items for select to authenticated
  using (exists (select 1 from public.stock_requests x where x.id = request_id));

create or replace function public.create_stock_request(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); rid uuid; rno text; n int;
begin
  if not exists (select 1 from app.lines(p->'lines')) then raise exception 'Enter a quantity for at least one item'; end if;
  if (select count(*) from products where active and id in (select product_id from app.lines(p->'lines'))) <> (select count(*) from app.lines(p->'lines')) then
    raise exception 'One of the items was not found';
  end if;
  rno := 'REQ-' || lpad(nextval('stock_request_seq')::text, 4, '0');
  insert into stock_requests (no, shop_id, note, created_by, created_by_name)
    values (rno, u.shop_id, left(btrim(coalesce(p->>'note','')), 120), u.id, u.name) returning id into rid;
  insert into stock_request_items (request_id, product_id, qty) select rid, l.product_id, l.qty from app.lines(p->'lines') l;
  select sum(qty) into n from stock_request_items where request_id = rid;
  perform app.log(u, format('Stock request %s from %s: %s items, %s units', rno, (select name from shops where id = u.shop_id),
    (select count(*) from stock_request_items where request_id = rid), n));
  return jsonb_build_object('id', rid, 'no', rno);
end $$;

create or replace function public.cancel_stock_request(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('shopadmin'); x public.stock_requests;
begin
  select * into x from stock_requests where id = p_id and shop_id = u.shop_id for update;
  if not found then raise exception 'Request not found'; end if;
  if x.status <> 'pending' then raise exception 'Request % was already %', x.no, x.status; end if;
  update stock_requests set status = 'cancelled', reason = nullif(left(btrim(coalesce(p_reason,'')), 120), ''), reviewed_by_name = u.name, reviewed_at = now() where id = p_id;
  perform app.log(u, format('Stock request %s cancelled by the shop', x.no));
end $$;

create or replace function public.reject_stock_request(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin','whop'); x public.stock_requests;
begin
  select * into x from stock_requests where id = p_id for update;
  if not found then raise exception 'Request not found'; end if;
  if x.status <> 'pending' then raise exception 'Request % was already %', x.no, x.status; end if;
  if length(btrim(coalesce(p_reason,''))) < 4 then raise exception 'Write a short reason, the shop admin will see it'; end if;
  update stock_requests set status = 'rejected', reason = left(btrim(p_reason), 120), reviewed_by_name = u.name, reviewed_at = now() where id = p_id;
  perform app.log(u, format('Stock request %s from %s rejected: %s', x.no, (select name from shops where id = x.shop_id), btrim(p_reason)));
end $$;

-- approve as asked (no lines), or with the warehouse's own lines (an edit: changed quantities,
-- removed or added items). Either way a delivery is made for the shop, checked against the store
-- stock not already promised to other deliveries.
create or replace function public.approve_stock_request(p_id uuid, p_lines jsonb default null, p_note text default '') returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin','whop'); x public.stock_requests; lines jsonb; made jsonb; did uuid; dno text; edited boolean;
  v_note text := btrim(coalesce(p_note,''));
begin
  select * into x from stock_requests where id = p_id for update;
  if not found then raise exception 'Request not found'; end if;
  if x.status <> 'pending' then raise exception 'Request % was already %', x.no, x.status; end if;
  if p_lines is null then
    select jsonb_agg(jsonb_build_object('product_id', product_id, 'qty', qty)) into lines from stock_request_items where request_id = p_id and qty > 0;
  else
    if exists (select 1 from jsonb_array_elements(p_lines) e where coalesce(e->>'qty','') !~ '^\d{1,7}$') then raise exception 'Quantities must be whole numbers'; end if;
    select jsonb_agg(e) into lines from jsonb_array_elements(p_lines) e where (e->>'qty')::int > 0;
  end if;
  if lines is null then raise exception 'Nothing to send. Reject the request instead'; end if;
  -- what changed compared with the request
  edited := exists (
    with a as (select product_id pid, qty q from stock_request_items where request_id = p_id),
         b as (select l.product_id pid, l.qty q from app.lines(lines) l)
    select 1 from a full join b using (pid) where coalesce(a.q, 0) <> coalesce(b.q, 0));
  if edited and length(v_note) < 4 then raise exception 'You changed the request. Write a short reason, the shop admin will see it'; end if;
  made := public.create_deliveries(array[x.shop_id], lines);
  did := (made->0->>'id')::uuid; dno := made->0->>'no';
  insert into stock_request_items (request_id, product_id, qty, approved_qty)
    select p_id, l.product_id, 0, l.qty from app.lines(lines) l
    on conflict (request_id, product_id) do update set approved_qty = excluded.approved_qty;
  update stock_request_items set approved_qty = 0 where request_id = p_id and approved_qty is null;
  update stock_requests set status = 'approved', delivery_id = did, reviewed_by_name = u.name, reviewed_at = now(),
    reason = case when edited then left(v_note, 120) else nullif(left(v_note, 120), '') end where id = p_id;
  perform app.log(u, format('Stock request %s from %s approved%s: %s', x.no, (select name from shops where id = x.shop_id),
    case when edited then ' with changes (' || v_note || ')' else '' end, dno));
  return jsonb_build_object('delivery_id', did, 'delivery_no', dno, 'edited', edited);
end $$;

-- ---------- who may call what ----------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.create_stock_request(jsonb), public.cancel_stock_request(uuid, text), public.reject_stock_request(uuid, text),
  public.approve_stock_request(uuid, jsonb, text) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
