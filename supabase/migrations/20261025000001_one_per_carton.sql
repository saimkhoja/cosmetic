-- SIM: an item can come one pc per carton. "Pcs in one carton" now takes 1 or more (it was 2 or more).
-- For such an item one carton is one pc, so its carton price is its price per pc and the till offers it once, as pcs.
-- Already running SIM? Run this file once, after 20261024000001_supplier_returns.sql; it keeps your data.

create or replace function app.product_fields(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  name text := btrim(regexp_replace(coalesce(p->>'name',''), '\s+', ' ', 'g'));
  cat text := btrim(coalesce(p->>'category',''));
  b boolean := coalesce((p->>'is_bundle')::boolean, false);
  cc numeric; per numeric; pc numeric; dz numeric; hz numeric; ctn numeric; cpc numeric;
  sc numeric; sp numeric; pcs numeric; pp numeric;
begin
  if name = '' then raise exception 'Enter the item name'; end if;
  if length(name) > 60 then raise exception 'Item name is too long (60 characters at most)'; end if;
  if cat = '' then raise exception 'Choose the category'; end if;
  select c.name into cat from categories c where lower(c.name) = lower(cat);
  if cat is null then raise exception 'Category "%" does not exist. The Admin creates categories first', btrim(p->>'category'); end if;
  if b then
    sc := app.num(p->>'set_cost'); sp := app.num(p->>'set_price'); pcs := app.num(p->>'pcs'); pp := app.num(p->>'piece');
    if sc is null or sc < 0 or sp is null or sp <= 0 then raise exception 'Enter the cost and selling price of one set'; end if;
    if sp < sc then raise exception 'Set price cannot be below its cost'; end if;
    if pcs is null or pcs < 2 or pcs <> trunc(pcs) or pp is null or pp <= 0 then
      raise exception 'For a mixed set, enter the pieces per set and the last price for one piece';
    end if;
    return jsonb_build_object('name',name,'category',cat,'stock_unit','set','is_bundle',true,
      'per_carton',0,'pieces_per_set',pcs::int,'price_usd',sp,'dozen_usd',0,'half_dozen_usd',0,'carton_usd',0,'piece_usd',pp,
      'carton_cost_usd',0,'cost_usd',sc);
  end if;
  cc := app.num(p->>'carton_cost'); per := app.num(p->>'per_carton'); pc := coalesce(app.num(p->>'pc'), 0);
  dz := coalesce(app.num(p->>'dzn'), 0); hz := coalesce(app.num(p->>'half'), 0); ctn := coalesce(app.num(p->>'ctn'), 0);
  if cc is null or cc < 0 then raise exception 'Enter the cost of one carton'; end if;
  if per is null or per < 1 or per <> trunc(per) then raise exception 'Enter how many pcs are in one carton (1 or more)'; end if;
  if pc < 0 or dz < 0 or hz < 0 or ctn < 0 then raise exception 'Prices cannot be negative'; end if;
  cpc := cc / per;
  -- a carton of 12 (or 6) is the dozen (or half dozen): that price is the carton price
  if per = 12 then ctn := coalesce(nullif(ctn, 0), dz); dz := 0; end if;
  if per = 6 then ctn := coalesce(nullif(ctn, 0), hz); hz := 0; end if;
  -- one pc per carton: the carton is the pc, so the carton price is the price per pc
  if per = 1 then pc := coalesce(nullif(pc, 0), ctn); ctn := 0; end if;
  if pc = 0 and hz = 0 and dz = 0 and ctn = 0 then raise exception 'Enter at least one selling price: per pc, half dozen, dozen or carton'; end if;
  if pc > 0 and pc < cpc - 0.000000001 then raise exception 'Price per pc is below the cost of one pc (%)', app.usd(cpc); end if;
  if hz > 0 and hz < cpc * 6 - 0.000000001 then raise exception 'Price per half dozen is below the cost of 6 pcs (%)', app.usd(cpc * 6); end if;
  if dz > 0 and dz < cpc * 12 - 0.000000001 then raise exception 'Price per dozen is below the cost of 12 pcs (%)', app.usd(cpc * 12); end if;
  if ctn > 0 and ctn < cc then raise exception 'Price per carton cannot be below the carton cost'; end if;
  return jsonb_build_object('name',name,'category',cat,'stock_unit','pcs','is_bundle',false,
    'per_carton',per::int,'pieces_per_set',0,'price_usd',pc,'dozen_usd',dz,'half_dozen_usd',hz,'carton_usd',ctn,'piece_usd',0,
    'carton_cost_usd',cc,'cost_usd',cpc);
end $$;
