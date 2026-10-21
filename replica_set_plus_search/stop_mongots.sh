#!/bin/bash
DATA_PATH_ROOT="$(pwd)/data"

kill $(cat "${DATA_PATH_ROOT}/mongot1/mongot.pid")
rm "${DATA_PATH_ROOT}/mongot1/mongot.pid"
kill $(cat "${DATA_PATH_ROOT}/mongot2/mongot.pid")
rm "${DATA_PATH_ROOT}/mongot2/mongot.pid"