#!/bin/bash
DATA_PATH_ROOT="$(pwd)/data"

# Create passwordfile
echo "searchpass" > "${DATA_PATH_ROOT}/mongot_passwordfile"
chmod 400 "${DATA_PATH_ROOT}/mongot_passwordfile"

../mongot-community/mongot --config ./mongot_configs/mongot_1.yaml &> "${DATA_PATH_ROOT}/shard1/mongot1/mongot.log" & echo $! > "${DATA_PATH_ROOT}/shard1/mongot1/mongot.pid"
../mongot-community/mongot --config ./mongot_configs/mongot_2.yaml &> "${DATA_PATH_ROOT}/shard1/mongot2/mongot.log" & echo $! > "${DATA_PATH_ROOT}/shard1/mongot2/mongot.pid"
../mongot-community/mongot --config ./mongot_configs/mongot_3.yaml &> "${DATA_PATH_ROOT}/shard2/mongot1/mongot.log" & echo $! > "${DATA_PATH_ROOT}/shard2/mongot1/mongot.pid"
../mongot-community/mongot --config ./mongot_configs/mongot_4.yaml &> "${DATA_PATH_ROOT}/shard2/mongot2/mongot.log" & echo $! > "${DATA_PATH_ROOT}/shard2/mongot2/mongot.pid"