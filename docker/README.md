# Running search-no-k8s in a container

## What this does

mongot Community is published for **Linux only** (there is no macOS or Windows
build), so on a laptop the stack has to run inside a Linux container. This
directory builds a single image containing everything the experiment needs:

| Component | Version | Role |
|---|---|---|
| `mongod` / `mongos` / `mongosh` | 8.3.3 (pinned) | the replica set or sharded cluster |
| mongot Community | 1.70.4 | the Search process; bundles its own JDK |
| HAProxy | from Ubuntu 24.04 | HTTP/2 load balancer in front of the mongots |

Everything runs in **one container** rather than one service per process. That
is deliberate: every config and script in this repo addresses its peers as
`localhost`, so splitting them across compose services would mean rewriting all
of them. The container is the "machine" the experiment assumes.

On start, `entrypoint.sh` runs the repo's own scripts in dependency order:

```
prepare_dirs.sh -> start_mongods.sh -> setup_mongod.sh -> start_mongots.sh -> start_load_balancer.sh
                                       (first run only)
```

`setup_mongod.sh` is gated on a `data/.initialized` marker, so restarting the
container reuses the existing replica set instead of trying to initiate it
again. Data lives in named volumes and survives `docker compose down`.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Builds the image. Build context is the **repo root**, not this directory. |
| `Dockerfile.dockerignore` | Keeps `.git/`, `data/` and a previously extracted `mongot-community/` out of the build context. |
| `docker-compose.yml` | Ports, named volumes, memory limit, `TOPOLOGY` switch. |
| `entrypoint.sh` | Orchestrates startup, waits for each tier, handles shutdown. |
| `prepare_dirs.sh` | Creates the `data/` layout and the replica set keyfile. Usable standalone on Linux. |
| `patch_scripts.sh` | Build-time fixes to the repo's scripts (see below). |
| `shard2_users.part` | Snippet injected into the sharded `setup_mongod.sh` by `patch_scripts.sh`. |
| `reset_marker.part` | Snippet appended to each `reset.sh` by `patch_scripts.sh`. |

## Build

From this directory:

```bash
docker compose build
```

Or build the image directly, from the **repo root**:

```bash
docker build -f docker/Dockerfile -t search-no-k8s:latest .
```

The build downloads ~300 MB of mongot and produces an image of roughly 1.9 GB.
To use a different MongoDB or mongot build:

```bash
docker build -f docker/Dockerfile --build-arg MONGODB_VERSION=8.3 --build-arg MONGODB_PACKAGE_VERSION=8.3.13 -t search-no-k8s:latest .
```

## Run

Replica set (the default topology):

```bash
docker compose up -d --build
```

Sharded cluster:

```bash
TOPOLOGY=sharded_cluster docker compose up -d --build
```

First start takes 1-4 minutes, because `setup_mongod.sh` sleeps 30 seconds per
replica set while it initiates. Follow progress:

```bash
docker compose logs -f
```

Wait for `[entrypoint] Stack is up.`

### Starting it again later

Once the image has been built, you don't need `--build` again - Compose will
reuse the existing image if nothing under `docker/` (or the project scripts it
copies) has changed:

```bash
docker compose up -d
```

Add `--build` back whenever you've edited the `Dockerfile`, `patch_scripts.sh`,
or anything it copies (including the scripts in `replica_set_plus_search/` and
`sharded_cluster_plus_search/`). Compose does **not** detect those changes on
its own, so a bare `up -d` will happily start a stale image - if in doubt,
add `--build`; it's close to a no-op when nothing changed.

### Connecting

Replica set, from the host:

```bash
mongosh "mongodb://admin:password@localhost:27017/demo?directConnection=true&authSource=admin"
```

Sharded cluster, through `mongos`:

```bash
mongosh "mongodb://admin:password@localhost:27020/demo?authSource=admin"
```

Note the `authSource=admin`: the users live in the `admin` database, so without
it the driver authenticates against `demo` and fails.

### Smoke test

```bash
mongosh "mongodb://admin:password@localhost:27017/demo?directConnection=true&authSource=admin" --eval 'db.movies.insertOne({title:"Inception",plot:"a thief enters dreams to plant an idea"}); db.movies.createSearchIndex("default",{mappings:{dynamic:true}})'
```

Wait for the index to report `READY`, then query it:

```bash
mongosh "mongodb://admin:password@localhost:27017/demo?directConnection=true&authSource=admin" --eval 'db.movies.getSearchIndexes("default")[0].status'
```

