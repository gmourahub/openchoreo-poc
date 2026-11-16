# ${{ values.name }}

API HTTP da Empresa criada pelo Golden Path. Roda no OpenChoreo como componente do tipo
`empresa-service`. Time/projeto: `${{ values.team }}`.

## Estrutura esperada

- `server.js`: a API. Pode crescer em pastas (`src/`, `routes/`), mas o ponto de entrada fica aqui.
- `package.json`: dependências e `npm start`.
- `Dockerfile`: como a imagem é construída. O build da plataforma usa este arquivo.
- `workload.yaml`: o contrato da app com a plataforma (endpoints, variáveis, segredos).

Cada push na branch `main` dispara um build; com sucesso, a versão nova sobe em
development sozinha. O resultado do build chega no Slack.

## Regras que não podem quebrar

1. **Porta 8080 e rota `GET /health`.** O componente usa essas duas para as probes. Se mudar a
   porta, mude também o `port` do endpoint no `workload.yaml` e peça para trocar o parâmetro
   `port` do componente no portal. A rota `/health` responde 200 rápido, sem depender de banco.
2. **Usuário não-root com UID numérico.** O `Dockerfile` termina com `USER 1000`. O pod roda com
   `runAsNonRoot` e não sobe como root.
3. **Segredos nunca no código**, nem em `.env` commitado, nem no `workload.yaml`. O segredo é
   criado no portal (Settings > Secrets) e entra como variável pelo `secretKeyRef` do
   `workload.yaml` (há um exemplo comentado lá). No código, leia de `process.env`.
4. **Infraestrutura não muda por este repositório.** Réplicas, CPU, memória, autoscaling, role
   IAM (IRSA) e promoção para staging/produção são feitos no portal do OpenChoreo, por ambiente.
   Não crie manifests Kubernetes, Helm charts, Terraform ou arquivos de pipeline aqui.
5. Configuração que muda por ambiente vem de variável de ambiente, não de `if (env === 'prod')`.

## Rodar local

```bash
npm start            # http://localhost:8080/health
docker build -t app . && docker run -p 8080:8080 app
```
