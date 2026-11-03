# Requirements

What this lab builds and the rules it holds itself to. Requirement IDs (`FR-*`, `NFR-*`) are cited across the code,
tests and ADRs. Locked decisions live in [`docs/adr/`](adr/); when this file and an ADR disagree, the ADR wins.
Conventions per domain: [`docs/reference/standards/`](reference/standards/). Every trade-off behind the design:
[`docs/tradeoffs.md`](tradeoffs.md).

This repository was created from the `ship-it-safely` template (ECS Fargate). ADRs 0001 to 0011 are that lab's
history and still hold where ADR 0012 does not replace them. ADR 0012 moves the runtime to AWS Lambda.

## Goal

"Vibe coding an app is easy; shipping it safely is hard." This lab takes a small web app, which already runs
locally with `docker compose`, and runs it as a **Lambda web function**: the unchanged HTTP server inside a container
image, behind the AWS Lambda Web Adapter, fronted by an API Gateway HTTP API. It ships through GitHub Actions and
Terraform, and the security lessons are built into every step:

- No long-lived AWS keys. GitHub Actions authenticates with **OIDC**, one set of roles per AWS account.
- Separate roles for plan, apply and deploy, each least privilege. The deploy role cannot pass any IAM role.
- One AWS account per cloud environment (dev, prod). Each environment has its own state and its own secrets.
- App secrets live in **Secrets Manager**. The pipeline never reads secret values.
- Supply-chain hardening: actions pinned by SHA, tools and images pinned by checksum or digest, runner egress
  control, secret scanning.

### The deployment path

One image (one digest) travels the whole path; nothing is rebuilt on the way. A Lambda **version** pins that digest,
the alias `live` decides which version serves.

```
PR (app-ci) ──► merge ──► dev (publish version, smoke, move live) ──► promote (approval) ──► prod
                                                        ◄── rollback: move live back / promote an earlier green SHA
```

Done means this demo passes on live AWS, each step checked by `/version` (SHA and digest):

| # | Action | Proof |
|---|---|---|
| 1 | Merge an app change | Dev serves that SHA and digest through the API |
| 2 | Deploy with `strategy: canary` | `live` routes 10 percent to the new version during the bake, then 100 percent |
| 3 | Deploy a build that only breaks on Lambda | The smoke invoke of the new version fails; `live` never moves |
| 4 | Run App Promote with a green SHA and approve | Prod serves the **same digest** as dev |
| 5 | Promote an earlier green SHA (rollback) | Prod is back on the earlier digest within seconds, no rebuild, no new version when one exists |

## Scope

| In scope | Out of scope |
|---|---|
| `local` env (Docker Compose), `dev` env (AWS account A), `prod` env (account B, AWS Organizations) | ECS, EKS, EC2 (removed by ADR 0012 L11) |
| Bootstrap stack per account (state bucket, OIDC, roles, budget, ECR, security alert) | VPC networking (the function runs outside a VPC) |
| Infra pipeline (Terraform plan/apply) and app pipeline (build, ECR, Lambda version and alias) | CodeDeploy, CodePipeline, SAM, CDK (README notes only) |
| Secrets Manager read by the app at cold start | Custom domain and TLS certificate (optional extra) |
| All-at-once and alias-weighted canary releases, rollback by alias | WAF, IP allowlists (would need REST API or CloudFront) |
| Promote by digest dev to prod | PR preview environments (ADR 0009, deferred) |
| Destroy workflow, supply-chain hardening | Provisioned concurrency, SnapStart |

## Architecture

