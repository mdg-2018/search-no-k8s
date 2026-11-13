#!/bin/bash
# Brings up mongod and mongot in one container, in the order they need.
#
# Ordering matters and is the one genuinely fiddly part of this setup:
#   1. mongod starts, already pointing at mongot's address. mongot does not
#      have to exist yet - mongod only tries to reach it when a search index
#      or query is issued. The search setParameters are startup-only, so they
#      cannot be added later without a restart.
#   2. The replica set is initiated and mongotUser is created.
#   3. mongot starts and authenticates to mongod as mongotUser.
set -euo pipefail

DATA="${DATA_DIR:-/data}"
RS="${REPL_SET:-rs0}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-password}"
MONGOT_USER="${MONGOT_USER:-mongotUser}"
MONGOT_PASS="${MONGOT_PASS:-searchpass}"

log() { echo ">>> $*"; }

mkdir -p "$DATA/mongod" "$DATA/mongot"

# Internal cluster auth. Required as soon as --auth and --replSet are combined,
# even for a single-member set.
if [ ! -f "$DATA/keyfile" ]; then
    openssl rand -base64 756 > "$DATA/keyfile"
fi
chmod 400 "$DATA/keyfile"

# mongot reads its SCRAM password from a file, never from the config or argv.
echo "$MONGOT_PASS" > "$DATA/mongot.pwd"
chmod 400 "$DATA/mongot.pwd"

log "starting mongod (search parameters are set here, at startup)"
mongod \
    --dbpath "$DATA/mongod" \
    --port 27017 \
    --bind_ip_all \
    --replSet "$RS" \
    --auth \
    --keyFile "$DATA/keyfile" \
    --wiredTigerCacheSizeGB 0.5 \
    --setParameter mongotHost=127.0.0.1:27028 \
    --setParameter searchIndexManagementHostAndPort=127.0.0.1:27028 \
    --setParameter skipAuthenticationToSearchIndexManagementServer=false \
    --setParameter useGrpcForSearch=true \
    --setParameter searchTLSMode=disabled &

log "waiting for mongod to accept connections"
for _ in $(seq 1 90); do
    if mongosh --quiet --port 27017 --eval 'db.adminCommand({ping:1})' >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
mongosh --quiet --port 27017 --eval 'db.adminCommand({ping:1})' >/dev/null

if [ ! -f "$DATA/.initialized" ]; then
    log "initiating replica set '$RS'"
    # 'localhost' here, not 127.0.0.1, so that the member name a client
    # discovers also resolves correctly on your laptop through the published
    # port mapping.
    mongosh --quiet --port 27017 --eval \
        "rs.initiate({_id:'$RS', members:[{_id:0, host:'localhost:27017'}]})" >/dev/null

    log "waiting for this node to become primary"
    for _ in $(seq 1 60); do
        if mongosh --quiet --port 27017 --eval 'db.hello().isWritablePrimary' 2>/dev/null | grep -q true; then
            break
        fi
        sleep 1
    done

    # Created through the localhost exception, which applies only while no
    # user exists anywhere in the deployment.
    log "creating $ADMIN_USER (root)"
    mongosh --quiet --port 27017 --eval \
        "db.getSiblingDB('admin').createUser({user:'$ADMIN_USER', pwd:'$ADMIN_PASS', roles:[{role:'root', db:'admin'}]})" >/dev/null

    log "creating $MONGOT_USER (searchCoordinator)"
    mongosh --quiet --port 27017 -u "$ADMIN_USER" -p "$ADMIN_PASS" --authenticationDatabase admin --eval \
        "db.getSiblingDB('admin').createUser({user:'$MONGOT_USER', pwd:'$MONGOT_PASS', roles:[{role:'searchCoordinator', db:'admin'}]})" >/dev/null

    touch "$DATA/.initialized"
else
    log "existing data found, skipping replica set and user setup"
fi

log "starting mongot"
/opt/mongot/mongot --config /etc/mongot.yaml &

log "waiting for mongot health check"
for _ in $(seq 1 90); do
    if curl -fsS http://127.0.0.1:8080/health >/dev/null 2>&1; then
        log "mongot is healthy"
        break
    fi
    sleep 1
done

log "ready:  mongosh 'mongodb://$ADMIN_USER:$ADMIN_PASS@localhost:27017/?directConnection=true'"

# Exit the container if either process dies, rather than sitting there half up.
wait -n
log "a process exited, shutting down"
exit 1
