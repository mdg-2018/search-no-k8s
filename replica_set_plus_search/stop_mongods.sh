#!/bin/bash
DATA_PATH_ROOT="$(pwd)/data"

kill "$(cat "${DATA_PATH_ROOT}/node1/mongod.pid")"
kill "$(cat "${DATA_PATH_ROOT}/node2/mongod.pid")"
kill "$(cat "${DATA_PATH_ROOT}/node3/mongod.pid")"