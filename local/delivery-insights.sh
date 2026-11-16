#!/bin/bash
# Turns on Delivery Insights (DORA metrics, feature preview): the Observer collects
# delivery data and the console shows the page. Both flags are needed. Run again
# after install.sh, which reinstalls the planes without them. Runs helm/kubectl
# inside oc-toolbox. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"

MSYS_NO_PATHCONV=1 docker exec -i -e VERSION="$(cat ../src/VERSION)" oc-toolbox bash -s <<'EOF'
set -euo pipefail
REPO=oci://ghcr.io/openchoreo/helm-charts
CP=openchoreo-control-plane
OBS=openchoreo-observability-plane

echo '==> Observer: collect delivery data'
helm upgrade openchoreo-observability-plane "$REPO/openchoreo-observability-plane" \
  --version "$VERSION" --namespace "$OBS" --reuse-values \
  --set observer.featurePreview.deliveryInsights.enabled=true --timeout 10m > /dev/null
kubectl -n "$OBS" rollout restart deployment/observer
kubectl -n "$OBS" rollout status deployment/observer --timeout=300s

echo '==> Console: Delivery Insights page'
helm upgrade openchoreo-control-plane "$REPO/openchoreo-control-plane" \
  --version "$VERSION" --namespace "$CP" --reuse-values \
  --set backstage.features.deliveryInsights.enabled=true --timeout 10m > /dev/null
# A control-plane upgrade resets this ConfigMap to a placeholder; refill it like the installer does.
ca_crt=$(kubectl get secret cluster-gateway-ca -n "$CP" -o jsonpath='{.data.ca\.crt}' | base64 -d)
kubectl create configmap cluster-gateway-ca --from-literal=ca.crt="$ca_crt" \
  -n "$CP" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$CP" rollout status deployment/backstage --timeout=300s
EOF
