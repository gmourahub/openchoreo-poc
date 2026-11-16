#!/bin/bash
# Swaps the OpenChoreo console logo for the Empresa one (branding/*.svg) through the
# chart's backstage.appConfig (app.branding.{name,fullLogo,iconLogo}), as data URIs
# so nothing is fetched from outside. Run again after install.sh, which reinstalls
# the control plane without it. Runs helm/kubectl inside oc-toolbox. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"

uri() { printf 'data:image/svg+xml;base64,%s' "$(base64 -w0 "$1")"; }
VALUES="backstage:
  appConfig:
    app:
      branding:
        name: Empresa
        fullLogo: $(uri branding/empresa-logo.svg)
        iconLogo: $(uri branding/empresa-icon.svg)"

MSYS_NO_PATHCONV=1 docker exec -i -e VERSION="$(cat ../src/VERSION)" -e VALUES="$VALUES" oc-toolbox bash -s <<'EOF'
set -euo pipefail
CP=openchoreo-control-plane
printf '%s\n' "$VALUES" > /tmp/branding-values.yaml
helm upgrade openchoreo-control-plane oci://ghcr.io/openchoreo/helm-charts/openchoreo-control-plane \
  --version "$VERSION" --namespace "$CP" --reuse-values --values /tmp/branding-values.yaml
# A control-plane upgrade resets this ConfigMap to a placeholder; refill it like the installer does.
ca_crt=$(kubectl get secret cluster-gateway-ca -n "$CP" -o jsonpath='{.data.ca\.crt}' | base64 -d)
kubectl create configmap cluster-gateway-ca --from-literal=ca.crt="$ca_crt" \
  -n "$CP" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$CP" rollout status deploy/backstage --timeout=300s
EOF
