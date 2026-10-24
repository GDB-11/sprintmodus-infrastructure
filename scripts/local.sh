#!/usr/bin/env bash
# Build and run the WHOLE containerized stack on this machine, from the source in the sibling repos, with one command.
# The guide is LOCAL_TESTING.md. In short:
#
#   scripts/local.sh start        build every image (first time only) and start the stack
#   scripts/local.sh smoke        register an organization, log in, create a project and a work item, through the real stack
#   scripts/local.sh stop         stop it, KEEPING the data
#   scripts/local.sh reset        delete the stack AND its data
#
# It never touches the default compose project ("sprintmodus", your development MySQL volume): everything here lives in the
# project "sprintmodus-local", with its own volumes, its own secrets (.env.local) and the image tag "local".
set -euo pipefail

cd "$(dirname "$0")/.."
INFRA_DIR="$PWD"
REPOS_DIR="${SPRINTMODUS_REPOS:-$(cd .. && pwd)}"      # where the sprintmodus-* repos are checked out
PROJECT="sprintmodus-local"
ENV_FILE="$INFRA_DIR/.env.local"
TAG="local"
REGISTRY="ghcr.io/gdb-11"
MAVEN_PORT="${LOCAL_MAVEN_PORT:-8099}"                 # a throwaway Maven repository used only while building
MAVEN_CONTAINER="sprintmodus-local-maven"
WORK_DIR="$INFRA_DIR/.local"                            # git-ignored: the throwaway Maven repository
LIBS=(common-lib db-master db-tenant)
SERVICES=(eureka-server api-gateway auth-service project-service workitem-service)
ALL_IMAGES=("${SERVICES[@]}" ng)                        # ng = the frontend

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

dc() { COMPOSE_PROJECT_NAME="$PROJECT" docker compose --env-file "$ENV_FILE" "$@"; }
image_of() { echo "$REGISTRY/sprintmodus-$1:$TAG"; }

usage() {
  cat <<EOF
usage: scripts/local.sh <command> [options]

  start [--rebuild]     build the images that are missing (all of them with --rebuild) and start the stack
  build [name...]       (re)build images: ${ALL_IMAGES[*]}   (no names = all)
  up                    start the stack from the images already built
  status                what is running and healthy
  logs [service]        follow the logs (Ctrl+C leaves the stack running)
  smoke                 end-to-end check through the real stack
  seed                  create a demo organization with demo data to click on (login: demo / demo@example.com / demo-password-123)
  mysql                 open a MySQL shell on the master database
  fresh [--yes] [--rebuild]   start over: delete the local stack AND ITS DATA, start a clean one and seed it (--rebuild also rebuilds the images)
  stop                  stop the stack, keeping the data
  reset [--yes] [--images]   delete the stack AND ITS DATA (and the built images with --images)
EOF
}

preflight() {
  command -v docker >/dev/null || die "docker is not installed"
  docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon (is it running, and are you allowed to use it?)"
  local compose; compose="$(docker compose version --short 2>/dev/null || true)"
  [ -n "$compose" ] || die "docker compose (v2) is not installed"
  [ "$(printf '%s\n2.24.0\n' "$compose" | sort -V | head -1)" = "2.24.0" ] || die "docker compose $compose is too old, 2.24 or newer is needed"
}

preflight_build() {
  docker buildx version >/dev/null 2>&1 || die "the docker buildx plugin is missing (the builds use BuildKit secrets): https://docs.docker.com/build/install-buildx/"
  command -v java >/dev/null || die "no JDK found: the libraries are compiled on the host, a JDK 26 or newer is needed (JAVA_HOME or PATH)"
  local major; major="$(java -version 2>&1 | sed -n '1s/.*version "\([0-9]*\).*/\1/p')"
  [ "${major:-0}" -ge 26 ] || die "java $major found, 26 or newer is needed (set JAVA_HOME)"
  for repo in "${LIBS[@]}" "${SERVICES[@]}" ng; do
    [ -d "$REPOS_DIR/sprintmodus-$repo" ] || die "$REPOS_DIR/sprintmodus-$repo not found (set SPRINTMODUS_REPOS to the folder that holds the repos)"
  done
}

# The service images take common-lib and the db-* jars from a Maven repository (GitHub Packages in real life). Nothing is
# published yet, so the libraries are deployed to a folder and served by a throwaway nginx for the duration of the build.
serve_libraries() {
  say "1/3 libraries: build them and serve them as a Maven repository on localhost:$MAVEN_PORT"
  rm -rf "$WORK_DIR/maven-repo"; mkdir -p "$WORK_DIR/maven-repo"
  for lib in "${LIBS[@]}"; do
    echo "  - $lib"
    (cd "$REPOS_DIR/sprintmodus-$lib" && ./mvnw -B -q deploy -DskipTests \
      -DaltDeploymentRepository="github::file://$WORK_DIR/maven-repo") || die "could not build $lib"
  done
  docker rm -f "$MAVEN_CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$MAVEN_CONTAINER" -p "127.0.0.1:$MAVEN_PORT:80" -v "$WORK_DIR/maven-repo:/usr/share/nginx/html:ro" \
    nginx:1.29-alpine >/dev/null || die "could not start the Maven repository container (is port $MAVEN_PORT free? set LOCAL_MAVEN_PORT)"
}

