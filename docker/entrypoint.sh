#!/bin/bash
# Brings up the whole stack in dependency order and then stays in the
# foreground tailing logs, so `docker logs -f` shows what the cluster is doing.
set -euo pipefail

TOPOLOGY="${TOPOLOGY:-replica_set}"

case "$TOPOLOGY" in
  replica_set)     PROJECT_DIR=/opt/search-no-k8s/replica_set_plus_search ;;
  sharded_cluster) PROJECT_DIR=/opt/search-no-k8s/sharded_cluster_plus_search ;;
  *) echo "Unknown TOPOLOGY: $TOPOLOGY (expected replica_set or sharded_cluster)" >&2; exit 1 ;;
esac

# Every script in this repo uses paths relative to its own project directory.
cd "$PROJECT_DIR"
DATA_PATH_ROOT="${PROJECT_DIR}/data"
INIT_MARKER="${DATA_PATH_ROOT}/.initialized"

log() { echo "[entrypoint] $*"; }

wait_for_mongod() {
  local port="$1" label="$2" tries=0
  log "Waiting for ${label} on port ${port}..."
  # ping does not require authentication, so this works before users exist.
  until mongosh --quiet --port "$port" --eval 'db.adminCommand({ping:1})' >/dev/null 2>&1; do
    tries=$((tries + 1))
    if (( tries > 120 )); then
      log "ERROR: ${label} on port ${port} did not come up in 120s"
      return 1
    fi
    sleep 1
  done
  log "${label} on port ${port} is up"
}

shutdown() {
  log "Shutting down..."
  bash ./stop_load_balancer.sh >/dev/null 2>&1 || true
  bash ./stop_mongots.sh       >/dev/null 2>&1 || true
  bash ./stop_mongods.sh       >/dev/null 2>&1 || true
  exit 0
}
trap shutdown SIGTERM SIGINT

/opt/search-no-k8s/docker/prepare_dirs.sh "$TOPOLOGY" "$PROJECT_DIR"

log "Starting mongods (topology: ${TOPOLOGY})..."
bash ./start_mongods.sh

wait_for_mongod 27017 "mongod"
if [[ "$TOPOLOGY" == "sharded_cluster" ]]; then
  wait_for_mongod 27007 "shard 2 mongod"
fi

# setup_mongod.sh initiates the replica set and creates users; running it twice
# fails, so it is gated on a marker written into the (possibly mounted) data dir.
if [[ -f "$INIT_MARKER" ]]; then
  log "Already initialized (${INIT_MARKER} exists), skipping setup_mongod.sh"
else
  log "First run: initiating replica set and creating users..."
  bash ./setup_mongod.sh
  touch "$INIT_MARKER"
  log "Initialization complete (admin/password, mongotUser/searchpass)"
fi

# mongos only finishes starting once the config server replica set exists, so
# it can only be waited on after setup_mongod.sh has initiated it.
if [[ "$TOPOLOGY" == "sharded_cluster" ]]; then
  wait_for_mongod 27020 "mongos"
fi

log "Starting mongots..."
bash ./start_mongots.sh
sleep 5

log "Starting haproxy load balancer(s)..."
bash ./start_load_balancer.sh
sleep 2

log "Stack is up. Connect with:"
log "  mongosh 'mongodb://admin:password@localhost:27017/?directConnection=true'"
if [[ "$TOPOLOGY" == "sharded_cluster" ]]; then
  log "  mongosh 'mongodb://admin:password@localhost:27020/'   # via mongos"
fi

# Keep PID 1 alive and surface mongod logs (mongod --fork detaches).
tail -F $(find "$DATA_PATH_ROOT" -name 'mongod.log' -o -name 'mongos.log' 2>/dev/null) &
wait
