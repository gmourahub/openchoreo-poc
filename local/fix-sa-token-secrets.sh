#!/bin/bash
# Floci points kube-apiserver at its own service-account signing key, but k3s's
# token controller still signs legacy kubernetes.io/service-account-token
# Secrets with the k3s key. Those tokens fail with "invalid signature", e.g.
# Prometheus scraping the kubelet (401). Refill each such Secret with a token
# from the TokenRequest API, which the apiserver signs with the trusted key.
# The controller leaves a non-empty token alone. Safe to re-run; tokens last 1 year.
set -euo pipefail
cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1
K="kubectl --kubeconfig kubeconfig"

$K get secrets -A --field-selector type=kubernetes.io/service-account-token \
  -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name} {.metadata.annotations.kubernetes\.io/service-account\.name}{"\n"}{end}' |
while read -r ns name sa; do
  [ -n "$sa" ] || continue
  token=$($K -n "$ns" get secret "$name" -o jsonpath='{.data.token}' | base64 -d)
  ok=$(printf '{"apiVersion":"authentication.k8s.io/v1","kind":"TokenReview","spec":{"token":"%s"}}' "$token" |
    $K create -f - -o jsonpath='{.status.authenticated}')
  if [ "$ok" = true ]; then
    echo "ok       $ns/$name"
    continue
  fi
  new=$($K -n "$ns" create token "$sa" --duration=8760h)
  $K -n "$ns" patch secret "$name" --type=merge -p "{\"data\":{\"token\":\"$(printf %s "$new" | base64 -w0)\"}}" > /dev/null
  echo "refilled $ns/$name (service account $sa)"
  # prometheus-operator copies the token into Prometheus' config only on a
  # resync; touching the namespace's ServiceMonitors triggers one.
  $K -n "$ns" annotate servicemonitor --all floci.local/token-refreshed="$(date +%s)" --overwrite > /dev/null 2>&1 || true
done
