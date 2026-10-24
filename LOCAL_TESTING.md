# Testing the whole containerized stack on your machine

This guide runs **everything** (MySQL, Eureka, the gateway, the three services, the frontend behind nginx) as Docker containers
on your own computer, built from the source in your repos, the same way it will run on a server. You do not need the GitHub
registry, CI or a server for this.

## The short version

It is **one command to start** and one more if you want demo data:

```bash
cd ~/repos/sprintmodus-infrastructure

scripts/local.sh start     # builds the images (first time only) and starts the stack
scripts/local.sh seed      # creates a demo organization with data to click on
```

Then open **http://localhost:8080** and sign in with:

| | |
|---|---|
| Organization | `demo` |
| Email | `demo@example.com` |
| Password | `demo-password-123` |

That is all. Everything below explains what happened and what else you can do with it.

## Before you start

Linux, with:

| Needed | Check | Notes |
|---|---|---|
| Docker Engine + Compose v2.24+ | `docker compose version` | You must be allowed to use Docker without `sudo` |
| The `buildx` plugin | `docker buildx version` | The builds pass a token to Maven as a BuildKit *secret*, which needs it |
| A JDK 26 or newer | `java -version` | The libraries are compiled on your machine; JDK 27 works. Point `JAVA_HOME` at another one if needed |
| The repos side by side | `ls ~/repos \| grep sprintmodus` | `sprintmodus-infrastructure` finds its siblings in the parent folder. Elsewhere: `SPRINTMODUS_REPOS=/path scripts/local.sh ...` |
| About 10 GB of disk and free ports **8080**, **8090**, **8099** | `ss -ltn` | 8099 is only used while building. Override with `FRONTEND_PORT`, `GATEWAY_PORT`, `LOCAL_MAVEN_PORT` |

You do **not** need Node, pnpm or Maven installed for the containers: the frontend is built inside Docker, and the services are
built by the Maven wrapper inside Docker (the wrapper on your machine only builds the three small libraries).

## What `start` does

Three steps, printed as it goes:

1. **Libraries.** The three services that talk to databases need `common-lib` and the `db-*` jars while they are built.
   Normally those come from GitHub Packages, which is not published yet, so the script builds them, drops them into a folder
   (`.local/maven-repo`) and serves it from a throwaway nginx container on port 8099 for the length of the build.
2. **Images.** Six images are built and tagged `ghcr.io/gdb-11/sprintmodus-<name>:local`. Only the missing ones are built, so
   this is slow once and fast afterwards.
3. **The stack.** It creates `.env.local` with **fresh random secrets** (only for this local stack, never committed) and runs
   `docker compose up --wait`. Compose starts things in order and waits for each to be healthy: MySQL, then the **migrator**
   (creates the schemas), Eureka, the three services, the gateway, and finally the frontend.

Everything lives in its own Docker project, **`sprintmodus-local`**, with its own volumes. **It never touches your development
MySQL** (project `sprintmodus`, volume `sprintmodus_master-db-data`).

| How long | |
|---|---|
| The very first time | roughly 5 to 15 minutes, mostly downloading base images and Maven dependencies (an estimate: I measured a full `start` at 1½ minutes, but with those downloads already cached) |
| Later starts | 30 seconds to 1½ minutes |
| Rebuilding one service after a change | seconds to a couple of minutes |

> **Give it a minute after it says "healthy".** The services discover each other through Eureka, which takes up to a minute. In
> that window you may see `503` errors or a sign-in that fails once. It is normal on every fresh start; wait and retry.

## The app

`scripts/local.sh seed` fills the `demo` organization with a project **DEMO**: an epic, a feature, four PBIs, four tasks, a
critical bug, and **Sprint 1** (started, with work planned in it, one task done, the burndown starting at 43 hours). Running it
again does nothing.

