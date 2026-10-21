#!/bin/bash
DATA_PATH_ROOT="$(pwd)/data"

$(bash ./stop_mongods.sh)
$(bash ./stop_mongots.sh)

rm -rf "$DATA_PATH_ROOT"/node1/*
rm -rf "$DATA_PATH_ROOT"/node2/*
rm -rf "$DATA_PATH_ROOT"/node3/*
rm -rf "$DATA_PATH_ROOT"/mongot1/*
rm -rf "$DATA_PATH_ROOT"/mongot2/*
rm -rf "$DATA_PATH_ROOT"/mongot_passwordfile