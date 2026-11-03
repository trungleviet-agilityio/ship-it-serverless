# ADR 0012: Lambda Web Function architecture

- Status: proposed
- Date: 2026-11-03
- Amends (once accepted): `docs/requirements.md` Goal, Scope, Architecture, FR-4, FR-5, FR-7, FR-8, FR-11, FR-13,
  FR-15, FR-16; ADR 0008 P19 (ECR in the env stack); ADR 0004 and 0005 (the ECS module and deploy). Keeps
  ADR 0001, 0002 (trust), 0007 (supply chain), 0008 (accounts, env cloning, promote by digest), 0010 and 0011.

## Context

`ship-it-serverless` starts from the `ship-it-safely` template: one small stdlib Python app reaches prod through
GitHub Actions and Terraform, with OIDC roles per account (plan, apply, deploy), pinned actions and tools, one
image digest promoted from dev to prod, and rollback by promoting an earlier green SHA (ADR 0010 T1). The owner
wants the same delivery discipline with the web app running on AWS Lambda instead of ECS Fargate behind an ALB.
This ADR picks the runtime shape and the front door, maps every ECS lesson to its Lambda counterpart, and lists
what the follow-up build phases keep, replace and delete. It changes no code.

Inherited rules that constrain the design:

| Source | Rule |
|---|---|
| ADR 0001 D2, D3 | No account IDs in git; region `ap-southeast-1`; budget 20 USD/month |
| ADR 0001 D4 | App in Python 3.13, standard library only |
| ADR 0011 | Every AWS name is `<prefix>-<env>-<thing>`; `project.env` holds the prefix |
| ADR 0011 consequences | App contract: one port, a health path, `/version` with the commit SHA and the image digest, no writes to disk, secrets from the environment |
| ADR 0002, 0004 E1/E2, 0007 S2 | Trust pins `aud`, immutable `sub`, `repository_id`, `repository_owner_id`, `ref`, `aws:RequestedRegion`, and `job_workflow_ref` (`app-deploy.yml` in dev, `app-promote.yml` in prod) |
| FR-3 to FR-5 | Plan read-only; apply limited to the module's services with exact `iam:PassRole`; deploy limited to one repo and one runtime target; nobody reads secret values |
| FR-8 | Terraform creates only the secret shell; the value never reaches state or git |
| ADR 0005 F2 | Terraform owns the runtime shape; the deploy swaps only the image, by digest |
| ADR 0007 | Actions by SHA, tools by version and checksum, harden-runner `block` on credentialed jobs, base image by digest |
| ADR 0008 P9, P10 | Promote = copy by digest from dev ECR to prod ECR, then deploy; trigger is a dispatch with a green SHA |
| NFR-9 | Claude never applies, destroys or touches secret values |

### How the facts were checked

The authoring session could not open `docs.aws.amazon.com` or `aws.amazon.com` (blocked by its network policy).
Facts below come from search results that quote those official pages, from AWS blogs and re:Post, and from the
Lambda Web Adapter repository on GitHub. Each finding is marked:

- **(V)** the official page's own text appeared in the search result, or the GitHub source was read directly.
- **(S)** secondary source only (re:Post, blog, community). Phase L1 re-checks it on the live official page.
- **(C)** must be confirmed at a checkpoint on live AWS.

### Findings

1. **Lambda Web Adapter (LWA)** (V): latest release `v1.1.0` (released 18 September; the releases page shows no year). It is added to an existing image with
   one line, `COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:1.1.0 /lambda-adapter /opt/extensions/lambda-adapter`.
   It forwards Function URL, API Gateway (REST and HTTP) and ALB events to the app's port (`AWS_LWA_PORT`, default
   `8080`). A readiness check polls `AWS_LWA_READINESS_CHECK_PATH` (default `/`) until it gets a status in
   `AWS_LWA_READINESS_CHECK_HEALTHY_STATUS` (default `100-499`; v1.0.0 removed the older `..._MIN_UNHEALTHY_STATUS`).
   The same image still runs unchanged on Docker, Fargate or a laptop.