```bash
mongosh "mongodb://admin:password@localhost:27017/demo?directConnection=true&authSource=admin" --eval 'db.movies.aggregate([{$search:{index:"default",text:{query:"dreams",path:{wildcard:"*"}}}}]).toArray()'
```

### Stopping, pausing and restarting

| Command | Effect |
|---|---|
| `docker compose stop` | Pauses the container. Fastest option; image, container and volumes all stay. |
| `docker compose start` | Resumes a container stopped with `stop`. Re-runs `entrypoint.sh`, which skips `setup_mongod.sh` (marker already set) and just starts the existing `mongod`/mongot/HAProxy processes. |
| `docker compose restart` | `stop` + `start` in one step. Use this to re-trigger startup without touching data, e.g. if something hung. |
| `docker compose down` | Removes the container (not the image or volumes). Use when you want a clean container next time but keep your data. |
| `docker compose down -v` | Also removes the volumes - wipes all data, next `up` starts from scratch. |

```bash
docker compose stop
```

```bash
docker compose down -v
```

### Getting a shell / running commands inside the container

An interactive `mongosh` session:

```bash
docker exec -it search-no-k8s mongosh -u admin -p password --authenticationDatabase admin
```

A plain shell, started in one of the project directories (the repo's scripts
expect to be run from there):

```bash
docker exec -it -w /opt/search-no-k8s/replica_set_plus_search search-no-k8s bash
```

A one-off command, without an interactive session:

```bash
docker exec search-no-k8s mongosh --quiet -u admin -p password --authenticationDatabase admin --eval 'rs.status().members.map(m => m.name + " " + m.stateStr)'
```

Watch out for `$search`/`$project` in an `--eval` string from zsh/bash: an
unquoted or double-quoted `$search` is expanded by your shell to an empty
string before Docker ever sees it, and the aggregation silently breaks. Use
single quotes around the whole `--eval` argument, or put the pipeline in a
`.js` file and run it with `mongosh --file`.

`docker exec` works from any directory; `docker compose` commands must be run
from this `docker/` directory (where `docker-compose.yml` lives).

## Credentials and ports

Created by `setup_mongod.sh`. **Demo credentials, hardcoded in the repo** - do
not expose these ports beyond your laptop.

| User | Password | Role |
|---|---|---|
| `admin` | `password` | `root` on `admin` |
| `mongotUser` | `searchpass` | `searchCoordinator` on `admin` |

| Port | Published | Replica set | Sharded cluster |
|---|---|---|---|
| 27017-27019 | yes | the 3 mongods | shard 1 / config shard |
| 27007-27009 | no | - | shard 2 |
| 27020 | yes | - | `mongos` |
| 27028-27029 | no | mongot gRPC | shard 1 mongot gRPC |
| 27038-27039 | no | - | shard 2 mongot gRPC |
| 27030 | yes | HAProxy -> mongots | HAProxy -> shard 1 mongots |
| 27031 | yes | - | HAProxy -> shard 2 mongots |
| 8080-8083 | no | mongot health checks | mongot health checks |
| 9946-9949 | no | mongot metrics | mongot metrics |

Shard 2's mongods are deliberately not published: in a sharded cluster you
connect through `mongos` on 27020. To reach the mongot health or metrics
endpoints, either add them to `docker-compose.yml` or curl from inside:

```bash
docker exec search-no-k8s curl -s localhost:9946/metrics
```

## Requirements

- Docker with about **8 GB** of memory for the replica set and **12 GB** for the
  sharded cluster (6 `mongod`s plus 4 mongot JVMs). `docker-compose.yml` sets
  `mem_limit: 12g`; lower it if your Docker VM is smaller.
- About 3 GB of disk for the image, plus volume space for the data.
- Works on arm64 and x86_64. Only arm64 (Apple silicon) has been exercised.

## Fixes applied at build time

`patch_scripts.sh` rewrites the repo's scripts inside the image. Only #2 is
container-specific; the rest are genuine bugs that also affect a native Linux
run and are worth fixing upstream.

1. **HAProxy backends never come up.** mongot binds its gRPC server to
   `127.0.0.1` only, but HAProxy resolves the `localhost` in
   `server target1 localhost:27028` to `::1` first, because Ubuntu's
   `/etc/hosts` maps `localhost` to both families. Every health check fails
   with "Connection refused", the backend logs "no server available", and
   `$search` gets a 503. Fixed by pinning the backend addresses to `127.0.0.1`.

