#!/usr/bin/env bash
# Scheduled logical backup of the master database and every tenant database, run by the `db-backup` service.
#
# One gzip file per run, `sprintmodus-<UTC timestamp>.sql.gz`, written as `.partial` and renamed only once it has been verified
# (a crash or a full disk can never leave a half file that looks like a backup). Files older than BACKUP_KEEP_DAYS are deleted.
# Only master_db and tenant_* are dumped, never MySQL's own schemas, so restoring can never touch the root account.
#
# Environment: MYSQL_ROOT_PASSWORD (required), MYSQL_HOST (master-db), BACKUP_DIR (/backups), BACKUP_INTERVAL_HOURS (24),
# BACKUP_KEEP_DAYS (14). `backup.sh once` takes one backup and exits.
#
# This protects against a lost or damaged volume and against mistakes. It is NOT an off-site copy: a backup on the same disk dies
# with the disk, so copy BACKUP_DIR somewhere else too (see README, "Backups").
set -uo pipefail

HOST="${MYSQL_HOST:-master-db}"
DIR="${BACKUP_DIR:-/backups}"
INTERVAL_HOURS="${BACKUP_INTERVAL_HOURS:-24}"
KEEP_DAYS="${BACKUP_KEEP_DAYS:-14}"
export MYSQL_PWD="${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD is required}"

backup_once() {
  local stamp file tmp databases count
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  file="$DIR/sprintmodus-$stamp.sql.gz"
  tmp="$file.partial"

  databases="$(mysql -h "$HOST" -uroot -N -B -e \
    "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = 'master_db' OR SCHEMA_NAME LIKE 'tenant\_%' ORDER BY SCHEMA_NAME")" || return 1
  [ -n "$databases" ] || { echo "no database to back up (is master_db there?)" >&2; return 1; }
  count="$(wc -l <<<"$databases")"

  # Only master_db and no tenant: either a brand-new install, or (if backups already exist) a database that lost its data. In the
  # second case do NOT write an empty backup: it would become "the newest" and, after KEEP_DAYS, push the good ones out.
  if [ "$count" -le 1 ] && compgen -G "$DIR/sprintmodus-*.sql.gz" >/dev/null; then
    echo "REFUSED: the database has no tenant but earlier backups exist; not replacing them with an empty backup." >&2
    echo "         If data was lost, restore it (scripts/restore.sh --list); if it was emptied on purpose, delete the old backups." >&2
    return 1
  fi

  # --single-transaction: a consistent snapshot per database without locking the running application
  # shellcheck disable=SC2086
  mysqldump -h "$HOST" -uroot --single-transaction --routines --triggers --events --set-gtid-purged=OFF \
    --databases $databases | gzip -9 > "$tmp"
  local status=("${PIPESTATUS[@]}")
  if [ "${status[0]}" -ne 0 ] || [ "${status[1]}" -ne 0 ]; then
    rm -f "$tmp"; echo "mysqldump/gzip failed (${status[*]})" >&2; return 1
  fi
  gzip -t "$tmp" || { rm -f "$tmp"; echo "the backup file is not a valid gzip" >&2; return 1; }
  mv "$tmp" "$file" || return 1

  find "$DIR" -name 'sprintmodus-*.sql.gz' -mtime +"$KEEP_DAYS" -delete
  find "$DIR" -name '*.partial' -mmin +120 -delete
  echo "backup ok: $file ($(stat -c %s "$file") bytes, $count databases, keeping $KEEP_DAYS days)"
}

if [ "${1:-}" = "once" ]; then
  backup_once
  exit $?
fi

trap 'exit 0' TERM INT
mkdir -p "$DIR"
while true; do
  backup_once || echo "BACKUP FAILED at $(date -u +%FT%TZ); will retry in ${INTERVAL_HOURS}h" >&2
  sleep "$((INTERVAL_HOURS * 3600))" &
  wait $!
done
