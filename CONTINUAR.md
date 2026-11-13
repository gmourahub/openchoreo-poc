# OpenChoreo no Floci — onde paramos (2026-11-12)

## Ligar / desligar

```bash
cd ./local
bash up.sh     # sobe tudo e espera o OpenChoreo responder (~5-10 min)
bash down.sh   # desliga tudo sem apagar nada (cluster, imagens, dados)
```

Antes do `up.sh`: Docker Desktop aberto e, para os agentes de IA, o **Ollama aberto no Windows**.

## Endereços e logins

Todas as URLs e logins estão em [`URLS.md`](URLS.md). As principais:

| O quê | Onde |
|---|---|
| Console OpenChoreo | http://openchoreo.localhost:8080 (`admin@openchoreo.dev` / `Admin@123`) |
| Argo Workflows (builds) | http://localhost:10081 |
| Floci (AWS) | http://localhost:4566 (`test`/`test`; `docker exec oc-toolbox aws ...`) |
| kubectl | `kubectl --kubeconfig ./local/kubeconfig ...` |

## O que existe

- **Cluster**: EKS `openchoreo` emulado pelo Floci (k3s 1.35, nó t2.2xlarge 8 vCPU / 12 GB).
- **OpenChoreo v1.3.3**: control, data e observability planes (OpenSearch, Prometheus, OpenCost).
  Workflow plane (build a partir do código, Argo Workflows) instalado por `local/workflow-plane.sh`;
  as imagens vão para o ECR do Floci. Argo UI: http://localhost:10081.
- **GitOps com Flux** (`local/flux.sh`): sincroniza https://github.com/gmourahub/sample-gitops
  (fork do `openchoreo/sample-gitops`). O doc-insights e o app de exemplo Doclet vivem lá; mudanças,
  releases e promoções são por PR naquele repositório. Ver `flux/FLOCI.md` no fork. Status:
  `kubectl --kubeconfig local/kubeconfig get gitrepository,kustomization -n flux-system`.
- **Agentes de IA** (`local/ai-agents.sh`): SRE/RCA, FinOps e Portal Assistant, usando o Ollama
  local com `gemma4:12b-it-qat` (registrado no Ollama como `gpt-4o-mini`, ver "Decisões").
- **App `doc-insights`** (`app/`): frontend + api + worker, bucket S3 e fila SQS no Floci,
  alerta de erro no `api` que abre incidente e dispara a RCA.
- **MCP no Claude Code**: `.mcp.json` nesta pasta (`openchoreo-cp` e `openchoreo-obs`). Na primeira
  vez que abrir `claude` aqui, aprovar os dois servidores.

Detalhes: `local/README.md` (ambiente) e `app/README.md` (app).

## Scripts

| Script | Para quê |
|---|---|
| `local/up.sh` / `local/down.sh` | ligar / desligar |
| `local/install.sh --with-observability` | (re)instalar o OpenChoreo; depois rodar `ai-agents.sh` |
| `local/ai-agents.sh` | (re)aplicar os agentes de IA |
| `local/dns.sh` | DNS do cluster (`*.openchoreo.localhost`, `floci.internal`, `ollama.internal`, `host.k3d.internal`, ECR) |
| `local/secrets-floci.sh` | segredos do OpenChoreo no Secrets Manager do Floci (rodar de novo após `install.sh`) |
| `local/workflow-plane.sh` | (re)instalar o workflow plane (build a partir do código) |
| `local/ecr-mirror.sh` | aponta o mirror do ECR no nó para `oc-floci` (chamado pelo `up.sh`) |
| `local/flux.sh` | (re)instalar o Flux a partir do sample-gitops (depois ele se atualiza por PR) |
| `local/set-github-token.sh` | guardar o PAT do GitHub (`gitops-token`/`git-token`) no Floci para os builds GitOps |
| `app/build-push.sh` | publicar imagens novas da app no ECR (depois: PR no sample-gitops com Workload/ComponentRelease) |
| `app/deploy.sh` | **legado**: o doc-insights agora vem do sample-gitops; o Flux desfaz mudanças manuais |
| `app/chaos.sh break` / `fix` | simular falha (apaga o bucket) para testar a RCA |

## Decisões e pegadinhas (não óbvias)

- **Floci só publica a porta da API do k3s (6500)**: o container `oc-gateway` (nginx) expõe 8080,
  8443, 19080, 19443, 10081 (Argo Workflows) e 11080 no localhost. A 10082 era do
  registry do k3d e ficou sem uso (as imagens vão para o ECR do Floci).
- **Pods acessam o Floci como `floci.internal` e o Ollama como `ollama.internal`** (CoreDNS, `dns.sh`).
  Dentro de pods o `curl` sempre manda `*.localhost` para 127.0.0.1; testar com `busybox wget`.
