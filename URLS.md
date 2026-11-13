# URLs e logins

Tudo roda em localhost: o container `oc-gateway` (nginx) repassa as portas 8080, 8443, 19080,
19443, 10081, 10083 e 11080 para o nó k3s. O Floci publica 4566 (AWS) e 6500 (API do Kubernetes).

## Interfaces web

| O quê | URL | Login |
|---|---|---|
| Console OpenChoreo (Backstage) | http://openchoreo.localhost:8080 | `admin@openchoreo.dev` / `Admin@123` |
| Segredos do OpenChoreo (console) | http://openchoreo.localhost:8080/settings/secret | idem; ficam no Secrets Manager do Floci |
| Argo CD (GitOps) | http://localhost:10083 | `admin` / senha abaixo |
| Argo Workflows (builds) | http://localhost:10081 | sem login |

Senha do Argo CD (gerada na instalação):

```bash
kubectl --kubeconfig local/kubeconfig -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

## Apps implantadas

Development e staging usam o gateway do data plane (porta 19080).

| App | Ambiente | URL |
|---|---|---|
| Doc Insights | development | http://http-frontend-development-default-4cc7110c.openchoreoapis.localhost:19080/ |
| Doc Insights | staging | http://http-frontend-staging-default-d28af70a.openchoreoapis.localhost:19080/ |
| Doclet (frontend) | development | http://http-doclet-fronte-development-default-31fef952.openchoreoapis.localhost:19080/ |
| Doclet document-svc (API) | development | http://development-default.openchoreoapis.localhost:19080/document-svc-http |
| greeter-service (getting started) | development | http://development-default.openchoreoapis.localhost:19080/greeter-service-http/greeter/greet |
| greeting-service (teste do workflow plane) | development | http://development-default.openchoreoapis.localhost:19080/greeting-service-greeter-api/greeter/greet |

Para descobrir a URL de um componente novo:

```bash
kubectl --kubeconfig local/kubeconfig get httproute -A \
  -o custom-columns=NS:.metadata.namespace,HOST:.spec.hostnames[0],PATH:.spec.rules[0].matches[0].path.value
```

## APIs e MCP

| O quê | URL |
|---|---|
| API do OpenChoreo | http://api.openchoreo.localhost:8080 (MCP em `/mcp`) |
| Observer (logs, métricas, traces) | http://observer.openchoreo.localhost:11080 (MCP em `/mcp`) |
| Thunder (identidade / OAuth) | http://thunder.openchoreo.localhost:8080 |
| API do Kubernetes | https://localhost:6500 (use `kubectl --kubeconfig local/kubeconfig`) |

## AWS (Floci) e registry

| O quê | Endereço |
|---|---|
| Floci (S3, SQS, Secrets Manager, ECR, EKS...) | http://localhost:4566 (credenciais `test` / `test`; use `docker exec oc-toolbox aws ...`) |
| Saúde do Floci | http://localhost:4566/_floci/health |
| Registry ECR (push/pull de imagens) | `000000000000.dkr.ecr.us-east-1.localhost:4566` |
| Floci visto de dentro dos pods | `http://floci.internal:4566` |

## IA local

| O quê | URL |
|---|---|
| Ollama (no Windows) | http://localhost:11434 (pods usam `http://ollama.internal:11434`) |

## Repositórios

| Repositório | Para quê |
|---|---|
| https://github.com/gmourahub/openchoreo-poc | este: scripts do ambiente, app doc-insights (código e imagens) |
| https://github.com/gmourahub/sample-gitops | GitOps: o Argo CD aplica o que está na `main`; releases e promoções são PRs aqui |
| https://github.com/openchoreo/sample-workloads | código-fonte do Doclet e de outros exemplos (builds clonam daqui) |
| https://github.com/openchoreo/openchoreo (tag v1.3.3) | upstream, clonado em `src/` |
