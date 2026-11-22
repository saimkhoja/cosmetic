#!/usr/bin/env bash
# Installs the PostgreSQL 17 client tools (psql, pg_dump, pg_restore) on a GitHub runner, if they are not there yet.
# pg_dump must be at least as new as the database: Supabase runs 15 and 17.
set -euo pipefail
[[ -x /usr/lib/postgresql/17/bin/pg_dump ]] && exit 0
sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list >/dev/null
sudo apt-get update -qq && sudo apt-get install -y -qq postgresql-client-17