- **Tokens de ServiceAccount antigos falham no Floci** (assinatura do k3s vs. chave do Floci):
  `fix-sa-token-secrets.sh` corrige (afetava o Prometheus lendo o kubelet).
- **Imagens das apps** vão para o ECR do Floci (`000000000000.dkr.ecr.us-east-1.localhost:4566/...`).
- **Modelo com nome `gpt-4o-mini` no Ollama**: os agentes (LangChain) precisam de um nome de modelo
  conhecido para saber o tamanho do contexto. É o gemma4 local; nada vai para a OpenAI.
- **`ollama-shim`** (namespace `ai-gateway`): os agentes pedem tools + resposta JSON juntos e o Ollama
  não suporta isso. O shim separa as rodadas e exige todos os campos do schema. Sem ele, o chat
  inventava respostas e a RCA falhava.
- O `qwen3.8:27b` do Ollama está **corrompido** (arquivo faltando). Apagar ou baixar de novo.
- Incidentes **não fecham sozinhos**: o incidente de teste do `doc-insights` segue "active".
- **O IP do Floci muda quando o Docker reinicia**, e o Floci grava o mirror do ECR no nó
  (`/etc/rancher/k3s/registries.yaml`) com o IP fixo. `ecr-mirror.sh` troca pelo nome `oc-floci`
  e reinicia o nó uma vez; sem isso, pull de imagem nova do ECR falha.
- **Segredos no Secrets Manager do Floci, não no OpenBao**: o OpenBao do instalador roda em modo
  `-dev` (só memória) e perde tudo a cada restart do nó. `secrets-floci.sh` copia as chaves dele para
  o Floci e troca o ClusterSecretStore `default` para AWS SecretsManager (ESO com
  `AWS_SECRETSMANAGER_ENDPOINT=http://floci.internal:4566`). O OpenBao continua instalado, sem uso.
  Segredos criados no console (`/settings/secret`) viram `secret/<namespace>/<tipo>/<nome>` no Floci,
  gravados como `SecretBinary` (padrão do ESO para PushSecret). `install.sh` volta o store para o
  OpenBao: rode `secrets-floci.sh` depois dele.
- **GitOps manda no doc-insights e no Doclet**: o Flux reaplica tudo a cada 5 min (e a cada merge).
  Mudança feita no console ou com `kubectl` nesses apps é revertida; o caminho é PR no fork.
  Os componentes do doc-insights estão com `autoDeploy: false`. Os outros (greeter etc.) seguem
  pelo console.
- **Flux em vez de Argo CD**: é o CD do tutorial oficial do sample-gitops, tem só 2 controllers e
  se autogerencia (`flux/flux-system/gotk-components.yaml` no fork): upgrade do Flux é um PR.
- **ResourceReleaseBinding precisa de `resourceRelease` fixado** (OpenChoreo 1.3): sem isso fica
  `ResourceReleaseNotSet`. O sample upstream não traz o campo; o fork já fixa os do Doclet.
- **Workflow plane sem o registry twuni**: o `publish-image` faz push para
  `000000000000.dkr.ecr.us-east-1.localhost:4566` (o mesmo nome que o nó usa no pull; não precisa
  criar o repositório antes). O CA do agente vem do Secret `cluster-gateway-ca`, porque o ConfigMap
  do control plane volta a ser placeholder depois de um `helm upgrade`.
- **Builds com `--network host`**: os pods têm MTU 1450 (flannel) e a rede própria do podman/pack
  usa 1500; downloads nos passos `RUN` (`go mod download`, `npm ci`) morriam com `TLS handshake
  timeout`. Os templates do fork e o `containerfile-build` local (`workflow-plane.sh`) já constroem
  na rede do pod.
- **Token do GitHub dos builds GitOps**: segredos `gitops-token` e `git-token` no Floci, no formato
  `{"git-token": "<PAT>"}` (`local/set-github-token.sh`). PAT fine-grained só para o
  `sample-gitops`, com Contents e Pull requests em read/write.
- **Nomes de componente são únicos por namespace**: o frontend do Doclet virou `doclet-frontend`
  porque o doc-insights já tem `frontend` em `default`.
- Outras stacks do Floci (`cnoe-local`, `spike-eks`) também usam a porta 4566: só uma por vez.

## Pendências / ideias para continuar

- FinOps agent: só teste de inicialização; ver relatórios de custo no console depois que o OpenCost
  coletar dados.
- Testar o Portal Assistant pela interface do console (botão do assistente / "Investigate" nos logs).
- O modelo 12B às vezes repete a mesma tool várias vezes; um modelo maior (ex.: `gemma4:26b-a4b-it-qat`,
  16 GB) pode melhorar, ao custo de velocidade: `OLLAMA_BASE_MODEL=... bash local/ai-agents.sh`.
- O cliente MCP do Claude Code tem permissão de escrita no OpenChoreo (os agentes internos só leem).
