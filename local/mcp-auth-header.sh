#!/bin/bash
# headersHelper for Claude Code's OpenChoreo MCP servers: prints
# {"Authorization": "Bearer <token>"} using the ThunderID client-credentials
# client from the local install. Reuses a cached token until 5 minutes before
# it expires (tokens last 1 hour), so reconnects stay fast.
set -euo pipefail
CACHE="${TMPDIR:-${TEMP:-/tmp}}/openchoreo-mcp-token.json"
TOKEN_URL=http://thunder.openchoreo.localhost:8080/oauth2/token

now=$(date +%s)
token=''
if [ -f "$CACHE" ]; then
  token=$(python -c "import json,sys; c=json.load(open(sys.argv[1])); print(c['token'] if c['expires_at'] > $now + 300 else '')" "$CACHE" 2>/dev/null || true)
fi

if [ -z "$token" ]; then
  response=$(curl -sf -m 8 -X POST "$TOKEN_URL" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -u 'service_mcp_client:service_mcp_client_secret' \
    -d 'grant_type=client_credentials')
  token=$(printf '%s' "$response" | python -c "
import json, sys
r = json.load(sys.stdin)
json.dump({'token': r['access_token'], 'expires_at': $now + int(r.get('expires_in', 3600))}, open(sys.argv[1], 'w'))
print(r['access_token'])" "$CACHE")
fi

printf '{"Authorization": "Bearer %s"}\n' "$token"
