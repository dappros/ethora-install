# Migrating an install to the clean path layout

Short guide for moving an existing Ethora install (local dev, staging, a customer
box, anything) onto the path layout the deploy now expects. Applies to any install
created before this layout landed, including in-place ones.

Budget 10 minutes plus the time your services take to restart. The data move
itself is a `mv` on the same filesystem, so it is near-instant regardless of size.

## The layout

Three directories, each with exactly one job:

| Dir | Default | What lives there | Lifetime |
|---|---|---|---|
| `SRC_DIR` | wherever you cloned/unpacked, e.g. `~/ethora-install-shared` | the git distribution you run `install.sh` / `update.sh` from | disposable, overwritten on every update |
| `TARGET_DIR` | `$HOME/ethora` | the live install: code, builds, rendered config, what PM2 and nginx serve | rebuilt by deploys |
| `DATA_DIR` | `$HOME/ethora-data` | all persistent data: `mongo`, `minio`, `mysql`, `redis` | never touched by a deploy |

The rule that matters: **data lives outside both trees.** The source tree is git
managed and gets reset; the target tree is rsynced over. Anything stateful sitting
in either is one `git clean` or one prune away from being gone, and a deploy that
re-derives a data path can silently bring a database up on the wrong copy.

The deploy enforces this now. `deploy/scripts/preflight-paths.sh` runs first on
every install and update and refuses to continue when:

1. `SRC_DIR == TARGET_DIR` (in-place installs are no longer allowed),
2. a data dir resolves inside `SRC_DIR`,
3. the configured data dir is empty but a copy exists at a known legacy path,
4. `BACKEND_DIR` / `FRONTEND_DIR` / `EJABBERD_DIR` / etc. still point inside `SRC_DIR`.

If your install predates this, expect your next deploy to stop with one of those
messages. That is the signal to run this migration.

## 1. See where you stand

```bash
cd <your SRC_DIR>
set -a; source deploy/.deploy.env; set +a
SRC_DIR="$PWD" TARGET_DIR="$ROOT_DIR" bash deploy/scripts/preflight-paths.sh --yes
```

It prints the resolved plan and either passes or tells you exactly what is wrong.
Cross-check against what the containers actually mount, which is the ground truth:

```bash
for c in deploy-mongo-1 deploy-minio-1 deploy-mysql-1 deploy-redis-server-1; do
  echo "$c: $(docker inspect $c --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}} {{end}}{{end}}')"
done
```

Then look for copies you did not know about. Installs have accumulated data at
several historical paths, and more than one may be non-empty:

```bash
sudo du -sh \
  "$SRC_DIR"/{,deploy/}ethora-backend/{infra/,}docker/data/* \
  "$SRC_DIR"/{,deploy/}ejabberd-docker/docker-data/* \
  "$ROOT_DIR"/{,deploy/}ethora-backend/{infra/,}docker/data/* \
  "$ROOT_DIR"/{,deploy/}ejabberd-docker/docker-data/* \
  "$ROOT_DIR"/data/* "$HOME"/ethora-data/* 2>/dev/null
```

**Do this per service, not once.** Mongo, MinIO, MySQL and Redis are resolved
independently, so one service can be on the right copy while another is on a stale
one, and the mistake can point in different directions for different services.
When two copies exist, the live one is whatever the container currently mounts.
Confirm with row counts (see step 5) before you trust file sizes or timestamps.

## 2. Back up

Cheap, and the only thing that makes the rest low-risk:

```bash
B=~/backups; mkdir -p $B; TS=$(date +%Y%m%d-%H%M%S)
DB=$(yq eval '.databases.mongo.database' deploy/config/deploy.yml)

docker exec deploy-mongo-1 sh -c "mongodump --archive --gzip --db=$DB" > $B/mongo-$DB-$TS.archive.gz
docker exec deploy-mysql-1 sh -c 'mysqldump -uroot -p$MYSQL_ROOT_PASSWORD --single-transaction --routines ejabberd_db' | gzip > $B/mysql-ejabberd_db-$TS.sql.gz
```

On a cloud host, take a volume snapshot too. It is the only backup that also
covers MinIO objects.

## 3. Stop everything that writes

```bash
pm2 stop all
cd "$SRC_DIR/deploy"
set -a; source .deploy.env; set +a
docker compose -f docker-compose.enterprise.yml stop xmpp mysql mongo minio redis-server
```

Stop `xmpp` as well: ejabberd writes to MySQL.

## 4. Move the data

Substitute the paths your own inventory found on the left:

```bash
DATA="$HOME/ethora-data"; mkdir -p "$DATA"
sudo mv <current mongo path> "$DATA/mongo"
sudo mv <current minio path> "$DATA/minio"
sudo mv <current mysql path> "$DATA/mysql"      # note: dir is often named my-sql
sudo mv <current redis path> "$DATA/redis"
```

