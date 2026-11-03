# ADR 0012: Lambda Web Function architecture

- Status: accepted by the agent (2026-11-03) under the owner's delegation ("pick the best option yourself, research
  first, note every trade-off"); open to the owner's review in the PR
- Date: 2026-11-03
- Supersedes for this repository: the ECS runtime of ADR 0004 and 0005, the ECS parts of ADR 0006 and 0008 (P11,
  P12, P14, P15, P19) and the ALB parts of ADR 0007 (S10, S35). Keeps ADR 0001, 0002 (trust), 0003, 0007 (supply
  chain), 0008 (accounts, env cloning, promote by digest), 0010 and 0011.
- Trade-offs for study, one place: [`docs/tradeoffs.md`](../tradeoffs.md)

## Context

`ship-it-serverless` is a new lab created from the `ship-it-safely` template. The template ships one small stdlib
Python app to ECS Fargate behind an ALB through GitHub Actions and Terraform: OIDC roles per account (plan, apply,
deploy), actions pinned by SHA, tools pinned by checksum, one image digest promoted from dev to prod, and rollback
by promoting an earlier green SHA (ADR 0010 T1).

The owner's goal for the new lab: "a best-practice, classic serverless architecture. Before, I used Lambda
event-style functions. Now I want to learn Lambda Web Function." So the web app itself runs on Lambda (a
"Lambdalith": one function serves every route), with the same delivery discipline. This repository is a new lab,
not `ship-it-safely`, so ECS is removed rather than kept beside Lambda.

Inherited rules that constrain the design:

| Source | Rule |
|---|---|
| ADR 0001 D2, D3 | No account IDs in git; region `ap-southeast-1`; budget 20 USD/month |
| ADR 0001 D4 | App in Python 3.13, standard library only |
| ADR 0011 | Every AWS name is `<prefix>-<env>-<thing>`; `project.env` holds the prefix |
| App contract (ADR 0011) | One port, a health path, `/version` with the commit SHA and the image digest, no writes to disk, secrets from the environment |
| ADR 0002, 0004 E1/E2, 0007 S2 | Trust pins `aud`, immutable `sub`, `repository_id`, `repository_owner_id`, `ref`, `aws:RequestedRegion`, `job_workflow_ref` (`app-deploy.yml` in dev, `app-promote.yml` in prod) |
| FR-3 to FR-5 | Plan read-only; apply limited to the module's services with exact `iam:PassRole`; deploy limited to one repository and one runtime target; no CI role reads a secret value |
| FR-8 | Terraform creates only the secret shell; the value never reaches state or git |
| ADR 0005 F2 | Terraform owns the runtime shape; the deploy swaps only the image, by digest |
| ADR 0007 | Actions by SHA, tools by version and checksum, harden-runner `block` on credentialed jobs, base images by digest |
| ADR 0008 P9, P10 | Promote = copy by digest from dev ECR to prod ECR, then deploy; trigger is a dispatch with a green SHA |
| NFR-9 | Claude never applies, destroys or touches secret values |

### How the facts were checked

The authoring session could not open `docs.aws.amazon.com` or `aws.amazon.com` (blocked by its network policy).
Facts come from search results that quote those official pages, from AWS blogs and re:Post, from the Lambda Web
Adapter repository, and from registries read directly (ECR Public, PyPI, the Go module proxy, HashiCorp releases).
Each finding is marked **(V)** official text seen or source read directly, **(S)** secondary source only, re-check
on the live page, or **(C)** to confirm on live AWS at a checkpoint.

### Findings