2. **`mongod` is unreachable from the host.** `mongod` and `mongos` default to
   binding `127.0.0.1`, so published container ports refuse connections.
   Fixed with `--bind_ip_all`. Safe here because replica set members are
   registered as `localhost:2701x` and those ports are published 1:1, so a host
   client that discovers the set still resolves the members correctly.

3. **The sharded cluster hangs on startup.** `start_mongods.sh` launches
   `mongos --fork`, but `mongos` only daemonizes once it can read global
   settings from the config servers - which `setup_mongod.sh` does not initiate
   until afterwards. The script blocks forever. Fixed by backgrounding `mongos`
   so it retries while the replica sets are initiated.

4. **Sharded `$search` silently returns only part of the data.**
   `setup_mongod.sh` creates `admin` and `mongotUser` only on the shard 1 /
   config replica set. Shard 2 (`demo2`) is initiated later and never gets
   them, so `mongot_3` and `mongot_4` fail with
   `MongoSecurityException ... userName='mongotUser'` and shard 2 contributes
   nothing. The index still reports `READY` and queries still succeed - they
   just quietly miss a shard. Fixed by creating the same users on shard 2
   (via the localhost exception) before it is added to the cluster.

5. **`reset.sh` leaves the container unbootable.** This one is specific to the
   container: `reset.sh` wipes the data directories but knows nothing about the
   `data/.initialized` marker `entrypoint.sh` uses to decide whether
   `setup_mongod.sh` still needs to run. Without the fix, a reset leaves empty
   data directories plus a stale marker, so the next start skips initialisation
   and comes up with no replica set. Fixed by having `reset.sh` clear the
   marker too.

### Resetting

Prefer recreating the volumes from the host:

```bash
docker compose down -v
```

The repo's own `reset.sh` also works inside the container, but it stops the
`mongod`s and mongots without restarting them, so restart the container
afterwards:

```bash
docker exec -w /opt/search-no-k8s/replica_set_plus_search search-no-k8s bash ./reset.sh && docker compose restart
```

## Using `prepare_dirs.sh` on a native Linux host

The repo's `data/` directories are gitignored and nothing in the repo creates
them, so `start_mongods.sh` fails on a fresh checkout. This script creates the
directory layout and generates the keyfile, and is safe to re-run:

```bash
cd replica_set_plus_search && ../docker/prepare_dirs.sh replica_set
```

```bash
cd sharded_cluster_plus_search && ../docker/prepare_dirs.sh sharded_cluster
```

## Troubleshooting

**`Unknown --setParameter 'useGrpcForSearch'`** - the server is older than 8.2.
Check with `docker exec search-no-k8s mongod --version`.

**`Error connecting to Search Index Management service`** - `mongod` cannot
reach HAProxy on 27030, or HAProxy has no healthy mongot behind it:

```bash
docker compose logs | grep -E "is DOWN|no server available"
```

**A search index stays in a non-`READY` state, or `$search` returns too few
results** - check the mongot logs for authentication failures:

```bash
docker exec search-no-k8s grep -c MongoSecurityException /opt/search-no-k8s/sharded_cluster_plus_search/data/shard2/mongot1/mongot.log
```

**The container exits during startup** - `entrypoint.sh` gives each tier 120
seconds. On a slow or memory-starved Docker VM this can be too short; check
`docker compose logs` for a `did not come up in 120s` error and raise the
limit in `entrypoint.sh`.

**Where the logs are.** `mongod`, `mongos` and (in the sharded topology) mongot
write into the data volumes; the replica set's mongots log to the container's
stdout:

```bash
docker exec search-no-k8s ls /opt/search-no-k8s/replica_set_plus_search/data/node1/
```

## Caveats

- **Verified on MongoDB 8.2**, which is what the end-to-end testing of both
  topologies was done against. The pin was subsequently moved to 8.3.3 and has
  not been re-run; 8.3.3 is a later patch of the same line and is expected to
  behave identically, but it is untested here.
- Both topologies run on **one host with no real fault isolation**. HAProxy
  balancing two mongots on the same kernel demonstrates the routing, not
  availability.
- No TLS anywhere: `searchTLSMode=disabled`, mongot gRPC `tls.mode: disabled`,
  and SCRAM passwords in plaintext config. Laptop-only.
- This is an unsupported science experiment, as the top-level README says.
  Nothing here should inform a production deployment.
