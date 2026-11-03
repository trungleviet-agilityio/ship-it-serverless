# Requirements

What this lab builds and the rules it holds itself to. Requirement IDs (`FR-*`, `NFR-*`) are cited across the code,
tests and ADRs. Locked decisions live in [`docs/adr/`](adr/); when this file and an ADR disagree, the ADR wins.
Conventions per domain: [`docs/reference/standards/`](reference/standards/).

ADRs 0001 to 0008 cite `PLAN.md` and its sections. On 2026-10-30 that file was split: §1 (goal), §2 (scope), §5
(architecture), the demo app of §6, §7 (requirements) and §9 (cost) are below; the phase plan, inputs and
checkpoints are the maintainer's working notes and are not in the repository.

## Goal

"Vibe coding an app is easy; shipping it safely is hard." This lab takes a small containerized app, which already runs locally with `docker compose`, and ships it to **AWS ECS Fargate** through GitHub Actions + Terraform. The security lessons are built into every step:

- No long-lived AWS keys. GitHub Actions authenticates with **OIDC**, one set of roles per AWS account.
- Separate roles for plan, apply and deploy, each least privilege.
- One AWS account per cloud environment (dev, later prod). Each environment has its own state and its own secrets.
- App secrets live in **Secrets Manager**. The pipeline never reads secret values.
- Supply-chain hardening: actions pinned by SHA, runner egress monitoring, secret scanning.

### The deployment path (v3)

Phases 0 to 6 built a safe road from `main` to dev. v3 finishes the road from a development build to production:
**every build reaches production through one path, measurably, and can be taken back.** One image (one digest)
travels the whole path; nothing is rebuilt on the way.

```
PR (app-ci) ──► merge ──► dev ──► promote (approval) ──► prod
                                                                 ◄── rollback: promote an earlier green SHA
```

Done means steps 3 to 5 of this demo pass, each checked by `/version` (SHA and digest); steps 1 and 2 wait for PR previews (ADR 0010):

| # | Action | Proof |
|---|---|---|
| 1 | Open a PR that changes the app | Deferred with PR previews (ADR 0010 T2) |
| 2 | Close or merge the PR | Deferred with PR previews (ADR 0010 T2) |
| 3 | Merge | Dev serves that SHA (built in Phase 4) |
| 4 | Run App Promote with that SHA and approve | Prod serves the **same digest** as dev |
| 5 | Promote an earlier green SHA (rollback) | Prod is back on the earlier digest within minutes, with no rebuild |

Value: reviewers see the change running before merge; prod only ever runs what ran in dev; a bad release is
undone without a code change.

## Scope

| In scope | Out of scope |
|---|---|
| `local` env (Docker Compose), `dev` env (AWS account A) | Kubernetes / EKS |
| Bootstrap stack per account (state bucket, OIDC, roles, budget) | CodePipeline / CodeBuild (mentioned in README only) |
| Infra pipeline (Terraform plan/apply) + app pipeline (build → ECR → ECS) | Custom domain + TLS certificate (optional extra) |
| Secrets Manager wired into ECS task definition | Production-grade networking (private subnets + NAT) |
| Destroy workflow, supply-chain hardening | ECS `BLUE_GREEN` and `CANARY` (README only, v3) |
| `prod` env in a second AWS account via AWS Organizations, promote by digest, rollback (Phase 7) | Third-party hosting or tunnels (Cloudflare and similar) |
| | PR preview environments (Phase 8, deferred by ADR 0010; design in ADR 0009) |

## Architecture

```
local:  docker compose up  (app + .env with fake values)

GitHub ──OIDC──► AWS STS (per account)
  PR (infra/**)          → <prefix>-gha-plan    (read-only)       sub = repo:O/R:pull_request
  push main (infra/**)   → <prefix>-gha-apply   (Terraform write) sub = repo:O/R:environment:<env>
  push main (app/**)     → <prefix>-gha-deploy  (ECR push, ECS)   sub = repo:O/R:environment:<env>

dev account:  S3 state ─ ECR ─ ECS cluster ─ Fargate service ─ ALB (public)
              Secrets Manager: <prefix>/dev/app-api-key ──(execution role)──► container env APP_API_KEY
prod account: same module, own state/secrets/roles; promote = same image digest as dev; rollback = promote an earlier SHA
```

