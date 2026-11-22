#!/usr/bin/env bash
# Tests for ops/migrate.sh with small stand-in migrations, each case on a fresh database.
#   ops/tests/migrate_test.sh "<connection string of a role that can create databases and roles>"
# (supabase/tests/run.sh runs it on its throwaway container; it also runs the real migrations through migrate.sh.)
set -euo pipefail
cd "$(dirname "$0")/../.."
BASE=${1:?usage: migrate_test.sh <admin connection string>}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0
ok() { echo "ok - $*"; pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; exit 1; }
admin() { psql "$BASE" -X -qtA -v ON_ERROR_STOP=1 -c "$1"; }
urlfor() { # a connection string for database $1 (and optionally user/password $2/$3)
  python3 -I - "$BASE" "$1" "${2:-}" "${3:-}" <<'PY'
import sys, urllib.parse as u
b, db, user, pw = sys.argv[1:]
p = u.urlsplit(b)
net = p.netloc
if user:
    host = net.rsplit('@', 1)[-1]
    net = f"{u.quote(user)}:{u.quote(pw)}@{host}"
print(u.urlunsplit((p.scheme, net, '/' + db, p.query, '')))
PY
}
fresh() { admin "drop database if exists $1 with (force)"; admin "create database $1"; urlfor "$1" > "$T/$1.url"; }
inq() { psql "$(<"$T/$1.url")" -X -qtA -v ON_ERROR_STOP=1 -c "$2"; }
run() { MIGRATIONS_DIR=$T/m BASELINE_CHECK=$T/check.sql BASELINE_UPTO=${UPTO:-20260101000002} ops/migrate.sh "$T/$1.url" "$2"; }

mkdir -p "$T/m"
cat > "$T/m/20260101000001_start.sql" <<'SQL'
create table public.settings (id int primary key default 1 check (id = 1), rate numeric not null default 2850);
insert into public.settings default values;
SQL
cat > "$T/m/20260101000002_vat.sql" <<'SQL'
alter table public.settings add column vat numeric not null default 16;
SQL
cat > "$T/m/20260101000003_fn.sql" <<'SQL'
-- a function with 'quotes' and $$dollars$$
create or replace function public.rate_text() returns text language sql as $$ select 'rate ' || rate from public.settings $$;
SQL
cat > "$T/check.sql" <<'SQL'
select step, case when ok then 'done' else 'MISSING' end from (values
  ('20260101000001_start.sql', to_regclass('public.settings') is not null),
  ('20260101000002_vat.sql', exists (select 1 from information_schema.columns where table_name = 'settings' and column_name = 'vat'))
) as m(step, ok);
SQL

# 1. empty database: everything runs, in order, and is recorded
fresh mt_a
out=$(run mt_a plan); grep -q 'Empty database' <<< "$out" && grep -q 'To run (3)' <<< "$out" || bad "plan on an empty database: $out"
[[ $(inq mt_a "select to_regclass('supabase_migrations.schema_migrations') is null") == t ]] || bad "plan must not change anything"
ok "plan on an empty database lists 3 files and changes nothing"
run mt_a apply >/dev/null
[[ $(inq mt_a "select string_agg(version || ':' || name, ',' order by version) from supabase_migrations.schema_migrations") == "20260101000001:start,20260101000002:vat,20260101000003:fn" ]] || bad "records after apply"
[[ $(inq mt_a "select public.rate_text()") == "rate 2850" ]] || bad "function from file 3"
[[ $(inq mt_a "select statements[1] like '%''quotes'' and \$\$dollars\$\$%' from supabase_migrations.schema_migrations where version = '20260101000003'") == t ]] || bad "file text stored"
ok "apply runs all 3, records them with their text"

# 2. nothing left
out=$(run mt_a apply); grep -q 'Up to date: nothing to run' <<< "$out" || bad "second run: $out"
ok "a second run does nothing"