1. **Lambda Web Adapter (LWA)** (V). Releases: `v1.1.0` is the latest semver tag on
   `public.ecr.aws/awsguru/aws-lambda-adapter` (read from the registry on 2026-11-03), index digest
   `sha256:17cfd08eff1dfea3f6a9a1e9c65fdac80aa4919b6085e746615530f43f57d2f1` (amd64
   `sha256:9d6b29a4...`, arm64 `sha256:98d6d1dc...`). Added with one line:
   `COPY --from=<image> /lambda-adapter /opt/extensions/lambda-adapter`. It forwards Function URL, API Gateway
   REST and HTTP, and ALB events to `AWS_LWA_PORT` (default `8080`). A readiness check polls
   `AWS_LWA_READINESS_CHECK_PATH` (default `/`) until the status is in `AWS_LWA_READINESS_CHECK_HEALTHY_STATUS`
   (default `100-499`). v1.0.0 removed `..._MIN_UNHEALTHY_STATUS` and deprecated unprefixed variables. The same image
   still runs on Docker, Fargate or a laptop: the extension only starts inside Lambda.
2. **Image cold start** (V): Lambda optimizes an image after each upload and caches it near the execution
   environment, "so cold start times are the same as for .zip archives". The function is `Pending` for a few seconds
   after each code update.
3. **Idle image functions go `Inactive`** (V): after weeks without an invoke Lambda reclaims the optimized image; the
   first invoke is rejected and the function is `Pending` until re-optimized.
4. **No code signing for images** (V): AWS Signer code signing for Lambda is zip only.
5. **ECR access** (S): the repository policy must allow `lambda.amazonaws.com` `ecr:BatchGetImage` and
   `ecr:GetDownloadUrlForLayer`; Lambda adds that statement itself only when the caller holds
   `ecr:GetRepositoryPolicy` and `ecr:SetRepositoryPolicy`. AWS examples scope it with `aws:sourceArn` = the
   function ARN (confused deputy protection); cross-account use names the other account's function ARN.
6. **Image location** (S): an image function takes a private ECR repository in the same region; a public image
   cannot be used, so a function cannot be created before its repository holds an image.
7. **Deleting an image that a version uses**: behavior not found in any source (C).
8. **Function URL auth** (V, with a conflict): for `NONE`, the EU mirror says URLs created from October 2025 need a
   resource policy allowing both `lambda:InvokeFunctionUrl` and `lambda:InvokeFunction` (the latter limited by
   `lambda:InvokedViaFunctionUrl`); the English page in the results showed the older text. Console and SAM add the
   policy; the API, CLI and Terraform do not.
9. **IAM** (V): `iam:PassRole` (with `iam:PassedToService = lambda.amazonaws.com`) belongs to `CreateFunction` and to
   `UpdateFunctionConfiguration` with a `Role`; `UpdateFunctionCode` lists none. A deploy role without `PassRole` can
   update code and env values but never attach another execution role (C: negative test).
10. **Reserved concurrency** (V): you can reserve up to the unreserved account concurrency minus 100. Some new
    accounts report a quota of 10 (not confirmed), where no reservation is possible (C).
11. **CodeDeploy for Lambda** (S): shifts an alias between two versions (`Canary*`, `Linear*`, `AllAtOnce`), watches
    CloudWatch alarms and reverts on alarm; `BeforeAllowTraffic` and `AfterAllowTraffic` hooks are extra functions
    that must call `codedeploy:PutLifecycleEventHookExecutionStatus`.
12. **Front door limits** (S): HTTP API integration timeout about 30 s, stage and route throttling, access logs, no
    AWS WAF (REST API only). Function URL: bound only by the function timeout, no throttling or access log. 6 MB
    Lambda payload for both.
13. **Prices** (S, US reference rates; ap-southeast-1 to confirm, C): Lambda 0.20 USD per million requests and
    0.0000166667 USD per GB-second (x86), always-free 1 million requests and 400,000 GB-seconds per month. HTTP API
    about 1.00 USD per million requests (free tier for new customers, 12 months). ALB hourly (partial hours billed
    as full) plus LCU. Function URLs cost nothing beyond Lambda.
14. **Parameters and Secrets Lambda Extension** (V for the pattern, S for details): image functions cannot attach
    layers, so an extension is copied into `/opt/extensions` at build time. This extension listens on
    `localhost:2773` and needs `X-Aws-Parameters-Secrets-Token`. It is distributed as a Lambda **layer** only; no
    public image was found. Getting it into the image needs `lambda:GetLayerVersion` with AWS credentials.
