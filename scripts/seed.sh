#!/usr/bin/env bash
# Creates a demo organization with demo data through the real API, so there is something to click on in the browser.
# The UI cannot create a project yet, so a brand-new organization has nothing to work with until one exists.
#
#   scripts/seed.sh                          # against http://localhost:8080 (the local stack)
#   BASE_URL=http://localhost:9090 scripts/seed.sh
#
# Login afterwards: organization "demo", email demo@example.com, password demo-password-123 (override with SEED_ORG, SEED_EMAIL,
# SEED_PASSWORD). Safe to run again: if the demo project already exists it only prints the login and exits. LOCAL TESTING ONLY:
# the password is public, never run it against a real deployment.
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
ORG="${SEED_ORG:-demo}"
EMAIL="${SEED_EMAIL:-demo@example.com}"
PASSWORD="${SEED_PASSWORD:-demo-password-123}"
CURL_OPTS="${SMOKE_CURL_OPTS:-}"

step() { printf '  - %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); v=d$1; print('' if v is None else v)" 2>/dev/null || true; }

# call METHOD PATH [BODY] -> prints the body, fails on HTTP >= 400 (a browser-like Origin is sent so CORS is exercised too)
call() {
  local method="$1" path="$2" body="${3:-}" out status
  out="$(mktemp)"
  local args=(-s $CURL_OPTS -o "$out" -w '%{http_code}' -X "$method" "$BASE_URL$path" -H "Origin: $BASE_URL")
  [ -z "${TOKEN:-}" ] || args+=(-H "Authorization: Bearer $TOKEN")
  [ -z "$body" ] || args+=(-H 'Content-Type: application/json' -d "$body")
  # Right after a start the services have not discovered each other yet (Eureka takes up to a minute): 502/503 means "not yet"
  local attempt
  for attempt in $(seq 1 15); do
    status="$(curl "${args[@]}")"
    case "$status" in 502|503|000) sleep 5 ;; *) break ;; esac
  done
  if [ "$status" -ge 400 ]; then echo "HTTP $status for $method $path: $(cat "$out")" >&2; rm -f "$out"; return 1; fi
  cat "$out"; rm -f "$out"
}

echo "Seeding $BASE_URL"
TOKEN=""

# The stack answers 503 for a few seconds after it is healthy, until Eureka has told the gateway where the services are
echo "register organization '$ORG'"
for attempt in $(seq 1 30); do
  code="$(curl -s $CURL_OPTS -o /tmp/seed-register.json -w '%{http_code}' -X POST "$BASE_URL/auth/register-organization" \
    -H "Origin: $BASE_URL" -H 'Content-Type: application/json' \
    -d "{\"organizationName\":\"Demo\",\"organizationCode\":\"$ORG\",\"fullName\":\"Demo Owner\",\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" || true)"
  case "$code" in
    201) step "created"; break ;;
    409|400) step "already there (HTTP $code), reusing it"; break ;;
    502|503|000) step "not ready yet (HTTP $code), retrying"; sleep 5 ;;
    *) die "registration failed: HTTP $code $(cat /tmp/seed-register.json)" ;;
  esac
done

TOKEN="$(call POST /auth/login "{\"organizationCode\":\"$ORG\",\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" | json "['token']")"
[ -n "$TOKEN" ] || die "could not log in as $EMAIL (an organization named '$ORG' with another password may exist: set SEED_ORG)"

announce() {
  cat <<EOF

Open $BASE_URL/login and sign in with:
  Organization  $ORG
  Email         $EMAIL
  Password      $PASSWORD
EOF
}

if call GET /api/projects | grep -q '"key":"DEMO"'; then
  echo "the demo project already exists: nothing to do."; announce; exit 0
fi

echo "create the project and the work items"
PROJECT="$(call POST /api/projects '{"name":"Proyecto demo","description":"Datos de ejemplo creados por scripts/seed.sh","key":"DEMO"}' | json "['projectCode']")"
[ -n "$PROJECT" ] || die "could not create the project"