Use `mv`, not `cp`, when the destination is on the same filesystem: it is atomic
and instant. If it is a different filesystem, `rsync -a --info=progress2` then
verify before removing the source.

Leftover copies go somewhere obvious rather than straight to `rm`:

```bash
mkdir -p ~/to-delete && sudo mv <stale copy> ~/to-delete/<service>-stale-$(date +%Y%m%d)
```

Named volumes (ai-postgres, uptime-db, ejabberd's own volume) need nothing. They
already live under `/var/lib/docker/volumes` and were never in either tree.

## 5. Repoint, restart, verify

```bash
ENVF="$SRC_DIR/deploy/.deploy.env"
cp -a "$ENVF" "$ENVF.bak.$(date +%Y%m%d-%H%M%S)"
```

Set these in `.deploy.env` (add them if absent). Explicit values win over anything
the deploy would derive, which is the point:

```bash
export DATA_DIR="/home/<user>/ethora-data"
export MONGO_DATA_DIR="$DATA_DIR/mongo"
export MINIO_DATA_DIR="$DATA_DIR/minio"
export MYSQL_DATA_DIR="$DATA_DIR/mysql"
export REDIS_DATA_DIR="$DATA_DIR/redis"
```

While you are in there, make sure the component dirs follow `TARGET_DIR` and not
`SRC_DIR`. This is what decides what actually gets built, run under PM2 and served:

```bash
export ROOT_DIR="/home/<user>/ethora"
export BACKEND_DIR="$ROOT_DIR/ethora-backend"
export FRONTEND_DIR="$ROOT_DIR/ethora-app-reactjs"
export EJABBERD_DIR="$ROOT_DIR/ejabberd-docker"
export PLAYGROUND_DIR="$ROOT_DIR/ethora-sdk-playground"
export UPTIME_DIR="$ROOT_DIR/ethora-uptime"
export WIDGET_DIR="$ROOT_DIR/ethora-ai-chat-widget"
```

Bring it back up and check the mounts moved with it:

```bash
cd "$SRC_DIR/deploy"; set -a; source .deploy.env; set +a
docker compose -f docker-compose.enterprise.yml up -d mongo minio redis-server mysql xmpp
pm2 start all
```

Verify against the numbers you noted before the move. Counts, not sizes:

```bash
docker exec deploy-mongo-1 mongosh --quiet "$DB" --eval \
  'print("apps="+db.apps.countDocuments({})+" users="+db.users.countDocuments({})+" chats="+db.chats.countDocuments({}))'
docker exec deploy-mysql-1 sh -c 'mysql -uroot -p$MYSQL_ROOT_PASSWORD -N -e \
  "select concat(\"archive=\",(select count(*) from ejabberd_db.archive),\" rooms=\",(select count(*) from ejabberd_db.muc_room))"'
```

Then re-run the preflight from step 1. A clean plan with every service marked
`existing` means you are done. Run a normal `update.sh` afterwards to confirm the
deploy honours the new paths: the old warning about stateful data nested under
submodule directory names should be gone for good.

## Alternative: let the script do it

`deploy/scripts/migrate-data-paths.sh` performs the same move (with `--dry-run` to
preview). It refuses when a service has data in more than one place, because
guessing which copy is live is exactly the failure this whole layout exists to
prevent. In that case consolidate by hand using the steps above.

## Local dev

Same model, smaller stakes. Clone into `~/ethora-install-shared`, let `paths.base`
default to `~/ethora`, and leave `DATA_DIR` alone so it lands in `~/ethora-data`.
The one thing to avoid is running the installer from the directory you install
into: in-place is refused, and that is deliberate.

To wipe local state and start clean, delete `~/ethora-data` (or run
`install.sh --reset` for the databases only). Because data is no longer inside
either tree, `git clean -fdx` in your checkout is now safe.

## Gotchas worth knowing

- **`sudo` git fetch.** Running `update.sh` under `sudo -E` can fail at the source
  fetch with `Permission denied (publickey)`, because root does not pick up your
  SSH key. Prefix with
  `GIT_SSH_COMMAND="ssh -i /home/<user>/.ssh/<key> -o IdentitiesOnly=yes"`.
- **Root-owned files in the checkout.** Earlier `sudo` runs leave root-owned files
  that block `git pull`. Fix with `sudo chown -R <user>:<user> <SRC_DIR>`. Now that
  data has left the tree, this is safe to run over the whole checkout.
- **Certificates.** nginx refuses its entire config if a single referenced
  certificate file is missing, so one un-issuable subdomain can take down every
  site on the box. `setup-ssl.sh` now writes a marked self-signed placeholder on
  failure so nginx still starts, and retries a real certificate on the next run.
  A placeholder means HTTPS for that host is untrusted until the real one lands.
- **Two backend path variants.** Older installs used
  `ethora-backend/docker/data/<svc>`, newer ones
  `ethora-backend/infra/docker/data/<svc>`. The preflight scans both, but keep it
  in mind when inventorying by hand.
