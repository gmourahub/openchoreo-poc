#!/bin/bash
# Floci writes the node's containerd mirrors for its ECR
# (/etc/rancher/k3s/registries.yaml) with Floci's IP at cluster creation. That IP
# changes when Docker restarts the containers, and every image pull from ECR
# then fails. Point the mirrors at the container name instead (Docker DNS on the
# compose network) and restart the node once. Safe to re-run: no-op when fixed.
set -euo pipefail
cd "$(dirname "$0")"
# Only for the docker exec paths: a global MSYS_NO_PATHCONV breaks curl -o /dev/null.
dx() { MSYS_NO_PATHCONV=1 docker exec "$@"; }
NODE=floci-aws-eks-openchoreo
FILE=/etc/rancher/k3s/registries.yaml

if ! dx "$NODE" grep -qE 'http://[0-9.]+:4566' "$FILE"; then
  echo 'ECR mirror already uses oc-floci'
  exit 0
fi
dx "$NODE" sed -i -E 's#http://[0-9.]+:4566#http://oc-floci:4566#' "$FILE"
echo 'ECR mirror now uses oc-floci; restarting the node so containerd reloads it'
docker restart "$NODE" > /dev/null
until curl -sk -m 3 -o /dev/null https://localhost:6500/version; do sleep 2; done
until kubectl --kubeconfig kubeconfig get nodes 2> /dev/null | grep -q ' Ready'; do sleep 3; done
