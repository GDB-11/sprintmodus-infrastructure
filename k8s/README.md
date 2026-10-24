# Sprintmodus on k3s (single node)

Kubernetes manifests for the same stack as `compose.yaml`, sized for a **4 GB / 2 vCPU** server (Hetzner CX23, Debian 13). One
node, one replica of everything, `workitem-service` always exactly one (its WebSocket broker is in memory). Meant for a PoC; the
production recipe for a single machine is still `compose.prod.yaml`.

| Compose | Here |
|---|---|
| `master-db` + volume | StatefulSet + 10 Gi `local-path` PVC |
| `db-backup` | CronJob (same `scripts/backup.sh`), 03:15, 7 days kept, 5 Gi PVC |
| `migrator` | Job, run and awaited before the services start |
| Caddy (HTTPS, www redirect, HSTS) | k3s's bundled Traefik + its own Let's Encrypt resolver (no cert-manager: 3 pods less) |
| `.env` secrets | Secret `sprintmodus-secrets`, generated once by `deploy.sh` |
| image tags in `.env` | `images:` in `kustomization.yaml` |

Eureka stays (the gateway routes with `lb://`); services register by **pod IP** (`EUREKA_INSTANCE_PREFER_IP_ADDRESS`) because a pod's
hostname does not resolve for the others the way a container's does in Docker.

## 1. Server (once, as root on the fresh Debian 13)

```bash
apt update && apt full-upgrade -y && apt install -y curl ca-certificates ufw fail2ban unattended-upgrades
adduser --disabled-password --gecos "" deploy && usermod -aG sudo deploy
mkdir -p /home/deploy/.ssh && cp ~/.ssh/authorized_keys /home/deploy/.ssh/ && chown -R deploy:deploy /home/deploy/.ssh && chmod 700 /home/deploy/.ssh
# check `ssh deploy@<ip>` works in a second terminal, THEN disable password and root login in /etc/ssh/sshd_config and `systemctl restart ssh`
fallocate -l 3G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab && echo 'vm.swappiness=10' > /etc/sysctl.d/99-swap.conf && sysctl --system
ufw default deny incoming && ufw default allow outgoing
ufw allow 22/tcp && ufw allow 80/tcp && ufw allow 443/tcp && ufw enable
curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
kubectl get nodes          # Ready
```

Swap note: pods do not use host swap by default (cgroup v2), so swap only protects the host processes; the memory **limits** below
are what keep the node alive.

Do not open 6443 to the internet; use an SSH tunnel for remote `kubectl`.

## 2. DNS (Porkbun)

`A` records for `@` and `www` to the server's IPv4, TTL 600. Check with `dig +short sprintmodus.com` before deploying, or Let's
Encrypt's challenge fails.

## 3. Deploy

On the server, with this repo checked out (the images are public on GHCR, no pull secret):

```bash
cd k8s
# Dry run first: a staging certificate (browsers distrust it) does not use up Let's Encrypt's production rate limit
ACME_EMAIL=you@example.com ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory ./deploy.sh
# then the real one: see "Switching from the staging certificate to the real one" below (do NOT restart Traefik to do it)
ACME_EMAIL=you@example.com ./deploy.sh
```

`deploy.sh` is re-runnable and is also the upgrade path (edit the tags in `kustomization.yaml`, run it again). It applies in waves
(MySQL → migrations → Eureka → services → edge) and stops if the migration fails. First start takes several minutes on 2 vCPU.

**Back up the secrets off the server right away** (the script prints the command): without `TENANT_CREDENTIALS_KEY`/`SALT` the tenant
credentials stored in the database cannot be decrypted.

## 4. Check

```bash
kubectl -n sprintmodus get pods                 # all Running / Ready; migrator Completed
kubectl -n sprintmodus top pods; free -m        # real memory: tune the limits from this
curl -I https://sprintmodus.com                 # 200, valid certificate
```

Then register an organization in the browser. The seed script (`scripts/seed.sh`) is compose-oriented; for the PoC use the UI.

## Data safety (read before deleting anything)

- All data is on the node's disk (`/var/lib/rancher/k3s/storage`). **Deleting the server, the namespace or the PVCs deletes it.**
- The CronJob dumps to a PVC on the *same* disk. To get a dump off the box, run a one-off backup and copy it with `scp`:
  `kubectl -n sprintmodus create job --from=cronjob/db-backup bk-now`, then read the file from the PVC's directory under
  `/var/lib/rancher/k3s/storage/*db-backups*/` (as root) and `scp` it to your PC.
- A Hetzner snapshot of the server before deleting it also keeps everything (billed per GB, cheap).
- To tear the PoC down: delete the Hetzner server (stopping it is still billed).

## Tuning and caveats

- JVMs run with `-XX:MaxRAMPercentage=55 -XX:+UseSerialGC -XX:TieredStopAtLevel=1` (the image's own entrypoint uses 75, which gets
  OOM-killed under these limits, so `command` is overridden). MySQL: 256 MB buffer pool, performance schema off, 100 connections.
  Limits are a first estimate: watch `kubectl top` and raise a limit (and `MaxRAMPercentage`) if a pod restarts with `OOMKilled`.
- Not exercised against a real cluster when written: `kubectl kustomize`/`apply` were not run. Traefik objects assume k3s's Traefik v3
  (`traefik.io/v1alpha1`); on an older k3s with Traefik v2 change the apiVersion to `traefik.containo.us/v1alpha1`.
- `traefik-config.yaml` keeps certificates on a 128 Mi PVC; its access log stays off on purpose (the WebSocket URL carries `?token=`).

## Switching from the staging certificate to the real one

Verified on the PoC server. Traefik asks Let's Encrypt for a certificate **when it loads an Ingress**, and a failed attempt is
only retried when the router configuration changes again. If Traefik is restarted for the switch, it asks during startup, before
its HTTP challenge route and port 80 are ready, and Let's Encrypt gets a `404` or `Connection refused` (each failure counts toward
5 per hostname per hour). So:

```bash
cd ~/sprintmodus-infrastructure/k8s
ACME_EMAIL=you@example.com ./deploy.sh                                    # no ACME_CA: production
kubectl -n kube-system exec deploy/traefik -- rm -f /data/acme.json       # forget the staging account and certificate
kubectl -n kube-system scale deploy/traefik --replicas=0                  # one Traefik pod, no overlap
kubectl -n kube-system scale deploy/traefik --replicas=1
kubectl -n kube-system rollout status deploy/traefik
# wait until its log shows no "does not exist" errors for a minute, and `curl -I http://<domain>` answers 308, THEN recreate
# the edge so Traefik sees the Ingress objects while it is fully up:
kubectl -n sprintmodus delete ingress app www-to-apex http-to-https
kubectl kustomize . | sed "s#__DOMAIN__#sprintmodus.com#g" | kubectl apply -f - -l phase=5-edge
kubectl -n kube-system logs deploy/traefik --since=3m | grep -iE 'acme|certificate'   # "Server responded with a certificate"
```

The issuer should then be `Let's Encrypt` (`R10`, `E5`, `YR1`...), without "STAGING": `curl -v https://<domain> 2>&1 | grep -i issuer`.