Notes from official docs:
- This repo uses GitHub's immutable OIDC subject: `repo:OWNER@OWNER_ID/REPO@REPO_ID:...` (ADR 0002 B12). Every trust also checks `aud`, `repository_id` and `repository_owner_id`; the plan role pins `ref = refs/pull/*/merge` (so `pull_request_target` is refused), and apply and deploy pin `ref = refs/heads/main` and the workflow `name:` (`terraform-iac`/`terraform-destroy`, `app-deploy`) (ADR 0004 E1, E2).
- The OIDC `sub` claim contains the environment name when the job references an environment. It contains `pull_request` only when the job does **not** reference an environment. So PR plan jobs must not set `environment:`.
- ECS `secrets[].valueFrom` takes the full ARN of a Secrets Manager secret or an SSM parameter.

## Demo app

**Demo app: "Ship-it Board".** The app is NOT the target of this lab; keep it tiny (one file, about 100 lines, no database, no frontend framework). Use Node or Python, user's choice.

| Endpoint | Behavior |
|---|---|
| `GET /` | One HTML page showing `APP_ENV` (local/dev/prod), `GIT_SHA` (Docker build arg), deploy/start time, and image digest if available (read from `ECS_CONTAINER_METADATA_URI_V4`; show `n/a` locally). Background color comes from `APP_COLOR`, or is derived from `GIT_SHA`, so a new version is visibly different during blue/green. Shows `secret_loaded: yes/no`. |
| `GET /health` | `200 {"status":"ok"}`. If `BREAK=true`, returns `500` (used to demo alarm-driven rollback). |
| `GET /version` | JSON with env, git SHA, image digest. |
| `GET /admin` | Requires header `X-API-Key` equal to `APP_API_KEY` (from Secrets Manager); returns `401` otherwise. |

Rules: never print or log the value of `APP_API_KEY`. Run as a non-root user. Make the `HEALTHCHECK` hit `/health`.

## Functional and non-functional requirements

### Functional

