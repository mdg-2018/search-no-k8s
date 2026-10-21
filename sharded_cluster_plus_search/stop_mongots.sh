#!/bin/bash
DATA_PATH_ROOT="$(pwd)/data"

# Shard 1
kill -9 $(cat "${DATA_PATH_ROOT}/shard1/mongot1/mongot.pid")
kill -9 $(cat "${DATA_PATH_ROOT}/shard1/mongot2/mongot.pid")

# Shard 2
kill -9 $(cat "${DATA_PATH_ROOT}/shard2/mongot1/mongot.pid")
kill -9 $(cat "${DATA_PATH_ROOT}/shard2/mongot2/mongot.pid")

sleep 10

rm "${DATA_PATH_ROOT}/shard1/mongot1/mongot.pid"
rm "${DATA_PATH_ROOT}/shard1/mongot2/mongot.pid"
rm "${DATA_PATH_ROOT}/shard2/mongot1/mongot.pid"
rm "${DATA_PATH_ROOT}/shard2/mongot2/mongot.pid"

# Remove password file
rm -f "${DATA_PATH_ROOT}/mongot_passwordfile"