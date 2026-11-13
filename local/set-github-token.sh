#!/bin/bash
# Stores a GitHub PAT in Floci Secrets Manager for the GitOps workflows
# (sample-gitops): gitops-token (push branch + open PR in the GitOps repo) and
# git-token (clone private source repos). Both as {"git-token": "<PAT>"}, the
# shape the workflows' ExternalSecrets read. Prompts without echo, so the token
# stays out of shell history and process arguments. Safe to re-run (updates).
#   bash local/set-github-token.sh
set -euo pipefail

read -rsp 'GitHub PAT: ' token
echo
[ -n "$token" ] || { echo 'empty token, nothing stored' >&2; exit 1; }

for name in gitops-token git-token; do
  printf '{"git-token":"%s"}' "$token" | MSYS_NO_PATHCONV=1 docker exec -i oc-toolbox sh -c '
    f=$(mktemp); cat > "$f"
    aws secretsmanager create-secret --name "$1" --secret-string "file://$f" > /dev/null 2>&1 ||
      aws secretsmanager put-secret-value --secret-id "$1" --secret-string "file://$f" > /dev/null
    rm -f "$f"' _ "$name"
  echo "stored $name"
done
unset token
