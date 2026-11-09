#!/bin/bash
# Enables OpenChoreo's built-in AI agents (SRE/RCA, FinOps, Portal Assistant)
# with an Ollama model on the Windows host. Requires the observability plane
# (install.sh --with-observability). Safe to re-run.
#   OLLAMA_BASE_MODEL=gemma4:12b-it-qat bash ai-agents.sh
set -euo pipefail
cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1

BASE_MODEL=${OLLAMA_BASE_MODEL:-gemma4:12b-it-qat}
# The agents' LangChain middleware sizes its summarisation by the model's
# "profile", which LangChain only has for model names it knows. So the Ollama
# alias borrows such a name (gpt-4o-mini: 128k input) and gets the same context
# window. It is still the local BASE_MODEL; nothing calls OpenAI.
MODEL=gpt-4o-mini
CONTEXT=131072   # gemma4:12b-it-qat still fits 100% on a 16 GB GPU at this size

echo "==> Ollama model $MODEL (from $BASE_MODEL, num_ctx $CONTEXT)"
ollama list | grep -q "^${BASE_MODEL}[[:space:]]" || ollama pull "$BASE_MODEL"
printf 'FROM %s\nPARAMETER num_ctx %s\n' "$BASE_MODEL" "$CONTEXT" > ollama/Modelfile
ollama create "$MODEL" -f ollama/Modelfile > /dev/null

bash dns.sh > /dev/null   # ollama.internal -> the Windows host

# LangChain "openai:" provider + base_url = the in-cluster ollama-shim, an
# OpenAI-compatible front for Ollama that makes tools + structured output work
# together (see ollama-shim/shim.py).
docker exec \
  -e LLM_MODEL="openai:$MODEL" \
  -e LLM_BASE_URL="http://ollama-shim.ai-gateway.svc.cluster.local:8080/v1" \
  oc-toolbox bash /local/ai-agents-cluster.sh
