#!/bin/bash
DATA_PATH_ROOT="$(pwd)/data"

mongod --dbpath="${DATA_PATH_ROOT}/node1/" \
       --logpath="${DATA_PATH_ROOT}/node1/mongod.log" \
       --port=27017 \
       --replSet=demo \
       --auth \
       --keyFile="$DATA_PATH_ROOT/keyfile" \
       --pidfilepath="${DATA_PATH_ROOT}/node1/mongod.pid" \
       --wiredTigerCacheSizeGB=1 \
       --setParameter searchIndexManagementHostAndPort=localhost:27030 \
       --setParameter mongotHost=localhost:27030 \
       --setParameter skipAuthenticationToSearchIndexManagementServer=false \
       --setParameter useGrpcForSearch=true \
       --setParameter searchTLSMode=disabled \
       --fork

mongod --dbpath="${DATA_PATH_ROOT}/node2/" \
       --logpath="${DATA_PATH_ROOT}/node2/mongod.log" \
       --port=27018 \
       --replSet=demo \
       --auth \
       --keyFile="$DATA_PATH_ROOT/keyfile" \
       --pidfilepath="${DATA_PATH_ROOT}/node2/mongod.pid" \
       --wiredTigerCacheSizeGB=1 \
       --setParameter searchIndexManagementHostAndPort=localhost:27030 \
       --setParameter mongotHost=localhost:27030 \
       --setParameter skipAuthenticationToSearchIndexManagementServer=false \
       --setParameter useGrpcForSearch=true \
       --setParameter searchTLSMode=disabled \
       --fork

mongod --dbpath="${DATA_PATH_ROOT}/node3/" \
       --logpath="${DATA_PATH_ROOT}/node3/mongod.log" \
       --port=27019 \
       --replSet=demo \
       --auth \
       --keyFile="$DATA_PATH_ROOT/keyfile" \
       --pidfilepath="${DATA_PATH_ROOT}/node3/mongod.pid" \
       --setParameter searchIndexManagementHostAndPort=localhost:27030 \
       --setParameter mongotHost=localhost:27030 \
       --setParameter skipAuthenticationToSearchIndexManagementServer=false \
       --setParameter useGrpcForSearch=true \
       --setParameter searchTLSMode=disabled \
       --wiredTigerCacheSizeGB=1 \
       --fork