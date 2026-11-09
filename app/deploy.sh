#!/bin/bash
# Deploys doc-insights to the development environment. Safe to re-run; run
# build-push.sh first (or again, to roll out a code change).
set -euo pipefail
cd "$(dirname "$0")"
export KUBECONFIG="$(cygpath -m "$PWD/../local/kubeconfig" 2>/dev/null || echo "$PWD/../local/kubeconfig")"
[ -f .images ] || { echo 'no .images: run build-push.sh first' >&2; exit 1; }
. ./.images

echo '==> platform resource types (S3, SQS)'
kubectl apply -f platform/

echo '==> project'
kubectl apply -f openchoreo/project.yaml
kubectl wait --for=condition=Ready --timeout=5m projectreleasebinding/doc-insights-development

echo '==> resources (bucket, queue)'
kubectl apply -f openchoreo/resources.yaml
for r in docs-bucket docs-queue; do
  release=''
  for _ in $(seq 1 60); do
    release=$(kubectl get resource "$r" -o jsonpath='{.status.latestRelease.name}')
    [ -n "$release" ] && break
    sleep 2
  done
  [ -n "$release" ] || { echo "no release for resource $r" >&2; kubectl get resource "$r" -o yaml >&2; exit 1; }
  kubectl patch resourcereleasebinding "$r-development" --type=merge -p "{\"spec\":{\"resourceRelease\":\"$release\"}}"
done
kubectl wait --for=condition=Ready --timeout=5m resourcereleasebinding/docs-bucket-development resourcereleasebinding/docs-queue-development

echo '==> alerting (needs the observability plane)'
kubectl apply -f openchoreo/alerts.yaml

echo '==> components (api, worker, frontend)'
sed -e "s#__BACKEND_IMAGE__#$BACKEND_IMAGE#" -e "s#__FRONTEND_IMAGE__#$FRONTEND_IMAGE#" openchoreo/components.yaml |
  kubectl apply -f -

for c in api worker frontend; do
  for _ in $(seq 1 60); do
    kubectl get releasebinding "$c-development" > /dev/null 2>&1 && break
    sleep 2
  done
done
kubectl wait --for=condition=Ready --timeout=5m \
  releasebinding/api-development releasebinding/worker-development releasebinding/frontend-development

HOST=$(kubectl get httproute -A -l openchoreo.dev/component=frontend -o jsonpath='{.items[0].spec.hostnames[0]}')
echo
echo "Doc Insights: http://$HOST:19080/"