2. **Container images and cold start** (V): Lambda optimizes an image after each upload and caches it near the
   execution environment. "Cold start times are the same as for .zip archives". The function is `Pending` for a
   few seconds after each code update, until optimization is done.
3. **Idle image functions go `Inactive`** (V): after several weeks without an invoke, Lambda reclaims the
   optimized image. The first invoke is rejected, and the function is `Pending` until the image is re-optimized.
4. **Code signing does not support container images** (V). AWS Signer code signing is zip only.
5. **ECR access** (S): the repository policy must allow `lambda.amazonaws.com` to call `ecr:BatchGetImage` and
   `ecr:GetDownloadUrlForLayer`. Lambda adds that statement itself only when the caller holds
   `ecr:GetRepositoryPolicy` and `ecr:SetRepositoryPolicy`. Cross-account use is supported: the repository policy
   names the Lambda service with `aws:sourceArn` set to the function ARN in the other account.
6. **Image location** (S): an image function takes a private ECR repository in the same region. A public image
   (the ECS placeholder from ADR 0005 F2) cannot be used, so a function cannot be created before its repository
   holds an image.
7. **What happens when a referenced image is deleted from ECR**: not found in any source (C). The ECR lifecycle
   rule (keep the last 10 images, ADR 0004 E10) must therefore never delete an image that a kept version uses.
8. **Function URL auth** (V, with a conflict): `AWS_IAM` callers need `lambda:InvokeFunctionUrl` and
   `lambda:InvokeFunction`. For `NONE`, the EU mirror of the page says a function URL created from October 2025
   needs a resource policy that allows **both** actions, with the condition key `lambda:InvokedViaFunctionUrl`
   to limit `InvokeFunction` to URL calls. The English page in the results still shows the older text (C). The
   console and SAM add the policy for you; the API, CLI and Terraform do not.
9. **IAM for the deploy** (V): `iam:PassRole` (with `iam:PassedToService = lambda.amazonaws.com`) belongs to
   `CreateFunction`. The `UpdateFunctionCode` row lists no `PassRole`; a role change goes through
   `UpdateFunctionConfiguration` with a `Role`, which needs `PassRole`. So a deploy role **without any
   `iam:PassRole`** can update code but can never attach a different execution role (C: one negative test).
10. **Reserved concurrency** (V): you can reserve up to the unreserved account concurrency minus 100. In an
    account whose quota is at the 1,000 default this is a cheap cap on cost. In an account with a lower quota (some
    new accounts report 10, not confirmed) no reservation is possible (C).
11. **CodeDeploy for Lambda** (S): shifts an alias between two versions (`Canary*`, `Linear*`, `AllAtOnce`), watches
    CloudWatch alarms and reverts the alias on alarm. `BeforeAllowTraffic` and `AfterAllowTraffic` hooks are extra
    Lambda functions that must call `codedeploy:PutLifecycleEventHookExecutionStatus`. Alarms must not be in
    `ALARM` when a deployment starts.
12. **Front door limits** (S): HTTP API integration timeout about 30 s and no AWS WAF (WAF is a REST API feature);
    Function URL bound only by the function timeout (up to 15 min); 6 MB Lambda payload limit for both.
13. **Prices** (S, US reference rates; the ap-southeast-1 page could not be opened, C): Lambda 0.20 USD per
    million requests and 0.0000166667 USD per GB-second (x86), always-free 1 million requests and 400,000
    GB-seconds per month. HTTP API about 1.00 USD per million requests. ALB billed per hour (any partial hour is a
    full hour) plus LCUs; for Lambda targets one LCU is 0.4 GB processed per hour. Function URLs have no charge of
    their own beyond Lambda.
14. **Extensions in images** (V for the pattern, S for the Parameters and Secrets Lambda Extension): image
    functions cannot attach layers; an extension is copied into `/opt/extensions` at build time. The Parameters
    and Secrets Lambda Extension listens on `localhost:2773` and needs the `X-Aws-Parameters-Secrets-Token` header.
    It is published as a layer, not as a public image, so getting it into the image needs an AWS API call
    (`GetLayerVersion`) with credentials.