stop_libraries() { docker rm -f "$MAVEN_CONTAINER" >/dev/null 2>&1 || true; }

build_image() {
  local name="$1" dir="$REPOS_DIR/sprintmodus-$1"
  echo "  - $name"
  case "$name" in
    auth-service|project-service|workitem-service)
      GITHUB_TOKEN=local docker build -q --network host --secret id=github_token,env=GITHUB_TOKEN \
        --build-arg "LIBS_REPO_URL=http://localhost:$MAVEN_PORT" -t "$(image_of "$name")" "$dir" >/dev/null || die "the build of $name failed (run it without -q for details: cd $dir && docker build .)" ;;
    *)
      docker build -q -t "$(image_of "$name")" "$dir" >/dev/null || die "the build of $name failed (cd $dir && docker build .)" ;;
  esac
}

cmd_build() {
  preflight; preflight_build
  local names=("$@"); [ ${#names[@]} -gt 0 ] || names=("${ALL_IMAGES[@]}")
  local needs_libs=0
  for n in "${names[@]}"; do case "$n" in auth-service|project-service|workitem-service) needs_libs=1 ;; esac; done
  trap stop_libraries EXIT
  [ "$needs_libs" = 1 ] && serve_libraries
  say "2/3 images (the first build downloads a lot, later ones are much faster)"
  for n in "${names[@]}"; do
    case " ${ALL_IMAGES[*]} " in *" $n "*) build_image "$n" ;; *) die "unknown image '$n' (one of: ${ALL_IMAGES[*]})" ;; esac
  done
  stop_libraries
  say "built: $(printf '%s ' "${names[@]}")"
}

missing_images() {
  for n in "${ALL_IMAGES[@]}"; do docker image inspect "$(image_of "$n")" >/dev/null 2>&1 || echo "$n"; done
}

random() { head -c 96 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9' | head -c "$1"; }

ensure_env() {
  if [ -f "$ENV_FILE" ]; then return; fi
  if docker volume inspect "${PROJECT}_master-db-data" >/dev/null 2>&1; then
    die "the database volume ${PROJECT}_master-db-data exists but $ENV_FILE does not: MySQL keeps the password it was created with, so new secrets would never work. Run 'scripts/local.sh reset' to start clean."
  fi
  local port="${FRONTEND_PORT:-8080}" gw="${GATEWAY_PORT:-8090}"
  say "creating $ENV_FILE with fresh random secrets (only for this local stack)"
  umask 077
  cat > "$ENV_FILE" <<EOF
# Generated by scripts/local.sh for the LOCAL test stack only. Never committed. Deleting it (with the data) is 'scripts/local.sh reset'.
MASTER_DB_ROOT_PASSWORD=$(random 24)
JWT_SECRET=$(random 96)
TENANT_CREDENTIALS_KEY=$(random 32)
TENANT_CREDENTIALS_SALT=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')

# The address you type in the browser. Change the port AND this line together.
PUBLIC_ORIGIN=http://localhost:$port
FRONTEND_PORT=$port
GATEWAY_PORT=$gw

REGISTRY=$REGISTRY
EUREKA_SERVER_TAG=$TAG
API_GATEWAY_TAG=$TAG
AUTH_SERVICE_TAG=$TAG
PROJECT_SERVICE_TAG=$TAG
WORKITEM_SERVICE_TAG=$TAG
FRONTEND_TAG=$TAG
EOF
}

port_of() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2; }

cmd_up() {
  preflight; ensure_env
  local missing; missing="$(missing_images | tr '\n' ' ')"
  [ -z "$missing" ] || die "images not built yet: $missing (run 'scripts/local.sh build' or 'scripts/local.sh start')"
  say "3/3 starting the stack (about a minute: MySQL, then the migrator, Eureka, the services, the gateway, the frontend)"
  dc up -d --wait --wait-timeout 420
  local fe gw; fe="$(port_of FRONTEND_PORT)"; gw="$(port_of GATEWAY_PORT)"
  cat <<EOF

The stack is up and healthy.

  App        http://localhost:$fe        (register an organization first: http://localhost:$fe/register)
  Gateway    http://127.0.0.1:$gw        (the API, for curl)
  Check      scripts/local.sh smoke
  Logs       scripts/local.sh logs [service]
  Stop       scripts/local.sh stop         (keeps your data)     Delete everything: scripts/local.sh reset
EOF
}

