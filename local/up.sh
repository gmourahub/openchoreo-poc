#!/bin/bash
# Starts the environment stopped by down.sh (or by a Docker/PC restart) and
# waits until OpenChoreo answers. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"
# No global MSYS_NO_PATHCONV here: it makes Windows curl write to a literal
# "/dev/null" path and fail (exit 23). The helper scripts set it themselves.
K="kubectl --kubeconfig kubeconfig"

echo '==> Floci + toolbox'
# Other Floci stacks (cnoe-local, spike-floci) also bind 4566. If one is up,
# oc-floci fails to start and any curl on 4566 hits the wrong Floci.
other=$(docker ps --filter publish=4566 \
  --format '{{.Names}} (compose project: {{.Label "com.docker.compose.project"}})' |
  grep -v '^oc-floci ' || true)
if [ -n "$other" ]; then
  echo "ERROR: port 4566 is already used by: $other" >&2
  echo "       Stop that stack first (docker compose -p <project> stop) and re-run." >&2
  exit 1
fi
docker compose up -d floci toolbox
# After a failed start, oc-floci can come back without the compose network,
# which dns.sh needs to find Floci's IP. Reattach it instead of recreating.
if ! docker inspect oc-floci --format '{{json .NetworkSettings.Networks}}' |
  grep -q '"openchoreo-floci_default"'; then
  echo '    reattaching oc-floci to the openchoreo-floci_default network'
  docker network connect --alias floci openchoreo-floci_default oc-floci
fi
until [ "$(docker inspect -f '{{.State.Health.Status}}' oc-floci)" = healthy ]; do sleep 2; done

echo '==> EKS node (k3s) and ECR registry'
docker start floci-aws-ecr-registry floci-aws-eks-openchoreo > /dev/null
until curl -sk -m 3 -o /dev/null https://localhost:6500/version; do sleep 2; done
until $K get nodes 2> /dev/null | grep -q ' Ready'; do sleep 3; done
# Floci's IP can change on restart; the node's ECR mirror must follow it.
bash ecr-mirror.sh

echo '==> localhost gateway (8080, 19080, 11080, ...)'
docker compose --profile gateway up -d gateway

echo '==> cluster DNS (Floci, Ollama and node addresses can change on restart)'
bash dns.sh > /dev/null

echo '==> waiting for OpenChoreo'
for ns in openchoreo-control-plane openchoreo-data-plane openchoreo-observability-plane ai-gateway; do
  $K -n "$ns" wait --for=condition=Available deployment --all --timeout=600s > /dev/null ||
    echo "    WARNING: some deployments in $ns are not available yet"
done
bash fix-sa-token-secrets.sh > /dev/null

if curl -sf -m 3 -o /dev/null http://localhost:11434/api/tags; then
  echo '==> Ollama is running (AI agents ready)'
else
  echo '==> WARNING: Ollama is not running on Windows; start it for the AI agents'
fi

code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 http://openchoreo.localhost:8080/ || true)
echo
echo "Console     http://openchoreo.localhost:8080  (HTTP $code; admin@openchoreo.dev / Admin@123)"
echo "Doc Insights http://http-frontend-development-default-4cc7110c.openchoreoapis.localhost:19080/"