> **The UI cannot create projects or invite users yet** (there is no screen for either; the roadmap never included them). That is
> why `seed` exists: a brand-new organization you register by hand would have no project, so nothing to create or to see on the
> board. You *can* register more organizations at `/register`, but they will be empty.

### A tour, and what to look for

**This is the first time the frontend is run against the real containerized backend in a real browser** (until now it was
checked by automated tests and scripts). Please click around and write down anything odd.

| Screen | Address | Try |
|---|---|---|
| Dashboard | `/dashboard` | Your organization and plan; links to the other screens |
| Work items | `/work-items` | Filter by type, status, priority; search a word; open an item |
| One work item | `/work-items/<code>` | Change its status (only legal moves are offered); parent, sprint, links, comments; the **Historial** section |
| New work item | `/work-items/new` | Create one of each type; try a non-standard parent (you should get a *warning*, not an error) |
| Board | `/board` | Drag a card to another column **and** use the "Mover a…" select; the sprint filter; the priority/assignee/text filters |
| Sprints | `/sprints` | Start/close (asks first), velocity history, settings; **Ver burndown** shows the two lines and a projection |
| Workflow admin | `/work-items/admin/workflows` | Change a status name or a transition (owners/admins only) |

**Real time.** Open the board in **two browser windows** (a second profile or a private window; the same user is fine), move a card
in one and watch it move in the other. The connection indicator should say *Conectado en vivo*, and *En línea* lists who is connected. In the browser's developer tools →
Network → WS you should see the `/ws/...` connection with status **101**, which proves the WebSocket works through nginx.

**Losing the live connection.** Stop the service and watch the indicator fall back, then bring it back:

```bash
docker compose -p sprintmodus-local --env-file .env.local stop workitem-service    # indicator: Reconectando… / Sin conexión en vivo
docker compose -p sprintmodus-local --env-file .env.local start workitem-service   # it reconnects on its own
```

Tip: put this in your shell profile so you can type `dcl ps`, `dcl logs -f auth-service`...

```bash
alias dcl='docker compose -p sprintmodus-local --env-file ~/repos/sprintmodus-infrastructure/.env.local -f ~/repos/sprintmodus-infrastructure/compose.yaml'
```

## Everyday commands

Always from `sprintmodus-infrastructure`:

| I want to... | Command |
|---|---|
| Start (building what is missing) | `scripts/local.sh start` |
| See what is running and healthy | `scripts/local.sh status` |
| Follow the logs (all, or one service) | `scripts/local.sh logs` · `scripts/local.sh logs workitem-service` |
| Check the whole thing end to end | `scripts/local.sh smoke` |
| Create the demo data | `scripts/local.sh seed` |
| Look inside the database | `scripts/local.sh mysql` (a `mysql>` prompt on `master_db`) |
| Stop, **keeping** the data | `scripts/local.sh stop` |
| **Start over from scratch**: delete everything, start clean and seed | `scripts/local.sh fresh` (asks you to type `delete`; about 1½ minutes) |
| ...and rebuild every image too (after big changes) | `scripts/local.sh fresh --rebuild` |
| Only delete the stack **and its data**, without starting again | `scripts/local.sh reset` (asks you to type `delete`) |
| ...and the built images too | `scripts/local.sh reset --yes --images` |

`stop` followed by `start` keeps everything you created: the data is in a Docker volume, not in the containers.

**Starting over safely.** `scripts/local.sh fresh` is the "delete everything and begin again with the demo data" command. It
asks you to type `delete`, removes the local stack (containers, database volume, backups, `.env.local`), starts a clean one with
new random secrets and runs the seed, so you end up on the sign-in screen with `demo` again. It only ever touches the Docker
project `sprintmodus-local`, never your development MySQL. It keeps the built images, so it is fast; use `--rebuild` when you
want the images rebuilt from your latest code as well. Add `--yes` to skip the question (for scripts).

**Looking inside a tenant's database.** Each organization has its own database, `tenant_<id>`:

