#!/bin/bash

# Get mongot from github
MONGOT_VERSION=1.70.4

ARCH=$(uname -m)
case "$ARCH" in
  x86_64)
    MONGOT_ARCH="x86_64"
    ;;
  aarch64|arm64)
    MONGOT_ARCH="aarch64"
    ;;
  *)
    echo "Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

curl -o mongot.tar.gz -L "https://downloads.mongodb.org/mongodb-search-community/${MONGOT_VERSION}/mongot_community_${MONGOT_VERSION}_linux_${MONGOT_ARCH}.tgz"
tar -zxvf mongot.tar.gz