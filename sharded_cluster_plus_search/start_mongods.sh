#!/bin/bash
DATA_PATH_ROOT="$(pwd)/data"

# Shard 1

mongod --dbpath="${DATA_PATH_ROOT}/shard1/node1/" \
       --logpath="${DATA_PATH_ROOT}/shard1/node1/mongod.log" \
       --port=27017 \
       --replSet=demo \
       --configsvr \
       --auth \
       --keyFile="${DATA_PATH_ROOT}/keyfile" \
       --pidfilepath="${DATA_PATH_ROOT}/shard1/node1/mongod.pid" \
       --wiredTigerCacheSizeGB=1 \
       --setParameter searchIndexManagementHostAndPort=localhost:27030 \
       --setParameter mongotHost=localhost:27030 \
       --setParameter skipAuthenticationToSearchIndexManagementServer=false \
       --setParameter useGrpcForSearch=true \
       --setParameter searchTLSMode=disabled \
       --fork

mongod --dbpath="${DATA_PATH_ROOT}/shard1/node2/" \
       --logpath="${DATA_PATH_ROOT}/shard1/node2/mongod.log" \
       --port=27018 \
       --replSet=demo \
       --configsvr \
       --auth \
       --keyFile="${DATA_PATH_ROOT}/keyfile" \
       --pidfilepath="${DATA_PATH_ROOT}/shard1/node2/mongod.pid" \
       --wiredTigerCacheSizeGB=1 \
       --setParameter searchIndexManagementHostAndPort=localhost:27030 \
       --setParameter mongotHost=localhost:27030 \
       --setParameter skipAuthenticationToSearchIndexManagementServer=false \
       --setParameter useGrpcForSearch=true \
       --setParameter searchTLSMode=disabled \
       --fork

mongod --dbpath="${DATA_PATH_ROOT}/shard1/node3/" \
       --logpath="${DATA_PATH_ROOT}/shard1/node3/mongod.log" \
       --port=27019 \
       --replSet=demo \
       --configsvr \
       --auth \
       --keyFile="${DATA_PATH_ROOT}/keyfile" \
       --pidfilepath="${DATA_PATH_ROOT}/shard1/node3/mongod.pid" \
       --setParameter searchIndexManagementHostAndPort=localhost:27030 \
       --setParameter mongotHost=localhost:27030 \
       --setParameter skipAuthenticationToSearchIndexManagementServer=false \
       --setParameter useGrpcForSearch=true \
       --setParameter searchTLSMode=disabled \
       --wiredTigerCacheSizeGB=1 \
       --fork

# Shard 2
mongod --dbpath="${DATA_PATH_ROOT}/shard2/node1/" \
       --logpath="${DATA_PATH_ROOT}/shard2/node1/mongod.log" \
       --port=27007 \
       --replSet=demo2 \
       --shardsvr \
       --auth \
       --keyFile="${DATA_PATH_ROOT}/keyfile" \
       --pidfilepath="${DATA_PATH_ROOT}/shard2/node1/mongod.pid" \
       --wiredTigerCacheSizeGB=1 \
       --setParameter searchIndexManagementHostAndPort=localhost:27031 \
       --setParameter mongotHost=localhost:27031 \
       --setParameter skipAuthenticationToSearchIndexManagementServer=false \
       --setParameter useGrpcForSearch=true \
       --setParameter searchTLSMode=disabled \
       --fork

mongod --dbpath="${DATA_PATH_ROOT}/shard2/node2/" \
       --logpath="${DATA_PATH_ROOT}/shard2/node2/mongod.log" \
       --port=27008 \
       --replSet=demo2 \
       --shardsvr \
       --auth \
       --keyFile="${DATA_PATH_ROOT}/keyfile" \
       --pidfilepath="${DATA_PATH_ROOT}/shard2/node2/mongod.pid" \
       --wiredTigerCacheSizeGB=1 \
       --setParameter searchIndexManagementHostAndPort=localhost:27031 \
       --setParameter mongotHost=localhost:27031 \
       --setParameter skipAuthenticationToSearchIndexManagementServer=false \
       --setParameter useGrpcForSearch=true \
       --setParameter searchTLSMode=disabled \
       --fork

mongod --dbpath="${DATA_PATH_ROOT}/shard2/node3/" \
       --logpath="${DATA_PATH_ROOT}/shard2/node3/mongod.log" \
       --port=27009 \
       --replSet=demo2 \
       --shardsvr \
       --auth \
       --keyFile="${DATA_PATH_ROOT}/keyfile" \
       --pidfilepath="${DATA_PATH_ROOT}/shard2/node3/mongod.pid" \
       --setParameter searchIndexManagementHostAndPort=localhost:27031 \
       --setParameter mongotHost=localhost:27031 \
       --setParameter skipAuthenticationToSearchIndexManagementServer=false \
       --setParameter useGrpcForSearch=true \
       --setParameter searchTLSMode=disabled \
       --wiredTigerCacheSizeGB=1 \
       --fork

# Mongos
mongos --configdb=demo/localhost:27017,localhost:27018,localhost:27019 \
       --port=27020 \
       --keyFile="${DATA_PATH_ROOT}/keyfile" \
       --logpath="${DATA_PATH_ROOT}/mongos/mongos.log" \
       --pidfilepath="${DATA_PATH_ROOT}/mongos/mongos.pid" \
       --setParameter searchIndexManagementHostAndPort=localhost:27030 \
       --setParameter mongotHost=localhost:27030 \
       --setParameter skipAuthenticationToSearchIndexManagementServer=false \
       --setParameter useGrpcForSearch=true \
       --setParameter searchTLSMode=disabled \
       --fork