15. **Image manifest** (V, repo): `scripts/image/build.sh` already builds `--platform linux/amd64 --provenance=false
    --sbom=false --load` with the default driver, and `scripts/image/ecr-push.sh` refuses anything but a single
    image manifest. So no OCI index with attestations reaches ECR; Lambda and `/version` see one digest.
16. **Toolchain** (V): terraform 1.17.0 from releases.hashicorp.com matches `scripts/ci/tools.sha256`; the AWS
    provider 6.70.0 zip matches the `zh:` hash in the lock files.

## Decisions

Each decision lists the options compared; [`docs/tradeoffs.md`](../tradeoffs.md) has the long form with pros and
cons per option.

### L1. Runtime packaging

| Option | Pros | Cons |
|---|---|---|
| **(a) Existing image + LWA, image in ECR, deployed by digest** | One artifact for compose, CI and Lambda; app keeps its HTTP server; image supply chain (base digest, Trivy gate, Dependabot `docker`) unchanged; promote by digest unchanged | No Lambda code signing for images; LWA is one more binary to pin; readiness wait adds to the cold start |
| (b) Native handler as zip | Smallest cold start; SnapStart and code signing available | App rewrite to `handler(event, context)`; local run differs from Lambda; new S3 artifact pipeline and cross-account bucket; image gate lost |
| (c) AWS base image + runtime interface client | AWS-patched base | Still a handler rewrite; base image is larger; same code-signing gap as (a) |

**Choice: (a).** The lesson is "web function": an ordinary web app becomes a Lambda without code changes to its
routing. LWA is pinned as `public.ecr.aws/awsguru/aws-lambda-adapter:1.1.0@sha256:17cfd08e...f2d1` (Finding 1).
Package type `Image`, 512 MB, timeout 10 s.

### L2. Front door

| Option | Pros | Cons |
|---|---|---|
| **API Gateway HTTP API** | Stage throttling is a hard cost ceiling that does not depend on the account's concurrency quota; JSON access logs; the classic serverless front door; custom domain later; Lambda permission is a plain `InvokeFunction` with `SourceArn` | About 1 USD per million requests after the free tier; 30 s timeout; no WAF; four more resources |
| Lambda Function URL | Zero cost and fewest resources | No throttling and no access log, so a public URL has no cost ceiling when reserved concurrency is unavailable (Finding 10); the October 2025 auth-policy change is not settled in the docs (Finding 8) |
| ALB + Lambda target | WAF, SG CIDR allowlist | Hourly charge (the reason the template destroyed envs after each session); VPC and subnets back |

**Choice: HTTP API**, `$default` stage with auto-deploy, one `$default` route, `AWS_PROXY` integration on the
**alias `live` ARN**, payload format 2.0, stage throttling `rate_limit = 5`, `burst_limit = 10` (lab values,
tfvars). The Function URL stays documented as the cheaper alternative.

### L3. Function shape and ownership

Terraform owns: function `<prefix>-<env>-app` (package `Image`, `x86_64`, memory, timeout, execution role, env
`APP_ENV`, `AWS_LWA_PORT=8080`, `AWS_LWA_READINESS_CHECK_PATH=/health`, `APP_API_KEY_SECRET_ARN`, `IMAGE_DIGEST`
initial value), alias `live`, the HTTP API, logs, alarms and the execution role. The deploy owns which image and
which version serve. Terraform therefore ignores `image_uri` and `environment[0].variables["IMAGE_DIGEST"]` on the
function, and `function_version` and `routing_config` on the alias. The first image comes from `data
"aws_ecr_image"` (`most_recent = true`), so `App Deploy` must push once before the first `terraform apply` (the
deploy stops green with a notice when the function does not exist yet).

### L4. ECR repository placement (owner Q2)

