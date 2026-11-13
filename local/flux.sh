#!/bin/bash
# Installs Flux from the GitOps repo and starts syncing it. Flux's own manifests
# live in that repo (flux/flux-system/gotk-components.yaml) and the flux-system
# Kustomization keeps them applied, so after this first run Flux upgrades itself
# through PRs there. Safe to re-run.
#   GITOPS_REPO=https://github.com/<user>/sample-gitops bash local/flux.sh
set -euo pipefail
cd "$(dirname "$0")"
GITOPS_REPO=${GITOPS_REPO:-https://github.com/gmourahub/sample-gitops}
RAW=$(echo "$GITOPS_REPO" | sed 's#https://github.com/#https://raw.githubusercontent.com/#')/main

MSYS_NO_PATHCONV=1 docker exec -i -e RAW="$RAW" oc-toolbox bash -s <<'EOF'
set -euo pipefail
echo "==> Flux controllers ($RAW/flux/flux-system/gotk-components.yaml)"
kubectl apply --server-side -f "$RAW/flux/flux-system/gotk-components.yaml" > /dev/null
kubectl -n flux-system wait --for=condition=Available deployment --all --timeout=300s > /dev/null

echo '==> GitRepository + flux-system Kustomization (the rest comes from the repo)'
kubectl apply -f "$RAW/flux/gitrepository.yaml" -f "$RAW/flux/flux-system.yaml"
kubectl -n flux-system wait --for=condition=Ready kustomization --all --timeout=600s > /dev/null || true
kubectl -n flux-system get gitrepository,kustomization
EOF
