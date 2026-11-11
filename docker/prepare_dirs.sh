#!/bin/bash
# Creates the data directory layout and the replica set keyfile.
#
# The repo's data/ directories are gitignored and no script creates them, so
# start_mongods.sh fails on a fresh checkout without this. Safe to re-run:
# existing directories and an existing keyfile are left alone.
set -euo pipefail

TOPOLOGY="${1:-replica_set}"
PROJECT_DIR="${2:-$(pwd)}"
DATA_PATH_ROOT="${PROJECT_DIR}/data"

case "$TOPOLOGY" in
  replica_set)
    DIRS=(node1 node2 node3 mongot1 mongot2)
    ;;
  sharded_cluster)
    DIRS=(
      shard1/node1 shard1/node2 shard1/node3 shard1/mongot1 shard1/mongot2
      shard2/node1 shard2/node2 shard2/node3 shard2/mongot1 shard2/mongot2
      mongos
    )
    ;;
  *)
    echo "Unknown topology: $TOPOLOGY (expected replica_set or sharded_cluster)" >&2
    exit 1
    ;;
esac

for d in "${DIRS[@]}"; do
  mkdir -p "${DATA_PATH_ROOT}/${d}"
done

# mongod --keyFile requires a shared secret readable only by its owner.
if [[ ! -f "${DATA_PATH_ROOT}/keyfile" ]]; then
  openssl rand -base64 756 > "${DATA_PATH_ROOT}/keyfile"
  echo "Created ${DATA_PATH_ROOT}/keyfile"
fi
chmod 400 "${DATA_PATH_ROOT}/keyfile"

echo "Data layout ready under ${DATA_PATH_ROOT} (topology: ${TOPOLOGY})"
