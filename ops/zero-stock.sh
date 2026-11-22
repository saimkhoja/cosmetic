#!/usr/bin/env bash
# Runs supabase/scripts/zero_stock.sql on one client's database: every quantity in the central store and the shops to 0,
# sales kept, the value removed booked as a stock adjustment. Used by .github/workflows/zero-stock.yml and the tests.
#
#   ops/zero-stock.sh <db-url-file> plan     shows what would be cleared; changes nothing
#   ops/zero-stock.sh <db-url-file> apply    does it
#
# The connection string is read from a file so it never shows in the process list or the logs. Like ops/migrate.sh,
# a temporary login from the Management API acts as postgres; a login that cannot is refused.
set -euo pipefail
cd "$(dirname "$0")/.."
URL_FILE=${1:?usage: zero-stock.sh <db-url-file> plan|apply}; MODE=${2:?usage: zero-stock.sh <db-url-file> plan|apply}
[[ $MODE == plan || $MODE == apply ]] || { echo "mode must be plan or apply"; exit 2; }
PSQL=${PSQL:-psql}
DB=$(<"$URL_FILE")
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/run.sql" <<'SQL'
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
SQL
echo "\\i '$(realpath supabase/scripts/zero_stock.sql)'" >> "$TMP/run.sql"
set +e
out=$("$PSQL" "$DB" -X -q -v ON_ERROR_STOP=1 -v apply=$([[ $MODE == apply ]] && echo true || echo false) -f "$TMP/run.sql" 2>&1)
rc=$?
set -e
# the notices are the report, place by place; the summary gets them too
report=$(echo "$out" | sed -n -e 's/^psql:[^:]*:[0-9]*: //' -e 's/^NOTICE:  //p' -e '/^Done:/p' -e '/^Plan only:/p' -e '/remaining stock lines/p' -e 's/^ERROR:  /Stopped: /p')
echo "$report"
[[ -n ${GITHUB_STEP_SUMMARY:-} ]] && echo "$report" | sed 's/^/- /' >> "$GITHUB_STEP_SUMMARY"
if [[ $rc -ne 0 ]]; then
  [[ -n ${GITHUB_ACTIONS:-} ]] && echo "::error::$(echo "$out" | grep -m1 'ERROR' | sed 's/.*ERROR:  //')"
  echo "$out" | grep -v '^NOTICE' | tail -5 >&2
  exit "$rc"
fi
