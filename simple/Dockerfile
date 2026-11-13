# One container, two processes: mongod and mongot side by side on localhost.
#
# This is the smallest thing that demonstrates how mongod and mongot are wired
# together. There is no load balancer, no TLS, and only one of each process.
# See RUNBOOK.md in this repo for the scalable, multi-host version.
FROM ubuntu:24.04

# MongoDB 8.3 is the minimum for self-managed Search. 8.2 is EOL as a search
# source and 8.0 rejects --setParameter useGrpcForSearch at startup.
ARG MONGODB_VERSION=8.3
ARG MONGODB_PACKAGE_VERSION=8.3.17
# MongoDB publishes one signing key per major line; the 8.0 key also signs the
# 8.3 repo and there is no server-8.3.asc.
ARG MONGODB_KEY_VERSION=8.0
ARG MONGOT_VERSION=1.70.6
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg openssl procps tini \
 && install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL "https://pgp.mongodb.com/server-${MONGODB_KEY_VERSION}.asc" \
      | gpg --dearmor -o /etc/apt/keyrings/mongodb-server.gpg \
 && echo "deb [ arch=amd64,arm64 signed-by=/etc/apt/keyrings/mongodb-server.gpg ] https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/${MONGODB_VERSION} multiverse" \
      > /etc/apt/sources.list.d/mongodb-org.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      "mongodb-org-server=${MONGODB_PACKAGE_VERSION}" \
      mongodb-mongosh \
 && apt-mark hold mongodb-org-server \
 && rm -rf /var/lib/apt/lists/* \
 && mongod --version | head -1

# mongot Community ships as a tarball with its own bundled JDK, so no JRE
# package is required. It is published for Linux x86_64 and aarch64 only.
RUN set -eux; \
    case "$(uname -m)" in \
      x86_64)        MONGOT_ARCH=x86_64 ;; \
      aarch64|arm64) MONGOT_ARCH=aarch64 ;; \
      *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    mkdir -p /opt/mongot; \
    curl -fsSL -o /tmp/mongot.tgz \
      "https://downloads.mongodb.org/mongodb-search-community/${MONGOT_VERSION}/mongot_community_${MONGOT_VERSION}_linux_${MONGOT_ARCH}.tgz"; \
    tar -xzf /tmp/mongot.tgz -C /opt/mongot --strip-components=1; \
    rm /tmp/mongot.tgz; \
    test -x /opt/mongot/mongot

COPY mongot.yaml   /etc/mongot.yaml
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# 27017 mongod | 8080 mongot health | 9946 mongot Prometheus metrics
# mongot's gRPC port (27028) is deliberately NOT exposed: only mongod talks to it.
EXPOSE 27017 8080 9946
VOLUME /data

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
