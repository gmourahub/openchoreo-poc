# Golden Path Empresa no OpenChoreo

This implements the spec "Golden Path Empresa no OpenChoreo" on the local OpenChoreo 1.3.3.

```bash
bash local/gitea.sh                       # git server (Gitea), token and push webhook; run first
bash local/golden-path.sh                 # applies everything (safe to re-run; run again after install.sh / branding.sh)
bash local/golden-path.sh slack-webhook   # once: Slack incoming webhook URL
bash local/golden-path.sh team pagamentos # RBAC for the IdP group "pagamentos" (project of the same name)
```

| Spec | File |
|---|---|
| 1. ClusterComponentType `empresa-service` | `platform/empresa-service.yaml` |
| 2. Traits `empresa-autoscaler`, `empresa-pdb` | `platform/traits.yaml` |
| 3. ClusterWorkflow `empresa-dockerfile-builder` + Slack | `platform/workflow.yaml` |
| 4. Template repo | `template-repo/` (used as the scaffolder skeleton) |
| 5. Template "Nova aplicação Empresa" | `scaffolder/template.yaml` |
| 6. Guardrails (RBAC, Kyverno, git secret) | `platform/guardrails.yaml`, `platform/rbac-team.yaml` |

## Decisions and gotchas

- **Git server: Gitea in the cluster** (`local/gitea.sh`), not GitHub. UI: http://localhost:3300, user `empresa`
  (password: `bash local/gitea.sh password`). Pods reach it as `gitea.internal:3300` (CoreDNS, `dns.sh`); not
  `*.localhost`, because git/curl send that to the pod itself. Repos live under the **user** `empresa`, not an
  org: `publish:github` tells user from org by a field Gitea's API lacks, so it always creates the repo
  under the token's user.
- **Gitea through `publish:github`.** The 1.3.3 image has no `publish:gitea`. Gitea is registered as a GitHub
  Enterprise host in `integrations.github` (`apiBaseUrl: .../api/v1`), with `protectDefaultBranch: false`
  (branch protection is the part Gitea doesn't implement).
- **Two tokens, no admin scope.** Backstage uses Floci `empresa-git-token` (`write:repository,write:user`), through
  the ExternalSecret `empresa-git`. Builds use `empresa-git-read` (`read:repository`), through the SecretReference
  `git-credentials`. The checkout sends that token to the component's URL, so Kyverno `empresa-repo-host` only
  accepts `empresa-service` components with a repo at `http://gitea.internal:3300/`. `gitea.sh` regenerates a
  token when its scopes change; it does not revoke the old one.
- **Push = build, including the first one.** A webhook on user `empresa` → `openchoreo-api /api/v1alpha1/autobuild`.
  Gitea signs with `X-Hub-Signature-256`, so OpenChoreo treats it as GitHub (secret
  `git-webhook-secrets/github-secret`). The template creates the component **before** the repo, so the first
  push already builds. Kyverno (`empresa-autobuild`) sets `autoBuild: true` (the portal action has no input for
  it) and turns `appPath: "."` into `""`: OpenChoreo 1.3.3 compares changed files against `./` and would
  never trigger.
- **Webhook on the user, not `/admin/hooks`.** On Gitea 1.22, `/admin/hooks` creates a per-repo copy the API
  can't list, so re-runs duplicated the hook and every push built twice.
- **The template repo is `template-repo/`**, mounted into Backstage file by file (`subPath`). A whole-ConfigMap
  volume is symlinks into `..<timestamp>/`, and `fetch:template` rejects that as "outside its parent".
- **Rollback in development gets undone by `autoDeploy`.** The controller always points dev at the latest
  release. Do rollbacks in staging and production, or turn autoDeploy off.
- **Slack is optional.** Without the `slack-webhook` secret, the exit handler logs the message and exits 0. The
  run template uses no `${...}` in shell, because OpenChoreo evaluates `${...}` as CEL there.
- **CPU/memory ceilings.** OpenChoreo's CEL has no quantity library, so the type requires `m` (CPU) and `Mi`
  (memory) units, with ceilings of 2000m and 4096Mi.
- **RBAC.** The installer's global `developer-binding` (group `developers`) still grants everything. In the
  real setup, teams get only `team-<name>`. Production is `empresa-prod-approvers` only.
- **Kyverno** pins the exact registry (Floci's ECR). On EKS, replace it with `<account>.dkr.ecr.<region>.amazonaws.com/*`
  and don't use a wildcard on the account, because that would accept another account's ECR. It applies only to golden-path pods (label `empresa.io/golden-path`), so existing apps that use
  ghcr/Docker Hub images aren't blocked. Locally the script installs it (chart 3.9.2, admission controller only).
- Workload endpoints default to `project` visibility, so there is no public URL. For a URL, add `external`.

## Verified locally (component `gp-smoke`, greeter sample)

Build with the new workflow → Workload → auto deploy in dev. Labels, runAsNonRoot, probes, topology-mode and
IRSA ServiceAccount all checked. 50 replicas, a 4000m CPU limit and HPA max 20 were blocked with the
messages. HPA and PDB were created. Promotion to staging got a different role, 3 replicas and no HPA.
Rollback in staging changed only the image. The Slack message was sent (failure case) to a fake webhook.
Kyverno blocked `nginx` and allowed the ECR image.

Template end to end (`vagas-api` and `candidatos-api`, team `recrutamento`): repo in Gitea, project created
only on the first run, component, first build fired by the push itself, app in dev answering `/health`.
One push = one build (also tested with a commit after creation).

RBAC through OpenChoreo's `POST /api/v1/authz/evaluates` with `subject_context` (group `recrutamento` after
`golden-path.sh team recrutamento`, and `empresa-prod-approvers`). The team creates `empresa-service` in its own
project, deploys to dev and staging, and is denied on another type, another project and production. The
approver promotes to production only.

Not tested: real Slack, and logging in with a real IdP user (the evaluate API uses the same bindings).
Cleanup: `kubectl delete component gp-smoke -n default` (also removes its bindings).
