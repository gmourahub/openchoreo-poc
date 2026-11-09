#!/bin/bash
# Installs OpenChoreo on the Floci EKS cluster by running the upstream k3d
# installer (from ../src, pinned to a release tag) with the k3d-only bits swapped
# for Floci equivalents. Runs inside the oc-toolbox container. Safe to re-run.
#   bash install.sh [--with-build] [--with-observability]
set -euo pipefail
cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1
NODE_CONTAINER=floci-aws-eks-openchoreo

bash dns.sh

sed \
  -e 's/^KUBECTL=.*/KUBECTL="kubectl"/' \
  -e 's/^HELM=.*/HELM="helm"/' \
  -e 's/for t in k3d kubectl helm docker/for t in kubectl helm docker/' \
  -e 's/^create_cluster() {/create_cluster() { return 0;/' \
  -e 's#"$(asset install/k3d/common/coredns-custom.yaml)"#/local/coredns-custom.yaml#' \
  -e "s#\"k3d-\${CLUSTER_NAME}-server-0\"#$NODE_CONTAINER#" \
  -e 's/k3d cluster delete ${CLUSTER_NAME}/docker exec oc-toolbox aws eks delete-cluster --name openchoreo/' \
  ../src/install/k3d/k3d-install.sh > .floci-install.sh

docker exec oc-toolbox bash /local/.floci-install.sh --version "$(cat ../src/VERSION)" "$@"

# Legacy SA token Secrets (Prometheus -> kubelet) need re-signed tokens on Floci.
bash fix-sa-token-secrets.sh