| Option | Pros | Cons |
|---|---|---|
| **Bootstrap (one repository per account, admin-applied)** | The function can be created from an image that already exists (Finding 6); env destroy never deletes images that versions use; promotion and rollback work with the dev stack down (closes ADR 0008 R22) | Bootstrap grows; the repository policy changes need an admin re-apply |
| Env stack (template layout) | No bootstrap change | Chicken and egg at create (a public placeholder image is not allowed); destroy deletes images |
| Separate shared Terraform root | Clean ownership | A third state and a third apply path for one resource |

**Choice: bootstrap.** Repository `<prefix>-<env>-app`: IMMUTABLE tags, scan on push, `force_delete` (bootstrap
destroy only), lifecycle keeps the last 20 images. Repository policy: `LambdaPull` (`lambda.amazonaws.com`, pull
actions, `aws:sourceArn` like `arn:aws:lambda:<region>:<account>:function:<prefix>-<env>-app*`) and, in dev when
`promotion_target_account_id` is set, `PromotionPull` for the prod deploy role only (ADR 0008 P9, moved here from
the module). Lambda never edits the policy: no role holds `ecr:SetRepositoryPolicy` except the admin bootstrap.

### L5. Secret delivery (owner Q1)

| Option | Pros | Cons |
|---|---|---|
| (a) Parameters and Secrets extension copied into the image | No app code; cache built in | Layer only (Finding 14): the build job would need AWS credentials, breaking the credential-free build of ADR 0005; no public digest to pin; a second binary in the image |
| **(b) The app reads the secret itself with stdlib SigV4** | Stdlib only (D4); no extra binary; one HTTPS call per cold start; testable offline with AWS's published SigV4 example | About 80 lines of signing code to own and test |
| (b') The app uses boto3 | Battle-tested client | Breaks D4 (third-party dependency, 15+ MB) |
| (c) Deploy or Terraform injects the value into an env var | Simplest app | The value lands in state or in `GetFunctionConfiguration`; the deploy role would need `GetSecretValue`; violates FR-8 |

**Choice: (b).** At first use the app calls `secretsmanager.GetSecretValue` for `APP_API_KEY_SECRET_ARN` with the
execution role credentials Lambda puts in the environment, caches the value in memory for the life of the execution
environment, and never logs it. `APP_API_KEY` from `.env` still wins locally. A failed read means
`secret_loaded: no` and `/admin` answers 401.

### L6. `/version` digest

Lambda does not expose the image digest to the function. The deploy sets `IMAGE_DIGEST` with
`UpdateFunctionConfiguration` **before** `PublishVersion`, so every version carries its own digest and an alias flip
shows the right one. The pipeline proves equality four ways: ECR `imageDigest`, the version's resolved image URI,
the version's `IMAGE_DIGEST`, and `/version` through the API.

### L7. Release strategy and canary

| Option | Pros | Cons |
|---|---|---|
| **Pipeline-driven alias update, pre-traffic smoke invoke, optional alias-weighted canary** | No extra AWS service; bad versions never get traffic (smoke invoke on the version); canary is native alias routing; rollback is one `UpdateAlias` | The pipeline holds the logic (scripts with self-tests); canary judgment over lab traffic is synthetic |
| CodeDeploy traffic shifting | Managed canary, alarm-based auto revert, hooks | CodeDeploy app, deployment group, service role, `PassRole` to CodeDeploy, hook functions; meaningless canary at near-zero traffic |
| All at once only | Simplest | Nothing to learn about canaries |

**Choice: pipeline-driven.** Every deploy: preflight, push once, `UpdateFunctionCode` by digest, set
`IMAGE_DIGEST`, `PublishVersion` (description `sha=<40 hex> digest=sha256:<64 hex>`), smoke-invoke **that version**
with an HTTP API v2 event for `/health` and `/version`, then either:

- `all-at-once` (default): `UpdateAlias live` to the new version;
- `canary` (dispatch input): `UpdateAlias live` with `routing_config` weight `canary_percent` (default 10) on the new
  version, a bake of `bake_minutes` (default 5) that sends synthetic `/health` requests through the API and then
  reads the `Errors` metric with dimension `ExecutedVersion` for the new version. Zero errors and zero failed
  probes: promote to 100 percent. Otherwise: remove the weight (old version keeps 100 percent) and fail the run.

The run ends by reading `/version` through the API.

### L8. Promote and rollback

Promote keeps ADR 0008 P9 and P10: `app-promote.yml` dispatch with a green SHA, credential-free `resolve`, then
`promote` copies by digest with crane into the prod repository and runs L7 (strategy input as in dev).

**Rollback** is one path in both workflows: if the function already has a published version whose description
names the requested digest, the run skips push and publish, smoke-invokes that version and moves `live` (seconds).
Prod rolls back by promoting an earlier green SHA (FR-16); dev also gets `app-deploy.yml` dispatch `mode: rollback`
with a `sha` input that must have a version in dev. `git revert` stays the normal dev path. Deploy prunes published
versions beyond the newest 10 that `live` does not reference; ECR keeps 20 images, so no kept version points at a
deleted image (Finding 7).

### L9. IAM

**Deploy role** (FR-5 rewritten, trust unchanged because the workflow file names are unchanged):

- ECR: `GetAuthorizationToken` (`*`); push and read on the one repository; prod also pulls from the dev repository
  (P9, unchanged).
- Lambda on `function:<prefix>-<env>-app` and `function:<prefix>-<env>-app:*`: `GetFunction`,
  `GetFunctionConfiguration`, `UpdateFunctionCode`, `UpdateFunctionConfiguration`, `PublishVersion`,
  `ListVersionsByFunction`, `GetAlias`, `UpdateAlias`, `InvokeFunction`.
- `lambda:DeleteFunction` on `function:<prefix>-<env>-app:*` only (qualified ARNs, so it can prune versions but never
  delete the function).
- `cloudwatch:GetMetricStatistics` (`*`, no resource-level support) for the canary judgment.
- `secretsmanager:DescribeSecret` on the one secret (metadata only, ADR 0006 G14).
- **No `iam:PassRole`**, and an explicit `Deny iam:PassRole` statement, so the execution role can never change
  (Finding 9).

**Apply role** (FR-4 rewritten): state as today; Lambda function, alias, permission, concurrency and tags on
`function:<prefix>-<env>-*`; API Gateway on `/apis` and `/apis/*` and `/tags/*` of this region; logs on
`/aws/lambda/<prefix>-<env>-*` and `/aws/apigateway/<prefix>-<env>-*` plus the log-delivery actions HTTP API access
logging needs; CloudWatch alarms `<prefix>-<env>-*`; ECR read (`DescribeImages`, `DescribeRepositories`) on the one
repository for the data source; the secret shell; IAM role CRUD on `<prefix>-<env>-app-*` with the bootstrap
boundary required; `iam:PassRole` **only** on `<prefix>-<env>-app-exec` with `iam:PassedToService =
lambda.amazonaws.com`. EC2, ELB, ECS and ECR-write statements are deleted. Plan role unchanged.

**Execution role** `<prefix>-<env>-app-exec` (Terraform, under the renamed boundary `<prefix>-<env>-app-boundary`):
`logs:CreateLogStream` and `logs:PutLogEvents` on the function's log group; `secretsmanager:GetSecretValue` on the one
secret. Not `AWSLambdaBasicExecutionRole` (it allows `logs:CreateLogGroup` on `*`).

### L10. Cost ceiling and observability

| Option | Pros | Cons |
|---|---|---|
| **HTTP API throttling + optional reserved concurrency + alarms to SNS** | Throttling works in any account; reserved concurrency adds a second cap where the quota allows; alarms reach the email already confirmed for security alerts | Throttled clients get 429 |
| Reserved concurrency only | One setting | Unavailable when the account quota is low (Finding 10) |
| X-Ray tracing | Request traces | Cost and noise for one route; LWA adds no spans on its own |

**Choice: first row.** Logs: `/aws/lambda/<prefix>-<env>-app` and `/aws/apigateway/<prefix>-<env>-api`, 7 days,
created by Terraform. Alarms (1-minute periods, `treat_missing_data = notBreaching`): Lambda `Errors` on the alias,
Lambda `Throttles`, HTTP API `5xx`. Actions go to the bootstrap SNS topic `<prefix>-<env>-security-alerts` when the
env passes it. `reserved_concurrency` defaults to `null` (off); set it in tfvars where the quota allows.

### L11. ECS in this repository

| Option | Pros | Cons |
|---|---|---|
| **Remove ECS** | One runtime to learn, fewer IAM statements, no VPC | The ECS lessons live only in `ship-it-safely` (history stays in ADR 0004 to 0008) |
| Keep both runtimes behind a switch | Side-by-side comparison | Double IAM, double tests, two deploy paths |

**Choice: remove.** `modules/app-ecs`, `scripts/ecs/`, `scripts/tf/mask-cidrs.sh`, the ALB CIDR secrets and the VPC
CIDR rules are deleted.

### L12. Architecture, environments, prefix

| Question | Options | Choice and why |
|---|---|---|
| CPU (owner Q4) | `x86_64`; `arm64` (about 20 percent cheaper per GB-second, needs an arm runner or QEMU) | **`x86_64`**: the runner builds natively, no emulation, the bill is inside the free tier either way |
| Environments (owner Q5) | dev only; dev and prod with promote by digest | **dev and prod**: promote and rollback by digest across accounts is the core lesson, and it costs nothing idle now |
| Prefix | keep `sis`; new prefix | **`sls`** (`make set-prefix PREFIX=sls`): a new lab gets new names so the two labs never collide in one account |
| Teardown | destroy after each session; keep up | **Keep dev up** (no hourly charges; one secret about 0.40 USD/month); destroy prod after its checkpoint (ADR 0010 T7) |

## Kept, replaced and deleted

| Piece | Fate |
|---|---|
| `app/src/board.py`, tests | Changed: `IMAGE_DIGEST`, SigV4 secret read, ECS metadata removed |
| `app/Dockerfile` | Changed: LWA by digest, `AWS_LWA_*`; base, test stage, UID 10001, `HEALTHCHECK` kept |
| `bootstrap` state, OIDC, budget, monitoring, plan role, guardrails, trust tests | Kept |
| `bootstrap` apply and deploy roles, boundary | Rewritten (L9) |
| `bootstrap` ECR | New (L4) |
| `modules/app-ecs` | Deleted |
| `modules/app-lambda` | New: function, alias, HTTP API, logs, alarms, secret shell, execution role, tests |
| `envs/dev`, `envs/prod` | Call `app-lambda`; tfvars lose VPC, ALB and ECS sizing values |
| `terraform-iac.yml`, `reusable-terraform-plan.yml`, `terraform-destroy.yml` | Kept; ALB and promotion-target secrets removed; endpoints updated |
| `app-ci.yml`, `oidc-smoke-test.yml`, `repo-guard.yml` | Kept |
| `app-deploy.yml`, `app-promote.yml` | Same file names (trust unchanged); deploy steps replaced by L7 and L8 |
| `scripts/image/*` | Kept |
| `scripts/ecs/*` | Replaced by `scripts/lambda/*` |
| `scripts/tf/mask-cidrs.sh` | Deleted |
| `scripts/tf/new-env.sh`, `scripts/guard/env_parity.py`, `scripts/tf/policy.sh`, self-tests | Changed (no CIDRs, no ECS) |
| ECS diagrams in `docs/diagrams/` | Deleted; the README carries a text diagram |
| `CLAUDE.md`, `.claude/skills/*`, `plugins/sis-team` | Not changed by the agent (a peer cannot authorize edits to agent configuration); the owner updates them (Q-A below) |

## Consequences

- One image runs locally, in CI and on Lambda.
- An idle env costs roughly one secret and a few cents of ECR storage; lab traffic sits in the always-free tier
  (rates to confirm in ap-southeast-1).
- Bootstrap grows (ECR) and is re-applied by an admin in every account.
- The OIDC trust, role names, workflow file names and GitHub environments do not change.
- Lost compared with the template: ALB ingress CIDR allowlist, ECS circuit breaker (replaced by the smoke invoke),
  Lambda code signing (not available for images).

### Risks

| # | Risk | Mitigation |
|---|---|---|
| R1 | Public API means cost scales with abuse | Stage throttling, optional reserved concurrency, alarms, budget alert, 10 s timeout |
| R2 | Unknown behavior when a version's image is deleted | ECR keeps 20, deploy keeps 10 versions; checkpoint records the real behavior |
| R3 | `Inactive` after weeks idle | Smoke invoke on every deploy; README note |
| R4 | Deploy role can change env values, memory and timeout | No `PassRole`; the publish script changes only `IMAGE_DIGEST`; the next PR plan shows drift |
| R5 | (S) and (C) facts may differ on live pages | Checkpoint steps; allow `docs.aws.amazon.com` in the environment and re-check |
| R6 | Hand-written SigV4 | AWS published example as a unit test; a live read is part of the first checkpoint |

## Questions left for the owner

| # | Question | Agent's default |
|---|---|---|
| Q-A | Update `CLAUDE.md`, `.claude/skills/*` and the `sis-team` plugin text from ECS to Lambda | Left as is; a peer session cannot authorize agent-config edits |
| Q-B | Allow `docs.aws.amazon.com` and `aws.amazon.com` in the cloud environment's network settings | Recommended, so (S) facts can be re-checked |
| Q-C | Switch to arm64 later | Not now |

## Sources

- Lambda Web Adapter: https://github.com/awslabs/aws-lambda-web-adapter and https://github.com/awslabs/aws-lambda-web-adapter/releases; registry `public.ecr.aws/awsguru/aws-lambda-adapter` (tags and digests read on 2026-11-03)
- Function URL access control: https://docs.aws.amazon.com/lambda/latest/dg/urls-auth.html (EU mirror: https://docs.aws.eu/lambda/latest/dg/urls-auth.html)
- Reserved concurrency: https://docs.aws.amazon.com/lambda/latest/dg/configuration-concurrency.html
- Code signing: https://docs.aws.amazon.com/lambda/latest/dg/configuration-codesigning-create.html
- Lambda actions and condition keys: https://docs.aws.amazon.com/service-authorization/latest/reference/list_awslambda.html
- Lambda and ECR permissions: https://repost.aws/knowledge-center/lambda-ecr-image
- Cross-account ECR for Lambda: https://aws.amazon.com/blogs/compute/introducing-cross-account-amazon-ecr-access-for-aws-lambda/
- Image optimization and `Inactive`: https://repost.aws/questions/QUUB4mNCLdTVGm_lUeGt8lsg/will-lambda-deployed-from-image-pull-the-ecr-image-on-every-startup
- Extensions in images: https://aws.amazon.com/blogs/compute/working-with-lambda-layers-and-extensions-in-container-images
- Parameters and Secrets extension: https://docs.aws.amazon.com/systems-manager/latest/userguide/ps-integration-lambda-extensions.html
- Pricing: https://aws.amazon.com/lambda/pricing/, https://aws.amazon.com/api-gateway/pricing/, https://aws.amazon.com/elasticloadbalancing/pricing/
- CodeDeploy for Lambda (secondary): https://oneuptime.com/blog/post/2026-02-12-codedeploy-lambda-deployments/view
- SigV4 signing process: https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv-create-signed-request.html
- Secrets Manager `GetSecretValue`: https://docs.aws.amazon.com/secretsmanager/latest/apireference/API_GetSecretValue.html
- Repo: ADR 0001 to 0011; `infra/terraform/bootstrap/*.tf`; `app/`; `scripts/image/build.sh`, `scripts/image/ecr-push.sh`

## Change log

| Date | Change |
|---|---|
| 2026-11-03 | Proposed (design only) |
| 2026-11-03 | Scope change from the owner (relayed by a peer session): the agent decides, builds the lab offline and documents every trade-off. Front door changed from Function URL to HTTP API (L2), canary added (L7), ECS removed (L11), prefix `sls` (L12). Status accepted by the agent |
