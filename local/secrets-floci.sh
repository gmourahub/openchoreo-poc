#!/bin/bash
# Moves OpenChoreo's secret backend from the in-cluster OpenBao (dev mode: in
# memory, wiped on every restart) to Floci's Secrets Manager (persisted in the
# floci-data volume):
#   1. copies OpenBao's top-level keys (platform secrets seeded by the installer)
#      to Secrets Manager under the same names, as {"value": ...} JSON, which is
#      the shape the ExternalSecrets read with property "value"
#   2. points External Secrets Operator's AWS client at Floci
#   3. replaces ClusterSecretStore "default" (vault -> aws SecretsManager)
#   4. forces every ExternalSecret and PushSecret to sync again
# Secrets created in the console (PushSecrets) are re-pushed by step 4.
# Safe to re-run: step 1 only creates names missing from Secrets Manager, so it
# never overwrites a value changed there.
set -euo pipefail
cd "$(dirname "$0")"

MSYS_NO_PATHCONV=1 docker exec -i oc-toolbox bash -s <<'EOF'
set -euo pipefail
FLOCI=http://floci.internal:4566

if kubectl get clustersecretstore default -o jsonpath='{.spec.provider}' | grep -q '"vault"'; then
  echo '==> copying OpenBao keys to Floci Secrets Manager'
  bao() { kubectl -n openbao exec openbao-0 -- env BAO_TOKEN=root bao "$@"; }
  for key in $(bao kv list -format=json secret/ | jq -r '.[] | select(endswith("/") | not)'); do
    if aws secretsmanager describe-secret --secret-id "$key" > /dev/null 2>&1; then
      echo "    $key (already in Floci, kept)"
      continue
    fi
    bao kv get -format=json "secret/$key" | jq -c '.data.data' |
      aws secretsmanager create-secret --name "$key" --secret-string file:///dev/stdin > /dev/null
    echo "    $key"
  done
else
  echo '==> ClusterSecretStore already uses AWS; skipping the OpenBao copy'
fi

echo '==> External Secrets Operator -> Floci'
kubectl -n external-secrets create secret generic floci-aws-credentials \
  --from-literal=access-key-id=test --from-literal=secret-access-key=test \
  --dry-run=client -o yaml | kubectl apply -f -
helm upgrade external-secrets oci://ghcr.io/external-secrets/charts/external-secrets \
  -n external-secrets --version 2.0.1 --reuse-values \
  --set "extraEnv[0].name=AWS_SECRETSMANAGER_ENDPOINT" --set "extraEnv[0].value=$FLOCI" \
  --set "extraEnv[1].name=AWS_STS_ENDPOINT" --set "extraEnv[1].value=$FLOCI" \
  --wait --timeout 180s > /dev/null

echo '==> ClusterSecretStore default -> AWS SecretsManager (Floci)'
kubectl apply -f - <<YAML
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: default
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        secretRef:
          accessKeyIDSecretRef:
            name: floci-aws-credentials
            namespace: external-secrets
            key: access-key-id
          secretAccessKeySecretRef:
            name: floci-aws-credentials
            namespace: external-secrets
            key: secret-access-key
YAML
# kubectl apply merges spec.provider, so drop the old vault block explicitly.
kubectl patch clustersecretstore default --type json -p '[{"op":"remove","path":"/spec/provider/vault"}]' 2> /dev/null || true
kubectl wait clustersecretstore default --for=condition=Ready --timeout=60s

echo '==> forcing every ExternalSecret and PushSecret to sync'
now=$(date +%s)
kubectl get externalsecret -A --no-headers -o custom-columns=NS:.metadata.namespace,N:.metadata.name |
  while read -r ns n; do kubectl -n "$ns" annotate externalsecret "$n" force-sync="$now" --overwrite > /dev/null; done
kubectl get pushsecret -A --no-headers -o custom-columns=NS:.metadata.namespace,N:.metadata.name |
  while read -r ns n; do kubectl -n "$ns" annotate pushsecret "$n" force-sync="$now" --overwrite > /dev/null; done
sleep 10
kubectl get externalsecret,pushsecret -A
EOF
