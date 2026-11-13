# Doc Insights — app de exemplo no OpenChoreo + Floci

Envie um texto pelo frontend; a **api** grava no **S3** e publica o id no **SQS**;
o **worker** consome a fila, calcula estatísticas e grava o resultado no S3.

```
browser ─► frontend (nginx) ─/api─► api (Node) ─► S3 uploads/<id>.json
                                         └──────► SQS {id} ─► worker ─► S3 results/<id>.json
```

| Pasta | O que é |
|---|---|
| [`backend/`](backend/) | `api.js` (HTTP) e `worker.js` (consumidor SQS), mesma imagem |
| [`frontend/`](frontend/) | página estática + nginx que faz proxy de `/api` para a api |
| [`platform/`](platform/) | `ClusterResourceType`s `aws-s3-bucket` e `aws-sqs-queue` (time de plataforma) |
| [`openchoreo/`](openchoreo/) | Project, Resources (bucket, fila) e Components (api, worker, frontend) |

## Rodar

```bash
bash build-push.sh   # build das imagens e push para o ECR do Floci
bash deploy.sh       # LEGADO: o doc-insights está descrito em github.com/gmourahub/sample-gitops;
                     # com o GitOps ligado o Flux desfaz mudanças manuais (hoje está suspenso)
```

Para publicar uma mudança de código, rode os dois de novo (cada build gera uma tag nova).

## Como as peças se ligam

- A api e o worker declaram `dependencies.resources` em `docs-bucket` e `docs-queue`; o OpenChoreo
  injeta `S3_BUCKET`, `SQS_QUEUE_NAME`, endpoint, região e credenciais como env vars.
- O frontend declara `dependencies.endpoints` na api; recebe `API_HOST`/`API_PORT`.
- Os ResourceTypes criam bucket/fila com um Job (aws-cli) no Floci em `http://floci.internal:4566`
  (nome resolvido pelo CoreDNS do cluster, ver `../local/dns.sh`).
- Bucket/fila: `default-docs-bucket-development`, `default-docs-queue-development`.

Atalhos só para ambiente local: credenciais fixas `test/test` e Job em vez de um provisionador real.
Na AWS seriam ACK/Crossplane + IRSA/Pod Identity. Apagar o Resource não apaga o bucket/fila no Floci.

## Alerta e análise de causa raiz (SRE agent)

`openchoreo/alerts.yaml` liga um alerta de log no `api` (mais de 2 linhas com "error" em 1 minuto)
que abre um incidente e dispara a RCA do SRE agent (precisa de `../local/ai-agents.sh`).

```bash
bash chaos.sh break   # apaga o bucket no Floci e manda uploads -> api devolve 500 (NoSuchBucket)
# ~1-3 min depois: Console -> Doc Insights -> Incidents, com o relatório da IA
bash chaos.sh fix     # recria o bucket (os documentos antigos se perdem)
```

## Inspecionar

```bash
docker exec oc-toolbox aws s3 ls --recursive s3://default-docs-bucket-development/
docker exec oc-toolbox aws sqs get-queue-attributes --attribute-names All \
  --queue-url http://localhost:4566/000000000000/default-docs-queue-development
kubectl --kubeconfig ../local/kubeconfig get pods -A -l openchoreo.dev/project=doc-insights
```
