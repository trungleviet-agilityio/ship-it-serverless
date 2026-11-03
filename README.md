# ship-it-serverless

> Vibe coding an app is easy; shipping it safely is hard.

A small web app shipped to **AWS Lambda as a web function**. The unchanged HTTP server runs inside a container
image behind the AWS Lambda Web Adapter, with an API Gateway HTTP API in front. It ships through GitHub
Actions and Terraform with OIDC instead of access keys, separate plan, apply and deploy roles, Secrets Manager per
environment, versions and an alias for releases, an alias-weighted canary, rollback in seconds, and promote by
digest from dev to prod.

Created from the [`ship-it-safely`](https://github.com/trungleviet-agilityio/ship-it-safely) template (ECS
Fargate). ADRs 0001 to 0011 are that lab's history; [ADR 0012](docs/adr/0012-lambda-web-function-architecture.md)
moves the runtime to Lambda.

- Requirements (goal, scope, `FR-*`, `NFR-*`): [`docs/requirements.md`](docs/requirements.md)
- Decisions: [`docs/adr/`](docs/adr/), start with [ADR 0012](docs/adr/0012-lambda-web-function-architecture.md)
- **Every trade-off, for study:** [`docs/tradeoffs.md`](docs/tradeoffs.md)
- Standards per domain: [`docs/reference/standards/`](docs/reference/standards/)

## Architecture

```
            ┌──────────── GitHub Actions ─────────────┐
            │ app-ci (PR, no AWS)                      │
            │ app-deploy (main → dev)   app-promote    │──OIDC──► STS (per account)
            │ terraform-iac / -destroy                 │          plan | apply | deploy roles
            └──────────────────────────────────────────┘

each account (dev, prod)
  bootstrap (admin, once):  S3 state · OIDC provider · roles · budget · ECR sls-<env>-app · trail + alert topic
  env stack (terraform-iac):
     client ─► HTTP API sls-<env>-api ($default stage: throttling 5 rps / burst 10, JSON access log)
                 └─► Lambda alias "live" ─► version N ─► image sls-<env>-app@sha256:<digest>
                                               └─► Lambda Web Adapter ─► app :8080 (ready when /health is 200)
                 execution role sls-<env>-app-exec ─► Secrets Manager sls/<env>/app-api-key (read at cold start)
                 logs 7 days · alarms (errors, throttles, 5xx) ─► SNS sls-<env>-security-alerts
```

| Piece | Where | Why (details in [`docs/tradeoffs.md`](docs/tradeoffs.md)) |
|---|---|---|
| Image + Lambda Web Adapter v1.1.0 (pinned by digest) | [`app/Dockerfile`](app/Dockerfile) | Same image locally, in CI and on Lambda; no handler rewrite |
| API Gateway HTTP API | [`modules/app-lambda/api.tf`](infra/terraform/modules/app-lambda/api.tf) | Throttling is a cost ceiling in any account; access logs |
| Alias `live`, published versions | [`modules/app-lambda/lambda.tf`](infra/terraform/modules/app-lambda/lambda.tf) | A version pins one digest; release and rollback are one alias move |
| ECR in bootstrap | [`bootstrap/ecr.tf`](infra/terraform/bootstrap/ecr.tf) | A function needs an existing private image; images outlive env teardown |
| Secret read with stdlib SigV4 | [`app/src/aws_sigv4.py`](app/src/aws_sigv4.py) | Keeps the app stdlib-only; the build stays credential-free |
| Deploy role without `iam:PassRole` | [`bootstrap/iam_deploy.tf`](infra/terraform/bootstrap/iam_deploy.tf) | A deploy can change code, never the execution role |

## Setup