## Options

### Runtime packaging

| | (a) **Existing image on Lambda via LWA, image in ECR, deployed by digest** | (b) Native Python handler packaged as zip |
|---|---|---|
| App change | One `COPY` line plus three `AWS_LWA_*` env values in the Dockerfile; `/version` and the secret read get a Lambda path (L11, L12). `board.py` keeps its HTTP server | Rewrite routing as `handler(event, context)`; a second code path for local runs or drop compose |
| Local = cloud | Same image in compose, `app-ci` smoke, Trivy and Lambda | Different artifact locally (server) and in Lambda (handler) |
| Cold start | Image cached by Lambda, comparable to zip (Finding 2) plus LWA's readiness wait; measured at the checkpoint (C) | Smallest; SnapStart available for Python (extra charge) |
| Supply chain kept | Base image by digest, Dependabot `docker`, Trivy image gate, artifact sha256 between jobs (ADR 0005, 0007) | Lose the image gate; need Trivy `fs`, an S3 artifact bucket per account, a new pin story for the zip |
| Signing | No Lambda code signing for images (Finding 4); integrity comes from the digest pin | AWS Signer code signing config available |
| Promote by digest | Unchanged: `crane copy` by digest dev to prod (P9); the version records the digest | Promote by S3 object and `CodeSha256`; new cross-account bucket policy |
| Rollback | Alias to an existing version, or publish from a digest already in prod ECR | Same alias mechanics, zip must still be in S3 |
| Rework | Small app change, new module and deploy scripts | App rewrite, new artifact pipeline, new module and deploy scripts |

### Front door

