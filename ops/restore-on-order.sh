#!/usr/bin/env bash
# Puts back, from a backup, the stock that was on order (below zero) before all stock was cleared: reads the shops'
# stock and the central store's quantities out of the backup (a plain .dump; the workflow decrypts it first) and runs
# supabase/scripts/restore_on_order.sql. Used by .github/workflows/restore-on-order.yml and the tests.
#
#   ops/restore-on-order.sh <db-url-file> <backup.dump> plan     shows what would come back; changes nothing
#   ops/restore-on-order.sh <db-url-file> <backup.dump> apply    does it
#
# Like ops/migrate.sh, a temporary login from the Management API acts as postgres; a login that cannot is refused.
set -euo pipefail
cd "$(dirname "$0")/.."
URL_FILE=${1:?usage: restore-on-order.sh <db-url-file> <backup.dump> plan|apply}; DUMP=${2:?backup.dump}; MODE=${3:?plan|apply}
[[ $MODE == plan || $MODE == apply ]] || { echo "mode must be plan or apply"; exit 2; }
PSQL=${PSQL:-psql}; PG_RESTORE=${PG_RESTORE:-pg_restore}
DB=$(<"$URL_FILE")
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
NAME=$(basename "$DUMP" .gpg); NAME=${NAME%.dump}
[[ $NAME =~ ^[A-Za-z0-9._-]{1,120}$ ]] || { echo "bad backup name: $NAME"; exit 2; }

# the two tables' rows, out of the backup, loaded into temporary tables instead
"$PG_RESTORE" --data-only --schema=public --table=shop_stock --table=products --file="$TMP/data.sql" "$DUMP"
grep -q '^COPY public.shop_stock ' "$TMP/data.sql" && grep -q '^COPY public.products ' "$TMP/data.sql" \
  || { echo "This backup has no shop stock or items: is it a QuickSales backup?"; exit 1; }
# only the rows: the session settings pg_restore writes around them depend on its version (pg_restore 17 writes
# "SET transaction_timeout", which an older server rejects), and none of them is needed to read two tables
sed -i -e '/^SET /d' -e '/^SELECT pg_catalog.set_config/d' \
  -e 's/^COPY public\.shop_stock /COPY pg_temp.zs_old_stock /' -e 's/^COPY public\.products /COPY pg_temp.zs_old_products /' "$TMP/data.sql"

cat > "$TMP/run.sql" <<SQL
set client_min_messages = warning;
select current_user <> 'postgres' as need_role, pg_has_role(current_user, 'postgres', 'member') as can_role \gset
\if :need_role
  \if :can_role
    set role postgres;
  \else
    \echo 'This login cannot act as postgres, so it must not change the database.'
    select 1/0 as cannot_act_as_postgres;
  \endif
\endif
create temp table zs_old_stock (like public.shop_stock);
create temp table zs_old_products (like public.products);
\i '$TMP/data.sql'
select set_config('zs.file', '$NAME', false);
\i '$(realpath supabase/scripts/restore_on_order.sql)'
SQL
set +e
out=$("$PSQL" "$DB" -X -q -v ON_ERROR_STOP=1 -v apply=$([[ $MODE == apply ]] && echo true || echo false) -f "$TMP/run.sql" 2>&1)
rc=$?
set -e
report=$(echo "$out" | sed -n -e 's/^psql:[^:]*:[0-9]*: //' -e 's/^NOTICE:  //p' -e '/^Done:/p' -e '/^Plan only:/p' -e 's/^ERROR:  /Stopped: /p')
echo "Backup: $NAME"; echo "$report"
[[ -n ${GITHUB_STEP_SUMMARY:-} ]] && { echo "- Backup: \`$NAME\`"; echo "$report" | sed 's/^/- /'; } >> "$GITHUB_STEP_SUMMARY"
if [[ $rc -ne 0 ]]; then
  [[ -n ${GITHUB_ACTIONS:-} ]] && echo "::error::$(echo "$out" | grep -m1 'ERROR' | sed 's/.*ERROR:  //')"
  echo "$out" | grep -v '^NOTICE' | tail -5 >&2
  exit "$rc"
fi
