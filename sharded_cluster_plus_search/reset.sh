#!/bin/bash
DATA_PATH_ROOT="$(pwd)/data"

$(bash ./stop_mongods.sh)
$(bash ./stop_mongots.sh)

rm -rf "$DATA_PATH_ROOT"/shard1/node1/*
rm -rf "$DATA_PATH_ROOT"/shard1/node2/*
rm -rf "$DATA_PATH_ROOT"/shard1/node3/*
rm -rf "$DATA_PATH_ROOT"/shard1/mongot1/*
rm -rf "$DATA_PATH_ROOT"/shard2/mongot2/*

rm -rf "$DATA_PATH_ROOT"/shard2/node1/*
rm -rf "$DATA_PATH_ROOT"/shard2/node2/*
rm -rf "$DATA_PATH_ROOT"/shard2/node3/*
rm -rf "$DATA_PATH_ROOT"/shard2/mongot2/*
rm -rf "$DATA_PATH_ROOT"/shard2/mongot2/*


rm -rf "$DATA_PATH_ROOT"/mongot_passwordfile