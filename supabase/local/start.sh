#!/usr/bin/env bash
# Local Supabase-compatible stack for development and end-to-end tests:
# Postgres (supabase/postgres), Auth (GoTrue), REST (PostgREST), the Edge Functions (Deno) and a gateway.
# API at http://127.0.0.1:54321, keys in supabase/local/.env.local. Stop with supabase/local/stop.sh
set -euo pipefail
cd "$(dirname "$0")"
LOG=${SIM_LOG_DIR:-/tmp}
eval "$(node keys.mjs)"
PG=postgres://postgres:postgres@127.0.0.1:54322/postgres
docker network create sim-local >/dev/null 2>&1 || true
docker rm -f sim-db sim-auth sim-rest >/dev/null 2>&1 || true
docker run -d --name sim-db --network sim-local -e POSTGRES_PASSWORD=postgres -p 54322:5432 supabase/postgres:15.8.1.060 >/dev/null
for i in $(seq 1 60); do psql "$PG" -tAc 'select 1' >/dev/null 2>&1 && break; sleep 2; done; sleep 3
psql "postgres://supabase_admin:postgres@127.0.0.1:54322/postgres" -q -c "alter role supabase_auth_admin with password 'postgres'; alter role authenticator with password 'postgres';"
docker run -d --name sim-auth --network sim-local -p 9999:9999 \
  -e GOTRUE_API_HOST=0.0.0.0 -e PORT=9999 -e API_EXTERNAL_URL=http://127.0.0.1:54321/auth/v1 \
  -e GOTRUE_DB_DRIVER=postgres -e DATABASE_URL="postgres://supabase_auth_admin:postgres@sim-db:5432/postgres" \
  -e GOTRUE_SITE_URL=http://localhost:5173 -e GOTRUE_JWT_SECRET="$JWT_SECRET" -e GOTRUE_JWT_EXP=3600 \
  -e GOTRUE_JWT_AUD=authenticated -e GOTRUE_JWT_DEFAULT_GROUP_NAME=authenticated -e GOTRUE_JWT_ADMIN_ROLES=service_role \
  -e GOTRUE_DISABLE_SIGNUP=true -e GOTRUE_EXTERNAL_EMAIL_ENABLED=true -e GOTRUE_MAILER_AUTOCONFIRM=true \
  -e GOTRUE_PASSWORD_MIN_LENGTH=10 -e GOTRUE_RATE_LIMIT_VERIFY=1000 -e GOTRUE_RATE_LIMIT_TOKEN_REFRESH=1000 \
  supabase/gotrue:v2.177.0 >/dev/null
for i in $(seq 1 60); do curl -sf http://127.0.0.1:9999/health >/dev/null && break; sleep 1; done
for f in ../migrations/*.sql; do psql "$PG" -v ON_ERROR_STOP=1 -q -f "$f"; done
docker run -d --name sim-rest --network sim-local -p 3000:3000 \
  -e PGRST_DB_URI="postgres://authenticator:postgres@sim-db:5432/postgres" -e PGRST_DB_SCHEMAS=public,graphql_public \
  -e PGRST_DB_ANON_ROLE=anon -e PGRST_JWT_SECRET="$JWT_SECRET" -e PGRST_DB_USE_LEGACY_GUCS=false \
  postgrest/postgrest:v12.2.12 >/dev/null
export SUPABASE_URL=http://127.0.0.1:54321 SUPABASE_SERVICE_ROLE_KEY="$SERVICE_ROLE_KEY" SUPABASE_ANON_KEY="$ANON_KEY"
pkill -f 'supabase/local/fnrun.ts' 2>/dev/null || true; pkill -f 'node gateway.mjs' 2>/dev/null || true
nohup deno run -A --quiet "$PWD/fnrun.ts" setup 8101 > "$LOG/sim-fn-setup.log" 2>&1 &
nohup deno run -A --quiet "$PWD/fnrun.ts" admin-users 8102 > "$LOG/sim-fn-admin.log" 2>&1 &
nohup node gateway.mjs > "$LOG/sim-gateway.log" 2>&1 &
for i in $(seq 1 30); do curl -sf http://127.0.0.1:3000/ -H "apikey: $ANON_KEY" >/dev/null 2>&1 && break; sleep 1; done
sleep 2
echo "SIM local stack ready: SUPABASE_URL=http://127.0.0.1:54321"
echo "ANON_KEY=$ANON_KEY"
