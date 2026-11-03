# modules/app-lambda

The application stack of one environment (ADR 0012): the board web app as a Lambda **web function** (the container
image with the Lambda Web Adapter, one function for every route), an alias `live`, an API Gateway HTTP API in front
of it, two log groups, three alarms, the secret shell and the execution role. It declares no provider and no
backend; `envs/<env>` supplies both.

The ECR repository, its policy and the execution role's permissions boundary are **not** here: bootstrap owns them
(ADR 0012 L4, L9), so the function can be created from an image that already exists and an env destroy never deletes
images.

## What it creates

| Area | Resources |
|---|---|
| Function (L1, L3) | `<prefix>-<env>-app`: package type `Image`, `x86_64`, `memory_mb` (512), `timeout_s` (10), `publish = true`, reserved concurrency only when `reserved_concurrency` is set. Env: `APP_ENV`, `AWS_LWA_PORT=8080`, `AWS_LWA_READINESS_CHECK_PATH=/health`, `APP_API_KEY_SECRET_ARN` (the ARN, never the value), `IMAGE_DIGEST` |
| Alias (L3, L7) | `live`, created on the version published at create; App Deploy moves it afterwards |
| HTTP API (L2) | `<prefix>-<env>-api`: `AWS_PROXY` integration on the **alias ARN**, payload 2.0, one `$default` route, `$default` stage with auto-deploy, stage throttling (`api_throttle_rate_limit` 5/s, `api_throttle_burst_limit` 10) and a JSON access log (request ID, route, status, integration status, latency, source IP; never headers) |
| Permission | `lambda:InvokeFunction` for `apigateway.amazonaws.com` on qualifier `live`, source ARN `<api execution ARN>/*/*` |
| Logs (L10) | `/aws/lambda/<prefix>-<env>-app` and `/aws/apigateway/<prefix>-<env>-api`, `log_retention_days` (7) |
| Alarms (L10) | `<prefix>-<env>-app-errors` and `-app-throttles` (Lambda, dimension `Resource = <function>:live`), `<prefix>-<env>-api-5xx` (HTTP API `5xx`, stage `$default`). 1-minute `Sum`, `notBreaching`; actions to `alarm_topic_arn` when set |
| Secret (FR-8) | `<prefix>/<env>/app-api-key`, a shell with **no value**. The module never creates a secret version |
| IAM (L9) | Execution role `<prefix>-<env>-app-exec`: trusts `lambda.amazonaws.com` for this account only (`aws:SourceAccount`), carries the bootstrap boundary `<prefix>-<env>-app-boundary`; inline policy `logs:CreateLogStream`/`logs:PutLogEvents` on the function log group and `secretsmanager:GetSecretValue` on the one secret ARN. Not `AWSLambdaBasicExecutionRole` |

## Usage

```hcl
module "app_lambda" {
  source = "../../modules/app-lambda"

  prefix          = "sls"
  env             = "dev"
  aws_region      = "ap-southeast-1"
  alarm_topic_arn = "<arn of the bootstrap <prefix>-<env>-security-alerts topic>"
}
```

## Constraints

- **Name contract.** Every name must equal the bootstrap `resource_names` output: the apply and deploy roles, the
  boundary and the ECR `LambdaPull` condition are scoped by them (ADR 0002). The boundary ARN and the repository URL
  are built from the caller account, partition and region, never typed in.
- **Image first (L3, Finding 6).** The function is created from the newest image in `<prefix>-<env>-app`
  (`data "aws_ecr_image"`, `most_recent = true`). While the repository is empty the plan fails with "no matching
  images": run App Deploy once (it pushes, then stops green with a notice because the function does not exist yet),
  then apply.
- **Who owns what (L3).** Terraform owns the function shape, the alias, the API, logs, alarms and the role. App
  Deploy owns the image and the serving version: Terraform ignores `image_uri` and
  `environment[0].variables["IMAGE_DIGEST"]` on the function, and `function_version` and `routing_config` on the
  alias. `tests/iam_documents.tftest.hcl` proves that a newer ECR image plans no change to either, while other
  settings still apply.
- **Versions.** `publish = true`, so a Terraform change to the function also publishes a version. That version gets
  no traffic: only App Deploy moves `live`.
- **Timeouts.** `timeout_s` is at most 30 (HTTP API integration limit); the integration waits 29 s.
- **Reserved concurrency.** `null` (default) leaves the function unreserved (`-1`). Lambda refuses a reservation
  that leaves the account fewer than 100 unreserved, so keep `null` in accounts with a low quota (Finding 10); stage
  throttling is the cost ceiling in any account.
- **Secret.** The app reads the value itself at first use (L5). Until someone runs `put-secret-value`, the app
  reports `secret_loaded: no` and `/admin` answers 401; the deploy preflight refuses a secret with no value.
- **Secret recovery window.** Defaults to 0 so a torn-down stack can be re-created in the same session.

Offline checks: `make tf-check` runs `terraform test` with a mocked provider, plus the `tf/policy.sh` rules.

<!-- BEGIN_TF_DOCS -->
<!-- END_TF_DOCS -->