# item TYPE TITLE PRIORITY PARENT POINTS EST_HOURS REMAINING_HOURS -> prints the item code
item() {
  local type="$1" title="$2" priority="$3" parent="${4:-}" points="${5:-}" est="${6:-}" rem="${7:-}" body
  body="{\"projectCode\":\"$PROJECT\",\"type\":\"$type\",\"title\":\"$title\",\"priority\":\"$priority\""
  [ -z "$parent" ] || body+=",\"parentCode\":\"$parent\""
  [ -z "$points" ] || body+=",\"effortPoints\":$points"
  [ -z "$est" ] || body+=",\"estimatedHours\":$est"
  [ -z "$rem" ] || body+=",\"remainingHours\":$rem"
  call POST /api/work-items "$body}" | json "['workItemCode']"
}

EPIC="$(item EPIC 'Checkout en línea' HIGH)";                                   step "epic     $EPIC"
FEATURE="$(item FEATURE 'Pagos con tarjeta' HIGH "$EPIC")";                     step "feature  $FEATURE"
PBI1="$(item PBI 'Como cliente quiero pagar con tarjeta' HIGH "$FEATURE" 8)"
PBI2="$(item PBI 'Como cliente quiero guardar mi tarjeta' MEDIUM "$FEATURE" 5)"
PBI3="$(item PBI 'Como cliente quiero ver mi recibo' LOW "$FEATURE" 3)"
PBI4="$(item PBI 'Como administrador quiero reembolsar un pago' MEDIUM "$FEATURE" 5)"; step "4 PBIs"
BUG="$(item BUG 'El total se redondea mal con descuentos' CRITICAL "" 2 3 3)";           step "bug"
T1="$(item TASK 'Diseñar el formulario de pago' MEDIUM "$PBI1" "" 8 8)"
T2="$(item TASK 'Integrar la pasarela de pago' HIGH "$PBI1" "" 16 16)"
T3="$(item TASK 'Escribir las pruebas del pago' MEDIUM "$PBI1" "" 6 6)"
T4="$(item TASK 'Cifrar los datos de la tarjeta' HIGH "$PBI2" "" 10 10)";               step "4 tasks"

echo "create a sprint, plan work in it and start it"
SPRINT="$(call POST /api/sprints "{\"projectCode\":\"$PROJECT\",\"name\":\"Sprint 1\",\"startDate\":\"$(date +%F)\",\"plannedVelocity\":13}" | json "['sprintCode']")"
[ -n "$SPRINT" ] || die "could not create the sprint"
for code in "$PBI1" "$PBI2" "$BUG" "$T1" "$T2" "$T3" "$T4"; do
  call PUT "/api/work-items/$code/sprint" "{\"sprintCode\":\"$SPRINT\"}" >/dev/null
done
step "PBI 1, PBI 2, the bug and the tasks are planned in Sprint 1 (PBI 3 and 4 stay in the backlog)"
# started AFTER the planning, so the burndown's first day is the planned scope (43 hours), not zero
call POST "/api/sprints/$SPRINT/start" >/dev/null && step "Sprint 1 started"

echo "move some of them along their workflows"
status_of() { call POST "/api/work-items/$1/status" "{\"status\":\"$2\"}" >/dev/null 2>&1 && return 0 || return 1; }
status_of "$PBI1" APPROVED && status_of "$PBI1" COMMITTED && step "PBI 1 -> Committed"
status_of "$PBI2" APPROVED && step "PBI 2 -> Approved"
# a Task goes New -> In Progress -> On Hold -> Done; done ones are what the burndown counts
if status_of "$T1" IN_PROGRESS; then
  status_of "$T1" ON_HOLD && status_of "$T1" DONE && step "task 'Diseñar el formulario' -> Done" || step "task 'Diseñar el formulario' -> In Progress"
fi
call POST "/api/work-items/$PBI1/comments" '{"content":"Comentario de ejemplo: aquí se conversa sobre el trabajo."}' >/dev/null && step "a comment on PBI 1"

echo "done."
announce
cat <<EOF

What is in it: project DEMO with an epic > feature > 4 PBIs > tasks, a critical bug, and Sprint 1 (started) with work in it.
EOF
