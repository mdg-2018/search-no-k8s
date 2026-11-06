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

## Running in a container

mongot Community is published for Linux only, so on macOS or Windows the stack
has to run inside a Linux container. See [docker/README.md](docker/README.md).

```bash
cd docker && docker compose up -d --build
```

## Requirements for a native Linux run

- **MongoDB 8.2 or newer.** The scripts pass `--setParameter useGrpcForSearch`,
  which 8.0 rejects at startup with "Unknown --setParameter".
- `mongod`, `mongos`, `mongosh`, and `haproxy` with HTTP/2 support on `PATH`.
- Roughly 8 GB of RAM for the replica set, 16 GB for the sharded cluster.
- Run `setup.sh` once to download and extract mongot.
- Create the `data/` directories and the replica set keyfile before starting -
  they are gitignored and no script creates them. `docker/prepare_dirs.sh` does
  this and works outside Docker too:
  ```bash
  cd replica_set_plus_search && ../docker/prepare_dirs.sh replica_set
  ```

## Known issues

These affect a native Linux run as well as the container, and are patched at
image build time by `docker/patch_scripts.sh`:

1. **HAProxy backends never come up.** mongot binds gRPC to `127.0.0.1`, but
   HAProxy resolves `server target1 localhost:27028` to `::1` first, so every
   health check fails with "Connection refused" and `$search` gets a 503.
   Use `127.0.0.1` in the backend server lines.
2. **The sharded cluster hangs on startup.** `start_mongods.sh` runs
   `mongos --fork`, but `mongos` only daemonizes once it can reach the config
   servers, which `setup_mongod.sh` does not initiate until afterwards.
3. **Sharded `$search` silently returns only part of the data.**
   `setup_mongod.sh` creates `admin` and `mongotUser` only on the shard 1 /
   config replica set, so shard 2's mongots fail to authenticate and contribute
   nothing. The index still reports `READY` and queries still succeed.
