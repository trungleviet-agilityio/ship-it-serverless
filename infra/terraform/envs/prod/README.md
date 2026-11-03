# Environment root (`envs/<env>`)

The root of one environment (FR-6, ADR 0004 E16 to E18, ADR 0008 P1, ADR 0012): one call to
[`modules/app-lambda`](../../modules/app-lambda/), the S3 backend for `envs/<env>/terraform.tfstate`, and the
committed `terraform.tfvars`. Every environment has its own root, and the roots differ only in four files:
`terraform.tfvars`, the `key` line of `backend.tf`, `versions.tf` and `.terraform.lock.hcl` (the last two so a provider
bump can reach one environment first). `scripts/guard/env-parity.sh` fails a pull request on any other difference,
and names the file. This README is the same in every root (outside the generated tables), so the environment is named
only through `terraform.tfvars` (`env`). Add an environment with `make new-env ENV=<name>`
(see [`scripts/tf/new-env.sh`](../../../../scripts/tf/new-env.sh)).

## Run

CI plans on every pull request that touches `infra/**` (`reusable-terraform-plan.yml`, one caller job per
environment) and applies on `main` after approval of the GitHub environment named like the root
(`.github/workflows/terraform-iac.yml`; a push applies `dev` only). To run it by hand (checkpoint, with SSO
admin; the account ID comes from your shell, never from a file in git):

```bash
export AWS_PROFILE=<admin profile> TF_VAR_aws_account_id=<ACCOUNT_ID>
terraform init -backend-config="bucket=<prefix>-<env>-tfstate-<ACCOUNT_ID>-ap-southeast-1-an"
terraform plan -out=tfplan
```

Offline checks need no credentials: `make tf-check` (init with `-backend=false`, validate, `terraform test`).

## Constraints

- **Account ID.** `aws_account_id` has no default and no tfvars entry. It feeds `allowed_account_ids` and
  nothing else. Outputs never carry it, because apply logs are public: the root exports names and the API endpoint
  only (`function_name`, `alias_name`, `api_endpoint`, `ecr_repository_name`, `secret_name`).
- **Backend.** Partial: the bucket name holds the account ID, so it arrives through `-backend-config`.
  `use_lockfile = true`, key `envs/<env>/terraform.tfstate`. A test checks that `env` equals the directory name.
- **Tags.** `default_tags` (`Project`, `Env`, `ManagedBy`) are identical to bootstrap (NFR-8).
- **Env name.** 2 to 8 lowercase letters and digits, starting with a letter (ADR 0008, P4), so every AWS name
  built from it stays within its limit.
- **Image first.** The function is created from the newest image in the bootstrap ECR repository
  `<prefix>-<env>-app` (ADR 0012 L3, L4). Push one first: run App Deploy in dev (it stops green with a notice while
  the function does not exist), or App Promote in prod. Until then the plan fails with "no matching images".
- **Alarms.** The three alarms notify the bootstrap topic `<prefix>-<env>-security-alerts`. Its ARN is built from
  the name, not looked up: the `aws_sns_topic` data source reads the topic's tags, and guardrail G6 denies every
  `sns` action on that topic to the CI roles.
- **Cost ceiling.** `api_throttle_rate_limit` and `api_throttle_burst_limit` cap the HTTP API in any account.
  `reserved_concurrency` is optional and stays unset where the account concurrency quota is low (ADR 0012 L10).
- **First apply.** Run `put-secret-value` (the app reads the secret at first use and answers `/admin` with 401
  until it has a value), then deploy. The state of `bootstrap/` is not readable by the CI roles.
- **Teardown.** Run the `terraform-destroy` workflow (Run workflow, pick the env, confirm `destroy-<env>`, then
  approve the environment). It plans the destroy, refuses anything but deletes under `module.app_lambda`, and
  applies the saved plan (ADR 0006). The images stay in the bootstrap repository. An admin can still run
  `plan -destroy` by hand; a local `init` here does not disturb `make tf-check`.

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

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| app_lambda | ../../modules/app-lambda | n/a |

## Resources

| Name | Type |
| ---- | ---- |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| api_throttle_burst_limit | Burst limit of the HTTP API stage. | `number` | n/a | yes |
| api_throttle_rate_limit | Steady-state requests per second of the HTTP API stage (the cost ceiling, ADR 0012 L2). | `number` | n/a | yes |
| aws_account_id | Target AWS account ID. Never committed: CI passes TF_VAR_aws_account_id; locally use the shell or a gitignored *.auto.tfvars. | `string` | n/a | yes |
| aws_region | AWS region for every resource. | `string` | n/a | yes |
| env | Environment name. Must equal the directory name of this root (the parity guard checks it). | `string` | n/a | yes |
| log_retention_days | Retention of the function and API access log groups. | `number` | n/a | yes |
| memory_mb | Function memory in MB. | `number` | n/a | yes |
| prefix | Name prefix. Must equal the bootstrap prefix. | `string` | n/a | yes |
| timeout_s | Function timeout in seconds (at most 30, the HTTP API limit). | `number` | n/a | yes |
| reserved_concurrency | Reserved concurrency of the function; null means no reservation (ADR 0012 L10, Finding 10). | `number` | `null` | no |
| secret_recovery_window_days | Secrets Manager recovery window; 0 deletes at once (ADR 0004, Q3). | `number` | `0` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| alias_name | Alias the HTTP API invokes; App Deploy moves it. |
| api_endpoint | Public HTTPS endpoint of the HTTP API (no account ID in it). |
| ecr_repository_name | ECR repository App Deploy pushes to (owned by bootstrap, ADR 0012 L4). |
| function_name | Lambda function name. |
| secret_name | Secrets Manager secret name. Set its value by hand (put-secret-value). |
<!-- END_TF_DOCS -->
