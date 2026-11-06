# Runs the search-no-k8s experiment inside a single Linux container.
#
# mongot Community ships for Linux only, and every config in this repo points
# at "localhost", so all processes (mongod/mongos, mongot, haproxy) live in one
# container rather than being split across compose services.
FROM ubuntu:24.04

# MONGODB_VERSION selects the apt repo line, MONGODB_PACKAGE_VERSION pins the
# exact server build. 8.2+ is required either way: the repo's scripts pass
# --setParameter useGrpcForSearch, which MongoDB 8.0 rejects at startup with
# "Unknown --setParameter".
ARG MONGODB_VERSION=8.3
ARG MONGODB_PACKAGE_VERSION=8.3.3
# MongoDB publishes one signing key per major line; 8.0's key also signs the
# 8.2 and 8.3 repos and there is no server-8.2.asc or server-8.3.asc, so the
# key version is set separately from the repo version.
ARG MONGODB_KEY_VERSION=8.0
ARG MONGOT_VERSION=1.70.4
ENV DEBIAN_FRONTEND=noninteractive

# Base tools + MongoDB apt repo (amd64 and arm64 are both published).
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg openssl procps haproxy tini \
 && install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL "https://pgp.mongodb.com/server-${MONGODB_KEY_VERSION}.asc" \
      | gpg --dearmor -o "/etc/apt/keyrings/mongodb-server.gpg" \
 && echo "deb [ arch=amd64,arm64 signed-by=/etc/apt/keyrings/mongodb-server.gpg ] https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/${MONGODB_VERSION} multiverse" \
      > "/etc/apt/sources.list.d/mongodb-org-${MONGODB_VERSION}.list" \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      "mongodb-org-server=${MONGODB_PACKAGE_VERSION}" \
      "mongodb-org-mongos=${MONGODB_PACKAGE_VERSION}" \
      "mongodb-org-shell=${MONGODB_PACKAGE_VERSION}" \
      mongodb-mongosh \
 && apt-mark hold mongodb-org-server mongodb-org-mongos mongodb-org-shell \
 && rm -rf /var/lib/apt/lists/* \
 && mongod --version | head -1

WORKDIR /opt/search-no-k8s

# mongot bundles its own JDK, so no JRE package is needed.
# Fetched directly rather than via setup.sh so the layer is cached and the
# build fails loudly on a bad download.
RUN set -eux; \
    case "$(uname -m)" in \
      x86_64)        MONGOT_ARCH=x86_64 ;; \
      aarch64|arm64) MONGOT_ARCH=aarch64 ;; \
      *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/mongot.tar.gz \
      "https://downloads.mongodb.org/mongodb-search-community/${MONGOT_VERSION}/mongot_community_${MONGOT_VERSION}_linux_${MONGOT_ARCH}.tgz"; \
    tar -zxf /tmp/mongot.tar.gz -C /opt/search-no-k8s; \
    rm /tmp/mongot.tar.gz; \
    /opt/search-no-k8s/mongot-community/mongot --version || true

COPY replica_set_plus_search/     ./replica_set_plus_search/
COPY sharded_cluster_plus_search/ ./sharded_cluster_plus_search/
COPY docker/prepare_dirs.sh docker/entrypoint.sh ./docker/
COPY docker/patch_scripts.sh docker/shard2_users.part docker/reset_marker.part ./docker/
RUN chmod +x ./docker/*.sh ./*/*.sh \
 && ./docker/patch_scripts.sh

# TOPOLOGY selects which project the entrypoint brings up.
ENV TOPOLOGY=replica_set

# Replica set: mongods 27017-27019, mongot gRPC 27028-27029, haproxy 27030.
EXPOSE 27017 27018 27019 27020 27030 27031

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/search-no-k8s/docker/entrypoint.sh"]
