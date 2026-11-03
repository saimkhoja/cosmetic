-- QuickSales: the sales report lists the sales of each category, with the items sold in it, for the category
-- chart on the Reports page. Amounts are after each invoice's discount, so the categories add up to the sales.
-- Already running QuickSales? Run this file once, after 20261103000003_carton_parts.sql, BEFORE the new app goes live.

create or replace function public.sales_report(p_from date, p_to date, p_shop uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare u public.profiles := app.req('admin','shopadmin'); sid uuid; tz text; res jsonb;
begin
  if p_from is null or p_to is null then raise exception 'Choose the dates'; end if;
  if p_from > p_to then select p_to, p_from into p_from, p_to; end if;
  sid := case when u.role = 'shopadmin' then u.shop_id else p_shop end;
  select settings.tz into tz from settings where id = 1;
  with inv as (
    select i.*, (i.t at time zone tz)::date as day,
      (select coalesce(sum(qty),0) from invoice_items where invoice_id = i.id) as q,
      (select coalesce(sum(cost_usd * qty),0) from invoice_items where invoice_id = i.id) as cogs,
      coalesce((select e.from_total from invoice_edits e where e.invoice_id = i.id order by e.at, e.id limit 1), i.total)
        + (select coalesce(sum(greatest(0, to_total - from_total)),0) from invoice_edits where invoice_id = i.id) as col,
      (select coalesce(sum(greatest(0, from_total - to_total)),0) from invoice_edits where invoice_id = i.id) as ret,
      exists (select 1 from invoice_edits where invoice_id = i.id) as edited
    from invoices i
    where (sid is null or i.shop_id = sid) and (i.t at time zone tz)::date between p_from and p_to
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'shop_id', sid,
    'n', (select count(*) from inv),
    'total', (select coalesce(sum(total),0) from inv),
    'total_usd', (select coalesce(sum(total / rate),0) from inv),
    'disc', (select coalesce(sum(disc),0) from inv),
    'vat', (select coalesce(sum(vat),0) from inv),
    'items', (select coalesce(sum(q),0) from inv),
    'edited', (select count(*) from inv where edited),
    'profit_usd', case when u.role = 'admin' then (select coalesce(sum(ht / rate - cogs),0) from inv) end,
    'by_day', (select coalesce(jsonb_agg(bd order by bd.day), '[]') from (select day, count(*) n, sum(q) q, sum(disc) d, sum(total) v from inv group by day) bd),
    'top', (select coalesce(jsonb_agg(x order by x.val desc), '[]') from (
        select ii.name, sum(ii.qty) qty, sum(ii.line) val from invoice_items ii join inv on inv.id = ii.invoice_id group by ii.product_id, ii.name order by 3 desc limit 15) x),
    -- sales by category (the item's category now), each with its items: the amount after the invoice's discount,
    -- the pcs sold (pieces of a mixed set apart) and how many of each unit
    'by_category', (select coalesce(jsonb_agg(jsonb_build_object('category', bc.cat, 'val', bc.val, 'pcs', bc.pcs, 'items', bc.items) order by bc.val desc, bc.cat), '[]') from (
        select bi.cat, sum(bi.val)::bigint val, sum(bi.pcs)::bigint pcs,
          jsonb_agg(jsonb_build_object('product_id', bi.product_id, 'name', bi.name, 'val', bi.val, 'pcs', bi.pcs, 'pieces', bi.pieces, 'units', bi.units)
            order by bi.val desc, bi.name) items
        from (
          select bu.cat, bu.product_id, min(bu.name) name, sum(bu.val)::bigint val, sum(bu.pcs)::bigint pcs, sum(bu.pieces)::bigint pieces,
            jsonb_object_agg(bu.unit, bu.qty) units
          from (
            select coalesce(nullif(btrim(p.category), ''), 'No category') cat, ii.product_id, min(ii.name) name, ii.unit, sum(ii.qty) qty,
              coalesce(round(sum(ii.line * inv.total::numeric / nullif(inv.gross, 0))), 0) val,
              sum(case when ii.piece then 0 else ii.qty * ii.mult end) pcs, sum(case when ii.piece then ii.qty else 0 end) pieces
            from invoice_items ii join inv on inv.id = ii.invoice_id join products p on p.id = ii.product_id
            group by 1, 2, 4) bu
          group by bu.cat, bu.product_id) bi
        group by bi.cat) bc),
    'by_cashier', (select coalesce(jsonb_agg(c order by c.v desc), '[]') from (select cashier_name as name, sum(total) v from inv group by cashier_name) c),
    'slips', (select coalesce(jsonb_agg(sl order by sl.shop_name), '[]') from (
        select s.id as shop_id, s.name as shop_name, s.code, count(inv.id) n, coalesce(sum(inv.total),0) value_fc, coalesce(sum(inv.total / inv.rate),0) value_usd,
          coalesce(sum(inv.col),0) collected, coalesce(sum(inv.ret),0) returned,
          coalesce(sum(inv.paid_usd - inv.change_usd),0) collected_usd,
          coalesce(sum(inv.col - round((inv.paid_usd - inv.change_usd) * inv.rate)),0)::bigint collected_cdf
        from shops s left join inv on inv.shop_id = s.id
        where (sid is null and s.active) or s.id = sid group by s.id, s.name, s.code) sl),
    'invoices', (select coalesce(jsonb_agg(v order by v.t desc), '[]') from (
        select id, no, t, shop_id, cashier_name, customer, q as items, disc, total, edited from inv order by t desc limit 300) v)
  ) into res;
  return res;
end $$;

-- ---------- who may call what ----------
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema app from public, anon;
grant execute on function public.setup_needed() to anon, authenticated;
grant execute on function public.sales_report(date, date, uuid) to authenticated;
revoke execute on function public.app_setup(uuid, text, text, jsonb) from authenticated;
