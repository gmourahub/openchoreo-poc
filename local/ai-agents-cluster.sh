#!/bin/bash
# Cluster half of ai-agents.sh; runs inside oc-toolbox (kubectl/helm against
# the Floci cluster). Expects LLM_MODEL and LLM_BASE_URL.
set -euo pipefail
: "${LLM_MODEL:?}" "${LLM_BASE_URL:?}"
REPO=oci://cr.openchoreo.dev/openchoreo/helm-charts
VERSION=$(cat /repo/VERSION)
FINOPS_MODULE_VERSION=0.3.0
OBS=openchoreo-observability-plane
CP=openchoreo-control-plane
# Ollama ignores API keys, but the agents require one to be set.
PLACEHOLDER_KEY=ollama-local

echo "==> ollama-shim (OpenAI-compatible front for the host's Ollama)"
kubectl create namespace ai-gateway --dry-run=client -o yaml | kubectl apply -f -
kubectl -n ai-gateway create configmap ollama-shim --from-file=/local/ollama-shim/shim.py \
  --dry-run=client -o yaml | kubectl apply -f -
sed "s/__SHIM_CHECKSUM__/$(sha256sum /local/ollama-shim/shim.py | cut -c1-16)/" /local/ollama-shim/deploy.yaml |
  kubectl apply -f -
kubectl -n ai-gateway rollout status deployment/ollama-shim --timeout=180s

echo "==> agent secrets"
# OAuth client secrets come from OpenBao (seeded by the installer); the LLM key
# is a literal in the template so it survives OpenBao (dev mode) restarts.
kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: rca-agent-secret
  namespace: ${OBS}
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: default }
  target:
    name: rca-agent-secret
    template:
      data:
        RCA_LLM_API_KEY: ${PLACEHOLDER_KEY}
        OAUTH_CLIENT_SECRET: "{{ .oauth }}"
  data:
    - secretKey: oauth
      remoteRef: { key: rca-oauth-client-secret, property: value }
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: finops-agent
  namespace: ${OBS}
spec:
  refreshInterval: 1h
  secretStoreRef: { kind: ClusterSecretStore, name: default }
  target:
    name: finops-agent
    template:
      data:
        LLM_API_KEY: ${PLACEHOLDER_KEY}
        OAUTH_CLIENT_SECRET: "{{ .oauth }}"
  data:
    - secretKey: oauth
      remoteRef: { key: finops-agent-oauth-client-secret, property: value }
EOF
kubectl create secret generic portal-assistant-secret -n "$CP" \
  --from-literal=PORTAL_ASSISTANT_LLM_API_KEY="$PLACEHOLDER_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl wait -n "$OBS" --for=condition=Ready --timeout=120s \
  externalsecret/rca-agent-secret externalsecret/finops-agent

echo "==> FinOps module (OpenCost ${FINOPS_MODULE_VERSION})"
helm upgrade --install finops-opencost oci://ghcr.io/openchoreo/helm-charts/finops-opencost \
  --version "$FINOPS_MODULE_VERSION" --namespace "$OBS" --wait --timeout 10m

echo "==> SRE (RCA) and FinOps agents on the observability plane"
helm upgrade openchoreo-observability-plane "$REPO/openchoreo-observability-plane" \
  --version "$VERSION" --namespace "$OBS" --reuse-values \
  --set rca.enabled=true \
  --set rca.llm.modelName="$LLM_MODEL" \
  --set rca.llm.baseUrl="$LLM_BASE_URL" \
  --set finOpsAgent.enabled=true \
  --set finOpsAgent.llmName="$LLM_MODEL" \
  --set finOpsAgent.llmBaseUrl="$LLM_BASE_URL" \
  --timeout 10m
kubectl patch clusterobservabilityplane default --type=merge -p '{"spec":{
  "rcaAgentURL":"http://rca-agent.openchoreo.localhost:11080",
  "finOpsAgentURL":"http://finops-agent.openchoreo.localhost:11080"}}'

echo "==> Portal Assistant on the control plane"
# reasoningEffort is an OpenAI-only knob; leave it unset for Ollama.
helm upgrade openchoreo-control-plane "$REPO/openchoreo-control-plane" \
  --version "$VERSION" --namespace "$CP" --reuse-values \
  --set portalAssistant.enabled=true \
  --set portalAssistant.llm.secretName=portal-assistant-secret \
  --set portalAssistant.llm.modelName="$LLM_MODEL" \
  --set portalAssistant.llm.baseUrl="$LLM_BASE_URL" \
  --set portalAssistant.config.reasoningEffort="" \
  --set portalAssistant.config.rcaAgentApiUrl="http://sre-agent.${OBS}.svc.cluster.local:8080" \
  --set backstage.features.assistant.enabled=true \
  --timeout 10m
kubectl -n "$CP" rollout restart deployment/backstage

echo "==> waiting for the agents"
kubectl -n "$OBS" rollout status deployment/sre-agent --timeout=10m
kubectl -n "$OBS" rollout status deployment/finops-agent --timeout=10m
kubectl -n "$CP" rollout status deployment/portal-assistant --timeout=10m
kubectl -n "$CP" rollout status deployment/backstage --timeout=10m
echo "AI agents ready (model ${LLM_MODEL} via ${LLM_BASE_URL})"
