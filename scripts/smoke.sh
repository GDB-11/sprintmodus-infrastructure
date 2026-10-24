#!/usr/bin/env bash
# End-to-end smoke test of a running stack, through the same address a browser uses:
# register an organization, log in, create a project and a work item, read it back.
#
#   scripts/smoke.sh                       # brings the stack up (docker compose up -d --wait) first, leaves it running
#   COMPOSE_PROJECT_NAME=sprintmodus-smoke scripts/smoke.sh --down   # ...and tears it down WITH its volumes afterwards
#                                          (refused on the default project: that would delete the real database)
#   BASE_URL=http://localhost:8080 scripts/smoke.sh --no-up     # test a stack that is already running
#   BASE_URL=https://localhost:18443 SMOKE_CURL_OPTS=-k scripts/smoke.sh --no-up   # behind Caddy with its local (self-signed) certificate
#
# The organization it registers is test data; --down removes the volume with it.
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:${FRONTEND_PORT:-8080}}"
UP=1
DOWN=0
for arg in "$@"; do
  case "$arg" in
    --no-up) UP=0 ;;
    --down) DOWN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/.."

# --down runs `docker compose down --volumes`, which DELETES THE DATABASE VOLUME. On the default project ("sprintmodus") that is
# the real stack, so it is refused: run the smoke test under its own project name (and ports, see .env.example) instead:
#   COMPOSE_PROJECT_NAME=sprintmodus-smoke FRONTEND_PORT=18080 GATEWAY_PORT=18090 scripts/smoke.sh --down
if [ "$DOWN" = 1 ] && [ "${COMPOSE_PROJECT_NAME:-sprintmodus}" = sprintmodus ]; then
  echo "refusing --down on the default project: it would delete the database volume of the real stack." >&2
  echo "set COMPOSE_PROJECT_NAME to something else (e.g. sprintmodus-smoke) to test on a disposable copy." >&2
  exit 2
fi

cleanup() { [ "$DOWN" = 1 ] && docker compose down --volumes --remove-orphans; return 0; }
trap cleanup EXIT

# A browser sends Origin on every POST and on the WebSocket handshake; without it CORS is never exercised
origin=(-H "Origin: $BASE_URL")

json() { python3 -c "import json,sys; print(json.load(sys.stdin)$1)"; }
step() { printf '\n== %s\n' "$*"; }

[ "$UP" = 1 ] && { step "up"; docker compose up -d --wait --wait-timeout 300; }

suffix="$(date +%s)$RANDOM"
code="smoke-$suffix"
email="owner-$suffix@example.com"
password="correct-horse-battery"

# The gateway needs a moment after it is healthy before Eureka has told it where the services are
step "register organization $code"
for attempt in $(seq 1 30); do
  status=$(curl ${SMOKE_CURL_OPTS:-} -s -o /tmp/smoke-register.json -w '%{http_code}' -X POST "$BASE_URL/auth/register-organization" \
    "${origin[@]}" -H 'Content-Type: application/json' \
    -d "{\"organizationName\":\"Smoke $suffix\",\"organizationCode\":\"$code\",\"fullName\":\"Smoke Owner\",\"email\":\"$email\",\"password\":\"$password\"}")
  [ "$status" = 201 ] && break
  echo "  attempt $attempt: HTTP $status, retrying"; sleep 5
done
[ "$status" = 201 ] || { echo "registration failed: HTTP $status"; cat /tmp/smoke-register.json; exit 1; }

step "log in"
token=$(curl ${SMOKE_CURL_OPTS:-} -sf -X POST "$BASE_URL/auth/login" "${origin[@]}" -H 'Content-Type: application/json' \
  -d "{\"organizationCode\":\"$code\",\"email\":\"$email\",\"password\":\"$password\"}" | json "['token']")
[ -n "$token" ] || { echo "no token"; exit 1; }
auth=(-H "Authorization: Bearer $token")

step "create a project"
project=$(curl ${SMOKE_CURL_OPTS:-} -sf -X POST "$BASE_URL/api/projects" "${auth[@]}" "${origin[@]}" -H 'Content-Type: application/json' \
  -d '{"name":"Smoke project","description":"created by scripts/smoke.sh","key":"SMK"}' | json "['projectCode']")

step "create a work item"
item=$(curl ${SMOKE_CURL_OPTS:-} -sf -X POST "$BASE_URL/api/work-items" "${auth[@]}" "${origin[@]}" -H 'Content-Type: application/json' \
  -d "{\"projectCode\":\"$project\",\"type\":\"PBI\",\"title\":\"Smoke test item\"}" | json "['workItemCode']")

step "read it back"
title=$(curl ${SMOKE_CURL_OPTS:-} -sf "$BASE_URL/api/work-items/$item" "${auth[@]}" | json "['title']")
[ "$title" = "Smoke test item" ] || { echo "unexpected title: $title"; exit 1; }

step "the app is served"
curl ${SMOKE_CURL_OPTS:-} -sf "$BASE_URL/" | grep -qi "<app-root" || { echo "the frontend page is not served"; exit 1; }

echo; echo "SMOKE OK: organization $code, project $project, work item $item"
