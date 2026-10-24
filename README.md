# sprintmodus-infrastructure

Orchestration only: how the published images of Sprintmodus are wired together. There is no application code here and nothing is
built from source; every repo builds and publishes its own image to GitHub Container Registry
(`ghcr.io/gdb-11/sprintmodus-<repo>`), and `compose.yaml` pulls them by an explicit version or commit tag.

On a machine with only Docker installed (no JDK, Node or Maven):

```bash
cp .env.example .env        # then fill it in: secrets and the image tags to run
docker login ghcr.io        # a token with read:packages (the packages are private)
docker compose up -d --wait # the whole system; open http://localhost:8080
```

**To try the whole stack on your own machine, follow [LOCAL_TESTING.md](LOCAL_TESTING.md)**: `scripts/local.sh start` builds the
images from your working copies and starts everything, no registry or server needed.

For production on **sprintmodus.com** (HTTPS, automatic certificates) use the production overlay instead, see
[Production on sprintmodus.com](#production-on-sprintmoduscom). What keeps the data safe is in [Data safety](#data-safety) and
[Backups](#backups); read those before putting real data in.

## What it starts

| Service | Image | Published | Notes |
|---|---|---|---|
| `master-db` | `mysql:9.7` | no | The databases of the master and of every tenant, named volume `master-db-data`. **MySQL only, MariaDB is not allowed** |
| `db-backup` | `mysql:9.7` | no | Scheduled backups of every database into the volume `db-backups` (see [Backups](#backups)) |
| `caddy` | `caddy:2.11-alpine` | `:80`, `:443` | **Production overlay only**: HTTPS and the public entry point |
| `migrator` | `sprintmodus-auth-service` | no | One-shot: migrates the master DB and every active tenant DB, then exits (see below) |
| `eureka-server` | `sprintmodus-eureka-server` | no | Service discovery |
| `auth-service`, `project-service` | `sprintmodus-<service>` | no | |
| `workitem-service` | `sprintmodus-workitem-service` | no | **Exactly one instance** (see below) |
| `api-gateway` | `sprintmodus-api-gateway` | `127.0.0.1:8090` | Routing, JWT-protected routes, `/ws/**` proxy, the only CORS authority |
| `frontend` | `sprintmodus-ng` | `:8080` (not with the production overlay) | nginx: serves the app and proxies `/auth`, `/api`, `/ws` to the gateway |

The browser talks to **one origin**, the frontend. Start order is enforced with health checks: MySQL, then the migrator, and
Eureka, then auth/project/workitem, then the gateway, then the frontend. Only the frontend and the gateway are published
(the gateway on loopback, for `curl` and tooling); every other port stays on the internal network `sprintmodus-net`. With the
production overlay only Caddy is published (80/443).

## Configuration (`.env`)

Everything comes from the environment; `.env` is never committed and there is **no default for a secret**: `docker compose`
refuses to start without one (`${VAR:?...}`).

| Variable | What |
|---|---|
| `MASTER_DB_ROOT_PASSWORD` | Root password of MySQL (used by every service that opens a tenant DB) |
| `JWT_SECRET` | Signing key of the tokens, at least 64 characters (`openssl rand -base64 48`) |
| `TENANT_CREDENTIALS_KEY`, `TENANT_CREDENTIALS_SALT` | Encrypt the tenant DB password recorded in the master DB (`openssl rand -base64 24`, `openssl rand -hex 8`). **Changing them makes stored tenant credentials unreadable**: keep them with the database backups |
| `PUBLIC_ORIGIN` | The public address of the frontend: `http://localhost:8080` locally, `https://sprintmodus.com` in production. It is the only origin the board WebSocket accepts (`sprintmodus.websocket.allowed-origins`) and, by default, the gateway's allowed CORS origin |
| `<SERVICE>_TAG`, `FRONTEND_TAG` | The image version to run: a released version (`0.1.0`) or a commit tag (`sha-1a2b3c4`). **Never `latest`**: compose refuses an unset tag |
| `REGISTRY` | Defaults to `ghcr.io/gdb-11` |
| `DOMAIN`, `ACME_EMAIL`, `ACME_CA` | Production overlay: the domain (`sprintmodus.com`), where Let's Encrypt writes about expiring certificates, and optionally the staging CA for a dry run |
| `MYSQL_MAX_CONNECTIONS`, `MYSQL_BUFFER_POOL_SIZE`, `MYSQL_MEMORY_LIMIT`, `MYSQL_BINLOG_RETENTION_SECONDS` | Database sizing, see [Data safety](#data-safety) |
| `BACKUP_INTERVAL_HOURS`, `BACKUP_KEEP_DAYS`, `BACKUP_DIR` | Backups, see [Backups](#backups) |
| `FRONTEND_PORT`, `GATEWAY_PORT`, `HTTP_PORT`, `HTTPS_PORT`, `CORS_ALLOWED_ORIGINS` | Optional |

Behind another TLS-terminating balancer instead of Caddy, point it at the frontend's port 8080 and set `PUBLIC_ORIGIN` to the
`https://` address; nginx honours `X-Forwarded-Proto` and keeps the `Host` header (with its port) for the gateway.

## Migrations

Schemas are only ever changed through Flyway, never by piping `.sql` files into `mysql` (that bypasses the schema history).

- **New organization:** `auth-service` creates the tenant database and migrates it (`MySqlTenantProvisioner`) as part of
  registration; nothing to do by hand.
- **New version of the scripts:** every `docker compose up` runs the `migrator` first, and everything that touches a tenant DB
  waits for it. To run it alone: `docker compose run --rm migrator`. It migrates the master DB, then every tenant with
  `IsActive = TRUE` in the master DB, keeps going if one fails and exits `1` in that case (the log names the database).
- It is the `auth-service` image started with `SPRING_PROFILES_ACTIVE=migrator`, so it carries exactly the scripts
  auth-service onboards tenants with (`db-master` and `db-tenant` jars).

## Why `workitem-service` runs once

The board's STOMP broker is in that process's memory. With two instances, a card moved by a user connected to instance A would
never reach a user connected to B. So compose sets no `deploy.replicas` and you must not use `--scale`. Scaling out is a
separate decision: a shared broker (RabbitMQ/Redis relay, which lifts the "no broker" rule) or sticky routing per
`tenant/project` in the gateway; either needs a test with two clients on different instances.

## Development

```bash
# only MySQL, published on 127.0.0.1:3306, to run a service or `ng serve` from the IDE against it
docker compose -f compose.yaml -f compose.dev.yaml up -d master-db
# the whole stack with every internal port published as well
docker compose -f compose.yaml -f compose.dev.yaml up -d --wait
```

Locally built images work too: `docker build` in a repo, tag it `ghcr.io/gdb-11/sprintmodus-<repo>:dev` and put `dev` in `.env`.
The service images need the libraries from GitHub Packages, see each repo's README (Docker section).

## Smoke test

```bash
BASE_URL=http://localhost:8080 scripts/smoke.sh --no-up   # against a stack that is already running (it leaves a test organization behind)
# on a disposable copy, torn down WITH its volumes:
COMPOSE_PROJECT_NAME=sprintmodus-smoke FRONTEND_PORT=18080 GATEWAY_PORT=18090 BASE_URL=http://localhost:18080 scripts/smoke.sh --down
```

It registers an organization, logs in, creates a project and a work item and reads it back, sending `Origin` like a browser does
so CORS is exercised (`SMOKE_CURL_OPTS=-k` accepts a self-signed certificate). **`--down` deletes the database volume, so it
refuses to run on the default project name** (the real stack); give it its own `COMPOSE_PROJECT_NAME`.

## Data safety

All data of all tenants lives in **one named Docker volume, `master-db-data`** (plus `db-backups` for the backups and `caddy-data`
for the certificates). Named volumes are independent of the containers, so these are safe and were tested against real data:

| Event | Data |
|---|---|
| `docker compose down` / `stop` / `up --force-recreate` | kept (tested: down/up, and the MySQL container replaced by a new one) |
| Upgrading to new image tags, `pull` + `up -d` | kept (the migrator brings the schemas up to date first) |
| MySQL dies without a clean shutdown (power cut, OOM kill) | kept: the restart policy starts it again, InnoDB recovers, the services reconnect by themselves (tested; committed writes survive) |
| Reboot of the machine | containers start again with Docker (`restart: unless-stopped`), as long as the Docker service is enabled at boot: `systemctl enable docker` |
| **`docker compose down -v`, `docker volume rm`, `docker system prune --volumes`** | **deleted. Never on a stack with real data.** |
| Disk failure, deleted machine | lost, unless the backups were copied elsewhere (see [Backups](#backups)) |

- **Durability:** MySQL runs with its safe defaults (`innodb_flush_log_at_trx_commit=1`, `sync_binlog=1`): a change reported as
  committed is on disk. A clean stop is given 120 s to flush before Docker would kill it.
- **Connections:** every tenant has its own pool (at most 5 connections, opened on demand) in each of the three services that
  open tenant databases, so the worst case is tenants × 3 × 5. MySQL's default of 151 runs out at a few dozen active tenants;
  `--max-connections` is 500 here (`MYSQL_MAX_CONNECTIONS`). Watch `SHOW STATUS LIKE 'Max_used_connections'` as tenants grow.
- **Memory:** `--innodb-buffer-pool-size` is 512 MB inside a 1.5 GB limit (`MYSQL_BUFFER_POOL_SIZE`, `MYSQL_MEMORY_LIMIT`). On a
  bigger machine raise both together (roughly the pool at half the limit); a pool bigger than the limit gets MySQL OOM-killed.
- **Disk:** binary logs are kept 7 days (`MYSQL_BINLOG_RETENTION_SECONDS`) instead of MySQL's default 30, so they cannot quietly
  fill the disk. Watch free space on the disk that holds `/var/lib/docker`.
- **Single host:** this is one MySQL on one machine. There is no replication or automatic failover: recovery is a restore from
  backup, measured in minutes, with up to one backup interval of data lost unless the binary logs are replayed by hand.
- **Secrets are part of the data:** the encrypted tenant credentials in the database need `TENANT_CREDENTIALS_KEY`/`SALT`, and
  users' sessions need `JWT_SECRET`. Back up `.env` with the database backups (in a password manager or encrypted, never in git).

## Backups

The `db-backup` service takes a backup **at start and then every `BACKUP_INTERVAL_HOURS` (24 h)**: one gzip file per run,
`sprintmodus-<UTC timestamp>.sql.gz`, holding `master_db` and every `tenant_*` database (never MySQL's own schemas, so a restore
cannot touch the root account). A file is written as `.partial` and renamed only after it has been verified, and files older than
`BACKUP_KEEP_DAYS` (14) are deleted. The container is unhealthy when the newest backup is older than one interval plus an hour.

```bash
scripts/restore.sh --list                          # what there is (a file of a few hundred bytes is an EMPTY database)
docker compose exec db-backup /usr/local/bin/backup.sh once     # a backup right now, e.g. before an upgrade
scripts/restore.sh sprintmodus-20260925T031500Z.sql.gz --yes    # restore that one (or `latest`, or a path to a file)
```

`restore.sh` stops the application (the database stays up), loads the dump, starts everything again (the migrator brings an old
dump up to the current schema) and refuses to run without `--yes`. **It replaces the data with the backup's version**, so
whatever was written since is lost, and tenants that are not in the file are left alone.

Tested end to end: with the data volume **deleted**, the stack came up empty, `restore.sh <backup>` brought the organization, its
project and work items back, and login worked again. Also tested: a backup never replaces the history with an empty one (if the
database has no tenant but backups exist, it refuses; the health check then flags the stale backup after one interval), and a dump
restores into a fresh MySQL.

**A backup on the same disk dies with the disk.** Put the backups where they can be copied off the machine, and copy them:

```bash
# in .env: BACKUP_DIR=/srv/sprintmodus/backups   (a host path instead of the Docker volume)
# then, from cron or a timer on the host, to anywhere else (another machine, object storage...), for example:
rsync -a --delete-after /srv/sprintmodus/backups/ backup-user@other-host:/srv/sprintmodus-backups/
```

That copy is an example, not something this repo runs. **Do a test restore now and then** into a scratch machine: a backup nobody
has restored is a hope, not a backup.

## Production on sprintmodus.com

`compose.prod.yaml` adds **Caddy**, the only thing that listens on the public interface: it gets and renews the Let's Encrypt
certificate by itself, redirects `http` to `https` and `www.sprintmodus.com` to `sprintmodus.com`, sends `Strict-Transport-Security`
(one year, this host only) and forwards everything, WebSocket included, to the frontend. The frontend, gateway and database are not
published.

**On the machine** (Linux with Docker Engine and Compose v2.24+; the containers' memory limits add up to about 6 GB, so plan for
8 GB of RAM):

1. **DNS** at wherever the domain is managed: an `A` record `sprintmodus.com` (and `AAAA` if the machine has IPv6) with the
   machine's public address, and `www` as a `CNAME` to `sprintmodus.com` (or the same `A`). Check with
   `dig +short sprintmodus.com www.sprintmodus.com` before continuing: Let's Encrypt must reach this machine by that name.
2. **Firewall:** allow inbound `80/tcp` (certificate challenge and redirect), `443/tcp` and `443/udp` (HTTP/3), and SSH. Nothing else
   needs to be reachable; Docker publishes only Caddy.
3. **`.env`** (`chmod 600 .env`): the secrets, the image tags, and

   ```
   PUBLIC_ORIGIN=https://sprintmodus.com
   DOMAIN=sprintmodus.com
   ACME_EMAIL=you@example.com
   ```

   `PUBLIC_ORIGIN` is exactly what the browser shows, with `https://` and no trailing slash: it is the only origin the board
   WebSocket and the gateway accept.
4. **Start:**

   ```bash
   docker login ghcr.io
   export COMPOSE_FILE=compose.yaml:compose.prod.yaml     # or pass both -f every time
   docker compose up -d --wait
   ```

   The first request to `https://sprintmodus.com` makes Caddy obtain the certificate (a few seconds). Watch it with
   `docker compose logs -f caddy`.
5. **Dry run first (recommended):** set `ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory`, start, confirm Caddy
   obtains a certificate (browsers will distrust it, that is expected), then remove the line, `docker compose down caddy`,
   `docker volume rm <project>_caddy-data` and start again. Production Let's Encrypt allows only a handful of failed attempts per
   hour and limits certificates per domain per week, so a typo in DNS is cheap on staging and annoying on production.
6. **Check:** `curl -I https://sprintmodus.com` (HTTP 200 and `strict-transport-security`), `curl -I http://sprintmodus.com`
   (a redirect), and `BASE_URL=https://sprintmodus.com scripts/smoke.sh --no-up` (leaves a test organization behind).

The certificates live in the volume `caddy-data` and **must persist**: without it every restart requests new ones and Let's
Encrypt's rate limits leave the site without HTTPS until they lift. Tested: recreating the Caddy container serves the same
certificate and requests none. Caddy's error log never contains the WebSocket token (the `token` parameter is replaced by
`REDACTED`; tested by forcing a proxy error).

**Upgrading:** change the tags in `.env`, then `docker compose pull && docker compose up -d --wait` (the migrator runs first). Take a
backup right before (`backup.sh once`).

**Not covered here:** monitoring and alerts (watch the health of the containers, disk space and the age of the newest backup),
off-site backups (see above), high availability, and email from the domain (there is no SMTP yet; when there is, SPF/DKIM/DMARC
records for sprintmodus.com will be needed).

## Operations

- **Logs** go to stdout (`docker compose logs -f <service>`), rotated at 3 × 10 MB. The board WebSocket URL carries the token in
  its query string, so nginx logs `$uri` (never the query) and only critical errors for `/ws`.
- **Health:** every image has a `HEALTHCHECK` on `/actuator/health/liveness` (nginx: `/healthz`). Only the `health` endpoint is
  exposed by the services, without details.
- **Shutdown:** `docker compose stop` sends SIGTERM; the services finish in-flight requests (up to 20 s, `stop_grace_period` 30 s).
- **Resource limits** are set per container (`deploy.resources.limits.memory`); JVMs use 75 % of their container's memory.

## Moving from the old skeleton

Until Phase 13 the MySQL container came from `sprintmodus-ng/docker-compose.yml` (project `sprintmodus`, container
`sprintmodus-master-db`, volume `sprintmodus_master-db-data`). This repo uses the same project name and volume, so `docker compose
up master-db` here keeps your data, **but MySQL only reads the root password when it creates the volume**: set
`MASTER_DB_ROOT_PASSWORD` to the value the volume was created with (the old skeleton's default was `password`). The old container and its fixed-name network stay behind, stopped:
`docker rm sprintmodus-master-db && docker network rm sprintmodus-net`.
