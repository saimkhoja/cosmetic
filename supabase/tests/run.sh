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
for f in supabase/migrations/*.sql; do psql -h 127.0.0.1 -p $PORT -U postgres -v ON_ERROR_STOP=1 -q -f "$f"; done
psql -h 127.0.0.1 -p $PORT -U postgres -v ON_ERROR_STOP=1 -q -f supabase/tests/sim_test.sql 2>&1 | sed -e 's/^psql:[^:]*:[0-9]*: //' -e '/^$/d'
exit ${PIPESTATUS[0]}