```bash
scripts/local.sh mysql
mysql> SHOW DATABASES LIKE 'tenant%';
mysql> SELECT OrganizationCode, DatabaseName, IsActive FROM Organization;
mysql> SELECT WorkItemNumber, Title FROM tenant_<paste the name here>.WorkItem;
```

**Eureka's dashboard and direct access to the services** are not published by default. To see them, add the development override
(it also publishes MySQL on `127.0.0.1:3306`, so stop your own MySQL first if it is running):

```bash
docker compose -p sprintmodus-local --env-file .env.local -f compose.yaml -f compose.dev.yaml up -d --wait
# Eureka: http://localhost:8761     the services: 8091, 8092, 8093
```

## You changed some code

The images are built from your working copy, so rebuild the one you touched and start again; only changed containers restart:

```bash
scripts/local.sh build workitem-service     # or: auth-service, project-service, api-gateway, eureka-server, ng (the frontend)
scripts/local.sh up
```

`scripts/local.sh start --rebuild` rebuilds all six. The image build **skips the tests** (they run in each repo, `./mvnw test`, and
in CI), so a green build here says nothing about them. If you changed **`common-lib`, `db-master` or `db-tenant`** (for example a
new migration), rebuild the services that use them: `scripts/local.sh build auth-service project-service workitem-service`. A new
migration reaches existing organizations through the migrator, which runs on every `up`.

## Drills worth doing once

These are what production relies on, so it is worth seeing them work on your machine first. All of them use the local stack; run
this first in the terminal you use for them:

```bash
cd ~/repos/sprintmodus-infrastructure
export COMPOSE_PROJECT_NAME=sprintmodus-local COMPOSE_ENV_FILES=$PWD/.env.local
```

### 1. The data survives a stop

```bash
scripts/local.sh stop && scripts/local.sh start     # sign in again: the demo data is still there
```

### 2. Backup, total loss, restore

```bash
docker compose exec db-backup /usr/local/bin/backup.sh once      # a backup right now (they also run daily)
scripts/restore.sh --list                                         # a file of a few hundred bytes would be an EMPTY database

scripts/local.sh stop
docker volume rm sprintmodus-local_master-db-data                 # the disaster: every database is gone
scripts/local.sh start                                            # an empty system; signing in as demo fails (401 or 503)

scripts/restore.sh latest --yes                                   # restore the newest backup
```

Sign in again as `demo`: the organization, the project and the work items are back. (After the loss the backup service
*refuses* to make a new backup of the empty database, precisely so `latest` still points at the good one. You will see the
`REFUSED` message in `scripts/local.sh logs db-backup`.)

### 3. HTTPS, the way production will run

`compose.prod.yaml` puts Caddy in front for automatic HTTPS. Locally it uses a certificate from its own private authority, so the
browser will warn about it: that is expected, accept it.

```bash
cp .env.local .env.local-https
sed -i 's|^PUBLIC_ORIGIN=.*|PUBLIC_ORIGIN=https://localhost:8443|' .env.local-https
printf 'DOMAIN=localhost\nACME_EMAIL=me@example.com\nHTTP_PORT=8081\nHTTPS_PORT=8443\n' >> .env.local-https

docker compose -p sprintmodus-local --env-file .env.local-https -f compose.yaml -f compose.prod.yaml up -d --wait
# open https://localhost:8443  (http://localhost:8080 no longer answers: only Caddy is public)
```

Go back to plain http with `scripts/local.sh stop && scripts/local.sh start`. The real domain works the same way with
`DOMAIN=sprintmodus.com`, see the README's "Production on sprintmodus.com".

## Cleaning up

| What | Command |
|---|---|
| Stop everything, keep the data | `scripts/local.sh stop` |
| Delete the local stack and its data | `scripts/local.sh reset` |
| Also delete the built images (frees a few GB; the next `start` rebuilds them) | `scripts/local.sh reset --yes --images` |
| See what Docker is using | `docker system df` |
| Reclaim build caches (safe; it does not touch volumes) | `docker builder prune` |

