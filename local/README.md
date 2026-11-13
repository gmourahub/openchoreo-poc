# OpenChoreo no Floci (EKS emulado)

OpenChoreo v1.3.3 (control, data e observability planes) num cluster EKS `openchoreo` do Floci
(k3s v1.35, node t2.2xlarge: 8 vCPU / ~12 GB; uso ~5 GB com observabilidade).

| Container | Papel |
|---|---|
| `oc-floci` | Floci (AWS em `localhost:4566`) |
| `floci-aws-eks-openchoreo` | o nó k3s do cluster EKS (API em `localhost:6500`) |
| `oc-gateway` | nginx que publica as portas LoadBalancer (8080, 19080, 11080, ...) no localhost |
| `oc-toolbox` | aws, kubectl, helm (roda o instalador) |

Para subir o ambiente (PowerShell):

```powershell
& "C:\Program Files\Git\bin\bash.exe" up.sh
```

## Acesso

Lista completa de URLs e logins: [`../URLS.md`](../URLS.md).

- Console: http://openchoreo.localhost:8080 (login padrão do OpenChoreo local, definido em `install/k3d/common/values-thunder.yaml` do upstream)
- API: http://api.openchoreo.localhost:8080
- Observer (logs/métricas/traces que o console usa): http://observer.openchoreo.localhost:11080
- Argo Workflows (builds): http://localhost:10081 · GitOps (Flux, sem UI): `kubectl get kustomization -n flux-system`
- Apps: `http://<endpoint>-<componente>-<env>-<ns>.openchoreoapis.localhost:19080/`
- kubectl: `kubectl --kubeconfig ./local/kubeconfig get pods -A`
- Prometheus / OpenSearch não são publicados; use port-forward, por exemplo
  `kubectl --kubeconfig kubeconfig -n openchoreo-observability-plane port-forward svc/prometheus-operated 19090:9090`

## Comandos

```bash
# do zero (cluster já criado): instala/atualiza
bash install.sh --with-observability   # workflow plane: bash workflow-plane.sh (não --with-build)
bash ai-agents.sh                      # agentes de IA (rodar de novo após install.sh)
bash secrets-floci.sh                  # segredos no Secrets Manager do Floci (rodar de novo após install.sh)
bash workflow-plane.sh                 # workflow plane (builds)
bash flux.sh                           # Flux + GitOps (github.com/gmourahub/sample-gitops)

# parar sem apagar nada (cluster, imagens e volumes ficam)
bash down.sh

# religar após down.sh ou reinício do Docker/PC (sobe ECR, DNS e espera o OpenChoreo)
bash up.sh

# derrubar tudo (apaga o cluster e os volumes)
docker exec oc-toolbox aws eks delete-cluster --name openchoreo
docker compose --profile gateway down -v
```

## Agentes de IA (Ollama local)

`bash ai-agents.sh` liga os três agentes do OpenChoreo usando o Ollama do Windows (GPU):

| Agente | Onde aparece | O que faz |
|---|---|---|
| SRE / RCA (`sre-agent`) | Console → projeto → Incidents | Análise de causa raiz quando um alerta com `triggerAiRca` dispara |
| FinOps (`finops-agent`, + módulo OpenCost) | Console → custos / recomendações | Relatórios de custo e rightsizing |
| Portal Assistant (Perch) | Console → botão do assistente / "Investigate" nos logs | Chat somente leitura sobre a plataforma, via MCP |

- Modelo: `gemma4:12b-it-qat` com 128k de contexto, servido no Ollama como **`gpt-4o-mini`**. O nome
  é emprestado só porque o LangChain dos agentes precisa de um "profile" de modelo conhecido para
  dimensionar o contexto; nada vai para a OpenAI. Trocar o modelo:
  `OLLAMA_BASE_MODEL=<modelo> bash ai-agents.sh` (precisa suportar tools).
- `ollama-shim/` (namespace `ai-gateway`): front OpenAI-compatível entre os agentes e o Ollama. Os
  agentes mandam `tools` + `response_format` juntos; o Ollama transforma o schema em gramática e o
  modelo nunca consegue chamar tools. O shim faz a rodada de tools sem schema e só formata a
  resposta final com o schema.
- `ollama.internal` (via `dns.sh`) aponta para o host; o Ollama precisa estar rodando no Windows.

## MCP no Claude Code

`../.mcp.json` registra os dois servidores MCP do OpenChoreo para quem abrir o Claude Code em
`<raiz-do-projeto>` (aprovar na primeira vez):

- `openchoreo-cp` — http://api.openchoreo.localhost:8080/mcp (projetos, componentes, deploys, ...)
- `openchoreo-obs` — http://observer.openchoreo.localhost:11080/mcp (logs, métricas, traces, alertas, custos)

A autenticação é feita por `mcp-auth-header.sh` (`headersHelper`): pega um token client-credentials
do ThunderID (`service_mcp_client`) e reaproveita até expirar. Para usar em qualquer pasta:
`claude mcp add-json --scope user openchoreo-cp '{"type":"http","url":"http://api.openchoreo.localhost:8080/mcp","headersHelper":"bash ./local/mcp-auth-header.sh"}'`
(idem para `openchoreo-obs`).

## Adaptações ao Floci

O instalador é o `install/k3d/k3d-install.sh` upstream (em `../src`, tag v1.3.3) com as partes
específicas do k3d trocadas, mais:

- `dns.sh`: CoreDNS resolve `*.openchoreo.localhost` para o nó k3s (onde o servicelb expõe as
  portas) e `floci.internal` para o Floci (S3, SQS, ... para as apps).
- `fix-sa-token-secrets.sh`: o Floci faz o kube-apiserver confiar só na chave de service account
  dele, mas o k3s assina os Secrets de token legados com a própria chave. O Prometheus usava um
  desses para ler o kubelet (401, sem métricas de CPU/memória). O script troca o token por um
  emitido pela TokenRequest API (válido 1 ano) e força o prometheus-operator a recarregar.
- Imagens de apps vão para o ECR do Floci (`000000000000.dkr.ecr.us-east-1.localhost:4566/...`),
  de onde o cluster puxa.

Workflow plane: não use `--with-build`. Rode `bash workflow-plane.sh`, que instala sem o
registry in-cluster e manda as imagens dos builds para o ECR do Floci (ver comentários no script).
Testado com `src/samples/from-source/services/go-docker-greeter`.
