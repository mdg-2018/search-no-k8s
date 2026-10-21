#!/bin/bash
DATA_PATH_ROOT="$(pwd)/data"

kill $(cat "${DATA_PATH_ROOT}/haproxy.pid")
rm "${DATA_PATH_ROOT}/haproxy.pid"