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
#   checked with supabase/scripts/check_migrations.sql. Every file up to BASELINE_UPTO (the newest file that was ever
#   run by hand) must be in, or the run stops: that client needs a look first. Those files, and the newer ones the
#   check finds already in (one after another, with no gap), are recorded as done without running them again;
#   the files after that run as usual.
# - An empty database gets every file.
# - A file older than the newest one already recorded is refused: migrations re-create functions in their latest
#   form, so running an old file after a newer one would bring back old versions. Give it a newer number.
#
# Settings for the control project and the tests: MIGRATIONS_DIR, BASELINE_CHECK, BASELINE_UPTO, APP_TABLE (a table
# that shows the database was set up, by hand or otherwise).
set -euo pipefail
cd "$(dirname "$0")/.."
URL_FILE=${1:?usage: migrate.sh <db-url-file> plan|apply}; MODE=${2:?usage: migrate.sh <db-url-file> plan|apply}
[[ $MODE == plan || $MODE == apply ]] || { echo "mode must be plan or apply"; exit 2; }
DIR=${MIGRATIONS_DIR:-supabase/migrations}
BASELINE_CHECK=${BASELINE_CHECK:-supabase/scripts/check_migrations.sql}
BASELINE_UPTO=${BASELINE_UPTO:-20261111000012}   # the newest file a database set up by hand must already have
APP_TABLE=${APP_TABLE:-public.settings}
[[ $APP_TABLE =~ ^[a-z_]+\.[a-z_]+$ ]] || { echo "bad APP_TABLE"; exit 2; }
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
  || '|' || (to_regclass('$APP_TABLE') is not null)::text")
has_table=${state%%|*}; has_app=${state##*|}
applied=""
[[ $has_table == true ]] && applied=$(q -f "$TMP/role.sql" -c "select version from supabase_migrations.schema_migrations order by version")
recorded_state=$([[ -n $applied ]] && echo recorded || echo none)

baseline=()
if [[ $recorded_state == none && $has_app == true ]]; then
  # set up by hand: check what is there
  # the check lists each file as done or MISSING, oldest first. Up to BASELINE_UPTO every file must be done; after
  # it, the files done one after another are in too, and the first one missing is where the run starts.
  checked=$(q -F '|' -f "$TMP/role.sql" -f "$BASELINE_CHECK")
  missing=""; upto=$BASELINE_UPTO; gap=""
  while IFS='|' read -r step st; do
    [[ -n $step ]] || continue
    v=${step%%_*}
    if [[ $st == done ]]; then [[ -z $gap && $v > $upto ]] && upto=$v
    else [[ $v > $BASELINE_UPTO ]] && gap=1 || missing+="$step "; fi
  done <<< "$checked"
  [[ -z $missing ]] || fail "this database was set up by hand and is missing: $missing. Run supabase/scripts/check_migrations.sql in its SQL Editor and follow it, then run this again."
  for e in "${files[@]}"; do v=${e%%|*}; [[ $v > $upto ]] || baseline+=("$e"); done
  note "Set up by hand, all ${#baseline[@]} files up to $upto are in: recorded as done."
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