cmd_start() {
  local rebuild=0; [ "${1:-}" = "--rebuild" ] && rebuild=1
  preflight
  if [ "$rebuild" = 1 ]; then cmd_build
  else
    local missing; missing="$(missing_images | tr '\n' ' ')"
    [ -z "$missing" ] || { echo "images to build: $missing"; cmd_build $missing; }
  fi
  cmd_up
}

cmd_smoke() {
  preflight; [ -f "$ENV_FILE" ] || die "the stack was never started (scripts/local.sh start)"
  COMPOSE_PROJECT_NAME="$PROJECT" COMPOSE_ENV_FILES="$ENV_FILE" BASE_URL="http://localhost:$(port_of FRONTEND_PORT)" \
    "$INFRA_DIR/scripts/smoke.sh" --no-up
}

cmd_seed() {
  preflight; [ -f "$ENV_FILE" ] || die "the stack was never started (scripts/local.sh start)"
  BASE_URL="http://localhost:$(port_of FRONTEND_PORT)" "$INFRA_DIR/scripts/seed.sh"
}

# One command to start over: delete -> start -> seed. Same safety as reset: only the project "sprintmodus-local" is touched.
cmd_fresh() {
  local yes=0 rebuild=0
  for a in "$@"; do case "$a" in --yes) yes=1 ;; --rebuild) rebuild=1 ;; *) die "unknown option $a" ;; esac; done
  preflight
  if [ "$yes" != 1 ]; then
    echo "This deletes the local stack AND ALL ITS DATA (project '$PROJECT': containers, database volume, backups, certificates, $ENV_FILE),"
    echo "then builds what is missing$([ "$rebuild" = 1 ] && echo ' (ALL the images, again)'), starts a clean stack and creates the demo data."
    echo "Your development MySQL (project 'sprintmodus') is not touched."
    read -r -p "Type 'delete' to continue: " answer; [ "$answer" = delete ] || die "cancelled"
  fi
  if [ "$rebuild" = 1 ]; then cmd_reset --yes --images; else cmd_reset --yes; fi
  cmd_start
  cmd_seed
}

cmd_reset() {
  local yes=0 images=0
  for a in "$@"; do case "$a" in --yes) yes=1 ;; --images) images=1 ;; *) die "unknown option $a" ;; esac; done
  preflight
  if [ "$yes" != 1 ]; then
    echo "This deletes the local stack AND ALL ITS DATA (the project '$PROJECT': containers, database volume, backups, certificates, $ENV_FILE)."
    echo "Your development MySQL (project 'sprintmodus') is not touched."
    read -r -p "Type 'delete' to continue: " answer; [ "$answer" = delete ] || die "cancelled"
  fi
  if [ -f "$ENV_FILE" ]; then dc down --volumes --remove-orphans; else
    COMPOSE_PROJECT_NAME="$PROJECT" docker compose down --volumes --remove-orphans 2>/dev/null || true
  fi
  # volumes that only an overlay declares (the Caddy certificates of the HTTPS recipe) are not known to the base file
  for v in $(docker volume ls -q --filter "label=com.docker.compose.project=$PROJECT"); do docker volume rm "$v" >/dev/null; done
  rm -f "$ENV_FILE" "$ENV_FILE-https"; rm -rf "$WORK_DIR"; stop_libraries
  if [ "$images" = 1 ]; then for n in "${ALL_IMAGES[@]}"; do docker rmi "$(image_of "$n")" >/dev/null 2>&1 || true; done; fi
  say "local stack deleted"
}

command="${1:-}"; shift || true
case "$command" in
  start)  cmd_start "$@" ;;
  build)  cmd_build "$@" ;;
  up)     cmd_up ;;
  status) preflight; [ -f "$ENV_FILE" ] || die "the stack was never started"; dc ps -a ;;
  logs)   preflight; [ -f "$ENV_FILE" ] || die "the stack was never started"; dc logs -f --tail=100 "$@" ;;
  smoke)  cmd_smoke ;;
  seed)   cmd_seed ;;
  mysql)  preflight; [ -f "$ENV_FILE" ] || die "the stack was never started"; dc exec master-db sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" master_db' ;;
  stop)   preflight; [ -f "$ENV_FILE" ] || die "the stack was never started"; dc down --remove-orphans; say "stopped; the data is kept (scripts/local.sh start brings it back)" ;;
  reset)  cmd_reset "$@" ;;
  fresh)  cmd_fresh "$@" ;;
  ""|-h|--help|help) usage ;;
  *) usage; exit 2 ;;
esac
