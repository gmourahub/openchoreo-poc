#!/bin/bash
# Installs the OpenChoreo workflow plane (Argo Workflows: build from source) on
# the Floci cluster. Same steps as install_workflow_plane in the upstream k3d
# installer, adapted to Floci:
#   - no in-cluster registry (twuni): builds push to Floci's ECR, which the node
#     already pulls from (see ecr-mirror.sh)
#   - publish-image pushes to 000000000000.dkr.ecr.us-east-1.localhost:4566
#     instead of host.k3d.internal:10082
#   - host.k3d.internal (generate-workload's control-plane URL) resolves to the
#     node via dns.sh
# Runs helm/kubectl inside oc-toolbox. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"

bash ecr-mirror.sh
bash dns.sh > /dev/null

MSYS_NO_PATHCONV=1 docker exec -i -e VERSION="$(cat ../src/VERSION)" oc-toolbox bash -s <<'EOF'
set -euo pipefail
NS=openchoreo-workflow-plane
CP=openchoreo-control-plane
REGISTRY=000000000000.dkr.ecr.us-east-1.localhost:4566
T=/repo/samples/getting-started/workflow-templates

echo '==> cluster-gateway CA for the workflow plane agent'
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
# From the Secret, not the control plane's ConfigMap: a helm upgrade of the control
# plane resets that ConfigMap to a placeholder.
ca_crt=$(kubectl get secret cluster-gateway-ca -n "$CP" -o jsonpath='{.data.ca\.crt}' | base64 -d)
kubectl create configmap cluster-gateway-ca --from-literal=ca.crt="$ca_crt" \
  -n "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo "==> openchoreo-workflow-plane $VERSION"
helm upgrade --install openchoreo-workflow-plane \
  oci://ghcr.io/openchoreo/helm-charts/openchoreo-workflow-plane \
  --version "$VERSION" --namespace "$NS" \
  --values /repo/install/k3d/single-cluster/values-wp.yaml

echo '==> workflow templates (publish-image -> Floci ECR)'
kubectl apply -f "$T/checkout-source.yaml" \
  -f /repo/samples/getting-started/workflow-templates.yaml \
  -f "$T/generate-workload-k3d.yaml"
sed "s#host.k3d.internal:10082#$REGISTRY#" "$T/publish-image-k3d.yaml" | kubectl apply -f -

echo '==> registering the workflow plane'
kubectl wait -n "$NS" --for=condition=Ready certificate/cluster-agent-workflowplane-tls --timeout=120s
ca=$(kubectl get secret cluster-agent-tls -n "$NS" -o jsonpath='{.data.ca\.crt}' | base64 -d)
kubectl apply -f - <<YAML
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterWorkflowPlane
metadata:
  name: default
spec:
  planeID: default
  clusterAgent:
    clientCA:
      value: |
$(echo "$ca" | sed 's/^/        /')
  secretStoreRef:
    name: default
YAML
if kubectl get clusterobservabilityplane default > /dev/null 2>&1; then
  kubectl patch clusterworkflowplane default --type merge \
    -p '{"spec":{"observabilityPlaneRef":{"kind":"ClusterObservabilityPlane","name":"default"}}}'
fi

kubectl -n "$NS" wait --for=condition=Available deployment --all --timeout=300s
echo
echo 'Workflow plane ready. Argo UI: http://localhost:10081'
EOF
