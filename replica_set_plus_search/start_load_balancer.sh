#!/bin/bash

DATA_PATH_ROOT="$(pwd)/data"

haproxy -f ./load_balancer/haproxy.cfg & echo $! > "${DATA_PATH_ROOT}/haproxy.pid"