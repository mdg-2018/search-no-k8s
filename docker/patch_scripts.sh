#!/bin/bash
# Build-time fixes applied to the repo's scripts so the stack works inside a
# single container. Each change is independent of the containerisation itself
# and is worth considering upstream.
set -euo pipefail

cd /opt/search-no-k8s

# 1. mongot binds its gRPC server to 127.0.0.1 only, but HAProxy resolves the
#    "localhost" in its backend server lines to ::1 first (Ubuntu maps both in
#    /etc/hosts), so every health check fails with "Connection refused" and the
#    backend reports "no server available".
sed -i -E 's/^([[:space:]]*server[[:space:]]+\S+[[:space:]]+)localhost:/\1127.0.0.1:/' \
  ./*/load_balancer/*.cfg
echo "[patch] haproxy backends pinned to IPv4:"
grep -h "server target" ./*/load_balancer/*.cfg | sed 's/^/[patch]   /'

# 2. mongod/mongos default to binding 127.0.0.1 only, so the container's
#    published ports would refuse connections from the host. Replica set
#    members are registered as "localhost:2701x" and those ports are published
#    1:1, so host clients still resolve correctly.
sed -i -E 's/^(mongo[ds]) (--dbpath=|--configdb=)/\1 --bind_ip_all \2/' \
  ./*/start_mongods.sh
echo "[patch] --bind_ip_all added to:"
grep -hE '^mongo[ds] ' ./*/start_mongods.sh | awk '{print "[patch]   " $1 " " $3}' 

# 3. Ordering fix for the sharded topology: start_mongods.sh launches mongos
#    with --fork, but mongos only daemonizes once it can read global settings
#    from the config servers -- which setup_mongod.sh does not initiate until
#    afterwards, so the script blocks forever. Background mongos instead; it
#    retries until the config replica set exists.
awk '
  /^mongos / { in_mongos = 1 }
  in_mongos && /^[[:space:]]*--fork[[:space:]]*$/ { print "       &"; next }
  { print }
' sharded_cluster_plus_search/start_mongods.sh > /tmp/start_mongods.sh
mv /tmp/start_mongods.sh sharded_cluster_plus_search/start_mongods.sh
chmod +x sharded_cluster_plus_search/start_mongods.sh
echo "[patch] mongos backgrounded instead of --fork:"
tail -2 sharded_cluster_plus_search/start_mongods.sh | sed 's/^/[patch]   /'

# 4. The sharded setup_mongod.sh creates the admin and mongotUser accounts only
#    on the shard 1 / config replica set. Shard 2 (demo2) is initiated later and
#    never gets them, so mongot_3/mongot_4 fail to authenticate against
#    localhost:27007-9 ("MongoSecurityException ... userName='mongotUser'") and
#    shard 2 contributes no results to $search. Create the same users on shard 2
#    (via the localhost exception) before it is added to the cluster.
SETUP=sharded_cluster_plus_search/setup_mongod.sh
grep -q "Add shard 2 to the cluster" "$SETUP"
awk '
  /^# Add shard 2 to the cluster/ && !done {
    while ((getline line < "/opt/search-no-k8s/docker/shard2_users.part") > 0) print line
    done = 1
  }
  { print }
' "$SETUP" > /tmp/setup.sh
mv /tmp/setup.sh "$SETUP"
chmod +x "$SETUP"
grep -q 'Create the same users on shard 2' "$SETUP"
echo "[patch] shard 2 admin/mongotUser creation inserted into setup_mongod.sh"

# 5. reset.sh wipes the data directories but knows nothing about the
#    data/.initialized marker that entrypoint.sh uses to decide whether
#    setup_mongod.sh still needs to run. Without this, running reset.sh inside
#    the container leaves empty data directories plus a stale marker, so the
#    next start skips initialisation and comes up with no replica set at all.
for reset in ./*/reset.sh; do
  if ! grep -q '\.initialized' "$reset"; then
    cat /opt/search-no-k8s/docker/reset_marker.part >> "$reset"
  fi
done
echo "[patch] reset.sh now clears the .initialized marker"
