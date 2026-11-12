# Runbook — MongoDB Search & Vector Search (mongot) on VMs / bare metal

**A self-contained proof of concept: a 3-node replica set, a horizontally scalable pool of
`mongot` instances behind a load balancer, TLS on the `mongod` ↔ `mongot` path, and a
demonstrated scale up / scale down of the search tier with no client downtime.**

No Kubernetes. No Ops Manager. No Atlas.

---

## 0. Scope, and what this is not

This runbook stands up a working search tier you can demo and then tear down. It is **not a
production deployment** and deliberately cuts the following corners:

| Corner cut | Consequence |
|---|---|
| Single load balancer instance | The LB is a single point of failure. Production needs 2+ LBs behind a VIP (keepalived/VRRP) or DNS. |
| One CA, long-lived certs, keys on disk unencrypted | No rotation story, no HSM, no cert lifecycle. |
| Demo passwords in plaintext files | `searchpass` etc. are in this document. Change them. |
| No backup of mongot index data | Indexes are rebuilt from `mongod` on loss; fine here, slow at scale. |
| No resource tuning | JVM heap, WiredTiger cache and disk sizing are left at defaults/toy values. |
| No monitoring stack | Prometheus endpoints are exposed but nothing scrapes them. |
| All VMs on one trusted subnet | The health and metrics endpoints have **no TLS and no auth** at all (per MongoDB docs) and are protected only by firewall rules. |

Read §13 before anyone proposes shipping this.

### Provenance of the technical claims in this document

Configuration in this runbook was checked rather than written from memory:

- **Both load balancer configs were validated** — `haproxy -c` (HAProxy 3.2.26) and
  `envoy --mode validate` (Envoy v1.31) both return clean, as does the `STRICT_DNS` variant
  in §11.3.
- **The certificate helper in §4.2 was run**, and its output checked for correct SANs, both
  extended key usages, chain validation, PKCS#8 key format and mongod's key-first PEM ordering.
- **The HAProxy health-check and runtime-API behaviour in §8A and §11 was tested
  empirically**, including the two gotchas in §12.4 and §12.5, which cost real debugging time
  to find and are not obvious from the documentation.
- **Per-stream load balancing was measured, not assumed** (§1.2): 100 HTTP/2 requests over a
  *single* connection distributed 50/50 across two backends.
- Where MongoDB's documentation is **silent** on something this design depends on, it is
  flagged in §14 rather than guessed at. Please read that section — it contains the questions
  worth resolving with MongoDB before a customer builds on these assumptions.

---

## 1. Architecture

### 1.1 Host layout — 6 VMs

```
                          ┌──────────────────────────────────────┐
                          │  Application / mongosh               │
                          │  mongodb://...:27017/?replicaSet=rs0 │
                          └───────────────┬──────────────────────┘
                                          │ TLS, SCRAM
         ┌────────────────────────────────┼────────────────────────────────┐
         │                                │                                │
┌────────▼─────────┐            ┌─────────▼────────┐            ┌──────────▼───────┐
│ mongo1 10.10.0.11│            │ mongo2 10.10.0.12│            │ mongo3 10.10.0.13│
│ mongod :27017    │◄──────────►│ mongod :27017    │◄──────────►│ mongod :27017    │
│ PRIMARY          │  keyFile   │ SECONDARY        │  keyFile   │ SECONDARY        │
└────────┬─────────┘            └─────────┬────────┘            └──────────┬───────┘
         │                                │                                │
         │  mongotHost = mongot-lb.poc.local:27030                          │
         │  gRPC over HTTP/2, TLS (mongod presents a client cert)           │
         └────────────────────────────────┼────────────────────────────────┘
                                          │
                              ┌───────────▼────────────┐
                              │ mongot-lb  10.10.0.30  │
                              │ HAProxy  :27030        │  ← L7. Terminates mTLS,
                              │   (or Envoy)           │    re-originates mTLS,
                              │ stats    :8404         │    balances per gRPC stream
                              └───────────┬────────────┘
                                          │ mTLS, h2
                        ┌─────────────────┴─────────────────┐
                        │                                   │
              ┌─────────▼──────────┐            ┌───────────▼────────┐
              │ mongot1 10.10.0.21 │            │ mongot2 10.10.0.22 │
              │ gRPC    :27028     │            │ gRPC    :27028     │
              │ health  :8080      │            │ health  :8080      │
              │ metrics :9946      │            │ metrics :9946      │
              └─────────┬──────────┘            └───────────┬────────┘
                        │                                   │
                        └──────────────┬────────────────────┘
                     change streams, SCRAM over TLS, readPreference
                       secondaryPreferred → back to the replica set
```

Note the traffic is **bidirectional and asymmetric**, which is the thing most people get wrong
first:

- `mongod` → LB → `mongot`: queries (`$search`, `$vectorSearch`) and index management
  (`createSearchIndex`). This is the gRPC/HTTP/2 path, and the only path the LB sits on.
- `mongot` → replica set **directly** (not through the LB): each mongot opens its own change
  stream against `mongod` to replicate collection data and build its indexes. Each mongot needs
  direct network access to all three `mongod` hosts.

### 1.2 Why the load balancer must be L7, not L4

This is the single most important design constraint, and it is documented:

