# Search Without K8s

This is a project to demonstrate how one might deploy MongoDB search in a scalable manner WITHOUT using Kubernetes. Obviously this isn't supported so it's just a science experiment. This repo contains two projects, one for deploying a replica set with load balanced Search and one for a sharded cluster with search support.

## Setup
Configure the project by running <code>setup.sh</code>. This will just download and extract mongot for you.

## Replica Set
In the directory *replica_set_plus_search* there are several scripts to help you set up a MongoDB replica set with load balanced Search using HAProxy. Here are the instructions to get started:

1. Navigate to the *replica_set_plus_search* directory, make sure you run all the scripts from there.
2. Start your mongods by running <code>start_mongods.sh</code>
3. If this is the FIRST TIME you are setting up this project run <code>setup_mongod.sh</code> to configure your replica set and create some users. The mongod on port 27017 has a higher priority and should remain the primary unless something goes wrong. The username is *admin* and the password is *password*. This script also creates the user for Search.
4. With mongod running you can now run <code>start_mongots.sh</code> to start Search
5. Finally start the haproxy load balancer with <code>start_load_balancer.sh</code>.

You now have a highly available and scalable search deployment up and running!