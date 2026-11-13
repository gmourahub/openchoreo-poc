#!/bin/bash
# Installs Argo CD and points it at the GitOps repo. The root Application
# (app-of-apps) syncs argocd/apps in that repo, which holds one Application per
# directory, ordered by sync waves:
#   0 namespaces, platform-shared -> 1 platform -> 2 projects
# Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"
GITOPS_REPO=${GITOPS_REPO:-https://github.com/gmourahub/sample-gitops}
CHART_VERSION=10.18.0 # Argo CD v3.6.1

MSYS_NO_PATHCONV=1 docker exec -i -e GITOPS_REPO="$GITOPS_REPO" -e CHART_VERSION="$CHART_VERSION" oc-toolbox bash -s <<'EOF'
set -euo pipefail
echo "==> Argo CD (chart $CHART_VERSION)"
helm repo add argo https://argoproj.github.io/argo-helm > /dev/null 2>&1 || true
helm repo update argo > /dev/null
helm upgrade --install argocd argo/argo-cd --version "$CHART_VERSION" \
  -n argocd --create-namespace --values /local/argocd-values.yaml --wait --timeout 600s > /dev/null

echo "==> root Application -> $GITOPS_REPO (argocd/apps)"
kubectl apply -f - <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: $GITOPS_REPO
    targetRevision: main
    path: argocd/apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: {prune: true, selfHeal: true}
YAML

pw=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
echo
echo "Argo CD UI: http://localhost:10083  (admin / $pw)"
EOF
