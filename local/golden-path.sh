#!/bin/bash
# Golden Path Empresa (golden-path/): installs the platform resources and the
# "Nova aplicação Empresa" scaffolder template in the local OpenChoreo.
#   bash local/golden-path.sh                 # apply everything (safe to re-run)
#   bash local/golden-path.sh slack-webhook   # store the Slack incoming webhook URL
#   bash local/golden-path.sh team <name>     # RBAC binding for IdP group <name>
# Needs local/gitea.sh first (git server, token empresa-git-token, push webhook).
# Run again after install.sh or branding.sh (both reset the Backstage values).
# Runs helm/kubectl inside oc-toolbox, like the other scripts here.
set -euo pipefail
cd "$(dirname "$0")/.."
GP=golden-path

# Stores {"<prop>": "<value read without echo>"} in Floci Secrets Manager as $1.
store_secret() {
  local name=$1 prop=$2 value
  read -rsp "$3: " value; echo
  [ -n "$value" ] || { echo 'empty, nothing stored' >&2; exit 1; }
  printf '{"%s":"%s"}' "$prop" "$value" | MSYS_NO_PATHCONV=1 docker exec -i oc-toolbox sh -c '
    f=$(mktemp); cat > "$f"
    aws secretsmanager create-secret --name "$1" --secret-string "file://$f" > /dev/null 2>&1 ||
      aws secretsmanager put-secret-value --secret-id "$1" --secret-string "file://$f" > /dev/null
    rm -f "$f"' _ "$name"
  echo "stored $name"
}

case "${1:-apply}" in
  slack-webhook)
    store_secret slack-webhook url 'Slack webhook URL'
    exit 0 ;;
  team)
    team=${2:?usage: golden-path.sh team <name>}
    [[ $team =~ ^[a-z][a-z0-9-]*$ ]] || { echo "invalid team name: $team" >&2; exit 1; }
    sed "s/TEAM/$team/g" $GP/platform/rbac-team.yaml | MSYS_NO_PATHCONV=1 docker exec -i oc-toolbox kubectl apply -f -
    exit 0 ;;
  apply) ;;
  *) sed -n 2,10p "$0"; exit 1 ;;
esac

