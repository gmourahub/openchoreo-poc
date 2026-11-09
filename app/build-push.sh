#!/bin/bash
# Builds the two images and pushes them to Floci ECR, where the EKS cluster
# pulls from. Writes the pushed image refs to .images for deploy.sh.
set -euo pipefail
cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1

REGISTRY=000000000000.dkr.ecr.us-east-1.localhost:4566
TAG=${TAG:-$(date +%Y%m%d-%H%M%S)}
aws() { docker exec oc-toolbox aws "$@"; }

aws ecr get-login-password | docker login -u AWS --password-stdin "$REGISTRY" > /dev/null

for name in backend frontend; do
  repo="doc-insights-$name"
  aws ecr describe-repositories --repository-names "$repo" > /dev/null 2>&1 ||
    aws ecr create-repository --repository-name "$repo" > /dev/null
  image="$REGISTRY/$repo:$TAG"
  docker build -q -t "$image" "$name" > /dev/null
  docker push -q "$image" > /dev/null
  echo "pushed $image"
done

cat > .images <<EOF
BACKEND_IMAGE=$REGISTRY/doc-insights-backend:$TAG
FRONTEND_IMAGE=$REGISTRY/doc-insights-frontend:$TAG
EOF
