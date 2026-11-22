#!/usr/bin/env bash
# Tests ops/zero-stock.sh on the database supabase/tests/sim_test.sql has just filled (sales, deliveries, sets, vendeurs).
# Usage: supabase/tests/zero_stock_test.sh <db-url-file>   (run.sh calls it)
set -euo pipefail
cd "$(dirname "$0")/../.."
URL_FILE=${1:?db url file}; DB=$(<"$URL_FILE")
q() { psql "$DB" -X -qtA -v ON_ERROR_STOP=1 -c "$1"; }
bad() { echo "FAIL: zero-stock: $*"; exit 1; }
ok() { echo "ok - $*"; }
stock() { q "select (select count(*) from products where wh_qty <> 0) + (select count(*) from shop_stock where qty <> 0 or open_pieces <> 0)"; }
books() { q "select count(*) || ':' || (select count(*) from invoices) || ':' || (select coalesce(sum(total), 0) from invoices) from vouchers"; }

# a delivery on its way stops it, changing nothing
pending=$(q "select count(*) from deliveries where status = 'pending'")
if [[ $pending == 0 ]]; then
  q "insert into deliveries (no, shop_id, rate, created_by_name) select 'DEL-ZS1', id, 2850, 'test' from shops order by name limit 1" >/dev/null
fi
before=$(stock); [[ $before -gt 0 ]] || bad "the test data should have stock"
if out=$(ops/zero-stock.sh "$URL_FILE" apply 2>&1); then bad "ran with a delivery on its way: $out"; fi
grep -q 'still on their way' <<< "$out" || bad "message: $out"
[[ $(stock) == "$before" ]] || bad "a refused run changed the stock"
ok "a delivery or return still on its way stops it, and nothing changes"
q "update deliveries set status = 'cancelled' where status = 'pending'; update shop_returns set status = 'cancelled' where status = 'pending'" >/dev/null

# plan: shows each place and changes nothing
b0=$(books)
out=$(ops/zero-stock.sh "$URL_FILE" plan)
grep -q 'Central store:' <<< "$out" && grep -q 'Plan only' <<< "$out" && grep -q 'In all:' <<< "$out" || bad "plan output: $out"
[[ $(stock) == "$before" && $(books) == "$b0" ]] || bad "plan changed something"
ok "plan shows what would be cleared, place by place, and changes nothing"

# apply: every quantity to zero, sales untouched, the value booked, the books balanced
value=$(q "select round(coalesce((select sum(p.wh_qty * coalesce(c.cost_usd, 0)) from products p left join product_costs c on c.product_id = p.id), 0)
  + coalesce((select sum((s.qty - s.open_pieces::numeric / greatest(p.pieces_per_set, 1)) * coalesce(c.cost_usd, 0)) from shop_stock s join products p on p.id = s.product_id
              left join product_costs c on c.product_id = s.product_id), 0), 2)")
inv=$(q "select count(*) || ':' || sum(total) from invoices")
out=$(ops/zero-stock.sh "$URL_FILE" apply)
grep -q 'Done: all stock is now zero' <<< "$out" && grep -q 'remaining stock lines: 0' <<< "$out" || bad "apply output: $out"
[[ $(stock) == 0 ]] || bad "stock left"
[[ $(q "select count(*) || ':' || sum(total) from invoices") == "$inv" ]] || bad "sales changed"
booked=$(q "select round(coalesce(sum(case when l.side = 'Dr' then l.amount else -l.amount end), 0), 2) from voucher_lines l join vouchers v on v.id = l.voucher_id
  where v.ref = 'ZERO-STOCK' and l.account_id = app.acc('STOCK_ADJ')")
awk -v a="$booked" -v b="$value" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= 0.05) }' || bad "booked $booked, stock was worth $value"
[[ $(q "select count(*) from (select v.id from vouchers v join voucher_lines l on l.voucher_id = v.id group by v.id
  having abs(sum(case when l.side = 'Dr' then l.base else -l.base end)) > 0.011) x") == 0 ]] || bad "unbalanced vouchers"
[[ $(q "select count(*) from audit_log where action like 'All stock set to zero%'") == 1 ]] || bad "not logged"
ok "apply sets every quantity to zero, keeps every sale, and books the value removed (\$$value) as a stock adjustment"

# a second run has nothing to do
out=$(ops/zero-stock.sh "$URL_FILE" apply)
grep -q 'nothing to clear' <<< "$out" || bad "second run: $out"
ok "a second run finds nothing to clear"
