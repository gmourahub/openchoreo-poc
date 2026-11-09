#!/bin/bash
# Stops the whole environment without deleting anything (cluster, images,
# Floci state and volumes are kept). Bring it back with up.sh.
set -uo pipefail
cd "$(dirname "$0")"

ollama stop gpt-4o-mini > /dev/null 2>&1 || true   # frees the GPU
docker stop -t 60 floci-aws-eks-openchoreo > /dev/null && echo 'stopped cluster node'
docker stop floci-aws-ecr-registry > /dev/null && echo 'stopped ECR registry'
docker compose --profile gateway stop
