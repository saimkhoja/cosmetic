#!/usr/bin/env bash
# Shows, for one client's database, whether the "new stock arrived" notices are working: the update, each shop's Shop
# Admins and notices, the last notices and the last stock added (supabase/scripts/check_stock_arrivals.sql). Read only.
#   ops/check-arrivals.sh <db-url-file>
set -euo pipefail
cd "$(dirname "$0")/.."
URL_FILE=${1:?usage: check-arrivals.sh <db-url-file>}
PSQL=${PSQL:-psql}
DB=$(<"$URL_FILE")
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/run.sql" <<SQL
set client_min_messages = warning;
select current_user <> 'postgres' as need_role, pg_has_role(current_user, 'postgres', 'member') as can_role \gset
\if :need_role
  \if :can_role
    set role postgres;
  \endif
\endif
\i '$(realpath supabase/scripts/check_stock_arrivals.sql)'
SQL
out=$("$PSQL" "$DB" -X -q -v ON_ERROR_STOP=1 -f "$TMP/run.sql" 2>&1)
echo "$out"
[[ -n ${GITHUB_STEP_SUMMARY:-} ]] && { echo '```'; echo "$out"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
exit 0
