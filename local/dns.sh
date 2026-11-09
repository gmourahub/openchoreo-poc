#!/bin/bash
# Cluster DNS for the Floci setup. Safe to re-run (e.g. after a Docker restart):
#   *.openchoreo.localhost -> the k3s node, where servicelb binds every
#                             LoadBalancer port (host.k3d.internal's role on k3d)
#   floci.internal         -> the Floci container (S3, SQS, ... on :4566)
#   ollama.internal        -> the Windows host, where Ollama serves the agents' LLM (:11434)
set -euo pipefail
cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1
K="kubectl --kubeconfig kubeconfig"

NODE_NAME=$($K get nodes -o jsonpath='{.items[0].metadata.name}')
FLOCI_IP=$(docker inspect oc-floci --format '{{(index .NetworkSettings.Networks "openchoreo-floci_default").IPAddress}}')
# The Windows host (Ollama on :11434), as Docker Desktop exposes it to containers.
HOST_IP=$(docker exec floci-aws-eks-openchoreo awk '/host.docker.internal/ && $1 ~ /^[0-9.]+$/ {print $1; exit}' /etc/hosts)

cat > coredns-custom.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  openchoreo.override: |
    rewrite stop {
      name regex (.+\.)?openchoreo\.localhost ${NODE_NAME}
      answer auto
    }
  floci.server: |
    floci.internal:53 {
      hosts {
        ${FLOCI_IP} floci.internal
      }
    }
  ollama.server: |
    ollama.internal:53 {
      hosts {
        ${HOST_IP} ollama.internal
      }
    }
EOF
# CoreDNS only picks up coredns-custom changes reliably on restart.
$K apply -f coredns-custom.yaml
$K -n kube-system rollout restart deploy/coredns
$K -n kube-system rollout status deploy/coredns --timeout=120s
