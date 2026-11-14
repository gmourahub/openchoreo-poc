# openchoreo-poc

Prova de conceito do [OpenChoreo](https://github.com/openchoreo/openchoreo) v1.3.3 rodando
100% local, num cluster EKS emulado pelo [Floci](https://github.com/floci-io/floci), com
agentes de IA usando um modelo local (Ollama) e uma aplicação de exemplo.

## O que tem aqui

| Pasta | O que é |
|---|---|
| [`local/`](local/README.md) | Ambiente: scripts para subir/desligar o cluster, instalar o OpenChoreo (control, data e observability planes), DNS do cluster e agentes de IA |
| [`app/`](app/README.md) | **Doc Insights**: app de exemplo (frontend + api + worker, S3 e SQS no Floci) com manifestos do OpenChoreo, alerta de erro e script de caos para testar a análise de causa raiz |
| [`URLS.md`](URLS.md) | **Todas as URLs e logins** (console, Argo Workflows, apps, Floci, APIs, repositórios) |
| [`CONTINUAR.md`](CONTINUAR.md) | Notas de estado, decisões e pendências |

## Requisitos

Docker Desktop, [Git Bash](https://git-scm.com/downloads/win) e, para os agentes de IA,
[Ollama](https://ollama.com) aberto no host. Cerca de 5 GB de RAM com observabilidade.

Os scripts são para o **Git Bash**. No PowerShell, `bash` abre o bash do WSL
(`C:\Windows\system32\bash.exe`), que não enxerga o Docker Desktop e falha com
`failed to connect to the docker API at unix:///var/run/docker.sock`. Rode os comandos
abaixo dentro do Git Bash, ou chame-o direto do PowerShell: `& "C:\Program Files\Git\bin\bash.exe" up.sh`.


## Começando

```bash
# no Git Bash
git clone https://github.com/openchoreo/openchoreo --branch v1.3.3 src   # referência, usada pelo install.sh
cd local
bash up.sh     # sobe tudo e espera o OpenChoreo responder (~5-10 min)
bash down.sh   # desliga sem apagar nada
```

Windows PowerShell
```bash
cd local
`& "C:\Program Files\Git\bin\bash.exe" up.sh`.
```

O diretório `src/` é um clone do upstream e não faz parte deste repositório: o
`local/install.sh` lê dele o script de instalação e o arquivo `VERSION`.

Os endereços e logins estão em [`URLS.md`](URLS.md).

As apps (doc-insights e o exemplo Doclet) estão descritas para GitOps (hoje **suspenso**, ver
[`CONTINUAR.md`](CONTINUAR.md)): com ele ligado, o Flux sincroniza
https://github.com/gmourahub/sample-gitops, e releases e promoções são PRs lá.

## Licença e atribuição

Apache License 2.0 (veja [`LICENSE`](LICENSE)). O `local/.floci-install.sh` é adaptado do
instalador do OpenChoreo, também Apache-2.0; veja [`NOTICE`](NOTICE).