# 3. a new file runs alone
cat > "$T/m/20260101000004_more.sql" <<'SQL'
alter table public.settings add column tz text not null default 'Africa/Kinshasa';
SQL
out=$(run mt_a apply); grep -q 'To run (1)' <<< "$out" && grep -q 'Done: 20260101000004_more.sql' <<< "$out" || bad "new file: $out"
ok "a new file runs on its own"

# 4. an old number after newer ones is refused, before anything runs
echo "create table public.should_not_exist (x int);" > "$T/m/20260101000000_late.sql"
if out=$(run mt_a apply 2>&1); then bad "out of order accepted: $out"; fi
grep -q '20260101000000_late.sql is older than 20260101000004' <<< "$out" || bad "out of order message: $out"
[[ $(inq mt_a "select to_regclass('public.should_not_exist') is null") == t ]] || bad "out-of-order file ran"
rm "$T/m/20260101000000_late.sql"
ok "a file older than one already in is refused"
echo "create table public.should_not_exist (x int);" > "$T/m/20260101000004_twin.sql"
if out=$(run mt_a apply 2>&1); then bad "two files with one number accepted: $out"; fi
grep -q 'two migration files start with 20260101000004' <<< "$out" || bad "duplicate message: $out"
rm "$T/m/20260101000004_twin.sql"
ok "two files with the same number are refused"

# 5. a failing file is rolled back and stops the run; earlier ones stay
cat > "$T/m/20260101000005_good.sql" <<'SQL'
create table public.five (x int);
SQL
cat > "$T/m/20260101000006_bad.sql" <<'SQL'
create table public.six (x int);
select no_such_function();
SQL
cat > "$T/m/20260101000007_after.sql" <<'SQL'
create table public.seven (x int);
SQL
if out=$(run mt_a apply 2>&1); then bad "a failing file passed: $out"; fi
grep -q '20260101000006_bad.sql failed and was rolled back' <<< "$out" || bad "failure message: $out"
[[ $(inq mt_a "select (to_regclass('public.five') is not null)::text || (to_regclass('public.six') is null)::text || (to_regclass('public.seven') is null)::text") == truetruetrue ]] || bad "rollback state"
[[ $(inq mt_a "select count(*) from supabase_migrations.schema_migrations where version in ('20260101000006', '20260101000007')") == 0 ]] || bad "failed file recorded"
ok "a failing file is rolled back, the ones before it stay, nothing after it runs"
rm "$T/m/20260101000005_good.sql" "$T/m/20260101000006_bad.sql" "$T/m/20260101000007_after.sql"

# 6. set up by hand (no records): checked, recorded up to the baseline, the rest runs
fresh mt_b
for f in "$T"/m/20260101000001_start.sql "$T"/m/20260101000002_vat.sql; do psql "$(<"$T/mt_b.url")" -X -q -v ON_ERROR_STOP=1 -f "$f"; done
out=$(run mt_b apply); grep -q 'Set up by hand, all 2 files up to 20260101000002 are in' <<< "$out" && grep -q 'To run (2)' <<< "$out" || bad "baseline: $out"
[[ $(inq mt_b "select string_agg(version || ':' || coalesce(array_length(statements, 1), 0), ',' order by version) from supabase_migrations.schema_migrations") == "20260101000001:0,20260101000002:0,20260101000003:1,20260101000004:1" ]] || bad "baseline records"
[[ $(inq mt_b "select vat from public.settings") == 16 ]] || bad "baseline must not re-run files"
ok "a database set up by hand is recorded as it is, then only the newer files run"