Prerequisites (macOS): Docker, the GitHub CLI and [mise](https://mise.jdx.dev). Every other CLI is pinned in
[`mise.toml`](mise.toml). From the repo root:

```bash
mise install
```

```bash
make venv
```

```bash
pre-commit install
```

Day to day, run everything through `make` (`make help` lists the targets):

| Target | Does |
|---|---|
| `make up` / `make down` | Run or stop the app on http://localhost:8080 (the Web Adapter is inert outside Lambda) |
| `make test` | App unit tests, including SigV4 against AWS's published example |
| `make lint` | pre-commit (gitleaks, zizmor, ruff, mypy, terraform hooks, account-ID guard), hadolint, shellcheck, actionlint, guards and CI helper self-tests |
| `make tf-check` | Offline Terraform policy rules, README check, `fmt`, `validate`, `terraform test` with mock providers |
| `make verify` | Build the image the way CI does, smoke test it read-only as UID 10001, scan it with Trivy |
| `make check` | Everything a PR must pass |

There is no `apply` or `destroy` target (ADR 0001 D15).

## Pipelines (`.github/workflows/`)

| Workflow | Trigger | Does |
|---|---|---|
| **App CI** `app-ci.yml` | PR touching `app/**` | No AWS: hadolint, build (tests run inside), smoke, Trivy |
| **App Deploy** `app-deploy.yml` | push to `main` touching `app/**`; dispatch | `build-scan` (no AWS) then `deploy (dev)` with approval (no Docker, sudo or containers): preflight, crane push by SHA tag, update code by **digest**, set `IMAGE_DIGEST` and the description, publish a version, **smoke-invoke that version**, move `live` (all at once, or canary), prune old versions; then `verify (dev)` (no credentials) checks `/version` through the API. Dispatch inputs: `mode` (`deploy` or `rollback`), `strategy`, `canary_percent`, `bake_minutes`, `sha` (rollback, gated by a green-SHA check). Push deploys take the strategy from the environment variable `RELEASE_STRATEGY` |
| **App Promote** `app-promote.yml` | dispatch on `main` with a green `sha` | `resolve` (no AWS; the SHA must be on `main` with green `deploy (dev)` and `verify (dev)` jobs, so an image that never ran on Lambda cannot be promoted), then `promote` in `prod` with approval: crane copy by digest from dev ECR, then the same release steps. Rollback = promote an earlier green SHA; when prod already has a version with that digest, only the alias moves |
| **Terraform** `terraform-iac.yml` | PR touching `infra/**`; push to `main`; dispatch | Plan with the read-only role and a PR comment; apply with approval |
| **Terraform Destroy** `terraform-destroy.yml` | dispatch, typed confirmation | Delete-only plan, then apply that plan |
| **Repo Guard**, **OIDC Smoke Test** | every PR / trust changes | Workflow policy, secrets scan, parity guard, negative trust tests |

### How a release works

1. `UpdateFunctionCode --image-uri <repo>@sha256:<digest>`, then one configuration update sets `IMAGE_DIGEST` (so
   `/version` can prove the digest) and the description `sha=<sha> digest=<digest>`. Writing the description first
   matters: `PublishVersion` creates no version when nothing changed, and Terraform already published version 1 with
   the same digest.
2. `PublishVersion` with that description. A version is immutable: it pins that digest. A version whose image and
   `IMAGE_DIGEST` already match is reused.
3. The pipeline invokes **the new version directly** (not the alias) with an API Gateway event for `/health` and
   `/version`, retrying a cold-start failure a few times. A broken build stops here and never receives traffic: the
   Web Adapter only reports ready when `/health` answers 200.
4. `all-at-once`: `live` points at the new version. `canary`: `live` keeps the old version and sends
   `canary_percent` to the new one for `bake_minutes`. Probes invoke the alias directly (`/health`, `/version`, `/`),
   so the weights apply and each response names the version that served it; any non-2xx from the new version fails
   the canary. The new version's `Errors` metric is a second, crash-only signal (an app 500 is a successful invoke).
   Pass: 100 percent; fail: the weight is removed.
5. A separate job without AWS credentials reads `/version` through the API, which must show the SHA and digest. The
   credentialed jobs never allow an `*.execute-api` host in their egress list.

## Repo configuration the pipelines read

| Where | Name | Kind |
|---|---|---|
| Repo | `AWS_PLAN_ROLE_ARN_<ENV>`, `AWS_ACCOUNT_ID_<ENV>` | secrets for the PR plan (no environment) |
| Repo | `AWS_REGION` = `ap-southeast-1` | variable |
| Environment `<env>` | `AWS_ACCOUNT_ID`, `AWS_APPLY_ROLE_ARN`, `AWS_DEPLOY_ROLE_ARN` | secrets, same names in every environment |
| Environment `dev`, `prod` | required reviewer (you), deployment branches `main` only | protection rules |
| Repo | ruleset on `main`: PR required, no force push, status check `guard` required | ruleset |

## Checkpoint: the commands you run

Claude never runs `terraform apply`, `destroy`, `import`, `state`, or reads or writes secret values (NFR-9).
Run these from the repo root, in order. Replace `<...>` placeholders; never commit real values.

### 1. Bootstrap the dev account (admin, once)

Fill `infra/terraform/bootstrap/accounts/dev.tfvars` from `dev.tfvars.example` (gitignored). Then:

```bash
aws sso login --profile sls-dev-admin
```

```bash
AWS_PROFILE=sls-dev-admin aws sts get-caller-identity --query Account --output text
```

Expect: the dev account ID.

The first apply runs on local state: create `infra/terraform/bootstrap/backend_override.tf` containing
`terraform { backend "local" {} }`, then:

```bash
AWS_PROFILE=sls-dev-admin terraform -chdir=infra/terraform/bootstrap init
```

```bash
AWS_PROFILE=sls-dev-admin terraform -chdir=infra/terraform/bootstrap plan -var-file=accounts/dev.tfvars -out=bootstrap.tfplan
```

Expect: only creates; the ECR repository `sls-dev-app`, the roles `sls-dev-gha-plan`, `-apply`, `-deploy`, the
boundary `sls-dev-app-boundary`, the state bucket, the OIDC provider, the budget, the trail and the alert topic.

```bash
AWS_PROFILE=sls-dev-admin terraform -chdir=infra/terraform/bootstrap apply bootstrap.tfplan
```

Delete `backend_override.tf` and `bootstrap.tfplan`, then move the state into the bucket:

```bash
AWS_PROFILE=sls-dev-admin terraform -chdir=infra/terraform/bootstrap init -migrate-state -backend-config="bucket=sls-dev-tfstate-<DEV_ACCOUNT_ID>-ap-southeast-1-an"
```

Expect: a second `plan -var-file=accounts/dev.tfvars` shows no changes. Confirm the SNS subscription email.

### 2. GitHub settings

Create environment `dev` (you as reviewer, `main` only) in the web UI, then set each secret (each command
prompts for the value; the role ARNs are bootstrap outputs):

```bash
gh secret set AWS_ACCOUNT_ID --env dev
```

```bash
gh secret set AWS_APPLY_ROLE_ARN --env dev
```

```bash
gh secret set AWS_DEPLOY_ROLE_ARN --env dev
```

```bash
gh secret set AWS_PLAN_ROLE_ARN_DEV
```

```bash
gh secret set AWS_ACCOUNT_ID_DEV
```

```bash
gh variable set AWS_REGION --body ap-southeast-1
```

### 3. First image, then the env stack, then the secret

The function can only be created from an image that is already in ECR (ADR 0012 L3). In the web UI: Actions >
**App Deploy** > Run workflow (branch `main`, `mode` = `deploy`), approve `deploy (dev)`.

Expect: the run is green with the notice "function not created yet"; the image is in `sls-dev-app`.

Then Actions > **Terraform** > Run workflow (`env` = `dev`), approve the apply.

Expect: the plan creates only `module.app_lambda.*` resources (function, alias, API, integration, route, stage,
permission, two log groups, three alarms, secret shell, execution role and its policy).

Set the secret value, in one line, in your own terminal:

```bash
AWS_PROFILE=sls-dev-admin aws secretsmanager put-secret-value --region ap-southeast-1 --secret-id sls/dev/app-api-key --secret-string "$(openssl rand -hex 24)" --query Name --output text
```

Expect: `sls/dev/app-api-key`.

### 4. Deploy, then check

Actions > **App Deploy** > Run workflow (`mode` = `deploy`, `strategy` = `all-at-once`), approve.

```bash
AWS_PROFILE=sls-dev-admin aws apigatewayv2 get-apis --region ap-southeast-1 --query "Items[?Name=='sls-dev-api'].ApiEndpoint" --output text
```

Expect: `https://<api-id>.execute-api.ap-southeast-1.amazonaws.com`.

```bash
curl -s https://<api-id>.execute-api.ap-southeast-1.amazonaws.com/version
```

Expect: `{"env": "dev", "git_sha": "<sha>", "image_digest": "sha256:<64 hex>"}`, the same digest the run summary
shows and the one ECR holds for the tag `<sha>`.

```bash
AWS_PROFILE=sls-dev-admin aws lambda get-alias --region ap-southeast-1 --function-name sls-dev-app --name live --query FunctionVersion --output text
```

Expect: the version number the run published.

Cold start numbers for [`docs/tradeoffs.md`](docs/tradeoffs.md) section 14: open the latest `REPORT` line with
`Init Duration` in the log group `/aws/lambda/sls-dev-app` (CloudWatch console).

### 5. Canary

A push deploy releases the merged commit, so a canary must be chosen before the merge. Set the strategy for the
`dev` environment (these variables are read only when the dispatch input is empty):

```bash
gh variable set RELEASE_STRATEGY --env dev --body canary
```

Optional: `gh variable set CANARY_PERCENT --env dev --body 10` and `gh variable set BAKE_MINUTES --env dev --body 5`
(defaults 10 and 5). Then merge an app change through a PR and approve `deploy (dev)`. A dispatch on a commit that is
already live is a no-op (the summary says so).

```bash
AWS_PROFILE=sls-dev-admin aws lambda get-alias --region ap-southeast-1 --function-name sls-dev-app --name live --query RoutingConfig
```

Expect during the bake: `{"AdditionalVersionWeights": {"<new>": 0.1}}`; after a green run: `null`, and
`FunctionVersion` is the new version. The run log shows each probe with its executed version and HTTP status.
Switch back to all-at-once afterwards:

```bash
gh variable delete RELEASE_STRATEGY --env dev
```

### 6. Broken build never gets traffic

Two gates stop a broken build. A build whose `/health` fails everywhere (for example `BREAK=true` as the default)
already fails in `build-scan` (`scripts/image/smoke.sh`), before any AWS step. To see the **Lambda** gate, break
something only Lambda sees: on a branch, make `/health` in `app/src/board.py` return 500 when
`AWS_LAMBDA_FUNCTION_NAME` is set, merge it through a PR and approve the deploy.

Expect: `build-scan` passes (no Lambda variable there); `deploy (dev)` fails at "Smoke-invoke the version" (the Web
Adapter never reports ready, so the version's invoke fails); `get-alias` still shows the previous version and the API
still serves the previous `/version`. Revert the change with a PR.

### 7. Rollback in dev

Actions > **App Deploy** > Run workflow (`mode` = `rollback`, `sha` = an earlier SHA that was deployed to dev).
A credential-free gate first checks that this SHA had a green `deploy (dev)` and `verify (dev)` run on `main`.

Expect: the summary says the version was reused (no new version published), and `/version` shows the earlier SHA
and digest within seconds.

### 8. Prod: account, bootstrap, promote, rollback

Create the prod account in AWS Organizations and an SSO profile `sls-prod-admin`. Fill
`accounts/prod.tfvars` (with `promotion_source_account_id`), then repeat step 1 with `sls-prod-admin`,
`accounts/prod.tfvars` and the prod bucket name. Then uncomment `promotion_target_account_id` in
`accounts/dev.tfvars` and re-apply the dev bootstrap:

```bash
AWS_PROFILE=sls-dev-admin terraform -chdir=infra/terraform/bootstrap init -reconfigure -backend-config="bucket=sls-dev-tfstate-<DEV_ACCOUNT_ID>-ap-southeast-1-an"
```

```bash
AWS_PROFILE=sls-dev-admin terraform -chdir=infra/terraform/bootstrap plan -var-file=accounts/dev.tfvars -out=bootstrap.tfplan
```

Expect: 0 to add, 1 to change (`aws_ecr_repository_policy.app`, statement `PromotionPull` added), 0 to destroy.

```bash
AWS_PROFILE=sls-dev-admin terraform -chdir=infra/terraform/bootstrap apply bootstrap.tfplan
```

Create environment `prod` and its secrets as in step 2 (`--env prod`, `AWS_PLAN_ROLE_ARN_PROD`,
`AWS_ACCOUNT_ID_PROD`). Prod also needs a first image before its stack: run **App Promote** (`env` = `prod`,
`sha` = the SHA dev serves) and approve; expect a green run with the notice "function not created yet". Then
**Terraform** with `env` = `prod`, then the prod secret:

```bash
AWS_PROFILE=sls-prod-admin aws secretsmanager put-secret-value --region ap-southeast-1 --secret-id sls/prod/app-api-key --secret-string "$(openssl rand -hex 24)" --query Name --output text
```

Run **App Promote** again with the same SHA and approve. Expect: prod `/version` shows the **same digest** as dev.

Rollback: **App Promote** with an earlier green SHA. Expect: prod `/version` shows the earlier digest within
seconds; when prod already had a version for it, the summary says reused.

### 9. Negative check: the deploy role cannot pass a role

```bash
AWS_PROFILE=sls-dev-admin aws iam simulate-principal-policy --policy-source-arn arn:aws:iam::<DEV_ACCOUNT_ID>:role/sls-dev-gha-deploy --action-names iam:PassRole lambda:DeleteFunction --resource-arns arn:aws:iam::<DEV_ACCOUNT_ID>:role/sls-dev-app-exec --query "EvaluationResults[].[EvalActionName,EvalDecision]" --output text
```

Expect: `iam:PassRole explicitDeny` and `lambda:DeleteFunction implicitDeny` (the role ARN is not a qualified
function ARN).

### 10. Teardown

Prod after its checkpoint, dev when you are done with the lab (dev has no hourly cost and may stay up). Actions >
**Terraform Destroy**, `env` = `prod`, type **destroy-prod**, approve; then the same with **destroy-dev**.

```bash
AWS_PROFILE=sls-dev-admin aws lambda get-function --region ap-southeast-1 --function-name sls-dev-app --query Configuration.FunctionName --output text
```

Expect: `ResourceNotFoundException`.

```bash
AWS_PROFILE=sls-dev-admin aws apigatewayv2 get-apis --region ap-southeast-1 --query "Items[?Name=='sls-dev-api'].ApiId" --output text
```

Expect: empty.

```bash
AWS_PROFILE=sls-dev-admin aws secretsmanager list-secrets --region ap-southeast-1 --filters Key=name,Values=sls/dev/ --query "SecretList[].Name" --output text
```

Expect: empty.

The bootstrap (and its ECR images) stays until the end of the lab. Removing it follows the template's order:
migrate the bootstrap state back to local, empty the state bucket including all versions, then a saved
`plan -destroy` and its apply, as admin, per account (ECR goes with it: `force_delete`).

## Cost

Nothing in the env stack bills per hour. Lambda (512 MB, about 0.1 s per request) and HTTP API bill per request;
lab traffic stays inside the Lambda always-free tier (1 million requests and 400,000 GB-seconds a month) and costs
cents on the HTTP API. The secret is about 0.40 USD a month per account, ECR storage and logs a few cents. US
reference rates; check the ap-southeast-1 pages for
[Lambda](https://aws.amazon.com/lambda/pricing/), [API Gateway](https://aws.amazon.com/api-gateway/pricing/) and
[Secrets Manager](https://aws.amazon.com/secrets-manager/pricing/). The budget alert at 80 percent of 20 USD stays.

## Agent team (Claude Code plugin `sis-team`)

The plugin in [`plugins/sis-team/`](plugins/sis-team/) comes from the template and still describes the ECS lab in
places; updating it, `CLAUDE.md` and `.claude/skills/` is an open owner item (ADR 0012 Q-A).
