#!/bin/bash
DATA_PATH_ROOT="$(pwd)/data"

kill "$(cat "${DATA_PATH_ROOT}/shard1/node1/mongod.pid")"
kill "$(cat "${DATA_PATH_ROOT}/shard1/node2/mongod.pid")"
kill "$(cat "${DATA_PATH_ROOT}/shard1/node3/mongod.pid")"

kill "$(cat "${DATA_PATH_ROOT}/shard2/node1/mongod.pid")"
kill "$(cat "${DATA_PATH_ROOT}/shard2/node2/mongod.pid")"
kill "$(cat "${DATA_PATH_ROOT}/shard2/node3/mongod.pid")"

kill "$(cat "${DATA_PATH_ROOT}/mongos/mongos.pid")"