> If a replica set or shard uses more than one `mongot` instance, use an L7 load balancer. An
> L4 load balancer is not sufficient because `mongod` opens a long-lived connection to
> `mongot`.
> — [Compatibility requirements](https://www.mongodb.com/docs/search/self-managed/current/deployment/compatibility-requirements/)

MongoDB's Kubernetes operator docs spell out the mechanism:

> The `mongod` process opens a single long-lived TCP connection to `mongot`, so an L4 load
> balancer cannot distribute queries across multiple `mongot` instances — all traffic flows
> over that one connection. An L7 load balancer understands HTTP/2 and gRPC, which allows it to
> distribute individual gRPC streams across `mongot` pods while pinning each stream to a single
> `mongot` for the duration of the query cursor.

So a `mode tcp` HAProxy, an F5 in L4 mode, or an AWS NLB will appear to work and will quietly
send **100% of your search traffic to one mongot**. You will see no error — just no scaling.

**This was verified rather than taken on faith.** Driving 100 HTTP/2 requests over a *single*
TCP connection through the HAProxy config in §8A distributed them exactly 50/50:

```
s1     stot=50    lbtot=50
s2     stot=50    lbtot=50
```

HAProxy's default `http-reuse safe` did not interfere. Keep this test in your back pocket —
§12.6 shows how to run the equivalent check against your real deployment.

### 1.3 How many mongots, and what each one holds

Each mongot **replicates independently from the replica set and builds its own index data** in
its own `storage.dataPath`. They are replicas of one another, not shards of a single index — so
any mongot can answer any query, which is what makes round-robin balancing valid.

Scaling therefore means: more query throughput and more redundancy, **not** more index capacity.
Every mongot stores a full copy of every index, so disk per mongot does not shrink as you add
instances.

> **Caveat, and please read §14.1.** MongoDB's self-managed documentation does not state this
> explicitly. It is a strong inference from the documented replication model ("Synchronizes
> index data from `mongod` over a permanent connection driven by change streams", each mongot
> writing "index segments to dedicated storage") plus the fact that MongoDB's own operator
> round-robins across mongots without any index affinity. §11.4 gives you a direct empirical
> test. Confirm it before betting a customer architecture on it.

---

## 2. Prerequisites

### 2.1 Versions

| Component | Version | Notes |
|---|---|---|
| **MongoDB Server** | **8.3 or later** | Hard requirement. Documented as "MongoDB Community Edition v8.3 or later". 8.2 reached end of life and is no longer a supported search source. |
| **mongot Community** | **1.70.6** (current at time of writing) | Linux **x86_64 or aarch64 only**. No macOS or Windows build exists. Bundles its own JDK — no JRE to install. |
| **HAProxy** | 2.8+ (3.2 recommended) | Needs HTTP/2 and, for §11, the `add server` runtime command. Configs here validated on 3.2.26. |
| **Envoy** | 1.27+ (1.31 recommended) | Alternative to HAProxy. Config here validated on v1.31. |
| **OS** | RHEL / Rocky / Alma 9 | Commands below use `dnf`, `firewalld` and `semanage`. |

> If you are coming from the `search-no-k8s` repo this runbook sits in: that repo's README says
> 8.2 and its `setup.sh` pins mongot 1.70.4. Both predate the current docs — use 8.3+ and
> 1.70.6 here.

### 2.2 Machines

| Role | Hostname | IP | vCPU | RAM | Disk |
|---|---|---|---|---|---|
| Replica set member | `mongo1.poc.local` | 10.10.0.11 | 2 | 4 GB | 20 GB |
| Replica set member | `mongo2.poc.local` | 10.10.0.12 | 2 | 4 GB | 20 GB |
| Replica set member | `mongo3.poc.local` | 10.10.0.13 | 2 | 4 GB | 20 GB |
| Search node | `mongot1.poc.local` | 10.10.0.21 | 4 | 8 GB | 40 GB |
| Search node | `mongot2.poc.local` | 10.10.0.22 | 4 | 8 GB | 40 GB |
| Load balancer | `mongot-lb.poc.local` | 10.10.0.30 | 2 | 2 GB | 10 GB |

mongot is a JVM and is the memory-hungry component — 8 GB is a floor for a toy dataset, not a
sizing recommendation.

Substitute your own IPs throughout. Every address in this document is a placeholder.

### 2.3 Port matrix

| Port | Protocol | From | To | Purpose |
|---|---|---|---|---|
| 27017 | TLS/TCP | apps, mongosh, all mongod, **both mongot** | mongod ×3 | Client + replication + mongot's change streams |
| 27030 | TLS/HTTP2 | mongod ×3 | LB | gRPC: queries + index management |
| 27028 | TLS/HTTP2 | **LB only** | mongot ×N | gRPC backend |
| 8080 | **plain HTTP** | **LB only** | mongot ×N | `/health`, `/ready` — no TLS, no auth |
| 9946 | **plain HTTP** | monitoring only | mongot ×N | Prometheus `/metrics` — no TLS, no auth |
| 8404 | HTTP | operators | LB | HAProxy stats UI (or Envoy admin 9901) |

> **Security note, from the docs:** "The health check (`healthCheck`) and metrics (`metrics`)
> endpoints don't support TLS or authentication. Restrict access to these ports at the network
> layer." The firewall rules in §3.2 do exactly that. Do not skip them.

---

## 3. Phase 0 — Host preparation

Run on **all six VMs** unless stated otherwise.

### 3.1 Name resolution

Real DNS is better, but `/etc/hosts` keeps the POC self-contained. The names must match the
certificate SANs you generate in §4, so get them right here.

```bash
sudo tee -a /etc/hosts >/dev/null <<'EOF'
10.10.0.11  mongo1.poc.local  mongo1
10.10.0.12  mongo2.poc.local  mongo2
10.10.0.13  mongo3.poc.local  mongo3
10.10.0.21  mongot1.poc.local mongot1
10.10.0.22  mongot2.poc.local mongot2
10.10.0.30  mongot-lb.poc.local mongot-lb
EOF
```

Verify from every host before continuing — a later TLS failure is much harder to read than a
name resolution failure now:

```bash
for h in mongo1 mongo2 mongo3 mongot1 mongot2 mongot-lb; do printf '%-12s ' "$h"; getent hosts $h.poc.local || echo MISSING; done
```

### 3.2 Firewall

On the **three mongod hosts** — allow peers, and both mongot hosts (for change streams):

```bash
sudo firewall-cmd --permanent --new-zone=pocdb 2>/dev/null || true
sudo firewall-cmd --permanent --zone=pocdb --add-source=10.10.0.0/24
sudo firewall-cmd --permanent --zone=pocdb --add-port=27017/tcp
sudo firewall-cmd --reload
```

On the **two mongot hosts** — gRPC and health reachable *only* from the LB:

```bash
sudo firewall-cmd --permanent --new-zone=poclb 2>/dev/null || true
sudo firewall-cmd --permanent --zone=poclb --add-source=10.10.0.30/32
sudo firewall-cmd --permanent --zone=poclb --add-port=27028/tcp
sudo firewall-cmd --permanent --zone=poclb --add-port=8080/tcp
sudo firewall-cmd --reload
```

On the **LB host** — 27030 from the mongod hosts, stats from your workstation:

```bash
sudo firewall-cmd --permanent --new-zone=pocmongod 2>/dev/null || true
for ip in 10.10.0.11 10.10.0.12 10.10.0.13; do
  sudo firewall-cmd --permanent --zone=pocmongod --add-source=$ip/32
done
sudo firewall-cmd --permanent --zone=pocmongod --add-port=27030/tcp
sudo firewall-cmd --permanent --add-port=8404/tcp
sudo firewall-cmd --reload
```

### 3.3 SELinux

mongot is not packaged by MongoDB with an SELinux policy, and it will live under `/opt`. The
honest POC choice is permissive mode; the alternative is writing a policy module, which is out
of scope here.

```bash
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
```

> Flag this to the customer explicitly. It is a real gap for production, not a formality — see §13.

### 3.4 Tuning (mongod hosts)

```bash
sudo tee /etc/security/limits.d/99-mongodb.conf >/dev/null <<'EOF'
mongod soft nofile 64000
mongod hard nofile 64000
mongod soft nproc  64000
mongod hard nproc  64000
EOF

# MongoDB warns about THP at startup; disable it for the POC.
sudo tee /etc/systemd/system/disable-thp.service >/dev/null <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages
Before=mongod.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl enable --now disable-thp
```

---

## 4. Phase 1 — Certificates

TLS is on the `mongod` ↔ `mongot` path, and because a load balancer sits in the middle the
certificate chain has a shape worth understanding before you generate anything.

### 4.1 What terminates where

```
mongod ──(1)──► LB ──(2)──► mongot
```

1. **mongod → LB.** The LB presents `lb-server` — a *server* cert whose SAN must match
   `mongot-lb.poc.local`, because that is the name in `mongotHost`. mongod validates it against
   its CA file. The LB is configured `verify required`, so mongod must also present a client
   cert; it uses its own `net.tls.certificateKeyFile` for this.
2. **LB → mongot.** The LB presents `lb-client`, a *client* cert of its own — **not** mongod's.
   mongot validates it against `server.grpc.tls.caFile`. The LB validates mongot's server cert
   against the same CA.

This mirrors exactly what MongoDB's Kubernetes operator does with Envoy:

> the Envoy proxy terminates the mTLS connection from `mongod` and establishes a new mTLS
> connection to `mongot` [...] uses its own client certificate when connecting to `mongot`, not
> the original `mongod` certificate.

The practical consequence: **mongot never sees mongod's certificate.** Any identity-based
authorization you might want at the mongot layer has to happen at the LB.

### 4.2 Generate the CA and certificates

Do this once, on your **workstation or the LB host**, then distribute. One CA for everything
keeps the POC manageable.

> Run this block with **bash**, not `sh` — the `issue()` helper uses process substitution
> (`<(...)`) to pass the SAN extension file, which dash does not support.

```bash
mkdir -p ~/poc-certs && cd ~/poc-certs

# --- Root CA -------------------------------------------------------------
openssl req -x509 -newkey rsa:4096 -nodes -days 825 \
  -keyout ca.key -out ca.crt \
  -subj "/C=US/O=PoC/CN=PoC Root CA"

# --- Helper: issue a cert with SANs --------------------------------------
# $1 = file prefix, $2 = CN, $3 = comma-separated SAN list
issue() {
  local name="$1" cn="$2" sans="$3"
  openssl req -newkey rsa:2048 -nodes -keyout "$name.key" -out "$name.csr" \
    -subj "/C=US/O=PoC/CN=$cn"
  openssl x509 -req -in "$name.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out "$name.crt" -days 825 -sha256 \
    -extfile <(printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth,clientAuth\n' "$sans")
  # mongod wants a single PEM with key first, then cert.
  cat "$name.key" "$name.crt" > "$name.pem"
  rm -f "$name.csr"
}

# Replica set members. serverAuth + clientAuth because members are both.
issue mongo1 mongo1.poc.local "DNS:mongo1.poc.local,DNS:mongo1,IP:10.10.0.11"
issue mongo2 mongo2.poc.local "DNS:mongo2.poc.local,DNS:mongo2,IP:10.10.0.12"
issue mongo3 mongo3.poc.local "DNS:mongo3.poc.local,DNS:mongo3,IP:10.10.0.13"

# mongot gRPC server certs.
issue mongot1 mongot1.poc.local "DNS:mongot1.poc.local,DNS:mongot1,IP:10.10.0.21"
issue mongot2 mongot2.poc.local "DNS:mongot2.poc.local,DNS:mongot2,IP:10.10.0.22"

# The LB's two identities.
issue lb-server mongot-lb.poc.local "DNS:mongot-lb.poc.local,DNS:mongot-lb,IP:10.10.0.30"
issue lb-client mongot-lb-client     "DNS:mongot-lb.poc.local"

ls -1 *.crt *.pem
```

> **Leave room to grow.** §11 adds a third mongot. Issue `mongot3` now and save yourself a
> round trip:
> ```bash
> issue mongot3 mongot3.poc.local "DNS:mongot3.poc.local,DNS:mongot3,IP:10.10.0.23"
> ```

**mongot needs a PKCS#8 private key** for its gRPC cert — the docs specify "a valid X.509
certificate for `mongot` using a PKCS#8 private key." OpenSSL 3 (Rocky 9's default) already
emits PKCS#8 from `openssl req -newkey`, so the files above are fine. If you reuse keys from an
older OpenSSL, convert them:

```bash
openssl pkcs8 -topk8 -nocrypt -in mongot1.key -out mongot1.pk8.key
```

### 4.3 Distribute

```bash
# Replica set members
for i in 1 2 3; do
  ssh mongo$i "sudo mkdir -p /etc/mongod/tls"
  scp ca.crt mongo$i.pem mongo$i:/tmp/
  ssh mongo$i "sudo mv /tmp/ca.crt /tmp/mongo$i.pem /etc/mongod/tls/ && \
               sudo chown -R mongod:mongod /etc/mongod/tls && \
               sudo chmod 600 /etc/mongod/tls/mongo$i.pem && \
               sudo chmod 644 /etc/mongod/tls/ca.crt"
done

# Search nodes — cert and key kept separate, which is what mongot expects
for i in 1 2; do
  ssh mongot$i "sudo mkdir -p /etc/mongot/tls"
  scp ca.crt mongot$i.crt mongot$i.key mongot$i:/tmp/
  ssh mongot$i "sudo mv /tmp/ca.crt /tmp/mongot$i.crt /tmp/mongot$i.key /etc/mongot/tls/"
done

# Load balancer — HAProxy wants cert+key concatenated; Envoy wants them separate
ssh mongot-lb "sudo mkdir -p /etc/haproxy/certs /etc/envoy/certs"
scp ca.crt lb-server.pem lb-client.pem lb-server.crt lb-server.key \
    lb-client.crt lb-client.key mongot-lb:/tmp/
ssh mongot-lb "sudo mv /tmp/ca.crt /tmp/lb-server.pem /tmp/lb-client.pem /etc/haproxy/certs/ && \
               sudo cp /etc/haproxy/certs/ca.crt /etc/envoy/certs/ && \
               sudo mv /tmp/lb-server.crt /tmp/lb-server.key /tmp/lb-client.crt /tmp/lb-client.key /etc/envoy/certs/ && \
               sudo chmod 600 /etc/haproxy/certs/*.pem /etc/envoy/certs/*.key"
```

> **HAProxy PEM ordering.** HAProxy accepts key-then-cert or cert-then-key in a `crt` file, so
> the `.pem` files above work as-is. mongod is stricter — key first. The `issue()` helper above
> produces key-first, which satisfies both.

### 4.4 The replica set keyfile

Internal cluster auth uses a shared keyfile. Generate once, copy to all three:

```bash
openssl rand -base64 756 > keyfile
for i in 1 2 3; do
  scp keyfile mongo$i:/tmp/
  ssh mongo$i "sudo mv /tmp/keyfile /etc/mongod/tls/keyfile && \
               sudo chown mongod:mongod /etc/mongod/tls/keyfile && \
               sudo chmod 400 /etc/mongod/tls/keyfile"
done
```

`chmod 400` is mandatory — mongod refuses to start if the keyfile is group- or world-readable.

---

## 5. Phase 2 — The replica set

### 5.1 Install (all three mongod hosts)

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
mongod --version | head -1   # expect db version v8.3.x
```

> **The GPG key version is not a typo.** MongoDB publishes one signing key per major line and
> the 8.0 key also signs the 8.2 and 8.3 repositories; there is no `server-8.3.asc`.

### 5.2 Configure — without search parameters yet

The search `setParameter` values are **startup-only** — the docs state that `mongotHost`,
`searchIndexManagementHostAndPort` and `useGrpcForSearch` "are set only at startup. You can't
change them at runtime with `setParameter`."

That creates an ordering problem: mongod can't usefully point at a load balancer that has no
healthy backends, and mongot can't start until the replica set exists and has a user for it to
authenticate as. So bring the replica set up **clean** now, and add the search parameters in a
rolling restart in §7.

On `mongo1` (adjust the two `mongo1` filenames per host):

```bash
sudo tee /etc/mongod.conf >/dev/null <<'EOF'
storage:
  dbPath: /var/lib/mongo

systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

processManagement:
  timeZoneInfo: /usr/share/zoneinfo

net:
  port: 27017
  bindIpAll: true
  tls:
    mode: requireTLS
    certificateKeyFile: /etc/mongod/tls/mongo1.pem
    CAFile: /etc/mongod/tls/ca.crt
    # Lets mongosh and mongot connect with TLS but no client certificate.
    # Tighten this for production.
    allowConnectionsWithoutCertificates: true

security:
  authorization: enabled
  keyFile: /etc/mongod/tls/keyfile

replication:
  replSetName: rs0
EOF

sudo systemctl enable --now mongod
sudo systemctl status mongod --no-pager
```

If it fails to start, the log is specific and worth reading before changing anything:

```bash
sudo tail -40 /var/log/mongodb/mongod.log
```

### 5.3 Initiate

From `mongo1` only. `--tlsAllowInvalidCertificates` is acceptable here *only* because we are
connecting to `localhost`, whose name is not in any SAN:

```bash
mongosh --host localhost --tls --tlsCAFile /etc/mongod/tls/ca.crt \
        --tlsAllowInvalidCertificates --eval '
rs.initiate({
  _id: "rs0",
  members: [
    { _id: 0, host: "mongo1.poc.local:27017", priority: 2 },
    { _id: 1, host: "mongo2.poc.local:27017", priority: 1 },
    { _id: 2, host: "mongo3.poc.local:27017", priority: 1 }
  ]
})'
```

Members are registered by **hostname, not IP** — it must match the certificate SANs, and it is
what mongot will use to reach them.

Wait for a primary:

```bash
until mongosh --host localhost --tls --tlsCAFile /etc/mongod/tls/ca.crt \
        --tlsAllowInvalidCertificates --quiet \
        --eval 'rs.status().members.filter(m => m.stateStr=="PRIMARY").length' 2>/dev/null \
        | grep -q 1; do echo "waiting for primary..."; sleep 3; done
echo "primary elected"
```

---

## 6. Phase 3 — Users

Created through the **localhost exception**, which is only open until the first user exists — so
the `admin` user must come first.

On `mongo1` (the primary, given `priority: 2`):

```bash
mongosh --host localhost --tls --tlsCAFile /etc/mongod/tls/ca.crt \
        --tlsAllowInvalidCertificates --eval '
db.getSiblingDB("admin").createUser({
  user: "admin",
  pwd:  "password",
  roles: [ { role: "root", db: "admin" } ]
})'
```

Now the mongot sync-source user. The role is **`searchCoordinator` on `admin`**:

```bash
mongosh --host localhost --tls --tlsCAFile /etc/mongod/tls/ca.crt \
        --tlsAllowInvalidCertificates \
        -u admin -p password --authenticationDatabase admin --eval '
db.getSiblingDB("admin").createUser({
  user: "mongotUser",
  pwd:  "searchpass",
  roles: [ { role: "searchCoordinator", db: "admin" } ]
})'
```

What that role grants, per the docs: `readAnyDatabase` privileges plus write permissions on the
`__mdb_internal_search` database. **Do not modify the contents of `__mdb_internal_search`** —
it is mongot's own bookkeeping.

Confirm, and prove TLS works by hostname this time (no `--tlsAllowInvalidCertificates`):

```bash
mongosh --host mongo1.poc.local --tls --tlsCAFile ~/poc-certs/ca.crt \
        -u admin -p password --authenticationDatabase admin --quiet \
        --eval 'db.getSiblingDB("admin").getUsers().users.map(u => u.user)'
```

Expect `[ 'admin', 'mongotUser' ]`. If this fails but the `localhost` version worked, your SANs
or `/etc/hosts` are wrong — fix that now, because mongot will hit the same wall.

---

## 7. Phase 4 — mongot

Run on **mongot1 and mongot2**, changing the hostname-specific values.

### 7.1 Install

```bash
MONGOT_VERSION=1.70.6
case "$(uname -m)" in
  x86_64)        MONGOT_ARCH=x86_64 ;;
  aarch64|arm64) MONGOT_ARCH=aarch64 ;;
  *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
