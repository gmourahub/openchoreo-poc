#!/bin/bash
# Failure scenario for the SRE agent demo.
#   bash chaos.sh break   # deletes the S3 bucket and sends uploads -> api 500s
#   bash chaos.sh fix     # recreates the bucket
# Breaking fires the api-error-log-alert within ~1-2 minutes; the incident
# triggers the SRE agent's root cause analysis (Console -> project -> Incidents).
set -euo pipefail
BUCKET=default-docs-bucket-development
# MSYS_NO_PATHCONV only for docker exec: globally it breaks curl -o /dev/null on Windows.
aws() { MSYS_NO_PATHCONV=1 docker exec oc-toolbox aws "$@"; }
FRONTEND=$(kubectl --kubeconfig "$(dirname "$0")/../local/kubeconfig" get httproute -A \
  -l openchoreo.dev/component=frontend -o jsonpath='{.items[0].spec.hostnames[0]}')

case "${1:-}" in
  break)
    aws s3 rb "s3://$BUCKET" --force
    echo "bucket $BUCKET deleted; sending uploads for 90s..."
    for _ in $(seq 1 18); do
      curl -s -o /dev/null -w '%{http_code} ' -X POST -H 'content-type: application/json' \
        -d '{"name":"chaos.txt","content":"isto deve falhar"}' "http://$FRONTEND:19080/api/docs"
      sleep 5
    done
    echo
    ;;
  fix)
    aws s3 mb "s3://$BUCKET"
    echo "bucket $BUCKET recreated (earlier documents are gone)"
    ;;
  *)
    echo "usage: $0 break|fix" >&2
    exit 1
    ;;
esac
