#!/usr/bin/env bash
# Dumps one client's database, checks the dump, encrypts it and uploads it to the backup bucket.
# Used by .github/workflows/backup.yml (every night) and migrate.yml (just before a database update).
#
#   ops/backup.sh <db-url-file> <folder> [label]
#
# Saved as <folder>/daily/<folder>-YYYY-MM-DD-HHMM[-label].dump.gpg; on the 1st of the month the nightly one
# (no label) also goes to <folder>/monthly/, which is kept. An R2 lifecycle rule deletes daily/ after 30 days.
# Needs: pg_dump/pg_restore 17 (PG_DUMP, PG_RESTORE), gpg, the aws CLI, and BACKUP_PASSPHRASE, AWS_ACCESS_KEY_ID,
# AWS_SECRET_ACCESS_KEY, R2_ENDPOINT, R2_BUCKET. The format is the one supabase/scripts/restore_backup.sh reads.
set -euo pipefail
URL_FILE=${1:?usage: backup.sh <db-url-file> <folder> [label]}; FOLDER=${2:?folder}; LABEL=${3:-}
[[ $FOLDER =~ ^[a-z0-9-]{2,40}$ ]] || { echo "bad folder name: $FOLDER"; exit 2; }
[[ -z $LABEL || $LABEL =~ ^[a-z0-9-]{1,40}$ ]] || { echo "bad label: $LABEL"; exit 2; }
PG_DUMP=${PG_DUMP:-pg_dump}; PG_RESTORE=${PG_RESTORE:-pg_restore}; PSQL=${PSQL:-psql}
missing=""
for v in BACKUP_PASSPHRASE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET; do [[ -n ${!v:-} ]] || missing="$missing $v"; done
[[ -z $missing ]] || { echo "::error::Not set:$missing (GitHub → Settings → Secrets and variables → Actions)"; exit 1; }
DB=$(<"$URL_FILE")
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# a temporary login from the Management API dumps as postgres, like a postgres connection does
role=()
[[ $("$PSQL" "$DB" -XqtAc "select current_user <> 'postgres' and pg_has_role(current_user, 'postgres', 'member')") == t ]] && role=(--role=postgres)

FILE="$FOLDER-$(date -u +%Y-%m-%d-%H%M)${LABEL:+-$LABEL}.dump"
"$PG_DUMP" "$DB" "${role[@]}" --format=custom --no-owner --no-privileges \
  --schema=public --schema=app --schema=auth --file="$TMP/$FILE"
# a usable backup: readable, and it has the invoices and the logins
"$PG_RESTORE" --list "$TMP/$FILE" > "$TMP/list.txt"
grep -q 'TABLE DATA public invoices' "$TMP/list.txt" && grep -q 'TABLE DATA auth users' "$TMP/list.txt" \
  || { echo "::error::$FOLDER: the dump has no invoices or no logins table"; exit 1; }
echo "Dump: $(du -h "$TMP/$FILE" | cut -f1), $(grep -c 'TABLE DATA' "$TMP/list.txt") tables"

gpg --batch --yes --symmetric --cipher-algo AES256 --pinentry-mode loopback --passphrase-fd 0 \
  --output "$TMP/$FILE.gpg" "$TMP/$FILE" <<< "$BACKUP_PASSPHRASE"
aws s3 cp "$TMP/$FILE.gpg" "s3://$R2_BUCKET/$FOLDER/daily/$FILE.gpg" --endpoint-url "$R2_ENDPOINT" --only-show-errors
if [[ -z $LABEL && $(date -u +%d) == 01 ]]; then
  aws s3 cp "$TMP/$FILE.gpg" "s3://$R2_BUCKET/$FOLDER/monthly/$FILE.gpg" --endpoint-url "$R2_ENDPOINT" --only-show-errors
fi
echo "### $FOLDER backup saved: \`$FOLDER/daily/$FILE.gpg\`" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
echo "Saved $FOLDER/daily/$FILE.gpg"
