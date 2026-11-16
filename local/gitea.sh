#!/bin/bash
# Gitea as the Golden Path's git server (instead of GitHub), in the cluster.
#   UI: http://localhost:3300  (user empresa; password: bash local/gitea.sh password)
#   cluster: http://gitea.internal:3300; apps' repos live under the user "empresa"
# "empresa" is a user, not an org: publish:github decides user vs org from a field Gitea's
# API lacks, so it always creates the repo under the token's user.
# Sets up, all idempotent:
#   - Floci secret gitea-admin   {"password"}         (generated once)
#   - Floci secret empresa-git-token {"username","token","scopes"}: Backstage (create repos)
#   - Floci secret empresa-git-read  {"username","token","scopes"}: builds (clone only)
#   - Secret git-webhook-secrets/github-secret in openchoreo-control-plane, and a webhook
#     on user empresa (all its repos) -> openchoreo-api /api/v1alpha1/autobuild (push = build).
#     Not /admin/hooks: on 1.22 that creates per-repo copies the API can't list. Gitea signs
#     with X-Hub-Signature-256, so OpenChoreo treats it as GitHub.
# Run golden-path.sh after this. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"
K="kubectl --kubeconfig kubeconfig"

if [ "${1:-}" = password ]; then
  MSYS_NO_PATHCONV=1 docker exec oc-toolbox aws secretsmanager get-secret-value \
    --secret-id gitea-admin --query SecretString --output text | sed 's/.*"password":"\([^"]*\)".*/\1/'
  exit 0
fi

$K apply -f gitea/gitea.yaml
bash dns.sh > /dev/null
docker compose --profile gateway up -d gateway   # picks up port 3300
$K -n gitea rollout status deploy/gitea --timeout=300s

MSYS_NO_PATHCONV=1 docker exec -i oc-toolbox bash -s <<'EOF'
set -euo pipefail
G=http://floci-aws-eks-openchoreo:3300/api/v1   # servicelb port on the k3s node
gitea() { kubectl -n gitea exec deploy/gitea -- gitea "$@"; }
secret() { aws secretsmanager get-secret-value --secret-id "$1" --query SecretString --output text 2>/dev/null; }
put() {
  f=$(mktemp); printf '%s' "$2" > "$f"
  aws secretsmanager create-secret --name "$1" --secret-string "file://$f" > /dev/null 2>&1 ||
    aws secretsmanager put-secret-value --secret-id "$1" --secret-string "file://$f" > /dev/null
  rm -f "$f"
}

echo '==> admin user empresa'
if ! secret gitea-admin > /dev/null; then
  put gitea-admin "$(jq -nc --arg p "$(openssl rand -hex 12)" '{password: $p}')"
fi
PASS=$(secret gitea-admin | jq -r .password)
gitea admin user list | grep -q ' empresa ' ||
  gitea admin user create --admin --username empresa --email empresa@gitea.internal \
    --password "$PASS" --must-change-password=false > /dev/null

echo '==> API tokens (Floci empresa-git-token for Backstage, empresa-git-read for builds)'
# (Re)generated when missing or when the stored scopes differ, so tightening scopes
# here rotates the token on the next run. Never write:admin.
token() { # <floci name> <scopes>
  if [ "$(secret "$1" | jq -r '.scopes // ""' 2>/dev/null)" != "$2" ]; then
    t=$(gitea admin user generate-access-token --username empresa --raw \
      --token-name "$1-$(date +%s)" --scopes "$2")
    put "$1" "$(jq -nc --arg t "$t" --arg s "$2" '{username: "empresa", token: $t, scopes: $s}')"
  fi
}
token empresa-git-token write:repository,write:user   # create repos, user webhook
token empresa-git-read read:repository                 # builds only clone
TOKEN=$(secret empresa-git-token | jq -r .token)
api() { curl -sS --fail-with-body -H "Authorization: token $TOKEN" -H 'Content-Type: application/json' "$@"; }

echo '==> push webhook -> OpenChoreo autobuild'
CP=openchoreo-control-plane
if ! kubectl -n $CP get secret git-webhook-secrets > /dev/null 2>&1; then
  kubectl -n $CP create secret generic git-webhook-secrets --from-literal=github-secret="$(openssl rand -hex 20)"
fi
WH_SECRET=$(kubectl -n $CP get secret git-webhook-secrets -o jsonpath='{.data.github-secret}' | base64 -d)
URL=http://openchoreo-api.$CP.svc.cluster.local:8080/api/v1alpha1/autobuild
if ! api "$G/user/hooks" | jq -e --arg u "$URL" 'any(.[]; .config.url == $u)' > /dev/null; then
  api -X POST "$G/user/hooks" -d "$(jq -nc --arg u "$URL" --arg s "$WH_SECRET" \
    '{type: "gitea", active: true, events: ["push"], branch_filter: "*",
      config: {url: $u, content_type: "json", secret: $s}}')" > /dev/null
fi
EOF
echo
echo 'Gitea ready: http://localhost:3300 (user empresa, password: bash local/gitea.sh password)'
