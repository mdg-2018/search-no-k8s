#!/bin/bash

DATA_PATH_ROOT="$(pwd)/data"

haproxy -f ./load_balancer/haproxy_shard_1.cfg & echo $! > "${DATA_PATH_ROOT}/haproxy_shard_1.pid"
haproxy -f ./load_balancer/haproxy_shard_2.cfg & echo $! > "${DATA_PATH_ROOT}/haproxy_shard_2.pid"
