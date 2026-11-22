#!/usr/bin/env bash
# Runs the SQL tests on a throwaway Supabase Postgres container.
# Needs Docker. Usage: supabase/tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
IMG=${SIM_PG_IMAGE:-supabase/postgres:15.8.1.060}
NAME=sim-test-db
PORT=${SIM_PG_PORT:-54329}
docker rm -f $NAME >/dev/null 2>&1 || true
docker run -d --name $NAME -e POSTGRES_PASSWORD=postgres -p $PORT:5432 $IMG >/dev/null
trap 'docker rm -f $NAME >/dev/null 2>&1 || true' EXIT
export PGPASSWORD=postgres
for i in $(seq 1 60); do psql -h 127.0.0.1 -p $PORT -U postgres -tAc 'select 1' >/dev/null 2>&1 && break; sleep 2; done
sleep 3
URL_FILE=$(mktemp); trap 'rm -f "$URL_FILE"; docker rm -f $NAME >/dev/null 2>&1 || true' EXIT
printf 'postgresql://postgres:postgres@127.0.0.1:%s/postgres' "$PORT" > "$URL_FILE"
# the migrations go in the way they go into every client's database: through ops/migrate.sh
ops/migrate.sh "$URL_FILE" apply | tail -1
set +e
psql -h 127.0.0.1 -p $PORT -U postgres -v ON_ERROR_STOP=1 -q -f supabase/tests/sim_test.sql 2>&1 | sed -e 's/^psql:[^:]*:[0-9]*: //' -e '/^$/d'
rc=${PIPESTATUS[0]}
set -e
[ "$rc" = 0 ] || exit "$rc"
# a database set up by hand (no record of what ran) is recognised as complete, and nothing runs again
psql -h 127.0.0.1 -p $PORT -U postgres -qc 'drop schema supabase_migrations cascade' 2>/dev/null
out=$(ops/migrate.sh "$URL_FILE" plan)
echo "$out" | grep -q 'Set up by hand, all' && echo "$out" | grep -q 'Up to date: nothing to run' || { echo "FAIL: baseline: $out"; exit 1; }
echo "ok - a database set up by hand is recognised as up to date"
# the runner itself
ops/tests/migrate_test.sh "$(cat "$URL_FILE")" 2>&1 | grep -v NOTICE
