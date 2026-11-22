#!/usr/bin/env bash
# Brings one client's database up to date with supabase/migrations. Used by .github/workflows/migrate.yml and the tests.
#
#   ops/migrate.sh <db-url-file> plan     lists what would be done; changes nothing
#   ops/migrate.sh <db-url-file> apply    does it
#
# The connection string is read from a file so it never shows in the process list or the logs.
# Applied files are recorded in supabase_migrations.schema_migrations (version = the file's leading number), the
# same table the Supabase CLI and the dashboard (Database → Migrations) use.
#
# - Each file runs in its own transaction with its record: a file that fails leaves no trace and stops the run.
# - A database that has never been recorded but already has QuickSales (set up by hand in the SQL Editor) is
#   checked with supabase/scripts/check_migrations.sql: if every file up to BASELINE_UPTO is in, they are recorded as
#   done without running them again. If one is missing the run stops: that client needs a look first.
# - An empty database gets every file.
# - A file older than the newest one already recorded is refused: migrations re-create functions in their latest
#   form, so running an old file after a newer one would bring back old versions. Give it a newer number.
#
# Settings for the tests: MIGRATIONS_DIR, BASELINE_CHECK, BASELINE_UPTO.
set -euo pipefail
cd "$(dirname "$0")/.."
URL_FILE=${1:?usage: migrate.sh <db-url-file> plan|apply}; MODE=${2:?usage: migrate.sh <db-url-file> plan|apply}
[[ $MODE == plan || $MODE == apply ]] || { echo "mode must be plan or apply"; exit 2; }
DIR=${MIGRATIONS_DIR:-supabase/migrations}
BASELINE_CHECK=${BASELINE_CHECK:-supabase/scripts/check_migrations.sql}
BASELINE_UPTO=${BASELINE_UPTO:-20261111000012}   # the newest file check_migrations.sql knows about
PSQL=${PSQL:-psql}
DB=$(<"$URL_FILE")
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
GH=${GITHUB_ACTIONS:-}
note() { echo "$*"; [[ -n ${GITHUB_STEP_SUMMARY:-} ]] && echo "$*" >> "$GITHUB_STEP_SUMMARY" || true; }
fail() { [[ -n $GH ]] && echo "::error::$*" || echo "ERROR: $*" >&2; [[ -n ${GITHUB_STEP_SUMMARY:-} ]] && echo "**Stopped:** $*" >> "$GITHUB_STEP_SUMMARY"; exit 1; }
q() { "$PSQL" "$DB" -X -v ON_ERROR_STOP=1 -qtA "$@"; }

# Every session acts as postgres, the owner of everything QuickSales made in the SQL Editor. A temporary login from
# the Management API is allowed to; a plain postgres connection already is postgres.
cat > "$TMP/role.sql" <<'SQL'
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

# files: version|name|path, oldest first
files=()
for f in "$DIR"/*.sql; do
  b=$(basename "$f" .sql); v=${b%%_*}; n=${b#*_}
  [[ $v =~ ^[0-9]{14}$ ]] || fail "$f: a migration file must start with 14 digits and an underscore"
  files+=("$v|$n|$f")
done
IFS=$'\n' files=($(printf '%s\n' "${files[@]}" | sort)); unset IFS
dup=$(printf '%s\n' "${files[@]}" | cut -d'|' -f1 | uniq -d | head -1)
[[ -z $dup ]] || fail "two migration files start with $dup; each needs its own number"

state=$(q -f "$TMP/role.sql" -c "select (to_regclass('supabase_migrations.schema_migrations') is not null)::text
  || '|' || (to_regclass('public.settings') is not null)::text")
has_table=${state%%|*}; has_app=${state##*|}
applied=""
[[ $has_table == true ]] && applied=$(q -f "$TMP/role.sql" -c "select version from supabase_migrations.schema_migrations order by version")
recorded_state=$([[ -n $applied ]] && echo recorded || echo none)

baseline=()
if [[ $recorded_state == none && $has_app == true ]]; then
  # set up by hand: check what is there
  missing=$(q -F '|' -f "$TMP/role.sql" -f "$BASELINE_CHECK" | awk -F'|' '$2 != "done" {print $1}')
  [[ -z $missing ]] || fail "this database was set up by hand and is missing: $(echo $missing | tr '\n' ' '). Run supabase/scripts/check_migrations.sql in its SQL Editor and follow it, then run this again."
  for e in "${files[@]}"; do v=${e%%|*}; [[ $v > $BASELINE_UPTO ]] || baseline+=("$e"); done
  note "Set up by hand, all ${#baseline[@]} files up to $BASELINE_UPTO are in: recorded as done."
elif [[ $recorded_state == none ]]; then
  note "Empty database: every file will run."
fi

# what is left to run
newest=""
for e in "${files[@]}"; do v=${e%%|*}; if grep -qx "$v" <<< "$applied"; then newest=$v; fi; done
for e in "${baseline[@]}"; do newest=${e%%|*}; done
pending=()
for e in "${files[@]}"; do
  v=${e%%|*}
  grep -qx "$v" <<< "$applied" && continue
  printf '%s\n' "${baseline[@]}" | grep -q "^$v|" && continue
  [[ -z $newest || $v > $newest ]] || fail "$(basename "${e##*|}") is older than $newest, which is already in. Rename it with a newer number."
  pending+=("$e")
done

if ((${#pending[@]} == 0)); then note "Up to date: nothing to run."; else
  note "To run (${#pending[@]}):"; for e in "${pending[@]}"; do note "- $(basename "${e##*|}")"; done
fi
[[ -n ${GITHUB_OUTPUT:-} ]] && echo "pending=${#pending[@]}" >> "$GITHUB_OUTPUT"
[[ $MODE == plan ]] && exit 0

record() { # version name file-to-store-or-empty
  printf "insert into supabase_migrations.schema_migrations (version, name, statements) values (%s, %s, %s) on conflict (version) do nothing;\n" \
    "'$1'" "'$2'" "$([[ -n $3 ]] && echo "array[:'body']" || echo null)"
}
{ cat "$TMP/role.sql"
  echo "create schema if not exists supabase_migrations;"
  echo "create table if not exists supabase_migrations.schema_migrations (version text not null primary key);"
  echo "alter table supabase_migrations.schema_migrations add column if not exists statements text[];"
  echo "alter table supabase_migrations.schema_migrations add column if not exists name text;"
  for e in "${baseline[@]}"; do IFS='|' read -r v n _ <<< "$e"; record "$v" "$n" ""; done
} > "$TMP/start.sql"
"$PSQL" "$DB" -X -v ON_ERROR_STOP=1 -q --single-transaction -f "$TMP/start.sql" >/dev/null

for e in "${pending[@]}"; do
  IFS='|' read -r v n f <<< "$e"
  abs=$(realpath "$f")
  { cat "$TMP/role.sql"; echo "\\set body \`cat '$abs'\`"; echo "\\i '$abs'"; record "$v" "$n" yes; } > "$TMP/run.sql"
  if ! out=$("$PSQL" "$DB" -X -v ON_ERROR_STOP=1 -q --single-transaction -f "$TMP/run.sql" 2>&1); then
    echo "$out" | grep -v '^NOTICE' | tail -20 >&2
    fail "$(basename "$f") failed and was rolled back; the files before it are in. Nothing after it was run."
  fi
  note "Done: $(basename "$f")"
done
note "Up to date."
