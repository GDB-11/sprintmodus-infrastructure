#!/usr/bin/env bash
# Deploys Sprintmodus to the k3s cluster kubectl points at. Safe to re-run: that is how you upgrade (change the tags in
# kustomization.yaml first). Run it on the server, or anywhere with a kubeconfig for it.
#
#   DOMAIN=sprintmodus.com ACME_EMAIL=you@example.com ./deploy.sh
#   ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory ...   dry run against Let's Encrypt staging first
#
# Why in waves: Kubernetes has no depends_on, and this node has 2 vCPU and 4 GB, so five JVMs starting at once would thrash.
# Order: MySQL -> migration Job -> Eureka -> services + frontend -> public edge. `phase` is a label on every object.
set -euo pipefail
cd "$(dirname "$0")"

: "${DOMAIN:=sprintmodus.com}"
: "${ACME_EMAIL:?set ACME_EMAIL (Lets Encrypt writes there before a certificate expires)}"
: "${ACME_CA:=https://acme-v02.api.letsencrypt.org/directory}"
K="kubectl"
NS=sprintmodus

$K apply -f namespace.yaml

# Secrets are created ONCE and never regenerated: the tenant credentials in the database cannot be decrypted without
# TENANT_CREDENTIALS_KEY/SALT, and MySQL keeps the root password it was first started with.
if ! $K -n $NS get secret sprintmodus-secrets >/dev/null 2>&1; then
  $K -n $NS create secret generic sprintmodus-secrets \
    --from-literal=MASTER_DB_ROOT_PASSWORD="$(openssl rand -base64 48 | tr -d '\n')" \
    --from-literal=JWT_SECRET="$(openssl rand -base64 48 | tr -d '\n')" \
    --from-literal=TENANT_CREDENTIALS_KEY="$(openssl rand -base64 48 | tr -d '\n')" \
    --from-literal=TENANT_CREDENTIALS_SALT="$(openssl rand -hex 8)"
  echo ">> Secrets created. BACK THEM UP now, off this server:"
  echo "   kubectl -n $NS get secret sprintmodus-secrets -o yaml > sprintmodus-secrets.yaml   (and keep it private)"
fi

# The backup script is the same one compose uses
$K -n $NS create configmap db-backup-script --from-file=backup.sh=../scripts/backup.sh --dry-run=client -o yaml | $K apply -f -

# Traefik: ACME resolver + certificate storage
sed "s#__ACME_EMAIL__#$ACME_EMAIL#g; s#__ACME_CA__#$ACME_CA#g" traefik-config.yaml | $K apply -f -

rendered="$($K kustomize . | sed "s#__DOMAIN__#$DOMAIN#g")"
apply_phase() { printf '%s\n' "$rendered" | $K apply -f - -l "phase=$1"; }

echo ">> 1/5 MySQL"
apply_phase 1-db
$K -n $NS rollout status statefulset/master-db --timeout=300s

echo ">> 2/5 Migrations (master_db + every tenant DB)"
$K -n $NS delete job migrator --ignore-not-found
apply_phase 2-migrate
if ! $K -n $NS wait --for=condition=complete job/migrator --timeout=600s; then
  $K -n $NS logs job/migrator --tail=60 || true
  echo "The migration failed; nothing else was started." >&2
  exit 1
fi

echo ">> 3/5 Eureka"
apply_phase 3-eureka
$K -n $NS rollout status deployment/eureka-server --timeout=400s

echo ">> 4/5 Services and frontend"
apply_phase 4-services
for d in auth-service project-service workitem-service api-gateway frontend; do
  $K -n $NS rollout status deployment/$d --timeout=600s
done

echo ">> 5/5 Public edge (https://$DOMAIN)"
apply_phase 5-edge
$K -n $NS get pods
echo "Done. The certificate is requested on the first https request; give it a minute."