| | **Lambda Function URL** | API Gateway HTTP API | ALB with Lambda target |
|---|---|---|---|
| Lab cost (Finding 13) | 0 USD on top of Lambda | About 1 USD per million requests (free tier 12 months for new customers) | Hourly charge plus LCU, roughly the 16 to 20 USD a month that drove the ECS teardown rule; the budget would be gone if left up |
| Pieces to manage | `aws_lambda_function_url` on the alias, one resource-policy statement | API, stage, integration, route, permission | VPC, subnets, SG, ALB, listener, target group, permission (today's `network.tf`, `alb.tf`) |
| Limits | Function timeout, 6 MB payload | About 30 s timeout | Lambda target payload rules |
| Edge controls | None built in; no IP allowlist (today's `ALB_INGRESS_CIDRS` cannot carry over); add CloudFront with OAC and WAF later if needed | Throttling per route; no WAF on HTTP APIs | SG ingress CIDRs, WAF |
| Alias routing | URL is bound to a qualifier (`live` alias) so a deploy is one `UpdateAlias` | Integration targets the alias ARN | Target group targets the alias ARN |
| Custom domain | Not supported directly (CloudFront in front) | Supported | Supported (with an ACM cert) |

### Rollout

| | **Pipeline-driven alias update with a pre-traffic smoke invoke** | CodeDeploy traffic shifting |
|---|---|---|
| Mechanics | `UpdateFunctionCode` by digest, `PublishVersion`, invoke the new version directly (`/health`, `/version`), then `UpdateAlias live` | Same publish, then a CodeDeploy deployment shifts `live` by `Canary10Percent5Minutes` (or similar) with alarms and hook functions |
| Value at lab traffic | The bad version never gets the alias (the BREAK demo fails the smoke invoke) | A canary over almost no traffic proves nothing; same reason FR-15 dropped ECS `BLUE_GREEN` and `CANARY` |
| IAM surface | Deploy role: Lambda actions on one function only, no `PassRole` | Plus a CodeDeploy app, deployment group, service role, `PassRole` to CodeDeploy, hook functions and their roles |
| Rollback | Point `live` at an earlier version (seconds) | Same, plus automatic revert on alarm |

## Decision

| # | Decision |
|---|---|
| L1 | **Option (a).** The existing app image runs on Lambda through the Lambda Web Adapter, from a private ECR repository, deployed by **digest** (`<repo>@sha256:<64 hex>`). LWA is copied from `public.ecr.aws/awsguru/aws-lambda-adapter` **pinned by digest** with the version in a comment (NFR-3; the digest is looked up with the `pin-versions` skill in Phase L1, v1.1.0 is current today). Package type `Image`, architecture `x86_64` (Q2), 512 MB, timeout 10 s, ephemeral `/tmp` untouched (the app writes nothing) |
| L2 | **Front door: Lambda Function URL**, auth type `NONE`, bound to the alias `live`. Terraform writes the resource policy (Finding 8): `lambda:InvokeFunctionUrl` with `lambda:FunctionUrlAuthType = NONE` and `lambda:InvokeFunction` with `lambda:InvokedViaFunctionUrl = true`, principal `*`, qualifier `live`. No API Gateway, no ALB, no VPC |
| L3 | **Function shape** (Terraform owns it, as ADR 0005 F2): one function `<prefix>-<env>-app`, alias `live`, env `APP_ENV`, `AWS_LWA_PORT=8080`, `AWS_LWA_READINESS_CHECK_PATH=/health`, `APP_API_KEY_SECRET_ARN`. Terraform sets `ignore_changes` on `image_uri` and on the one env key `IMAGE_DIGEST` (L12), and never moves the alias after create (`ignore_changes` on `function_version`). If Terraform cannot ignore a single map key in a nested block, the fallback is `ignore_changes = [environment]` plus a deploy guard that refuses any env change other than `IMAGE_DIGEST` (decided in Phase L3 from a `terraform test`) |
| L4 | **ECR moves to bootstrap** (amends ADR 0008 P19). The repository `<prefix>-<env>-app` (IMMUTABLE tags, scan on push) is created per account by the admin-applied bootstrap, so (1) the function can be created from an image that already exists (Finding 6), (2) promotion and rollback no longer need the dev stack up (closes ADR 0008 R22), and (3) env teardown never deletes images that versions use. Terraform reads the first image with `data "aws_ecr_image"` (`most_recent = true`) and a precondition that prints "run App Deploy once first" when the repository is empty. The repository policy allows `lambda.amazonaws.com` pull with `aws:sourceArn` = this account's function ARN; dev adds the pull-only statement for the prod deploy role (P9) as today. Lambda never edits the policy (no one holds `ecr:SetRepositoryPolicy` at deploy time) |
| L5 | **Lifecycle and versions.** ECR keeps the last 20 images; the deploy prunes published versions beyond the last 10 that `live` does not point at, so no kept version references a deleted image (Finding 7). A checkpoint step deletes an unreferenced old image on purpose and records what Lambda does (C) |
| L6 | **Rollout = pipeline-driven, no CodeDeploy.** Deploy: preflight (function `Active`, last update `Successful`, secret has a value via `DescribeSecret`), push once with the SHA tag, `UpdateFunctionCode --image-uri <repo>@<digest>`, wait `function-updated`, set `IMAGE_DIGEST`, wait, `PublishVersion` (description `sha=<40 hex>`), invoke that **version** with a synthetic Function URL event for `/health` and `/version` (both must be 200 and `/version` must show the SHA and digest), then `UpdateAlias live`, then `curl` the URL `/version`. A failed smoke stops before the alias moves; nothing serves the bad version. CodeDeploy is documented in the README as the next step once there is traffic, as FR-15 did for ECS |
| L7 | **Promote and rollback** keep ADR 0008 P9 and P10 and ADR 0010 T4: `app-promote.yml` dispatch with a green SHA, `resolve` job without AWS, `promote` job copies by digest with crane, then the L6 steps in prod. **Rollback** = promote an earlier green SHA. If prod already has a published version whose `IMAGE_DIGEST` matches, the job only runs the smoke invoke on that version and `UpdateAlias` (seconds, no copy, no publish); otherwise it publishes from the digest already in prod ECR. Dev rolls back with `git revert` (FR-16 unchanged) |
| L8 | **Deploy role** (FR-5 rewritten), per account, trust unchanged (same file names, so no trust edit): ECR push and pull on the one repository (dev) or pull on the dev source plus push on the prod repository (prod, P9); `lambda:GetFunction`, `GetFunctionConfiguration`, `UpdateFunctionCode`, `UpdateFunctionConfiguration`, `PublishVersion`, `ListVersionsByFunction`, `DeleteFunction` (qualified version ARNs only, for L5), `GetAlias`, `UpdateAlias`, `InvokeFunction` on `function:<prefix>-<env>-app` and `function:<prefix>-<env>-app:*`; `secretsmanager:DescribeSecret` on the one secret (ADR 0006 G14). **No `iam:PassRole` at all**, plus an explicit Deny on `iam:PassRole` in the deploy policy, so the execution role cannot be swapped (Finding 9). Each action's resource and condition support is checked in the Service Authorization Reference in Phase L2; `DeleteFunction` must be limited to version qualifiers, or L5 moves to the apply role |
| L9 | **Apply role** (FR-4 rewritten): state as today; `lambda:*Function*`, `*Alias*`, `*FunctionUrl*`, `AddPermission`, `RemovePermission`, `PutFunctionConcurrency`, `TagResource` on `function:<prefix>-<env>-*`; logs on `/aws/lambda/<prefix>-<env>-*`; secret shell; IAM create and update only for roles `<prefix>-<env>-app-*` with the bootstrap permissions boundary required; `iam:PassRole` **only** on `<prefix>-<env>-app-exec`, with `iam:PassedToService = lambda.amazonaws.com`. All EC2, ELB and ECS statements are deleted. The plan role is unchanged (`ReadOnlyAccess` plus the guardrails) |
| L10 | **Execution role** `<prefix>-<env>-app-exec`, created by Terraform under the boundary: `logs:CreateLogStream` and `logs:PutLogEvents` on the one log group; `secretsmanager:GetSecretValue` on the one secret ARN. Not `AWSLambdaBasicExecutionRole` (it allows `logs:CreateLogGroup` on `*`). The boundary policy (`iam_ecs_boundary.tf`) is renamed `<prefix>-<env>-app-boundary` and capped to those actions |
| L11 | **Secret value** (FR-8): Terraform keeps creating only the shell. At cold start the app reads the value once with a **stdlib SigV4 `GetSecretValue` call** using the execution role credentials Lambda puts in the environment, then keeps it in memory for the life of the execution environment. Locally, `APP_API_KEY` from `.env` still wins. Rejected: the Parameters and Secrets extension (Finding 14: copying the layer into the image needs AWS credentials in the build job, which ADR 0005 keeps credential-free, and the binary has no public digest to pin); a Lambda environment variable holding the value (it would sit in state and in `GetFunctionConfiguration` output). Q3 asks the owner |
| L12 | **`/version` on Lambda**: `image_digest` comes from `IMAGE_DIGEST`, set by the deploy before `PublishVersion`, so each version carries its own digest and an alias flip shows the right one. `ECS_CONTAINER_METADATA_URI_V4` stays as the ECS path for forks. The pipeline proves equality four ways: ECR `imageDigest`, the version's resolved image URI, `IMAGE_DIGEST` of the version, and `/version` through the URL |
| L13 | **Cost guard**: reserved concurrency 5 on the function when the account quota allows it (Finding 10), otherwise a CloudWatch alarm on `ConcurrentExecutions` to the existing security SNS topic; the budget alert stays. Denial of wallet through a public URL is the main new risk (R1) |
| L14 | **Logging**: Terraform creates `/aws/lambda/<prefix>-<env>-app` with 7-day retention before the function, so Lambda never creates an unmanaged group. The app keeps its one-line access log; LWA and platform lines land in the same group |
| L15 | **Teardown**: `terraform-destroy` keeps its shape (plan `-destroy`, delete-only guard, apply the saved plan). With no hourly resources the env may stay up between sessions (Q4). Bootstrap destroy empties ECR (`force_delete`) as it empties the state bucket today |
| L16 | **Names and contract unchanged**: `<prefix>-<env>-<thing>` from `project.env`; one port 8080; health `/health`; `/version` with SHA and digest; UID 10001 in the image (Lambda may run as its own non-root user, S; files stay world-readable); `HEALTHCHECK` is kept for compose and ignored by Lambda |
| L17 | **Image format**: the build keeps the default `docker` driver (single-platform manifest, no attestations), so ECR, Lambda and `/version` agree on one digest (ADR 0005 Finding 5). A guard in `scripts/image/build.sh` refuses a manifest list |

### Kept, replaced and deleted

| Piece | Fate | Notes |
|---|---|---|
| `app/src/board.py`, tests | **Changed** (Phase L1) | `IMAGE_DIGEST` fallback; stdlib SigV4 secret read behind `APP_API_KEY_SECRET_ARN`; tests for both |
| `app/Dockerfile` | **Changed** | LWA `COPY` by digest; `AWS_LWA_*` env. Base image, test stage, UID and `HEALTHCHECK` kept |
| `app/compose.yaml`, `.env.example` | Kept | LWA is inert outside Lambda |
| `infra/terraform/bootstrap`: `state.tf`, `oidc.tf`, `budget.tf`, `monitoring.tf`, `iam_plan.tf`, `iam_guardrails.tf` | Kept | Guardrails gain the deploy `PassRole` deny (L8); monitoring gains the L13 alarm target if needed |
| `bootstrap/iam_apply.tf`, `iam_deploy.tf` | **Rewritten** | L8, L9 |
| `bootstrap/iam_ecs_boundary.tf` | **Replaced** by `iam_app_boundary.tf` | L10 |
| `bootstrap` ECR (new `ecr.tf`) | **New** | L4 |
| `bootstrap/tests/*.tftest.hcl` | **Changed** | `iam.tftest.hcl` asserts the new statements, no `PassRole` on deploy, exact `PassRole` on apply; trust tests unchanged |
| `modules/app-ecs` | **Deleted** after `modules/app-lambda` lands | `network.tf`, `alb.tf`, `security_groups.tf`, `ecs.tf` have no counterpart; `ecr.tf` moves to bootstrap; `logs.tf`, `secrets.tf`, `iam.tf` are reworked in the new module |
| `modules/app-lambda` (new) | **New** | Function, alias `live`, URL, permission statements, log group, secret shell, execution role, tests with `mock_provider` |
| `envs/dev`, `envs/prod` | **Changed** | Call `app-lambda`; tfvars lose `azs`, `vpc_cidr`, `container_image`, `desired_count`, `task_cpu`, `task_memory`; gain `memory_mb`, `timeout_s`, `reserved_concurrency` |
| `.github/workflows/terraform-iac.yml`, `reusable-terraform-plan.yml`, `terraform-destroy.yml` | Kept, small changes | Drop `ALB_INGRESS_CIDRS*`; destroy drops the task-definition deregister step; harden-runner allowlists swap `ec2`, `elasticloadbalancing`, `ecs` hosts for `lambda` |
| `app-ci.yml` | Kept | Build, smoke, Trivy unchanged |
| `app-deploy.yml` | **Changed steps, same file name** | `build-scan` job kept as is; `deploy` steps become L6. File name kept so the trust (`job_workflow_ref`) needs no bootstrap change |
| `app-promote.yml` | **Changed steps, same file name** | `resolve` kept; `promote` = crane copy (kept) plus L6/L7 |
| `oidc-smoke-test.yml`, `repo-guard.yml`, Dependabot, CODEOWNERS | Kept | Negative tests gain N11: the deploy role cannot `UpdateFunctionConfiguration --role` |
| `scripts/image/*` | Kept | `build.sh` gains the L17 guard; `promote-copy.sh`, `promote-resolve.sh` unchanged |
| `scripts/ecs/*` (`preflight.sh`, `render-task-def.sh`, `wait-deployment.sh`, `deregister-revisions.sh`) | **Replaced** by `scripts/lambda/` (`preflight.sh`, `publish.sh`, `smoke-invoke.sh`, `shift-alias.sh`, `prune-versions.sh`) | Same style: `lib.sh`, self-tests in `scripts/selftest/lambda.sh` replacing `ecs.sh` and `render.sh` |
| `scripts/tf/mask-cidrs.sh` | **Deleted** | No CIDRs left to mask |
| `scripts/tf/new-env.sh`, `scripts/guard/env_parity.py` | **Changed** | No `vpc_cidr` rewrite or uniqueness rule |
| `scripts/tf/policy.sh`, `destroy-check.sh`, `selftest/*` | **Changed** | Drop ECS and ALB references |
| `lib.sh`, `names.sh`, `project.sh`, `Makefile`, `mise.toml` | Kept | Name helpers gain `function`, `alias`, `exec role` |
| Checkpoints of ADR 0004, 0005, 0006, 0008 PR B2 | **Rewritten** per phase below | Same pattern: the user applies, sets the secret, approves, and checks `/version` |
| `docs/diagrams` ECS diagrams | **Replaced** in Phase L5 | `/sis-team:diagram lambda` |

### Follow-up phases

| Phase | Owner | Content | Checkpoint (user runs) |
|---|---|---|---|
| L0 | orchestrator | This ADR, accepted with the Q answers; `docs/requirements.md` amended | Review and merge |
| L1 | backend-dev | App and Dockerfile (L1, L11, L12, L16, L17 guard test); LWA pinned by digest; local run unchanged | `make up`, `make verify`; `/version` locally |
| L2 | devops-engineer | Bootstrap rework: ECR (L4), apply and deploy roles (L8, L9), boundary (L10), tests | Bootstrap re-apply in dev with admin SSO; IAM simulator checks for L8 (no `PassRole`) |
| L3 | devops-engineer | `modules/app-lambda`, `envs/dev`, workflow and script cleanup, `modules/app-ecs` deleted | First App Deploy push (stops: no function yet), then `terraform-iac` apply dev, `put-secret-value`, URL returns 200 |
| L4 | devops-engineer | `app-deploy.yml` deploy job and `scripts/lambda/*` (L5, L6, L13) | Merge an app change; `/version` digest equals ECR digest; BREAK demo (the smoke invoke fails, `live` stays); N11 |
| L5 | devops-engineer, orchestrator | `envs/prod`, prod bootstrap, `app-promote.yml` (L7), docs and diagrams | Requirements demo steps 3 to 5 on live AWS, then teardown per L15 |

## Consequences

- One image for local, CI and Lambda; the supply-chain story of ADR 0005 and 0007 carries over unchanged.
- Idle cost of an env drops from the ALB and Fargate hourly charges to roughly the secret (one per account) and a
  few cents of ECR storage; lab traffic stays inside the Lambda always-free tier (rates to confirm, Finding 13).
- Bootstrap grows (ECR) and is re-applied by the user in every account once (L2).
- The OIDC trust, roles' names, workflow file names and GitHub environments do not change.
- Lost: the ALB ingress CIDR allowlist and the HTTP 80 listener (the URL is HTTPS only), ECS circuit breaker
  semantics (replaced by the smoke invoke), and code signing is not available for images.

### Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | A public URL can be called by anyone, so cost scales with abuse | L13 concurrency cap or alarm, budget alert, 10 s timeout; CloudFront with WAF later (Q5) |
| R2 | Lambda behavior on a deleted image is unknown (Finding 7) | L4 and L5 keep images for every kept version; checkpoint L4 records the real behavior |
| R3 | `Inactive` after weeks idle (Finding 3) makes the first request fail | Smoke invoke in every deploy; README note; an EventBridge ping is rejected as cost and noise for a lab |
| R4 | `UpdateFunctionConfiguration` lets the deploy role change env values, memory or timeout | No `PassRole` (role cannot change); the deploy script changes `IMAGE_DIGEST` only; Terraform plan shows drift on the next PR; Q6 offers a stricter variant |
| R5 | Facts marked (S) or (C) may differ on the live official pages | Phase L1 re-reads them with the network allowlist fixed; each (C) has a checkpoint step |

## Questions for the owner (recommendation first)

| # | Question | Recommendation |
|---|---|---|
| Q1 | Accept option (a) with a Function URL and no CodeDeploy (L1, L2, L6)? | Yes |
| Q2 | `x86_64` or `arm64` (Graviton, about 20 percent cheaper per GB-second, but needs the `ubuntu-24.04-arm` runner or QEMU)? | `x86_64` now; arm64 as a later PR |
| Q3 | Secret read: stdlib SigV4 in the app (L11), or the Parameters and Secrets extension copied in by a credentialed build step? | SigV4 in the app |
| Q4 | Keep envs up between sessions now that there is no hourly cost, or keep the destroy-after-session rule? | Keep dev up, destroy prod after each checkpoint (ADR 0010 T7) |
| Q5 | Is an IP allowlist (the old `ALB_INGRESS_CIDRS`) still wanted? If yes, CloudFront with OAC and WAF in front of the URL is a separate ADR | No for now |
| Q6 | Accept `IMAGE_DIGEST` via `UpdateFunctionConfiguration` (L12), or drop the digest from `/version` and prove it from the version's image URI only (deploy role then needs no `UpdateFunctionConfiguration`)? | Accept L12; it keeps the app contract |
| Q7 | Move ECR to bootstrap (L4)? It changes the admin-applied stack in both accounts | Yes |
| Q8 | Allow `docs.aws.amazon.com` and `aws.amazon.com` in the cloud environment's network settings so Phase L1 can re-check the (S) facts? | Yes |

## Sources

- Lambda Web Adapter, README and releases: https://github.com/awslabs/aws-lambda-web-adapter, https://github.com/awslabs/aws-lambda-web-adapter/releases
- Lambda function URL access control: https://docs.aws.amazon.com/lambda/latest/dg/urls-auth.html (EU mirror with the October 2025 note: https://docs.aws.eu/lambda/latest/dg/urls-auth.html)
- Lambda reserved concurrency: https://docs.aws.amazon.com/lambda/latest/dg/configuration-concurrency.html
- Lambda code signing (not for images): https://docs.aws.amazon.com/lambda/latest/dg/configuration-codesigning-create.html
- Lambda actions and condition keys: https://docs.aws.amazon.com/service-authorization/latest/reference/list_awslambda.html
- Lambda image pull permissions: https://repost.aws/knowledge-center/lambda-ecr-image
- Cross-account ECR for Lambda: https://aws.amazon.com/blogs/compute/introducing-cross-account-amazon-ecr-access-for-aws-lambda/
- Image optimization, `Pending` and `Inactive`: https://repost.aws/questions/QUUB4mNCLdTVGm_lUeGt8lsg/will-lambda-deployed-from-image-pull-the-ecr-image-on-every-startup
- Layers and extensions in images: https://aws.amazon.com/blogs/compute/working-with-lambda-layers-and-extensions-in-container-images
- Parameters and Secrets Lambda Extension: https://docs.aws.amazon.com/systems-manager/latest/userguide/ps-integration-lambda-extensions.html
- Lambda pricing: https://aws.amazon.com/lambda/pricing/
- API Gateway pricing: https://aws.amazon.com/api-gateway/pricing/
- ELB pricing: https://aws.amazon.com/elasticloadbalancing/pricing/
- CodeDeploy for Lambda (secondary): https://oneuptime.com/blog/post/2026-02-12-codedeploy-lambda-deployments/view
- Repo: ADR 0001, 0002, 0004, 0005, 0007, 0008, 0010, 0011; `infra/terraform/bootstrap/iam_deploy.tf`; `app/src/board.py`; `app/Dockerfile`

## Change log

| Date | Change |
|---|---|
| 2026-11-03 | Proposed |