**Never run `docker system prune --volumes`** or `docker volume rm` on a volume you did not mean to lose: named volumes hold
databases. The local stack is disposable; your development MySQL volume `sprintmodus_master-db-data` is not.

## When something goes wrong

| Symptom | Likely cause and what to do |
|---|---|
| `error: java 21 found, 26 or newer is needed` | Select a newer JDK: `export JAVA_HOME=/path/to/jdk-26 PATH=$JAVA_HOME/bin:$PATH` |
| `the docker buildx plugin is missing` | Install it (Arch: `pacman -S docker-buildx`), or download the binary into `~/.docker/cli-plugins/docker-buildx` |
| `could not start the Maven repository container` | Port 8099 is busy: `LOCAL_MAVEN_PORT=8199 scripts/local.sh start` |
| `port is already allocated` on 8080 | Something else uses it. `scripts/local.sh reset`, then `FRONTEND_PORT=9090 scripts/local.sh start` (the port and `PUBLIC_ORIGIN` are written together when `.env.local` is created, so it must be created again) |
| `the build of auth-service failed` | Build it by hand to see the error: `cd ../sprintmodus-auth-service && docker build --network host --secret id=github_token,env=GITHUB_TOKEN --build-arg LIBS_REPO_URL=http://localhost:8099 .` (with `export GITHUB_TOKEN=x` and the Maven container running) |
| A container is `unhealthy`, `start` times out | `scripts/local.sh logs <service>` shows why. The usual causes are a wrong secret in `.env.local` or too little memory (the whole stack needs about 2.5 GB free) |
| `503` or a failed sign-in for the first minute | Normal warm-up, see above |
| The browser shows a CORS error / `403` on every POST | `PUBLIC_ORIGIN` in `.env.local` is not exactly the address in the address bar (`http://localhost:8080`, no trailing slash, same port) |
| `.env.local does not exist but the volume does` | MySQL keeps the password it was created with. `scripts/local.sh reset`, then `start` |
| It worked yesterday and now the app is old | The images were built from your code at that time: `scripts/local.sh build <name>` then `up` |
| The board says *Sin conexión en vivo* | Check `scripts/local.sh logs workitem-service`; in DevTools → Network → WS the handshake should be `101` |
| I want to start over | `scripts/local.sh fresh` |

## How this differs from a real deployment

| Here | On a server |
|---|---|
| Images are built on your machine and tagged `local` | CI builds them, publishes them to GHCR, `.env` pins a version or commit tag |
| The libraries come from a throwaway folder | They come from GitHub Packages |
| Plain `http://localhost:8080` | HTTPS on `sprintmodus.com` through Caddy |
| Random secrets in `.env.local`, demo password public | Real secrets you keep and back up |
| Ports published for you to reach | Only 80/443 |

Everything else (the containers, the health-check ordering, the migrator, the volumes, the backups, nginx, the WebSocket path) is
identical, which is the point: what you verify here is what runs there. For the production steps (DNS, firewall, first deploy)
see the [README](README.md#production-on-sprintmoduscom).

## Cheat sheet

```bash
cd ~/repos/sprintmodus-infrastructure
scripts/local.sh start        # build what is missing + start   ->  http://localhost:8080
scripts/local.sh seed         # demo data                        ->  demo / demo@example.com / demo-password-123
scripts/local.sh status       # what is running
scripts/local.sh logs [svc]   # follow logs
scripts/local.sh smoke        # end-to-end check
scripts/local.sh mysql        # SQL shell
scripts/local.sh build <name> && scripts/local.sh up     # after changing code
scripts/local.sh stop         # stop, keep data
scripts/local.sh fresh        # delete everything + start clean + seed (the "start over" button)
scripts/local.sh reset        # delete everything, including the data, and stop there
```
