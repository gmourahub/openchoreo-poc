#!/bin/bash
# Turns GitOps (Flux syncing github.com/gmourahub/sample-gitops) off and on
# without uninstalling Flux.
#   bash local/gitops.sh suspend   # stop syncing: console/API changes stick
#   bash local/gitops.sh resume    # sync again: the cluster goes back to Git
#   bash local/gitops.sh status
# suspend also sets autoDeploy: true on the doc-insights components (Git has
# false), so a build deploys to development by itself, as before GitOps.
# resume puts Git back in charge: changes made in the console while suspended
# are overwritten unless they were also committed to the repo.
set -euo pipefail
cd "$(dirname "$0")"
K="kubectl --kubeconfig kubeconfig"
ACTION=${1:-status}

suspend_all() { # true|false
  for k in $($K -n flux-system get kustomization -o name) $($K -n flux-system get gitrepository -o name); do
    $K -n flux-system patch "$k" --type merge -p "{\"spec\":{\"suspend\":$1}}" > /dev/null
  done
}

case "$ACTION" in
  suspend)
    # flux-system first: it applies the other Kustomizations from Git, which
    # would otherwise drop their suspend flag.
    $K -n flux-system patch kustomization flux-system --type merge -p '{"spec":{"suspend":true}}' > /dev/null
    suspend_all true
    for c in api worker frontend; do
      $K -n default patch component "$c" --type merge -p '{"spec":{"autoDeploy":true}}' > /dev/null
    done
    echo 'GitOps suspended: the console/API is the source of truth again.' ;;
  resume)
    suspend_all false
    $K -n flux-system annotate gitrepository sample-gitops reconcile.fluxcd.io/requestedAt="$(date +%s)" --overwrite > /dev/null
    echo 'GitOps resumed: Flux re-applies the repo within a minute (autoDeploy goes back to false).' ;;
  status) ;;
  *) echo "usage: $0 suspend|resume|status" >&2; exit 1 ;;
esac
$K -n flux-system get gitrepository,kustomization \
  -o custom-columns='NAME:.metadata.name,KIND:.kind,SUSPENDED:.spec.suspend,READY:.status.conditions[?(@.type=="Ready")].status,REVISION:.status.lastAppliedRevision'
