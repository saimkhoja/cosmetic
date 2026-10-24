#!/usr/bin/env bash
# Restores a SIM backup (a .dump.gpg made by the Backup workflow, or a plain .dump) into a database that has
# SIM's migrations applied but no logins or sales yet: a NEW Supabase project, or a local database.
# It never touches a database that already has logins or invoices, so a live installation cannot be overwritten.
#
#   supabase/scripts/restore_backup.sh <backup.dump.gpg> "<connection string of the new database>"
#
# Needs: gpg, and pg_restore + psql of PostgreSQL 15 or newer (17 recommended).
# See deploy/DEPLOY.md, section 8.
set -euo pipefail
if [ $# -ne 2 ]; then echo "Usage: $0 <backup.dump.gpg> \"<target connection string>\""; exit 2; fi
IN=$1; TARGET=$2
PSQL=${PSQL:-psql}; PG_RESTORE=${PG_RESTORE:-pg_restore}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

if [[ $IN == *.gpg ]]; then
  if [ -n "${BACKUP_PASSPHRASE:-}" ]; then
    gpg --quiet --batch --pinentry-mode loopback --passphrase-fd 0 --decrypt --output "$TMP/backup.dump" "$IN" <<< "$BACKUP_PASSPHRASE"
  else
    echo "Decrypting $IN (enter the backup passphrase)..."
    gpg --quiet --decrypt --output "$TMP/backup.dump" "$IN"
  fi
else
  cp "$IN" "$TMP/backup.dump"
fi
"$PG_RESTORE" --list "$TMP/backup.dump" > "$TMP/list.txt"
grep -q 'TABLE DATA public invoices' "$TMP/list.txt" || { echo "This file is not a SIM backup."; exit 1; }

# the target must have SIM's tables, and nothing in them that matters
if ! users=$("$PSQL" "$TARGET" -tAc "select (select count(*) from auth.users) || '/' || (select count(*) from public.invoices)" 2>/dev/null); then
  echo "The target has no SIM tables. Run all the files in supabase/migrations on it first (deploy/DEPLOY.md, section 1)."; exit 1
fi
if [ "$users" != "0/0" ]; then
  echo "The target already has logins or invoices ($users). Restore only into a new, empty project: nothing was changed."; exit 1
fi
read -r -p "Restore this backup into that database? Type RESTORE to continue: " ok
[ "$ok" = "RESTORE" ] || { echo "Nothing was changed."; exit 1; }

# the migrations seed some rows (settings, ledgers, groups): empty SIM's tables, then load the backup's rows
"$PSQL" "$TARGET" -v ON_ERROR_STOP=1 -q -c "do \$\$ declare t text; begin
  for t in select format('%I.%I', schemaname, tablename) from pg_tables where schemaname = 'public' loop execute 'truncate table ' || t || ' cascade'; end loop;
end \$\$;" 2>/dev/null
# logins first (profiles point at them), then SIM's data, in one session with triggers and foreign-key checks off
# (the rows were consistent when backed up; Supabase lets the postgres role set this inside a session)
{ echo "set session_replication_role = replica;"
  "$PG_RESTORE" --data-only --no-owner --no-privileges --schema=auth --table=users --table=identities -f - "$TMP/backup.dump"
  "$PG_RESTORE" --data-only --no-owner --no-privileges --schema=public -f - "$TMP/backup.dump"
} | "$PSQL" "$TARGET" -v ON_ERROR_STOP=1 -q --single-transaction > /dev/null

"$PSQL" "$TARGET" -c "select (select count(*) from public.products) items, (select count(*) from public.invoices) invoices,
  (select count(*) from public.vouchers) vouchers, (select count(*) from public.profiles) logins, (select max(t)::date from public.invoices) last_sale"
echo "Restored. Point a Vercel preview (or the local app) at this project to look at the data in SIM."