| ID | Requirement |
|---|---|
| FR-1 | `docker compose up` runs the app locally using `.env`. `.env.example` is committed with fake values; `.env` is gitignored. |
| FR-2 | Bootstrap (per account): S3 state bucket (versioning, SSE, public access block, TLS-only policy), GitHub OIDC provider, budget alert at 80%. |
| FR-3 | **Plan role:** trusts `repo:O/R:pull_request`. Permissions: `ReadOnlyAccess` + state read + put/delete `*.tflock`. Explicit **deny** on `secretsmanager:GetSecretValue`. |
| FR-4 | **Apply role:** trusts `repo:O/R:environment:<env>`. Permissions: state read/write + only the services in `modules/app-ecs`. `iam:PassRole` is limited to the module's ECS roles. Explicit **deny** on `secretsmanager:GetSecretValue`. |
| FR-5 | **Deploy role:** trusts `repo:O/R:environment:<env>`. Permissions: push to the one ECR repo, `ecs:RegisterTaskDefinition`, `ecs:DescribeServices`, `ecs:UpdateService` on the one service, `iam:PassRole` on the task + execution roles only. No Secrets Manager read (the deploy role may only read the secret's metadata with `DescribeSecret`, ADR 0006 G14). |
| FR-6 | `envs/<env>` uses the S3 backend in **its own account**, with `use_lockfile = true`. Values differ only through `terraform.tfvars`. |
| FR-7 | `modules/app-ecs`: VPC with 2 public subnets (no NAT, tasks get public IPs, lab only), ALB → target group → Fargate service (0.25 vCPU / 0.5 GB, 1 task), ECR repo (scan on push, immutable tags), CloudWatch log group (7-day retention). |
| FR-8 | Secrets: Terraform creates only the **secret shell** `<prefix>/<env>/app-api-key` (no value, so nothing lands in state). The task definition maps it via `secrets[].valueFrom` = secret ARN. The execution role may `GetSecretValue` on that ARN only. The user sets the value with the AWS CLI, outside git and outside Terraform. |
| FR-9 | `terraform-iac.yml`: on PR touching `infra/**` → fmt, init, validate, tflint, plan, PR comment (plan role, **no** `environment:`). On push to `main` → apply, with `environment: dev`, required reviewer. |
| FR-10 | `app-ci.yml`: on PR touching `app/**` → build image, run tests, scan the image (e.g. Trivy **pinned by version + checksum**), no push. |
| FR-11 | `app-deploy.yml`: on push to `main` touching `app/**` → build once, tag with git SHA, push to dev ECR, register a task definition revision referencing the **image digest**, update the service, wait for stability. |
| FR-12 | `terraform-destroy.yml`: `workflow_dispatch`, input `env`, environment-gated. |
| FR-14 | Branching: trunk-based. Short-lived feature branches → PR → `main`. Merge to `main` deploys dev. A release tag `v*` (or `workflow_dispatch`) promotes the same image digest to prod. No `develop`/`release` branches, no branch-per-env. |
| FR-15 | Release strategy: dev and prod use ECS `ROLLING` with deployment circuit breaker + auto rollback. `BLUE_GREEN` and `CANARY` are documented in README as next steps once there is real traffic to measure (v3: dropped from Phase 7). |
| FR-16 | Rollback: prod returns to an earlier green SHA by promoting it again (FR-13). The image is already in prod ECR by digest, so nothing is rebuilt or copied, and the trust and approval are the ones promote uses. Dev rolls back with `git revert` on `main` (trunk-based). |
| FR-17 | **Deferred (ADR 0010 T2).** PR preview: a PR from this repository that touches `app/**` gets the image it built running in the dev account, with its own URL posted as a sticky PR comment and `/version` showing the PR's SHA. Closing the PR removes everything the preview created. The build stays in a credential-free job; the preview job uses GitHub environment `preview` (required reviewer) and a preview role that can only touch resources tagged `Env=preview`. Fork and Dependabot PRs get no preview. Design (URL, routing, secret, cost cap, the trust for a PR-ref workflow file) in the Phase 8 ADR. |
| FR-13 | Prod account in AWS Organizations, bootstrapped with `accounts/prod.tfvars`. `envs/prod` added. The prod deploy job copies the **same digest** from dev ECR to prod ECR (or uses ECR cross-account replication), then deploys. Trigger: `workflow_dispatch` or release tag; GitHub environment `prod` requires a reviewer. |

### Non-functional / security

| ID | Requirement |
|---|---|
| NFR-1 | No AWS access keys stored in GitHub. Values that contain the account ID (role ARNs, account ID) are GitHub **secrets** (repo level for the PR plan job, environment level for apply and deploy), because variables print unmasked in public logs; the region is a variable (ADR 0003 C10, ADR 0004 E25). |
| NFR-2 | Explicit `permissions:` per workflow and job. `id-token: write` only where a role is assumed. |
| NFR-3 | All third-party actions are pinned to a commit SHA (version in a comment). Tool versions are pinned and binaries are checksum-verified. Look up current versions; do not guess. |
| NFR-4 | `step-security/harden-runner` is the first step of every job (start in `audit` mode). |
| NFR-5 | `.terraform.lock.hcl` committed, with hashes for `linux_amd64` and the dev machine platform. Dependabot enabled for actions, Docker and Terraform. |
| NFR-6 | gitleaks pre-commit + GitHub secret scanning / push protection. |
| NFR-7 | Role `max_session_duration` = 3600 s. CloudTrail (management events) on, plus a metric filter/alarm on `AssumeRoleWithWebIdentity` with an unexpected `sub` (stretch). Built in Phase 6 as an EventBridge rule with an SNS email instead of a metric filter and alarm: about 0 USD a month, no log ingestion (ADR 0007 S8). |
| NFR-8 | Default tags: `Project`, `Env`, `ManagedBy=terraform`. |
| NFR-9 | Claude Code never runs `terraform apply`/`destroy` or `aws secretsmanager put-secret-value` against AWS. It prepares the commands and the user runs them. |

## Cost and cleanup

- ALB and Fargate are billed hourly, so destroy `envs/*` after each session (destroy workflow). No NAT gateway by design.
- (Deferred, ADR 0010) A preview would add one Fargate task (0.25 vCPU) while its PR is open, on the dev ALB that already exists; closing the PR would stop it.
- S3, Budgets, Organizations and the extra accounts cost close to $0.
- Teardown order: destroy workflow per env → bootstrap per account (empty the bucket first, migrate state back to local).