# 6b. set up by hand before a newer file the check knows about: that file is not "missing", it runs
cat > "$T/check3.sql" <<'SQL'
select step, case when ok then 'done' else 'MISSING' end from (values
  ('20260101000001_start.sql', to_regclass('public.settings') is not null),
  ('20260101000002_vat.sql', exists (select 1 from information_schema.columns where table_name = 'settings' and column_name = 'vat')),
  ('20260101000003_fn.sql', exists (select 1 from pg_proc where proname = 'rate_text'))
) as m(step, ok);
SQL
run3() { MIGRATIONS_DIR=$T/m BASELINE_CHECK=$T/check3.sql BASELINE_UPTO=20260101000002 ops/migrate.sh "$T/$1.url" "$2"; }
fresh mt_e
for f in "$T"/m/20260101000001_start.sql "$T"/m/20260101000002_vat.sql; do psql "$(<"$T/mt_e.url")" -X -q -v ON_ERROR_STOP=1 -f "$f"; done
out=$(run3 mt_e apply); grep -q 'Set up by hand, all 2 files up to 20260101000002 are in' <<< "$out" && grep -q 'To run (2)' <<< "$out" && grep -q 'Done: 20260101000003_fn.sql' <<< "$out" || bad "baseline before a newer file: $out"
[[ $(inq mt_e "select public.rate_text()") == "rate 2850" ]] || bad "the newer file should have run"
ok "a database set up by hand before a newer file gets that file run"
# 6c. and one that already has it by hand: it is recorded as done, not run again
fresh mt_f
for f in "$T"/m/20260101000001_start.sql "$T"/m/20260101000002_vat.sql "$T"/m/20260101000003_fn.sql; do psql "$(<"$T/mt_f.url")" -X -q -v ON_ERROR_STOP=1 -f "$f"; done
out=$(run3 mt_f apply); grep -q 'Set up by hand, all 3 files up to 20260101000003 are in' <<< "$out" && grep -q 'To run (1)' <<< "$out" || bad "baseline past the limit: $out"
ok "a database set up by hand with a newer file already in records it without running it again"

# 7. set up by hand with a file missing: stops without changing anything
fresh mt_c
psql "$(<"$T/mt_c.url")" -X -q -v ON_ERROR_STOP=1 -f "$T/m/20260101000001_start.sql"
if out=$(run mt_c apply 2>&1); then bad "missing file accepted: $out"; fi
grep -q 'missing: 20260101000002_vat.sql' <<< "$out" || bad "missing message: $out"
[[ $(inq mt_c "select to_regclass('supabase_migrations.schema_migrations') is null") == t ]] || bad "stopped run changed something"
ok "a database set up by hand with a file missing is left alone, with the file named"

# 8. a login that may act as postgres (like the Management API's temporary one): objects end up owned by postgres
admin "drop role if exists mt_cli_login; drop role if exists mt_stranger"
admin "create role mt_cli_login login password 'pw-cli-1' in role postgres; create role mt_stranger login password 'pw-str-1'"
fresh mt_d
admin "grant all on database mt_d to mt_cli_login, mt_stranger"
urlfor mt_d mt_cli_login pw-cli-1 > "$T/mt_d_cli.url"
MIGRATIONS_DIR=$T/m BASELINE_CHECK=$T/check.sql BASELINE_UPTO=20260101000002 ops/migrate.sh "$T/mt_d_cli.url" apply >/dev/null
[[ $(inq mt_d "select tableowner from pg_tables where tablename = 'settings'") == postgres ]] || bad "owner should be postgres"
ok "a temporary login acts as postgres, so postgres owns what it makes"
urlfor mt_d mt_stranger pw-str-1 > "$T/mt_d_str.url"
echo "create table public.stranger (x int);" > "$T/m/20260101000008_s.sql"
if out=$(MIGRATIONS_DIR=$T/m BASELINE_CHECK=$T/check.sql ops/migrate.sh "$T/mt_d_str.url" apply 2>&1); then bad "a login that is not postgres changed the database: $out"; fi
[[ $(inq mt_d "select to_regclass('public.stranger') is null") == t ]] || bad "stranger made a table"
ok "a login that cannot act as postgres is refused"

for d in mt_a mt_b mt_c mt_d; do admin "drop database if exists $d with (force)"; done
admin "drop role if exists mt_cli_login; drop role if exists mt_stranger"
echo "migrate.sh: all $pass tests passed"
