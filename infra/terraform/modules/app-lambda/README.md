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
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11, < 2.0 |
| aws | ~> 6.70 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | 6.70.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_apigatewayv2_api.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/apigatewayv2_api) | resource |
| [aws_apigatewayv2_integration.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/apigatewayv2_integration) | resource |
| [aws_apigatewayv2_route.default](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/apigatewayv2_route) | resource |
| [aws_apigatewayv2_stage.default](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/apigatewayv2_stage) | resource |
| [aws_cloudwatch_log_group.api](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_group.lambda](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_metric_alarm.api_5xx](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.lambda_errors](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.lambda_throttles](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_iam_role.exec](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.exec](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_lambda_alias.live](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_alias) | resource |
| [aws_lambda_function.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_permission.api](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_secretsmanager_secret.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| aws_region | AWS region of the stack. Used for the ECR repository URL. | `string` | n/a | yes |
| env | Environment name. | `string` | n/a | yes |
| prefix | Name prefix for every resource. Must equal the bootstrap prefix (name contract, ADR 0002). | `string` | n/a | yes |
| alarm_topic_arn | SNS topic for the three alarms (the bootstrap <prefix>-<env>-security-alerts topic). Null: alarms without actions. | `string` | `null` | no |
| api_throttle_burst_limit | Burst of requests the HTTP API stage accepts above the rate (ADR 0012 L2). | `number` | `10` | no |
| api_throttle_rate_limit | Steady-state requests per second the HTTP API stage accepts (ADR 0012 L2, R1: the cost ceiling). | `number` | `5` | no |
| log_retention_days | Retention of the function and API access log groups. | `number` | `7` | no |
| memory_mb | Function memory in MB (ADR 0012 L1: 512). CPU scales with it; so does the GB-second price. | `number` | `512` | no |
| reserved_concurrency | Reserved concurrency of the function (ADR 0012 L10). Null: no reservation. Lambda refuses a reservation that leaves less than 100 unreserved, so accounts with a low quota must keep null (Finding 10). | `number` | `null` | no |
| secret_recovery_window_days | Secrets Manager recovery window. 0 deletes at once, so a torn-down stack can be re-created (ADR 0004, Q3). | `number` | `0` | no |
| timeout_s | Function timeout in seconds (ADR 0012 L1: 10). At most 30, the HTTP API integration limit. | `number` | `10` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| alias_name | Alias the HTTP API invokes; App Deploy moves it. |
| api_endpoint | Public HTTPS endpoint of the HTTP API ($default stage, so no stage path). |
| api_id | HTTP API ID. |
| api_log_group_name | HTTP API access log group. |
| ecr_repository_name | ECR repository name (owned by bootstrap, ADR 0012 L4). |
| ecr_repository_url | ECR repository URL of the bootstrap repository (holds the account ID, so the root does not re-export it). |
| exec_role_arn | Execution role ARN. |
| exec_role_name | Execution role name. |
| function_arn | Lambda function ARN (holds the account ID, so the root does not re-export it). |
| function_name | Lambda function name. |
| lambda_log_group_name | Function log group. |
| secret_arn | Secret ARN the app reads (APP_API_KEY_SECRET_ARN). |
| secret_name | Secrets Manager secret name. |
<!-- END_TF_DOCS -->