```
local:  docker compose up  (app + .env with fake values; the Lambda Web Adapter is inert outside Lambda)

GitHub ──OIDC──► AWS STS (per account)
  PR (infra/**)          → <prefix>-<env>-gha-plan    (read-only)              sub = repo:O/R:pull_request
  push main (infra/**)   → <prefix>-<env>-gha-apply   (Terraform write)        sub = repo:O/R:environment:<env>
  push main (app/**)     → <prefix>-<env>-gha-deploy  (ECR push, Lambda code,  sub = repo:O/R:environment:<env>
                                                       versions, alias; no PassRole)

each account:  bootstrap: S3 state, OIDC provider, roles, budget, ECR <prefix>-<env>-app, trail + alert topic
               env stack: HTTP API <prefix>-<env>-api ($default stage, throttling, access log)
                            └─► Lambda alias live ─► version N (image @sha256 digest)
                                  └─► Lambda Web Adapter ─► app on :8080 (readiness /health)
                          execution role <prefix>-<env>-app-exec ─► Secrets Manager <prefix>/<env>/app-api-key
                          log groups /aws/lambda/<prefix>-<env>-app, /aws/apigateway/<prefix>-<env>-api (7 days)
                          alarms: Lambda errors, throttles, API 5xx ─► SNS <prefix>-<env>-security-alerts
prod: same module, own state, secrets and roles; promote = crane copy of the same digest from dev ECR
```

## Demo app

**"Ship-it Board"**, one Python file plus a small SigV4 helper, standard library only.

| Endpoint | Behavior |
|---|---|
| `GET /` | One HTML page with `APP_ENV`, `GIT_SHA`, start time, image digest (`IMAGE_DIGEST`, `n/a` locally), and `secret_loaded: yes/no`. Background color from `APP_COLOR` or derived from `GIT_SHA` |
| `GET /health` | `200 {"status":"ok"}`; `500` when `BREAK=true` (the Lambda Web Adapter then never reports ready, so the version fails its smoke invoke) |
| `GET /version` | JSON with env, git SHA, image digest |
| `GET /admin` | Requires header `X-API-Key` equal to the API key; `401` otherwise |

Rules: never print or log the API key. Run as a non-root user in the image. `HEALTHCHECK` hits `/health` (used by
compose; Lambda ignores it).

## Functional requirements

| ID | Requirement |
|---|---|
| FR-1 | `docker compose up` runs the app locally using `.env`. `.env.example` is committed with fake values; `.env` is gitignored |
| FR-2 | Bootstrap (per account): S3 state bucket (versioning, SSE, public access block, TLS-only policy), GitHub OIDC provider, budget alert at 80 percent, ECR repository `<prefix>-<env>-app` (immutable tags, scan on push, keep 20 images, repository policy for `lambda.amazonaws.com` scoped by `aws:sourceArn`; dev also allows the prod deploy role to pull) |
| FR-3 | **Plan role:** trusts `repo:O/R:pull_request`. `ReadOnlyAccess` + state read + lock file put/delete. Explicit deny on `secretsmanager:GetSecretValue` |
| FR-4 | **Apply role:** trusts `repo:O/R:environment:<env>`. State read/write + only the services in `modules/app-lambda` (Lambda, API Gateway v2, CloudWatch Logs and alarms, the secret shell, IAM roles `<prefix>-<env>-app-*` under the boundary). `iam:PassRole` only on `<prefix>-<env>-app-exec`, only to `lambda.amazonaws.com`. Explicit deny on `secretsmanager:GetSecretValue` |
| FR-5 | **Deploy role:** trusts `repo:O/R:environment:<env>`. Push to the one ECR repository; update code, set `IMAGE_DIGEST`, publish versions, invoke versions, move the alias, delete old **versions** (qualified ARNs only) on the one function; read the API endpoint; read Lambda metrics; `DescribeSecret` on the one secret. **No `iam:PassRole`** (explicit deny) |
| FR-6 | `envs/<env>` uses the S3 backend in its own account with `use_lockfile = true`. Environments differ only through `terraform.tfvars` (parity guard) |
| FR-7 | `modules/app-lambda`: image function (x86_64, 512 MB, 10 s), alias `live`, HTTP API with `$default` route and stage, stage throttling, JSON access log, Lambda permission for the API on the alias, two log groups (7 days), three alarms, the secret shell, the execution role |
| FR-8 | Secrets: Terraform creates only the secret shell `<prefix>/<env>/app-api-key`. The function gets its ARN in `APP_API_KEY_SECRET_ARN`; the app reads the value with SigV4 at first use and ignores a plain `APP_API_KEY` on Lambda. Only the execution role may `GetSecretValue` on that ARN, and only from inside the function (`lambda:SourceFunctionArn`, in the role policy and the boundary). No CI role policy can read it; the deploy role can still ship code that runs as the execution role (accepted risk, ADR 0012 R7). The user sets the value with the AWS CLI, outside git and Terraform |
| FR-9 | `terraform-iac.yml`: on PR touching `infra/**`: fmt, init, validate, tflint, plan, PR comment (plan role, no `environment:`). On push to `main`: apply in dev with approval |
| FR-10 | `app-ci.yml`: on PR touching `app/**`: build the image, run the tests, scan it with Trivy pinned by version and checksum, no push |
| FR-11 | `app-deploy.yml`: on push to `main` touching `app/**`: build once, push to dev ECR by SHA tag with crane (no Docker in the credentialed job), update the function code by **digest**, set `IMAGE_DIGEST` and the description `sha=.. digest=..`, publish a version, smoke-invoke that version (`/health`, `/version`), then move `live` (all at once, or canary), prune old versions; a credential-free job `verify (dev)` checks `/version` through the API |
| FR-12 | `terraform-destroy.yml`: `workflow_dispatch`, input `env` and a typed confirmation, environment-gated |
| FR-13 | Prod account in AWS Organizations, bootstrapped with `accounts/prod.tfvars`. `app-promote.yml` (dispatch with a green SHA, prod approval) copies the **same digest** from dev ECR to prod ECR with crane, then runs the FR-11 release steps |
| FR-14 | Branching: trunk-based. Short feature branches, PR, `main`. Merge to `main` deploys dev. No `develop` or per-env branches |
| FR-15 | Release strategy: `all-at-once` by default; `canary` from the dispatch input or the environment variable `RELEASE_STRATEGY`: `live` routes `canary_percent` (default 10) to the new version for `bake_minutes` (default 5); probes invoke the alias directly and fail on any non-2xx from the new version, then the new version's `Errors` metric (crashes only) is checked. CodeDeploy is documented as the next step for real traffic |
| FR-16 | Rollback: the alias moves back to an existing version with the requested digest (seconds, no new version), or a version is published from the digest already in ECR. Prod: promote an earlier green SHA. Dev: `git revert`, or `app-deploy.yml` dispatch `mode: rollback` with a SHA that had a green `deploy (dev)` and `verify (dev)` run |
| FR-17 | **Deferred (ADR 0010 T2).** PR previews |

