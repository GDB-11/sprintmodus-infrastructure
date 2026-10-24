#!/usr/bin/env bash
# Restores a backup taken by the db-backup service (or any gzip'd dump of master_db and tenant_* databases).
#
#   scripts/restore.sh --list                       list the backups the db-backup service holds
#   scripts/restore.sh latest --yes                 restore the newest one
#   scripts/restore.sh sprintmodus-20260925T031500Z.sql.gz --yes
#   scripts/restore.sh /path/to/dump.sql.gz --yes   a file on this machine (e.g. copied back from off-site)
#
# DESTRUCTIVE: every table of master_db and of the tenants in the file is replaced by the backup's version, so anything written
# since the backup is lost. Tenants that are NOT in the file are left alone. The application is stopped while it runs and started
# again afterwards (which also runs the migrator, so an older backup is brought up to the current schema).
# Keep the SAME .env (JWT_SECRET, TENANT_CREDENTIALS_KEY/SALT): the encrypted tenant credentials in the dump need them.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_SERVICES=(frontend api-gateway auth-service project-service workitem-service eureka-server)

if [ "${1:-}" = "--list" ]; then
  docker compose exec -T db-backup sh -c 'ls -lht /backups/sprintmodus-*.sql.gz 2>/dev/null || echo "no backups yet"'
  exit 0
fi

source_arg="${1:?usage: restore.sh <latest|backup name|file> --yes   (or --list)}"
[ "${2:-}" = "--yes" ] || { echo "This replaces the data in the database with the backup. Run again with --yes to confirm." >&2; exit 2; }

read_backup() {
  if [ -f "$source_arg" ]; then
    cat "$source_arg"
  elif [ "$source_arg" = latest ]; then
    docker compose exec -T db-backup sh -c 'cat "$(ls -1t /backups/sprintmodus-*.sql.gz | head -1)"'
  else
    docker compose exec -T db-backup cat "/backups/$(basename "$source_arg")"
  fi
}

echo "stopping the application (the database stays up)"
docker compose stop "${APP_SERVICES[@]}" >/dev/null
docker compose up -d --wait master-db >/dev/null

if [ "$source_arg" = latest ]; then
  echo "restoring the newest backup: $(docker compose exec -T db-backup sh -c 'f="$(ls -1t /backups/sprintmodus-*.sql.gz | head -1)"; echo "$(basename "$f") ($(stat -c %s "$f") bytes)"' | tr -d '\r')"
  echo "(a file of only a few hundred bytes is an EMPTY backup: cancel and pick a real one from --list)"
else
  echo "restoring $source_arg"
fi
read_backup | gunzip | docker compose exec -T master-db sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"'

echo "starting the application"
docker compose up -d --wait
echo "restore done"