# Scaffolder template + skeleton as one ConfigMap (flat keys), mounted file by file
# with subPath: a whole-ConfigMap volume is symlinks into "..<timestamp>/", which
# fetch:template rejects as "outside its parent". subPath files don't update in place,
# so Backstage is restarted at the end.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cp $GP/scaffolder/template.yaml "$tmp/template.yaml"
args=(--from-file="$tmp/template.yaml")
mounts="    - {name: empresa-templates, mountPath: /app/empresa-templates/template.yaml, subPath: template.yaml}"
for f in $GP/template-repo/* $GP/template-repo/.[!.]*; do
  [ -f "$f" ] || continue
  args+=(--from-file="$f"); b=$(basename "$f")
  mounts+=$'\n'"    - {name: empresa-templates, mountPath: /app/empresa-templates/skeleton/$b, subPath: $b}"
done
cm=$(kubectl --kubeconfig local/kubeconfig create configmap empresa-templates \
  -n openchoreo-control-plane "${args[@]}" --dry-run=client -o yaml)

# Backstage: Gitea registered as a GitHub Enterprise host (publish:github works
# against its API; publish:gitea is not in the 1.3.3 image) and the template location.
# Backstage replaces arrays instead of merging them, so the default
# catalog.locations of the 1.3.3 image are declared again here.
defaults="org.yaml:Group"
for t in componenttype resourcetype projecttype trait workflow environment namespace \
         deploymentpipeline clustercomponenttype clusterresourcetype clusterprojecttype \
         clustertrait clusterworkflow notification-channel; do
  defaults+=" create-openchoreo-$t:Template"
done
locations=$(for d in $defaults; do
  n=${d%%:*}; k=${d##*:}
  [ "$n" = org.yaml ] && p=/app/catalog-entities/org.yaml || p=/app/templates/$n/template.yaml
  printf '        - {type: file, target: %s, rules: [{allow: [%s]}]}\n' "$p" "$k"
done)
VALUES="backstage:
  appConfig:
    integrations:
      github:
        - host: gitea.internal:3300
          apiBaseUrl: http://gitea.internal:3300/api/v1
          rawBaseUrl: http://gitea.internal:3300
          token: \${EMPRESA_GIT_TOKEN}
    catalog:
      locations:
$locations
        - {type: file, target: /app/empresa-templates/template.yaml, rules: [{allow: [Template]}]}
  extraEnv:
    - name: EMPRESA_GIT_TOKEN
      valueFrom:
        secretKeyRef: {name: empresa-git, key: token, optional: true}
  extraVolumes:
    - name: empresa-templates
      configMap:
        name: empresa-templates
  extraVolumeMounts:
$mounts"

{ echo "$cm"; echo ---; cat $GP/platform/empresa-service.yaml; echo ---; cat $GP/platform/traits.yaml
  echo ---; cat $GP/platform/workflow.yaml; } > "$tmp/platform.yaml"
to_toolbox() { MSYS_NO_PATHCONV=1 docker exec -i oc-toolbox sh -c "cat > $2" < "$1"; }
to_toolbox "$tmp/platform.yaml" /tmp/gp-platform.yaml
to_toolbox $GP/platform/guardrails.yaml /tmp/gp-guardrails.yaml

MSYS_NO_PATHCONV=1 docker exec -i -e VERSION="$(cat src/VERSION)" -e VALUES="$VALUES" oc-toolbox bash -s <<'EOF'
set -euo pipefail
CP=openchoreo-control-plane

echo '==> Kyverno (the real EKS already has it)'
if ! kubectl get crd clusterpolicies.kyverno.io > /dev/null 2>&1; then
  helm repo add kyverno https://kyverno.github.io/kyverno/ > /dev/null 2>&1 || true
  helm upgrade --install kyverno kyverno/kyverno --version 3.9.2 -n kyverno --create-namespace \
    --set backgroundController.enabled=false --set cleanupController.enabled=false \
    --set reportsController.enabled=false --wait --timeout 5m
fi

echo '==> ComponentType, traits, workflow, scaffolder template'
kubectl apply -f /tmp/gp-platform.yaml
kubectl apply -f /tmp/gp-guardrails.yaml

echo '==> Gitea token for Backstage (Floci empresa-git-token -> Secret empresa-git)'
kubectl -n default delete secretreference github-git --ignore-not-found
kubectl apply -f - <<YAML
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: empresa-git
  namespace: $CP
spec:
  refreshInterval: 1m
  secretStoreRef: {kind: ClusterSecretStore, name: default}
  target: {name: empresa-git, creationPolicy: Owner}
  data:
    - secretKey: token
      remoteRef: {key: empresa-git-token, property: token}
YAML

echo '==> Backstage values'
printf '%s\n' "$VALUES" > /tmp/gp-values.yaml
helm upgrade openchoreo-control-plane oci://ghcr.io/openchoreo/helm-charts/openchoreo-control-plane \
  --version "$VERSION" --namespace "$CP" --reuse-values --values /tmp/gp-values.yaml
# A control-plane upgrade resets this ConfigMap to a placeholder; refill it like the installer does.
ca_crt=$(kubectl get secret cluster-gateway-ca -n "$CP" -o jsonpath='{.data.ca\.crt}' | base64 -d)
kubectl create configmap cluster-gateway-ca --from-literal=ca.crt="$ca_crt" \
  -n "$CP" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$CP" rollout restart deploy/backstage
kubectl -n "$CP" rollout status deploy/backstage --timeout=300s
EOF
echo
echo 'Golden Path installed. Portal: Create > "Nova aplicação Empresa"'