## Non-functional and security requirements

| ID | Requirement |
|---|---|
| NFR-1 | No AWS access keys stored in GitHub. Values that contain the account ID are GitHub secrets; the region is a variable |
| NFR-2 | Explicit `permissions:` per workflow and job; `id-token: write` only where a role is assumed |
| NFR-3 | Third-party actions pinned to a commit SHA; tools pinned by version and checksum; base image and the Lambda Web Adapter pinned by digest. Look up current versions; never guess |
| NFR-4 | `step-security/harden-runner` is the first step of every job; `block` with an explicit allowlist on credentialed jobs |
| NFR-5 | `.terraform.lock.hcl` committed with `linux_amd64` and dev-machine hashes. Dependabot for actions, Docker, Terraform and pre-commit |
| NFR-6 | gitleaks pre-commit + GitHub secret scanning and push protection |
| NFR-7 | Role `max_session_duration` = 3600 s. CloudTrail management events plus an EventBridge rule and SNS email on unexpected `AssumeRoleWithWebIdentity` |
| NFR-8 | Default tags: `Project`, `Env`, `ManagedBy=terraform` |
| NFR-9 | Claude Code never runs `terraform apply`/`destroy`/`import`/`state` or reads or writes secret values. It prepares the commands; the user runs them |
| NFR-10 | Cost ceiling: HTTP API stage throttling (5 requests/s, burst 10 by default), optional reserved concurrency, alarms, the budget alert |

## Cost and cleanup

- Nothing in the env stack is billed per hour: Lambda and HTTP API charge per request (lab traffic stays in the
  Lambda always-free tier), logs per GB ingested, the secret about 0.40 USD per month, ECR storage a few cents.
- Dev may stay up between sessions. Prod is destroyed after its checkpoint (ADR 0010 T7).
- Teardown order: destroy workflow per env, then bootstrap per account (empty the state bucket first and migrate
  state back to local; ECR is deleted with its images).
