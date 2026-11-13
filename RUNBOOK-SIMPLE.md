# MongoDB Search on a single node — the simplest thing that works

One `mongod`, one `mongot`, sitting next to each other. No load balancer, no
TLS, no scaling. The goal is to understand **how mongod and mongot are wired
together**, with as little else in the way as possible.

For the scalable, multi-host, TLS-secured version — a 3-node replica set with
a pool of mongots behind HAProxy or Envoy — see [RUNBOOK.md](RUNBOOK.md) in
this repo.

Everything below has been run and verified on MongoDB **8.3.17** with mongot
Community **1.70.6**, on `linux/arm64`.

---

## Contents

- [1. What this is, and what it is not](#1-what-this-is-and-what-it-is-not)
- [2. Run it (Docker)](#2-run-it-docker)
- [3. How the wiring actually works](#3-how-the-wiring-actually-works)
- [4. Try it: data, indexes, queries](#4-try-it-data-indexes-queries)
- [5. Watch the sync happen](#5-watch-the-sync-happen)
- [6. The four files, explained](#6-the-four-files-explained)
- [7. The same thing on a plain Linux VM, without Docker](#7-the-same-thing-on-a-plain-linux-vm-without-docker)
- [8. Troubleshooting](#8-troubleshooting)
- [9. What this leaves out](#9-what-this-leaves-out)
- [10. Teardown](#10-teardown)

---

## 1. What this is, and what it is not

**What it is.** The minimum viable MongoDB Search deployment: a single-node
replica set and a single mongot process on the same host, talking over
loopback. Enough to create search indexes, run `$search` and `$vectorSearch`,
and watch index updates flow from mongod to mongot in real time.

**What it is not.** Not production ready, and not even POC-ready for a
customer. There is one copy of everything, no TLS anywhere, hardcoded
passwords, and no backup or monitoring. It is a learning rig.

**Two things that are not optional**, even here, and that surprise people:

| Constraint | Why |
|---|---|
| The source **must be a replica set** | mongot builds its indexes by reading a change stream, and change streams require a replica set. A standalone mongod cannot be a sync source. A single-member replica set is fine. |
| **MongoDB 8.3 or newer** | 8.3 is the minimum documented version for self-managed Search. 8.2 is EOL as a search source, and 8.0 rejects `--setParameter useGrpcForSearch` outright at startup. |

---

## 2. Run it (Docker)

mongot Community is published for Linux only, so on macOS or Windows this has
to run in a container. One container, both processes.

```bash
cd simple && docker compose up -d --build
```

First build pulls MongoDB and the mongot tarball — a few minutes. Then watch
it come up:

```bash
docker compose -f simple/docker-compose.yml logs -f
```

You are looking for this sequence:

```
>>> starting mongod (search parameters are set here, at startup)
>>> waiting for mongod to accept connections
>>> initiating replica set 'rs0'
>>> waiting for this node to become primary
>>> creating admin (root)
>>> creating mongotUser (searchCoordinator)
>>> starting mongot
>>> waiting for mongot health check
>>> mongot is healthy
>>> ready:  mongosh 'mongodb://admin:password@localhost:27017/?directConnection=true'
```

Three ports are published to your laptop:

| Port | What |
|---|---|
| `27017` | mongod |
| `8080` | mongot health check — `curl localhost:8080/health` returns `{"status":"SERVING"}` |
| `9946` | mongot Prometheus metrics |

mongot's gRPC port (`27028`) is deliberately **not** published. Only mongod
talks to it, and it is bound to loopback inside the container.

Connect from your laptop:

```bash
mongosh "mongodb://admin:password@localhost:27017/?directConnection=true"
```

---

## 3. How the wiring actually works

```
                    one host
   ┌────────────────────────────────────────────────┐
   │                                                │
   │   mongod :27017                mongot          │
   │   ┌──────────────┐            ┌─────────────┐  │
   │   │              │  queries   │             │  │
   │   │              │  + index   │  gRPC       │  │
   │   │              │ ─────────► │  :27028     │  │
   │   │              │  mgmt      │             │  │
   │   │              │            │             │  │
   │   │   oplog      │ ◄───────── │  change     │  │
   │   │              │  SCRAM as  │  stream     │  │
   │   │              │  mongotUser│             │  │
   │   └──────┬───────┘            └──────┬──────┘  │
   │          │                           │         │
   │     /data/mongod               /data/mongot    │
   │     (your data)                (the indexes)   │
   └────────────────────────────────────────────────┘
```

**Two independent connections, in opposite directions.** This is the part
worth internalising:

1. **mongot → mongod**, for replication. mongot opens a change stream and
   authenticates as a *normal SCRAM user* (`mongotUser`). This is how index
   content gets built and kept current.
2. **mongod → mongot**, over gRPC, for two purposes: index management
   (`createSearchIndex`, `dropSearchIndex`) and queries (`$search`,
   `$vectorSearch`). Both go to the same address here.

They store data separately. `/data/mongod` is your collections;
`/data/mongot` is the Lucene indexes mongot built. In the running container
after the demo below, that was 202 MB and 428 KB respectively.

### What mongod needs to know

Five `setParameter` values. All of them are **startup-only** — you cannot set
them with `setParameter` at runtime, which is why they are passed at launch:

```
--setParameter mongotHost=127.0.0.1:27028
--setParameter searchIndexManagementHostAndPort=127.0.0.1:27028
--setParameter skipAuthenticationToSearchIndexManagementServer=false
--setParameter useGrpcForSearch=true
--setParameter searchTLSMode=disabled
```

| Parameter | Meaning |
|---|---|
| `mongotHost` | Where to send `$search` / `$vectorSearch` queries. |
| `searchIndexManagementHostAndPort` | Where to send index management commands. Same host here; in a scaled deployment it is the load balancer address. |
| `skipAuthenticationToSearchIndexManagementServer` | `false` means mongod authenticates to mongot. Leave it false. |
| `useGrpcForSearch` | Enables the gRPC transport. Required. |
| `searchTLSMode` | `disabled` because there is no TLS here. If unset it defaults to `globalTLS`, inheriting `net.tls.mode`. |

> **Use `127.0.0.1`, not `localhost`.** On a dual-stack host `localhost` can
> resolve to `::1` for one process and `127.0.0.1` for the other, and then
> mongod simply cannot reach mongot. This is the single most common cause of
> a dead search deployment, and this repo's own scripts hit it (see the
> "Known issues" section of [README.md](README.md)).

### What mongot needs to know

Three things, all in `mongot.yaml`:

1. **Where to replicate from** — `syncSource.replicaSet.hostAndPort`, plus the
   SCRAM credentials to get in.
2. **Where to keep its indexes** — `storage.dataPath`.
3. **Where to listen for mongod** — `server.grpc.address`.

### The ordering problem

This trips people up, so the entrypoint handles it explicitly:

1. **mongod starts first**, already pointing at mongot's address. mongot does
   not need to exist yet — mongod only dials it when a search index or query
   is issued. Since the parameters are startup-only, they have to be set now
   or you are restarting later.
2. **The replica set is initiated and `mongotUser` is created.**
3. **mongot starts** and authenticates as `mongotUser`.

You cannot start mongot first: it has nothing to authenticate against.

### The user mongot uses

```js
db.getSiblingDB("admin").createUser({
  user: "mongotUser",
  pwd:  "searchpass",
  roles: [ { role: "searchCoordinator", db: "admin" } ]
})
```

`searchCoordinator` is a built-in role. mongot reads the password from a
**file** (`passwordFile` in its config), never from argv or the config file
itself.

---

## 4. Try it: data, indexes, queries

Connect:

```bash
mongosh "mongodb://admin:password@localhost:27017/?directConnection=true"
```

### 4.1 Insert something

```js
use sample
db.movies.insertMany([
  { title: "The Shawshank Redemption", year: 1994, plot: "Two imprisoned men bond over a number of years, finding solace and eventual redemption through acts of common decency.", embedding: [0.9, 0.1, 0.2] },
  { title: "Finding Nemo",             year: 2003, plot: "After his son is captured in the Great Barrier Reef and taken to Sydney, a timid clownfish sets out on a journey to bring him home.", embedding: [0.1, 0.9, 0.2] },
  { title: "The Imitation Game",       year: 2014, plot: "During World War II, the English mathematician Alan Turing tries to crack the German Enigma code with help from fellow mathematicians.", embedding: [0.2, 0.2, 0.9] },
  { title: "Finding Dory",             year: 2016, plot: "The friendly but forgetful blue tang fish begins a search for her long-lost parents.", embedding: [0.15, 0.85, 0.25] }
])
```

The `embedding` vectors are hand-written 3-dimensional values so you can try
vector search without running an embedding model. Real embeddings are
typically 768 or 1536 dimensions.

### 4.2 Create the indexes

```js
// Full-text, dynamic mapping: index every field.
db.movies.createSearchIndex("default", { mappings: { dynamic: true } })

// Vector search index.
db.movies.createSearchIndex("vector_index", "vectorSearch", {
  fields: [
    { type: "vector", path: "embedding", numDimensions: 3, similarity: "cosine" }
  ]
})
```

If these return without error, **mongod reached mongot over gRPC** — that is
the integration working.

Watch them build:

```js
db.movies.getSearchIndexes().map(i => ({ name: i.name, status: i.status }))
```

On this tiny dataset `READY` arrives in roughly 30 seconds.

> **Queries work before the status says `READY`.** The status field lags
> behind actual queryability — in testing, `$search` returned correct results
> while both indexes still reported `PENDING`. Do not treat `PENDING` as
> "broken" until it has been sitting there for a few minutes.

### 4.3 `$search`

```js
db.movies.aggregate([
  { $search: { index: "default", text: { query: "finding", path: "title" } } },
  { $project: { _id: 0, title: 1, score: { $meta: "searchScore" } } }
])
```

```
[
  { title: 'Finding Nemo', score: 0.34314215183258057 },
  { title: 'Finding Dory', score: 0.34314215183258057 }
]
```

Both score identically — the match is on the same single term — so the two
may come back in either order between runs.

Searching the plot text instead:

```js
db.movies.aggregate([
  { $search: { index: "default", text: { query: "mathematician", path: "plot" } } },
  { $project: { _id: 0, title: 1, score: { $meta: "searchScore" } } }
])
```

```
[ { title: 'The Imitation Game', score: 0.5390923023223877 } ]
```

### 4.4 `$vectorSearch`

```js
db.movies.aggregate([
  { $vectorSearch: {
      index: "vector_index",
      path: "embedding",
      queryVector: [0.1, 0.9, 0.2],
      numCandidates: 10,
      limit: 3
  } },
  { $project: { _id: 0, title: 1, score: { $meta: "vectorSearchScore" } } }
])
```

```
[
  { title: 'Finding Nemo',       score: 1 },
  { title: 'Finding Dory',       score: 0.9979979991912842 },
  { title: 'The Imitation Game', score: 0.717174768447876 }
]
```

The query vector is exactly Finding Nemo's embedding, so it scores 1.0, and
Finding Dory — deliberately placed nearby — comes second. Note that
`$vectorSearch` always returns `limit` results ranked by similarity; it does
not filter out poor matches.

### 4.5 `$searchMeta`

```js
db.movies.aggregate([
  { $searchMeta: {
      index: "default",
      text: { query: "finding", path: "title" },
      count: { type: "total" }
  } }
])
```

```
[ { count: { total: Long('2') } } ]
```

---

## 5. Watch the sync happen

This is the most instructive thing in the whole setup. Insert a document and
search for it — **without touching the index**:

```js
db.movies.insertOne({
  title: "Finding Forrester", year: 2000,
  plot: "A writer discovers a young talent.",
  embedding: [0.12, 0.88, 0.2]
})

// give the change stream a moment
db.movies.aggregate([
  { $search: { index: "default", text: { query: "finding", path: "title" } } },
  { $project: { _id: 0, title: 1 } }
])
```

```
[
  { title: 'Finding Nemo' },
  { title: 'Finding Dory' },
  { title: 'Finding Forrester' }
]
```

The new document appeared in search results within a couple of seconds. No
reindex, no ETL job, no sync pipeline. mongot saw the change stream event and
updated its index. **This is the whole value proposition** versus bolting an
external search engine onto MongoDB — and it is the thing worth showing a
customer who is currently running a Logstash or Debezium pipeline into
Elasticsearch.

Indexes survive a restart, too:

```bash
docker compose -f simple/docker-compose.yml restart
```

On the way back up the entrypoint prints `existing data found, skipping
replica set and user setup`, and the indexes come back `READY` with their
contents intact.

---

## 6. The four files, explained

Everything lives in [simple/](simple/).

| File | Role |
|---|---|
| [simple/Dockerfile](simple/Dockerfile) | Installs `mongodb-org-server` 8.3.17 and the mongot 1.70.6 tarball. mongot bundles its own JDK, so there is no JRE to install. |
| [simple/mongot.yaml](simple/mongot.yaml) | mongot's entire configuration. ~20 meaningful lines. |
| [simple/entrypoint.sh](simple/entrypoint.sh) | Starts both processes in the right order and does one-time setup. |
| [simple/docker-compose.yml](simple/docker-compose.yml) | Port mappings, a named volume for `/data`, and a 4 GB memory limit. |

The config that matters, in full:

```yaml
syncSource:
  replicaSet:
    hostAndPort:
      - "127.0.0.1:27017"
    scramAuth:
      username: mongotUser
      authSource: admin
      passwordFile: "/data/mongot.pwd"
      tls:
        enabled: false

storage:
  dataPath: "/data/mongot"

server:
  grpc:
    address: "127.0.0.1:27028"
    tls:
      mode: "disabled"

metrics:
  enabled: true
  address: "0.0.0.0:9946"
healthCheck:
  address: "0.0.0.0:8080"

logging:
  verbosity: INFO
```

`metrics` and `healthCheck` bind to `0.0.0.0` only so you can reach them from
your laptop through the published ports. The gRPC listener stays on loopback.

You can override the defaults at run time:

| Variable | Default |
|---|---|
| `REPL_SET` | `rs0` |
| `ADMIN_USER` / `ADMIN_PASS` | `admin` / `password` |
| `MONGOT_USER` / `MONGOT_PASS` | `mongotUser` / `searchpass` |

---

## 7. The same thing on a plain Linux VM, without Docker

Identical architecture, one VM, no containers. Rocky/RHEL 9 shown; the only
difference on Ubuntu is `apt` instead of `dnf` and a different repo file.

mongot is published for Linux **x86_64 and aarch64 only** — there is no macOS
or Windows build, which is why the Docker path exists at all.

### 7.1 Install MongoDB 8.3

```bash
sudo tee /etc/yum.repos.d/mongodb-org-8.3.repo >/dev/null <<'EOF'
[mongodb-org-8.3]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/9/mongodb-org/8.3/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://pgp.mongodb.com/server-8.0.asc
EOF

sudo dnf install -y mongodb-org mongodb-mongosh
```

> MongoDB publishes one signing key per major line and there is no
> `server-8.3.asc`; the 8.0 key signs the 8.3 repo.

### 7.2 Install mongot

```bash
MONGOT_VERSION=1.70.6
ARCH=$(uname -m); case "$ARCH" in aarch64|arm64) A=aarch64 ;; *) A=x86_64 ;; esac

curl -fsSL -o /tmp/mongot.tgz \
  "https://downloads.mongodb.org/mongodb-search-community/${MONGOT_VERSION}/mongot_community_${MONGOT_VERSION}_linux_${A}.tgz"

sudo mkdir -p /opt/mongot
sudo tar -xzf /tmp/mongot.tgz -C /opt/mongot --strip-components=1
sudo mkdir -p /etc/mongot /var/lib/mongot /var/log/mongot
```

### 7.3 Create the service account and directories

```bash
sudo useradd --system --home-dir /var/lib/mongot --shell /sbin/nologin mongot || true
sudo chown -R mongot:mongot /var/lib/mongot /var/log/mongot
```

### 7.4 Configure mongod

Replace the `setParameter` block in `/etc/mongod.conf`, and set a replica set
name and keyfile:

```yaml
net:
  port: 27017
  bindIp: 127.0.0.1

replication:
  replSetName: rs0

security:
  authorization: enabled
  keyFile: /etc/mongod.keyfile

setParameter:
  mongotHost: "127.0.0.1:27028"
  searchIndexManagementHostAndPort: "127.0.0.1:27028"
  skipAuthenticationToSearchIndexManagementServer: false
  useGrpcForSearch: true
  searchTLSMode: "disabled"
```

The keyfile is required as soon as `authorization: enabled` is combined with
a replica set — even a single-member one:

```bash
sudo bash -c 'openssl rand -base64 756 > /etc/mongod.keyfile'
sudo chmod 400 /etc/mongod.keyfile
sudo chown mongod:mongod /etc/mongod.keyfile

sudo systemctl enable --now mongod
```

### 7.5 Initiate the replica set and create users

```bash
mongosh --eval 'rs.initiate({_id:"rs0", members:[{_id:0, host:"127.0.0.1:27017"}]})'

# The localhost exception lets you create the first user before auth applies.
mongosh --eval '
  db.getSiblingDB("admin").createUser({
    user: "admin", pwd: "password",
    roles: [{ role: "root", db: "admin" }]
  })'

mongosh -u admin -p password --authenticationDatabase admin --eval '
  db.getSiblingDB("admin").createUser({
    user: "mongotUser", pwd: "searchpass",
    roles: [{ role: "searchCoordinator", db: "admin" }]
  })'
```

### 7.6 Configure mongot

```bash
sudo bash -c 'echo "searchpass" > /etc/mongot/mongot.pwd'
sudo chmod 400 /etc/mongot/mongot.pwd
sudo chown mongot:mongot /etc/mongot/mongot.pwd

sudo tee /etc/mongot/mongot.yaml >/dev/null <<'EOF'
syncSource:
  replicaSet:
    hostAndPort:
      - "127.0.0.1:27017"
    scramAuth:
      username: mongotUser
      authSource: admin
      passwordFile: "/etc/mongot/mongot.pwd"
      tls:
        enabled: false
storage:
  dataPath: "/var/lib/mongot"
server:
  grpc:
    address: "127.0.0.1:27028"
    tls:
      mode: "disabled"
metrics:
  enabled: true
  address: "127.0.0.1:9946"
healthCheck:
  address: "127.0.0.1:8080"
logging:
  verbosity: INFO
EOF
```

### 7.7 A systemd unit for mongot

```bash
sudo tee /etc/systemd/system/mongot.service >/dev/null <<'EOF'
[Unit]
Description=MongoDB Search (mongot)
After=network-online.target mongod.service
Wants=network-online.target

[Service]
Type=simple
User=mongot
Group=mongot
ExecStart=/opt/mongot/mongot --config /etc/mongot/mongot.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=64000

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now mongot
```

Check it:

```bash
curl -s http://127.0.0.1:8080/health     # {"status":"SERVING"}
sudo systemctl status mongot
```

Then run everything in [section 4](#4-try-it-data-indexes-queries) exactly as
written.

> **SELinux and firewalld.** Everything is loopback-only here, so neither
> needs changing. The moment you split mongod and mongot onto separate hosts,
> both come into play — [RUNBOOK.md](RUNBOOK.md) covers that.

---

## 8. Troubleshooting

### 8.1 `$search` fails with `HostUnreachable`

```
codeName: HostUnreachable
message : Failed to establish connectivity of gRPC channel before deadline
```

mongod cannot reach mongot. In order of likelihood:

1. **mongot is not running.** See 8.3 below — it does not appear in `ps` as
   `mongot`.
2. **`localhost` vs `127.0.0.1` mismatch.** mongot bound to `127.0.0.1` and
   mongod is dialling `::1`, or vice versa. Use literal `127.0.0.1` on both
   sides. Confirm with `ss -ltnp | grep 27028`.
3. **Port mismatch** between `mongotHost` and `server.grpc.address`.

### 8.2 `createSearchIndex` fails with `SearchIndexManagementHostUnreachable`

```
codeName: SearchIndexManagementHostUnreachable
message : Error connecting to Search Index Management service.
```

Same root causes as 8.1, but it means `searchIndexManagementHostAndPort` is
the parameter pointing somewhere wrong. Note that these are two separate
parameters — it is possible to get queries working while index management is
broken, and vice versa.

### 8.3 `ps aux | grep mongot` finds nothing, `pkill mongot` does nothing

**mongot runs as a `java` process.** The `mongot` binary is a launcher that
execs the bundled JDK, so the process you are looking for is:

```
/opt/mongot/bin/jdk/bin/java -XX:+ExitOnOutOfMemoryError ...
```

Find it with `pgrep -af 'mongot'` matching the full command line, or
`ss -ltnp | grep 27028`. Under systemd just use `systemctl status mongot`.

Be careful with `pkill -f /opt/mongot/mongot` — the pattern can match your own
shell command and kill that instead.

### 8.4 mongot starts, then exits

Almost always authentication. Check:

- `mongotUser` exists on `admin` with the `searchCoordinator` role
- the password in `passwordFile` matches the user's actual password
- `authSource` is `admin`
- the password file is readable by the user mongot runs as

### 8.5 The index stays `PENDING` or never reaches `READY`

First, check it is actually a problem: `PENDING` for the first 30 seconds or
so is normal, and queries often work before the status flips (see §4.2). If
it is still `PENDING` after a few minutes, mongot is running but cannot
replicate. It can accept the index definition
over gRPC while failing to read the change stream — the two paths are
independent. Check mongot's log for connection or auth errors against
`syncSource`.

### 8.6 "Checking authorization failed ... atlascli" spam in the logs

Harmless. That is `mongosh` probing for Atlas CLI local-dev metadata before
it has authenticated. It appears once per `mongosh` connection and can be
ignored:

```
"errmsg":"not authorized on admin to execute command { aggregate: \"atlascli\", ...
```

### 8.7 Where are the logs?

In the container, both processes log to stdout, so:

```bash
docker compose -f simple/docker-compose.yml logs -f
```

On a VM: `journalctl -u mongod -f` and `journalctl -u mongot -f`.

### 8.8 The container exits shortly after starting

The entrypoint runs `wait -n` and exits if **either** process dies, rather
than leaving you with a half-up stack. Read the logs above the exit to see
which one went. A common cause on a laptop is the JVM being OOM-killed —
raise `mem_limit` in `docker-compose.yml`.

---

## 9. What this leaves out

Everything that makes it survivable. Named explicitly so nobody mistakes this
for a starting point for real work:

| Missing | Consequence |
|---|---|
| **A second mongot** | mongot is a single point of failure. Search is down whenever it is. |
| **A load balancer** | No way to add or remove mongot capacity. See [RUNBOOK.md](RUNBOOK.md) §8. |
| **TLS anywhere** | Credentials and query content cross the loopback in clear text. Fine on one host, not fine the moment the two are on separate machines. |
| **A real replica set** | One member means no HA and no failover for the data itself. |
| **Hardcoded passwords** | `admin`/`password` and `searchpass` are in the repo. |
| **Backup for the indexes** | mongot's data is rebuildable from the source collections, but a rebuild takes time proportional to your data. |
| **Monitoring** | The metrics endpoint is exposed but nothing scrapes it. |
| **Resource isolation** | mongod and mongot compete for the same RAM and page cache. In any real deployment mongot gets its own hosts, sized for its indexes. |

**The RAM point is the one to carry into a sizing conversation.** mongot is a
JVM holding Lucene indexes, and vector indexes in particular are memory
hungry. Co-locating it with mongod means the two fight over page cache, which
is exactly why the dedicated-host layout in [RUNBOOK.md](RUNBOOK.md) exists.

---

## 10. Teardown

```bash
cd simple
docker compose down -v        # -v also removes the data volume
docker image rm mongot-simple:latest
```

On a VM:

```bash
sudo systemctl disable --now mongot mongod
sudo rm -rf /opt/mongot /etc/mongot /var/lib/mongot /var/log/mongot
sudo rm -f /etc/systemd/system/mongot.service
sudo systemctl daemon-reload
```

---

## Reference

- [RUNBOOK.md](RUNBOOK.md) — the multi-host, load-balanced, TLS version
- [MongoDB Search self-managed documentation](https://www.mongodb.com/docs/search/self-managed/current/)
- [mongodb/mongodb-kubernetes](https://github.com/mongodb/mongodb-kubernetes) — the supported Kubernetes path, using Envoy for the same load-balancing job
