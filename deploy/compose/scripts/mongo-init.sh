#!/bin/bash
# mongo-init.sh - the `mongo-init` service of the compose bundle.
#
# The API needs MongoDB as a replica set (rs0, one member). Same set-up as
# deploy/docker/mongo_scripts/mongosetup.sh, but idempotent and without the
# fixed 30 s sleep: wait for mongod, initiate only when the set has no
# config yet, then wait until the member is PRIMARY.
set -euo pipefail

HOST="${MONGO_HOST:-mongo:27017}"
mq() { mongosh --host "$HOST" --quiet --eval "$1"; }

for i in $(seq 1 90); do
  [ "$(mq 'db.adminCommand({ ping: 1 }).ok' 2>/dev/null || true)" = "1" ] && break
  [ "$i" = 90 ] && { echo "[mongo-init] mongod at $HOST did not answer within 3 minutes" >&2; exit 1; }
  sleep 2
done

state="$(mq 'try { rs.status().ok } catch (e) { e.codeName }' 2>/dev/null || true)"
if [ "$state" = "1" ]; then
  echo "[mongo-init] replica set rs0 already initiated"
elif [ "$state" = "InvalidReplicaSetConfig" ]; then
  # The set exists but this mongod is not in it: the member's host name no
  # longer resolves to it (a renamed service, an older layout). Keep the set,
  # point its single member at $HOST.
  echo "[mongo-init] replica set rs0 names another host; reconfiguring its member as $HOST"
  mq "const c = rs.conf(); c.members[0].host = '$HOST'; rs.reconfig(c, { force: true }).ok"
else
  echo "[mongo-init] initiating replica set rs0 ($state)"
  # Tolerate a concurrent initiate (two pods starting at once): the loser
  # sees AlreadyInitialized and simply waits for PRIMARY below.
  mq "try { rs.initiate({ _id: 'rs0', members: [{ _id: 0, host: '$HOST' }] }).ok } catch (e) { e.codeName }"
fi

for i in $(seq 1 60); do
  [ "$(mq 'db.hello().isWritablePrimary' 2>/dev/null || true)" = "true" ] && { echo "[mongo-init] rs0 PRIMARY"; exit 0; }
  sleep 2
done
echo "[mongo-init] rs0 did not elect a PRIMARY within 2 minutes" >&2
exit 1
