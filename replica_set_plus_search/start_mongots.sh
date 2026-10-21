#!/bin/bash
DATA_PATH_ROOT="$(pwd)/data"

# Create passwordfile
echo "searchpass" > "${DATA_PATH_ROOT}/mongot_passwordfile"
chmod 400 "${DATA_PATH_ROOT}/mongot_passwordfile"

../mongot-community/mongot --config ./mongot_configs/mongot_1.yaml & echo $! > "${DATA_PATH_ROOT}/mongot1/mongot.pid"
../mongot-community/mongot --config ./mongot_configs/mongot_2.yaml & echo $! > "${DATA_PATH_ROOT}/mongot2/mongot.pid"