esac

curl -fsSL -o /tmp/mongot.tgz \
  "https://downloads.mongodb.org/mongodb-search-community/${MONGOT_VERSION}/mongot_community_${MONGOT_VERSION}_linux_${MONGOT_ARCH}.tgz"

sudo mkdir -p /opt
sudo tar -xzf /tmp/mongot.tgz -C /opt
sudo ln -sfn /opt/mongot-community /opt/mongot
/opt/mongot/mongot --version
```

mongot bundles its own JDK — do not install a JRE.

### 7.2 User, directories, password file

```bash
sudo useradd --system --home-dir /var/lib/mongot --shell /sbin/nologin mongot 2>/dev/null || true
sudo mkdir -p /var/lib/mongot /var/log/mongot /etc/mongot
sudo chown -R mongot:mongot /var/lib/mongot /var/log/mongot

# SCRAM password for mongotUser, readable only by mongot
echo -n 'searchpass' | sudo tee /etc/mongot/mongot.pwd >/dev/null
sudo chown mongot:mongot /etc/mongot/mongot.pwd
sudo chmod 400 /etc/mongot/mongot.pwd

# TLS material
sudo chown -R mongot:mongot /etc/mongot/tls
sudo chmod 400 /etc/mongot/tls/*.key
sudo chmod 444 /etc/mongot/tls/ca.crt /etc/mongot/tls/*.crt
```

> Use `echo -n`. A trailing newline in the password file is a silent authentication failure
> that looks exactly like a wrong password.

### 7.3 Configuration

On **mongot1** — substitute `mongot2`/`10.10.0.22` on the second host:

```bash
sudo tee /etc/mongot/mongot.yaml >/dev/null <<'EOF'
syncSource:
  replicaSet:
    hostAndPort:
      - "mongo1.poc.local:27017"
      - "mongo2.poc.local:27017"
      - "mongo3.poc.local:27017"
    scramAuth:
      username: mongotUser
      authSource: admin
      passwordFile: "/etc/mongot/mongot.pwd"
      tls:
        enabled: true
        caFile: "/etc/mongot/tls/ca.crt"
  replicationReader:
    # Keep replication reads off the primary.
    readPreference: secondaryPreferred

storage:
  dataPath: "/var/lib/mongot"

server:
  name: "mongot1"
  grpc:
    # MUST be the routable IP, not localhost — the LB has to reach it. See §12.1.
    address: "10.10.0.21:27028"
    tls:
      mode: "mTLS"
      certificateKeyFile: "/etc/mongot/tls/mongot1.crt"
      caFile: "/etc/mongot/tls/ca.crt"

metrics:
  enabled: true
  address: "10.10.0.21:9946"

healthCheck:
  address: "10.10.0.21:8080"

logging:
  verbosity: INFO
  logPath: "/var/log/mongot/mongot.log"
EOF
```

Notes on choices made here:

- **`server.grpc.tls.mode: "mTLS"`** makes mongot verify the LB's client certificate. The
  documented values are `"TLS"`, `"mTLS"` and `"disabled"`. `"mTLS"` requires `caFile`.
  `"TLS"` alone is one-way — the LB would not have to prove anything. (The docs are internally
  inconsistent on case: the configuration reference uses `"TLS"`/`"mTLS"`, the TLS page's
  examples use lowercase `tls`/`mtls`. The reference is authoritative; these configs use its
  casing and were accepted.)
- **`certificateKeyFile` is given the `.crt`**, and mongot reads the matching `.key` alongside
  it. If mongot complains it cannot find a private key, concatenate them into one PEM and point
  at that instead.
- **`replicationReader.readPreference`** defaults to `secondaryPreferred`; it is set explicitly
  because mongot's replication read load landing on your primary is a surprise worth not having.
- **`address` fields are routable IPs, not `localhost`.** This is the single most common failure
  in this whole build — see §12.1.

### 7.4 systemd unit

On both mongot hosts:

```bash
sudo tee /etc/systemd/system/mongot.service >/dev/null <<'EOF'
[Unit]
Description=MongoDB Search (mongot)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mongot
Group=mongot
ExecStart=/opt/mongot/mongot --config /etc/mongot/mongot.yaml
Restart=on-failure
RestartSec=10
LimitNOFILE=64000
LimitNPROC=64000
# mongot bundles its own JDK; set heap explicitly for a predictable POC footprint.
Environment=JAVA_OPTS=-Xmx4g

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now mongot
sudo systemctl status mongot --no-pager
```

### 7.5 Verify before going further

**Do not proceed until both mongots are healthy.** Debugging a broken LB on top of a broken
mongot wastes an afternoon.

On each mongot host:

```bash
curl -s http://10.10.0.21:8080/health  ; echo    # {"status":"SERVING"}
curl -s http://10.10.0.21:8080/ready   ; echo    # {"status":"SERVING"}
curl -s http://10.10.0.21:9946/metrics | head -5
```

Confirm it actually connected to the replica set — a mongot with bad credentials still reports
`SERVING`, because the health endpoint reflects the process, not its sync source:

```bash
sudo grep -iE 'MongoSecurityException|Authentication failed|sync' /var/log/mongot/mongot.log | tail -20
```

Any `MongoSecurityException` means §6 or the password file is wrong. Fix it here.

From the **LB host**, confirm reachability and that mongot really demands a client cert:

```bash
for ip in 10.10.0.21 10.10.0.22; do
  echo "--- $ip ---"
  curl -s --max-time 3 "http://$ip:8080/health" ; echo
  # Expect a TLS failure complaining about a missing client certificate: that is mTLS working.
  openssl s_client -connect "$ip:27028" -CAfile /etc/haproxy/certs/ca.crt \
    -alpn h2 </dev/null 2>&1 | grep -E 'Verify return code|alert|CN='
done
```

---

## 8. Phase 5 — The load balancer

Two complete, independently validated options. **Deploy one.** §8C compares them.

Both do the same three jobs: terminate mTLS from mongod, balance gRPC **streams** across
mongots, and re-originate mTLS with the LB's own client identity.

### 8A — Option A: HAProxy

Recommended for this POC. Smaller config, and a runtime API that makes §11's live scaling
genuinely impressive.

```bash
sudo dnf install -y haproxy socat
haproxy -v | head -1    # want 2.8+, ideally 3.x
```

`socat` is needed to talk to the runtime API in §11.

#### Configuration

```bash
sudo tee /etc/haproxy/haproxy.cfg >/dev/null <<'EOF'
global
    log         stdout format raw local0 info
    maxconn     4096
    # Runtime API — level admin is required for add/del server in §11.
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    ssl-default-bind-options   ssl-min-ver TLSv1.2
    ssl-default-server-options ssl-min-ver TLSv1.2

defaults
    log     global
    mode    http
    option  httplog
    option  log-health-checks
    timeout connect 5s
    # Search cursors are long-lived; short timeouts kill queries mid-flight.
    timeout client  1h
    timeout server  1h

frontend mongot_grpc
    # alpn h2 negotiates HTTP/2 inside TLS. verify required = mongod must
    # present a client certificate (mTLS).
    # NOTE: this MUST be one physical line. HAProxy does not support
    # backslash line continuation in its config file.
    bind 0.0.0.0:27030 ssl crt /etc/haproxy/certs/lb-server.pem ca-file /etc/haproxy/certs/ca.crt verify required alpn h2
    default_backend mongot_pool

backend mongot_pool
    balance roundrobin

    # Health check targets mongot's PLAIN HTTP /health on 8080, not the
    # gRPC port. See §12.4 and §12.5 for the two traps here.
    option httpchk
    http-check send meth GET uri /health ver HTTP/1.1 hdr Host mongot
    http-check expect status 200

    # Also one physical line, for the same reason as the bind above.
    default-server proto h2 ssl alpn h2 verify required ca-file /etc/haproxy/certs/ca.crt crt /etc/haproxy/certs/lb-client.pem check port 8080 inter 5s fall 3 rise 2

    # check-proto h1 MUST be on each server line - it is NOT inherited
    # from default-server. Without it the check speaks h2 to an HTTP/1.1
    # endpoint and reports SOCKERR forever. (§12.5)
    server mongot1 10.10.0.21:27028 check-proto h1
    server mongot2 10.10.0.22:27028 check-proto h1

listen stats
    bind 0.0.0.0:8404
    mode http
    stats enable
    stats uri /
    stats refresh 5s
EOF
```

Validate before starting — this catches typos in seconds instead of in mongod's logs:

```bash
sudo haproxy -c -V -f /etc/haproxy/haproxy.cfg
# "Configuration file is valid"
```

#### Runtime directory and start

The stats socket lives in `/run/haproxy`, which must exist and belong to haproxy:

```bash
sudo mkdir -p /etc/systemd/system/haproxy.service.d
sudo tee /etc/systemd/system/haproxy.service.d/override.conf >/dev/null <<'EOF'
[Service]
RuntimeDirectory=haproxy
RuntimeDirectoryMode=0755
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now haproxy
sudo systemctl status haproxy --no-pager
```

#### Confirm both backends are UP

**Do not continue until both report `UP` / `L7OK`.**

```bash
echo "show stat" | sudo socat stdio /run/haproxy/admin.sock \
  | awk -F, 'NR==1{next} $1=="mongot_pool" && $2!="BACKEND" {printf "%-10s %-6s %s\n",$2,$18,$37}'
```

Expected:

```
mongot1    UP     L7OK
mongot2    UP     L7OK
```

`SOCKERR` → §12.5. `L4TOUT` → firewall or wrong IP (§12.1). `L7STS` → mongot is up but not
returning 200 on `/health`.

The stats UI at `http://mongot-lb.poc.local:8404/` shows the same thing, and is a good thing to
have on screen during a demo.

---

### 8B — Option B: Envoy

Use this when the customer expects to move to Kubernetes later — MCK deploys Envoy for exactly
this role, so the config concepts transfer directly.

```bash
sudo tee /etc/yum.repos.d/envoy.repo >/dev/null <<'EOF'
[getenvoy-rpm-stable]
name=GetEnvoy RPM Stable
baseurl=https://rpm.dl.getenvoy.io/public/rpm/el/9/$basearch
enabled=1
gpgcheck=0
repo_gpgcheck=0
EOF
sudo dnf install -y getenvoy-envoy || {
  # Fallback: pull the static binary out of the official image.
  sudo dnf install -y podman
  CID=$(sudo podman create docker.io/envoyproxy/envoy:v1.31-latest)
  sudo podman cp "$CID":/usr/local/bin/envoy /usr/local/bin/envoy
  sudo podman rm "$CID"
  sudo chmod +x /usr/local/bin/envoy
}
envoy --version
```

#### Configuration

```bash
sudo mkdir -p /etc/envoy
sudo tee /etc/envoy/envoy.yaml >/dev/null <<'EOF'
admin:
  address:
    socket_address: { address: 127.0.0.1, port_value: 9901 }

static_resources:
  listeners:
  - name: mongot_grpc
    address:
      socket_address: { address: 0.0.0.0, port_value: 27030 }
    filter_chains:
    - transport_socket:
        name: envoy.transport_sockets.tls
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext
          # mTLS: mongod must present a client certificate.
          require_client_certificate: true
          common_tls_context:
            tls_certificates:
            - certificate_chain: { filename: /etc/envoy/certs/lb-server.crt }
              private_key:       { filename: /etc/envoy/certs/lb-server.key }
            validation_context:
              trusted_ca: { filename: /etc/envoy/certs/ca.crt }
            alpn_protocols: ["h2"]
      filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: mongot_grpc
          codec_type: HTTP2
          # Search cursors are long-lived: disable idle and route timeouts.
          stream_idle_timeout: 0s
          route_config:
            name: mongot_route
            virtual_hosts:
            - name: mongot
              domains: ["*"]
              routes:
              - match: { prefix: "/" }
                route:
                  cluster: mongot_pool
                  timeout: 0s
          http_filters:
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router

  clusters:
  - name: mongot_pool
    type: STATIC
    connect_timeout: 5s
    lb_policy: ROUND_ROBIN

    # HTTP/2 upstream. NOTE: the old cluster-level `http2_protocol_options: {}`
    # is DEPRECATED; this is the current form.
    typed_extension_protocol_options:
      envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
        "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
        explicit_http_config:
          http2_protocol_options: {}

    health_checks:
    - timeout: 2s
      interval: 5s
      unhealthy_threshold: 3
      healthy_threshold: 2
      # Health checks use the cluster transport socket by default, which is
      # mTLS here and would fail against the plaintext /health port. This
      # selects the raw_buffer socket below instead. See §12.4.
      transport_socket_match_criteria:
        plaintext_hc: true
      http_health_check:
        path: /health
        expected_statuses:
        - start: 200
          end: 201      # end is EXCLUSIVE: this means exactly 200

    # First match wins and an empty match always matches, so the
    # plaintext health-check socket MUST be listed first.
    transport_socket_matches:
    - name: plaintext_hc
      match: { plaintext_hc: true }
      transport_socket:
        name: envoy.transport_sockets.raw_buffer
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.transport_sockets.raw_buffer.v3.RawBuffer
    - name: mtls_default
      match: {}
      transport_socket:
        name: envoy.transport_sockets.tls
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext
          common_tls_context:
            tls_certificates:
            - certificate_chain: { filename: /etc/envoy/certs/lb-client.crt }
              private_key:       { filename: /etc/envoy/certs/lb-client.key }
            validation_context:
              trusted_ca: { filename: /etc/envoy/certs/ca.crt }
            alpn_protocols: ["h2"]

    load_assignment:
      cluster_name: mongot_pool
      endpoints:
      - lb_endpoints:
        - endpoint:
            address: { socket_address: { address: 10.10.0.21, port_value: 27028 } }
            # Health check hits 8080 while traffic goes to 27028.
            health_check_config: { port_value: 8080 }
        - endpoint:
            address: { socket_address: { address: 10.10.0.22, port_value: 27028 } }
            health_check_config: { port_value: 8080 }
EOF
```

Validate:

```bash
sudo envoy --mode validate -c /etc/envoy/envoy.yaml
# ... configuration '/etc/envoy/envoy.yaml' OK
```

A warning about `internal_address_config` not being configured is expected and harmless here.

> **Two Envoy traps worth naming**, both of which cost a debugging cycle to find:
> - `envoy.transport_sockets.raw_buffer` **requires an explicit `typed_config`**. Without it
>   Envoy refuses to start: `Didn't find a registered implementation for
>   'envoy.transport_sockets.raw_buffer' with type URL: ''`.
> - `alt_port` **does not exist** on the current `HealthCheck` message, despite appearing in
>   older examples. Use per-endpoint `health_check_config.port_value`, as above.

#### systemd unit and start

```bash
sudo useradd --system --shell /sbin/nologin envoy 2>/dev/null || true
sudo chown -R envoy:envoy /etc/envoy/certs
sudo chmod 400 /etc/envoy/certs/*.key

sudo tee /etc/systemd/system/envoy.service >/dev/null <<'EOF'
[Unit]
Description=Envoy proxy for mongot
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=envoy
Group=envoy
ExecStart=/usr/local/bin/envoy -c /etc/envoy/envoy.yaml --restart-epoch 0
Restart=on-failure
RestartSec=5
LimitNOFILE=64000
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now envoy
```

Confirm both endpoints are healthy:

```bash
curl -s http://127.0.0.1:9901/clusters | grep -E 'mongot_pool.*health_flags'
# expect "healthy" for both; "/failed_active_hc" means the health check is failing
```

### 8C — Choosing between them

| | HAProxy | Envoy |
|---|---|---|
| Config size for this job | ~35 lines | ~95 lines |
| Matches MongoDB's own K8s operator | no | **yes** |
| Live add/remove of a mongot | **runtime API, no reload, no dropped streams** | hot restart, or `STRICT_DNS` re-resolution |
| Per-stream gRPC balancing | yes (measured, §1.2) | yes |
| mTLS terminate + re-originate | yes | yes |
| Observability out of the box | stats UI on :8404 | admin API + rich stats on :9901 |
| Shard routing by TLS SNI (future) | `req_ssl_sni` ACLs | what MCK uses |

**Pick HAProxy** for a POC focused on demonstrating elastic scaling — §11 is materially better
with it. **Pick Envoy** if the customer's real destination is Kubernetes and you want the POC to
rehearse that config.

---

## 9. Phase 6 — Point mongod at the load balancer

Only now, with mongots healthy behind a working LB, do the search parameters go in.

### 9.1 Add the search parameters

On **each** mongod host, append to `/etc/mongod.conf`:

```bash
sudo tee -a /etc/mongod.conf >/dev/null <<'EOF'

setParameter:
  # Both must point at the LB, and must be identical to each other.
  mongotHost: "mongot-lb.poc.local:27030"
  searchIndexManagementHostAndPort: "mongot-lb.poc.local:27030"
  useGrpcForSearch: true
  skipAuthenticationToSearchIndexManagementServer: false
  # searchTLSMode is deliberately NOT set: it defaults to globalTLS, which
  # inherits net.tls.mode (requireTLS above). See the note below.
EOF
```

On `searchTLSMode`: the docs state that "When you don't set `searchTLSMode`, `mongod` inherits
the TLS mode from `net.tls.mode` [...] because `searchTLSMode` defaults to `globalTLS`." Since
`net.tls.mode` is `requireTLS`, the mongod→mongot path is TLS without setting anything. That is
why it is omitted.

> **If you want TLS on the search path but *not* cluster-wide**, you would need
> `searchTLSMode: requireTLS` with `net.tls.mode: disabled`. MCK's documentation references
> `requireTLS` as a value, but the self-managed configuration reference does **not** list the
> full value set — only `globalTLS` (default) and `disabled` (in an example). Treat that
> combination as unverified; see §14.2.

### 9.2 Rolling restart

Secondaries first, primary last, so you only step down once.

```bash
# On mongo2, then mongo3:
sudo systemctl restart mongod
sleep 20
mongosh --host localhost --tls --tlsCAFile /etc/mongod/tls/ca.crt \
        --tlsAllowInvalidCertificates --quiet \
        -u admin -p password --authenticationDatabase admin \
        --eval 'rs.status().members.map(m => m.name + " " + m.stateStr).join("\n")'
```

Then step the primary down and restart it:

```bash
# On mongo1:
mongosh --host localhost --tls --tlsCAFile /etc/mongod/tls/ca.crt \
        --tlsAllowInvalidCertificates \
        -u admin -p password --authenticationDatabase admin \
        --eval 'rs.stepDown(60)' || true
sudo systemctl restart mongod
```

`rs.stepDown()` drops your connection by design — the `|| true` keeps the script moving.

Because `mongo1` has `priority: 2` it will reclaim the primary role within a minute.

### 9.3 Confirm mongod reached mongot

```bash
sudo grep -iE 'mongot|search' /var/log/mongodb/mongod.log | tail -20
```

You want **no** `Error connecting to Search Index Management service`. If you see it, work
through §12.2.

Cross-check from the LB that mongod actually connected:

```bash
# HAProxy
echo "show stat" | sudo socat stdio /run/haproxy/admin.sock \
  | awk -F, 'NR==1{next} $1=="mongot_pool" {printf "%-10s scur=%s stot=%s\n",$2,$5,$8}'

# Envoy
curl -s http://127.0.0.1:9901/stats | grep -E 'mongot_pool.*(cx_active|rq_total)'
```

Non-zero connections means the path is live end to end.

---

## 10. Phase 7 — Verify search and vector search

### 10.1 A connection string to reuse

```bash
export MDB='mongodb://admin:password@mongo1.poc.local:27017,mongo2.poc.local:27017,mongo3.poc.local:27017/demo?replicaSet=rs0&authSource=admin&tls=true'

# A function, not an alias: aliases do not expand inside the loops used below.
m() { mongosh "$MDB" --tlsCAFile ~/poc-certs/ca.crt --quiet "$@"; }
```

`authSource=admin` matters — without it the driver authenticates against `demo` and fails.

### 10.2 Full-text search

```bash
m --eval '
db.movies.insertMany([
  { title: "Inception",   plot: "A thief enters dreams to plant an idea." },
  { title: "The Matrix",  plot: "A hacker learns reality is a simulation." },
  { title: "Interstellar",plot: "Explorers travel through a wormhole to save humanity." }
]);
db.movies.createSearchIndex("default", { mappings: { dynamic: true } });
'
```

Wait for `READY` — index builds are asynchronous and querying early returns nothing rather than
an error:

```bash
until m --eval 'db.movies.getSearchIndexes("default")[0]?.status' | grep -q READY; do
  echo "building..."; sleep 5
done; echo "index READY"
```

Query it:

```bash
m --eval '
db.movies.aggregate([
  { $search: { index: "default", text: { query: "dreams", path: { wildcard: "*" } } } },
  { $project: { _id: 0, title: 1, score: { $meta: "searchScore" } } }
]).toArray()
'
```

Expect `Inception`.

> **Shell quoting.** Always single-quote the whole `--eval` string. In bash/zsh an unquoted or
> double-quoted `$search` expands to an empty string and the pipeline silently breaks.

### 10.3 Vector search

```bash
m --eval '
db.products.insertMany([
  { name: "running shoes", embedding: [0.9, 0.1, 0.1] },
  { name: "dress shoes",   embedding: [0.8, 0.2, 0.1] },
  { name: "laptop",        embedding: [0.1, 0.1, 0.9] }
]);
db.products.createSearchIndex("vector_idx", "vectorSearch", {
  fields: [ { type: "vector", path: "embedding", numDimensions: 3, similarity: "cosine" } ]
});
'

until m --eval 'db.products.getSearchIndexes("vector_idx")[0]?.status' | grep -q READY; do
  echo "building..."; sleep 5
done

m --eval '
db.products.aggregate([
  { $vectorSearch: {
      index: "vector_idx", path: "embedding",
      queryVector: [0.9, 0.1, 0.1], numCandidates: 10, limit: 3 } },
  { $project: { _id: 0, name: 1, score: { $meta: "vectorSearchScore" } } }
]).toArray()
'
```

Expect `running shoes` first.

Three dimensions is a toy. Real embeddings are 768–3072 and dominate mongot's memory footprint.

### 10.4 Prove the load balancer is distributing

The whole point of the exercise. Generate traffic, then look at per-backend counters:

```bash
for i in $(seq 1 50); do
  m --eval 'db.movies.aggregate([{$search:{index:"default",text:{query:"dreams",path:{wildcard:"*"}}}}]).toArray()' >/dev/null
done
```

```bash
# HAProxy — expect both rows to be non-zero and roughly equal
echo "show stat" | sudo socat stdio /run/haproxy/admin.sock \
  | awk -F, 'NR==1{next} $1=="mongot_pool" && $2!="BACKEND" {printf "%-10s requests=%s\n",$2,$8}'

# Envoy
curl -s http://127.0.0.1:9901/clusters | grep -E 'mongot_pool.*rq_total'
```

**If one mongot shows all the traffic and the other zero, you are running an L4 proxy somewhere**
— re-read §1.2 and check for a `mode tcp` in your config.

---

## 11. Phase 8 — Scale up

The payoff. Add a third mongot to a live system without restarting mongod or dropping a query.

### 11.1 Build mongot3

Provision `mongot3.poc.local` / 10.10.0.23, then repeat §3 (host prep), §7.1–§7.4 with
`mongot3`/`10.10.0.23` substituted, using the `mongot3` certificate from §4.2.

Verify in isolation before touching the LB:

```bash
curl -s http://10.10.0.23:8080/health; echo
sudo grep -ciE 'MongoSecurityException' /var/log/mongot/mongot.log   # want 0
```

The new instance begins an **initial sync**, replicating from the replica set and building every
existing index from scratch. Let it finish before adding it to the pool — otherwise it will
serve incomplete results for whatever window the build takes. Watch:

```bash
sudo tail -f /var/log/mongot/mongot.log | grep -iE 'initial sync|steady|index'
```

### 11.2 Add it to HAProxy — with no reload

The runtime API adds a server in place. **The whole command was tested; the keyword set is
exact** — see §12.5 for why `check-proto h1` is present and `no-check-ssl` is absent.

```bash
sudo socat stdio /run/haproxy/admin.sock <<'EOF'
add server mongot_pool/mongot3 10.10.0.23:27028 proto h2 ssl alpn h2 verify required ca-file /etc/haproxy/certs/ca.crt crt /etc/haproxy/certs/lb-client.pem check check-proto h1 port 8080 inter 5s fall 3 rise 2
EOF
# "New server registered."
```

A freshly added dynamic server starts disabled with health checks off. Enable both:

```bash
echo "enable server mongot_pool/mongot3" | sudo socat stdio /run/haproxy/admin.sock
echo "enable health mongot_pool/mongot3" | sudo socat stdio /run/haproxy/admin.sock
```

Confirm:

```bash
echo "show stat" | sudo socat stdio /run/haproxy/admin.sock \
  | awk -F, 'NR==1{next} $1=="mongot_pool" && $2!="BACKEND" {printf "%-10s %-6s %s\n",$2,$18,$37}'
```

```
mongot1    UP     L7OK
mongot2    UP     L7OK
mongot3    UP     L7OK
```

No reload happened. No mongod was restarted. No query failed.

> **Dynamic servers do not survive a reload.** HAProxy's docs are explicit that servers added
> this way are not restored from the configuration file. Persist the change as well:
> ```bash
> sudo sed -i '/server mongot2 /a\    server mongot3 10.10.0.23:27028 check-proto h1' /etc/haproxy/haproxy.cfg
> sudo haproxy -c -f /etc/haproxy/haproxy.cfg   # validate BEFORE any future reload
> ```
> Note `add server` also requires a **dynamic** load-balancing algorithm — `roundrobin` and
> `leastconn` qualify, `static-rr` and hash-based ones do not.

### 11.3 Add it to Envoy

Envoy has no equivalent live `add server`. Two options:

**(a) Edit and hot restart** — update `load_assignment` with the new endpoint, then:

```bash
sudo envoy --mode validate -c /etc/envoy/envoy.yaml && sudo systemctl restart envoy
```

`systemctl restart` drops in-flight streams. A true Envoy hot restart uses an incremented
`--restart-epoch` with the hot-restart wrapper, which is beyond a POC's value.

**(b) `STRICT_DNS` — better if you will scale repeatedly.** Replace the cluster's `type` and
`load_assignment` with a DNS name carrying one A record per mongot:

```yaml
    type: STRICT_DNS
    dns_refresh_rate: 5s
    load_assignment:
      cluster_name: mongot_pool
      endpoints:
      - lb_endpoints:
        - endpoint:
            address: { socket_address: { address: mongot-pool.poc.local, port_value: 27028 } }
            health_check_config: { port_value: 8080 }
```

Scaling then means adding an A record; Envoy re-resolves every 5s and drains removed hosts
automatically. The cost is losing per-host health-check ports, so all mongots must use 8080
uniformly — which they do here.

> `dns_refresh_rate` is marked deprecated in favour of a `DnsCluster` cluster extension in
> recent Envoy; it still works on 1.31. Check `envoy --version` against the current docs.

### 11.4 Prove the new mongot is actually serving

This also settles the §1.3 question empirically — **worth doing**, because the docs do not state
it:

```bash
# Reset counters for a clean read
echo "clear counters all" | sudo socat stdio /run/haproxy/admin.sock

for i in $(seq 1 60); do
  m --eval 'db.movies.aggregate([{$search:{index:"default",text:{query:"dreams",path:{wildcard:"*"}}}}]).toArray()' >/dev/null
done

echo "show stat" | sudo socat stdio /run/haproxy/admin.sock \
  | awk -F, 'NR==1{next} $1=="mongot_pool" && $2!="BACKEND" {printf "%-10s requests=%s\n",$2,$8}'
```

If all three show traffic **and** results stay correct, then each mongot holds a complete copy
of the index and round-robin across them is sound — including for the `default` index created
*before* mongot3 existed. That is the proof that a new instance picks up pre-existing indexes.

### 11.5 Scale down gracefully

`drain` stops new traffic while letting in-flight cursors finish — this is the difference
between a clean scale-down and a demo full of errors.

```bash
# 1. Stop sending new streams; existing ones continue.
echo "set server mongot_pool/mongot3 state drain" | sudo socat stdio /run/haproxy/admin.sock

# 2. Wait for the connection count to reach zero.
while true; do
  cur=$(echo "show stat" | sudo socat stdio /run/haproxy/admin.sock \
        | awk -F, '$1=="mongot_pool" && $2=="mongot3" {print $5}')
  echo "mongot3 active connections: ${cur:-0}"; [ "${cur:-0}" = "0" ] && break; sleep 2
done

# 3. Full maintenance: stops health checks too.
echo "set server mongot_pool/mongot3 state maint" | sudo socat stdio /run/haproxy/admin.sock

# 4. Remove it. Requires maintenance state and no remaining connections.
echo "del server mongot_pool/mongot3" | sudo socat stdio /run/haproxy/admin.sock
# "Server deleted."
```

Then stop the instance and reclaim its disk:

```bash
ssh mongot3 "sudo systemctl stop mongot && sudo systemctl disable mongot"
```

Nothing on the mongod side changes at any point — `mongotHost` still points at the LB. **That
is the architectural win worth demonstrating:** the search tier scales independently of the
database tier, and clients never notice.

For Envoy: `drain` has no direct analogue. Remove the endpoint (or its DNS A record) and Envoy
drains it on the next resolution; `STRICT_DNS` does this automatically, `STATIC` needs a restart.

---

## 12. Troubleshooting

Ordered by how often each one actually bites.

### 12.1 HAProxy/Envoy backends never come up — `L4TOUT`, "no server available", `$search` returns 503

**Almost always `mongot.yaml` binding to `localhost`.** mongot binds exactly what
`server.grpc.address` says. `localhost:27028` is reachable only from the mongot host itself, so
the LB on another VM can never connect.

```bash
sudo ss -tlnp | grep -E '27028|8080'
```

You want `10.10.0.21:27028`, not `127.0.0.1:27028`. Fix `server.grpc.address`,
`healthCheck.address` and `metrics.address`, then restart mongot.

There is a second, subtler form of this on a **single-host** setup: mongot binds `127.0.0.1`
while HAProxy resolves `localhost` to `::1` first, so every check fails with "Connection
refused". Always write backend addresses as literal IPv4 in the LB config — as this runbook
does.

### 12.2 `Error connecting to Search Index Management service`

mongod cannot reach the LB, or the LB has no healthy backend.

```bash
# From a mongod host — does the LB answer TLS at all?
openssl s_client -connect mongot-lb.poc.local:27030 \
  -CAfile /etc/mongod/tls/ca.crt \
  -cert /etc/mongod/tls/mongo1.pem -key /etc/mongod/tls/mongo1.pem \
  -alpn h2 </dev/null 2>&1 | grep -E 'Verify return code|ALPN|alert'
```

- `ALPN protocol: h2` + `Verify return code: 0 (ok)` → TLS is fine; check LB backend health.
- `alert handshake failure` → certificate problem. Confirm the LB's cert SAN covers
  `mongot-lb.poc.local` and that both sides trust the same CA.
- `alert certificate required` → the frontend is `verify required` but mongod sent no client
  cert. Confirm `net.tls.certificateKeyFile` is set, or relax the bind line to `verify optional`.
- Connection refused → firewall (§3.2) or HAProxy not listening.

### 12.3 Index stays in a non-`READY` state, or `$search` returns too few results

Check mongot's view of the replica set first — a mongot that cannot authenticate still reports
`SERVING`, because `/health` reflects the process, not its sync source:

```bash
sudo grep -cE 'MongoSecurityException' /var/log/mongot/mongot.log
```

Non-zero → `mongotUser` is missing, has the wrong password, or `authSource` is wrong. A
trailing newline in `/etc/mongot/mongot.pwd` is a classic cause — re-create it with `echo -n`.

If **one** mongot is broken and others are fine, behaviour is nastier: the index reports `READY`,
queries succeed, and results are quietly incomplete depending on which backend served them.
Always check *every* mongot, not just one.

### 12.4 Health checks fail with a TLS error while the backend is healthy

The health check is being sent over TLS to mongot's **plaintext** port 8080.

- **Envoy:** health checks use the cluster transport socket by default, which is mTLS here. Fix
  with `transport_socket_matches` + `transport_socket_match_criteria`, as in §8B. The plaintext
  entry must come **first** — first match wins and an empty `match: {}` matches everything.
- **HAProxy:** checks do *not* inherit the server's `ssl` keyword, so there is nothing to
  disable. `no-check-ssl` is unnecessary — and is **rejected** by `add server`:
  `'no-check-ssl' option is not accepted for dynamic server`. Omit it entirely so your static
  and dynamic server lines stay identical.

### 12.5 HAProxy health check reports `SOCKERR` forever

**The trap in this build, and not obvious from the docs.** The check inherits `proto h2` from
`default-server` and speaks HTTP/2 at mongot's HTTP/1.1 health endpoint, which fails at the
socket layer.

The fix is `check-proto h1` — and **it must be on each `server` line, because it is not
inherited from `default-server`.** This was confirmed by direct test: with `check-proto h1` only
on `default-server` the check stayed `SOCKERR`; moved onto the server line, the same backend
immediately reported `L7OK`/`UP`.

```
server mongot1 10.10.0.21:27028 check-proto h1    #  correct
server mongot1 10.10.0.21:27028                   #  SOCKERR forever
```

Same rule for `add server`: pass `check-proto h1` explicitly in the runtime command.

### 12.6 Only one mongot ever gets traffic

Either the proxy is operating at L4, or only one backend is healthy.

```bash
grep -nE 'mode\s+(tcp|http)' /etc/haproxy/haproxy.cfg   # must be http
```

`mode tcp` balances connections, and mongod opens exactly one — see §1.2.

The real-traffic check is §10.4 and should be your first move. To test the *proxy itself* in
isolation — many requests over a **single** connection, which is what mongod does — use
`h2load` from `nghttp2-client`.

**`h2load` cannot speak to the mTLS frontend**: current builds have no `--ca-file` and no
client-certificate options, so it cannot present the certificate that `verify required`
demands. Give it a temporary plaintext h2c frontend bound to loopback instead, and remove it
afterwards:

```bash
sudo tee -a /etc/haproxy/haproxy.cfg >/dev/null <<'EOF'

# TEMPORARY, loopback-only, for the balancing test. Remove when done.
frontend h2c_test
    bind 127.0.0.1:27040 proto h2
    default_backend mongot_pool
EOF
sudo haproxy -c -f /etc/haproxy/haproxy.cfg && sudo systemctl reload haproxy

echo "clear counters all" | sudo socat stdio /run/haproxy/admin.sock
h2load -n 100 -c 1 -m 10 http://127.0.0.1:27040/ 2>&1 | grep -E 'requests:|status codes'
echo "show stat" | sudo socat stdio /run/haproxy/admin.sock \
  | awk -F, 'NR==1{next} $1=="mongot_pool" && $2!="BACKEND" {printf "%-10s stot=%s\n",$2,$8}'
```

`-c 1` is the point: one connection, 100 requests. A healthy result splits them evenly across
the backends — this is the test that produced the 50/50 figure quoted in §1.2. mongot will
reject the requests at the application layer (they are not valid gRPC calls), which is fine —
you are measuring the proxy's distribution, not mongot's responses.

Delete the `h2c_test` frontend when you are finished.

If it still pins to one backend, try `http-reuse always` in the backend. (Default `safe`
behaviour did not cause pinning in testing, but it is the first knob to reach for.)

### 12.7 `Unknown --setParameter 'useGrpcForSearch'`

The server is older than 8.2, and search needs **8.3+**:

```bash
mongod --version | head -1
```

### 12.8 mongot will not start

```bash
sudo journalctl -u mongot -n 50 --no-pager
sudo tail -50 /var/log/mongot/mongot.log
```

Common causes: `storage.dataPath` not writable by `mongot` (`chown -R mongot:mongot
/var/lib/mongot`); the TLS key not readable; a non-PKCS#8 private key (§4.2); or a YAML
indentation error — mongot's parser is strict and its message is not always obvious.

### 12.9 Useful one-liners

```bash
# Replica set state
m --eval 'rs.status().members.map(m => m.name + " " + m.stateStr).join("\n")'

# Every search index and its status
m --eval 'db.getSiblingDB("demo").getCollectionNames().forEach(c => db.getSiblingDB("demo")[c].getSearchIndexes().forEach(i => print(c, i.name, i.status)))'

# Are the search parameters actually in effect?
m --eval 'db.adminCommand({getParameter:1, mongotHost:1, useGrpcForSearch:1, searchTLSMode:1})'

# mongot replication lag and index metrics
curl -s http://10.10.0.21:9946/metrics | grep -iE 'lag|index|replication' | head -20

# HAProxy: full backend health
echo "show servers state mongot_pool" | sudo socat stdio /run/haproxy/admin.sock

# Envoy: cluster health
curl -s http://127.0.0.1:9901/clusters | grep mongot_pool
```

---

## 13. What this POC is missing for production

Hand this list over with the demo.

1. **The load balancer is a single point of failure.** Every `$search` in the deployment goes
   through one VM. Production needs 2+ LB instances sharing a VIP (keepalived/VRRP), or a
   managed L7 balancer. Note it must remain **L7** (§1.2).
2. **SELinux is permissive** (§3.3). Needs a real policy module for mongot under `/opt`.
3. **Certificates are long-lived, self-signed, and unrotatable.** No automation, keys
   unencrypted on disk. Production wants a real PKI with rotation, and mongod's TLS certificate
   rotation is itself a rolling-restart exercise.
4. **Passwords are in plaintext files** and in this document. Use a secrets manager; both mongod
   and mongot read from files, so this integrates reasonably.
5. **No monitoring.** `/metrics` is exposed but unscraped. At minimum alert on mongot
   replication lag — sustained lag forces a re-sync, which means a **full index rebuild**.
6. **No sizing work.** JVM heap is a flat 4 GB and WiredTiger cache is default. Real sizing
   depends on index size, embedding dimensionality and query concurrency.
7. **`allowConnectionsWithoutCertificates: true`** lets any client skip certificate auth.
   Tighten with x509 client auth.
8. **No backup strategy for index data.** Indexes rebuild from `mongod`, but a rebuild on a
   large collection is long and the search tier is degraded throughout.
9. **Health and metrics endpoints have no TLS and no auth at all** — by design, per MongoDB's
   docs. They are protected only by firewall rules. Verify those rules are real.
10. **Single region, no failure-domain separation.** Both mongots can be on the same hypervisor,
    which makes the HA story cosmetic.
11. **Unsupported configuration.** MongoDB does not support hand-rolled mongot deployments. For
    supported search on self-managed infrastructure, the path is
    [MongoDB Controllers for Kubernetes](https://www.mongodb.com/docs/kubernetes/current/) (§15).

---

## 14. Open questions — verify before relying on these

Points where MongoDB's self-managed documentation is silent and this runbook had to infer.
Resolve them with MongoDB before a customer designs around them.

### 14.1 Does each mongot hold a complete copy of every index?

**This runbook assumes yes** (§1.3), and the whole round-robin design depends on it. The
evidence is circumstantial but strong: the docs describe each mongot as synchronising index data
from `mongod` over its own change-stream connection into its own dedicated storage, and MCK
round-robins across mongots with no index affinity. But no page states it outright.

**§11.4 is a direct test** — query an index created *before* a new mongot existed, confirm the
new instance serves traffic, and confirm results stay correct. Run it.

### 14.2 The full `searchTLSMode` value set

Documented: `globalTLS` (the default, inheriting `net.tls.mode`) and `disabled` (in an example).
MCK's docs reference `requireTLS` for external-mongod deployments, but the self-managed
configuration reference does not enumerate the values. This runbook therefore relies only on the
documented default (§9.1). If you need TLS on the search path with cluster TLS *off*, verify
`requireTLS` works before designing around it.

### 14.3 Hostname verification on the mongod → mongot path

The docs say mongod "validates the certificate using the `--tlsCAFile` option" but do **not**
say whether the hostname is verified against the gRPC address, nor whether
`net.tls.allowInvalidHostnames` / `allowInvalidCertificates` apply to this path (their
documented scope is other cluster members). This matters behind a load balancer, where mongod
sees the LB's certificate rather than mongot's.

This runbook sidesteps the question by issuing the LB a certificate whose SAN genuinely matches
`mongot-lb.poc.local` — correct under either behaviour. Keep doing that.

### 14.4 How a newly started mongot learns about pre-existing indexes

`createSearchIndex` goes through `searchIndexManagementHostAndPort`, so behind a load balancer it
lands on exactly **one** mongot. How the others learn the index exists is not documented. The
configuration reference mentions a "local index catalog" under `storage.dataPath`, while the
`searchCoordinator` role has write access to a `__mdb_internal_search` database in MongoDB
itself — suggesting the catalog is persisted centrally and replicated to every mongot, but the
docs never reconcile the two.

Practically this works (§11.4 demonstrates it). The mechanism, and its failure modes, are
unverified.

### 14.5 Whether all mongots behind one LB must be identically configured

Not documented. This runbook keeps them identical apart from host-specific addresses and
certificates, which is the only safe assumption.

---

## 15. Appendix A — How this maps to MongoDB's Kubernetes operator

If the customer later moves to [MCK](https://www.mongodb.com/docs/kubernetes/current/), the
architecture carries over almost one-to-one. Useful for framing the POC as a stepping stone
rather than a dead end.

| This runbook | MCK equivalent |
|---|---|
| 2+ mongot VMs | `MongoDBSearch` with `spec.clusters[].replicas` > 1 (a separately sized pool, not one per mongod) |
| HAProxy or Envoy on its own VM | A single Envoy **Deployment** per cluster, via `spec.clusters[].loadBalancer.managed` — a central service, not a sidecar |
| `mongotHost` → the LB | Operator sets `mongotHost` to the LB endpoint automatically |
| mTLS terminated at the LB, re-originated with `lb-client` | Exactly what MCK's Envoy does: "terminates the mTLS connection from `mongod` and establishes a new mTLS connection to `mongot`" using "its own client certificate [...] not the original `mongod` certificate" |
| `lb-server` SAN = `mongot-lb.poc.local` | LB server cert secret `<name>-search-lb-0-cert`, which "must be issued and signed by the same CA that issued the CA certificate that the MongoDB replica set uses" |
| `lb-client` cert | LB client cert secret `<name>-search-lb-0-client-cert` |
| mongot gRPC cert | `<name>-search-cert` |
| `add server` / `del server` at runtime | Change `replicas`; the operator reconciles |
| n/a (replica set only) | Sharded clusters: Envoy routes by **TLS SNI** to the right shard's mongots. HAProxy's analogue is `req_ssl_sni` ACLs. |

MCK's own stated reason for requiring L7 is the same single-long-lived-connection problem from
§1.2 — the constraint is in `mongod`, not in Kubernetes, which is why it applies identically
here.

Minimum versions on the MCK path: MongoDB Server 8.3.4, mongot 1.70.1, Operator 1.9.1.

---

## 16. Appendix B — Teardown

```bash
# Search tier
for h in mongot1 mongot2 mongot3; do
  ssh $h "sudo systemctl disable --now mongot; sudo rm -rf /var/lib/mongot /var/log/mongot /etc/mongot /opt/mongot-community /opt/mongot" 2>/dev/null
done

# Load balancer
ssh mongot-lb "sudo systemctl disable --now haproxy envoy 2>/dev/null; sudo rm -rf /etc/haproxy/certs /etc/envoy"

# Replica set
for h in mongo1 mongo2 mongo3; do
  ssh $h "sudo systemctl disable --now mongod; sudo rm -rf /var/lib/mongo /var/log/mongodb /etc/mongod/tls"
done
```

To drop just the search tier and leave the database intact, stop the mongots and the LB, then
remove the `setParameter` block from each `/etc/mongod.conf` and do a rolling restart (§9.2).
Search indexes remain in `__mdb_internal_search` and are picked up again if you rebuild the
search tier later.

---

## 17. Reference

**MongoDB Search, self-managed**
- [Overview](https://www.mongodb.com/docs/search/self-managed/current/)
- [Install mongot on Linux](https://www.mongodb.com/docs/search/self-managed/current/installation/linux/)
- [Configure mongot — full YAML reference](https://www.mongodb.com/docs/search/self-managed/current/configuration/reference/)
- [TLS encryption](https://www.mongodb.com/docs/search/self-managed/current/security/tls-encryption/)
- [Authentication and authorization](https://www.mongodb.com/docs/search/self-managed/current/security/authentication-and-authorization/)
- [Compatibility requirements](https://www.mongodb.com/docs/search/self-managed/current/deployment/compatibility-requirements/) — the L7 load balancer requirement
- [Verify the connection](https://www.mongodb.com/docs/search/self-managed/current/connection/verify-connection/) — `/health`, `/ready`, `/metrics`
- [Monitoring](https://www.mongodb.com/docs/search/self-managed/current/deployment/monitoring/)
- [Release notes](https://www.mongodb.com/docs/search/self-managed/current/release-notes)

**Kubernetes operator (for comparison)**
- [Deploy MongoDB Search and Vector Search](https://www.mongodb.com/docs/kubernetes/current/fts-vs-deployment/)
- [Vector Search architecture](https://www.mongodb.com/docs/kubernetes/current/tutorial/arch-vector-search/)
- [mongodb/mongodb-kubernetes](https://github.com/mongodb/mongodb-kubernetes)

**Load balancers**
- [HAProxy configuration manual](https://docs.haproxy.org/)
- [HAProxy gRPC tutorial](https://www.haproxy.com/documentation/haproxy-configuration-tutorials/protocol-support/grpc/)
- [HAProxy management guide — runtime API](https://docs.haproxy.org/dev/management.html)
- [Envoy static configuration quickstart](https://www.envoyproxy.io/docs/envoy/latest/start/quick-start/configuration-static)
- [Envoy health checking](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/health_checking)
- [Envoy HttpProtocolOptions](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/upstreams/http/v3/http_protocol_options.proto)
