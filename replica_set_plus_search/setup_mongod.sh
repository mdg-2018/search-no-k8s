#!/bin/bash

# Run this once to initiate replica set and configure users
mongosh <<'EOF'
rs.initiate({
  _id: "demo",
  members: [
    { _id: 0, host: "localhost:27017", priority: 2 },
    { _id: 1, host: "localhost:27018", priority: 1 },
    { _id: 2, host: "localhost:27019", priority: 1 }
  ]
})
exit()
EOF

echo "Waiting for replica set to initiate..."
sleep 30

mongosh <<'EOF'
db.getSiblingDB("admin").createUser({
  user: "admin",
  pwd: "password",
  roles: [ { role: "root", db: "admin" } ]
})
exit()
EOF

mongosh -u admin -p password --authenticationDatabase "admin" <<'EOF'
db.getSiblingDB("admin").createUser({
  user: "mongotUser",
  pwd: "searchpass",
  roles: [ { role: "searchCoordinator", db: "admin" } ]
})
exit()
EOF
