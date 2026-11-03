# Environment root (`envs/<env>`)

The root of one environment (FR-6, ADR 0004 E16 to E18, ADR 0008 P1): one call to
[`modules/app-ecs`](../../modules/app-ecs/), the S3 backend for `envs/<env>/terraform.tfstate`, and the committed
`terraform.tfvars`. Every environment has its own root, and the roots differ only in four files: `terraform.tfvars`,
the `key` line of `backend.tf`, `versions.tf` and `.terraform.lock.hcl` (the last two so a provider bump can reach
one environment first). `scripts/guard/env-parity.sh` fails a pull request on any other difference, and names the
file. This README is the same in every root (outside the generated tables), so the environment is named only through
`terraform.tfvars` (`env`). Add an environment with `make new-env ENV=<name>`
(see [`scripts/tf/new-env.sh`](../../../../scripts/tf/new-env.sh)).

## Run

CI plans on every pull request that touches `infra/**` (`reusable-terraform-plan.yml`, one caller job per
environment) and applies on `main` after approval of the GitHub environment named like the root
(`.github/workflows/terraform-iac.yml`; a push applies `dev` only). To run it by hand (checkpoint, with SSO
admin; the account ID comes from your shell, never from a file in git):

```bash
export AWS_PROFILE=<admin profile> TF_VAR_aws_account_id=<ACCOUNT_ID>
terraform init -backend-config="bucket=sis-<env>-tfstate-<ACCOUNT_ID>-ap-southeast-1-an"
terraform plan -out=tfplan
```

Offline checks need no credentials: `make tf-check` (init with `-backend=false`, validate, `terraform test`).

## Constraints

- **Account ID.** `aws_account_id` has no default and no tfvars entry. It feeds `allowed_account_ids` and
  nothing else. Outputs never carry it, because apply logs are public.
- **Backend.** Partial: the bucket name holds the account ID, so it arrives through `-backend-config`.
  `use_lockfile = true`, key `envs/<env>/terraform.tfstate`. A test checks that `env` equals the directory name.
- **Tags.** `default_tags` (`Project`, `Env`, `ManagedBy`) are identical to bootstrap; the apply role's EC2
  conditions depend on them, and standalone security group rules need them to be changeable.
- **Env name.** 2 to 8 lowercase letters and digits, starting with a letter (ADR 0008, P4), so every AWS name
  built from it stays within its limit.
- **ALB ingress.** The environment secret `ALB_INGRESS_CIDRS` is required for apply, which refuses an empty value:
  a JSON list such as `["<your IP>/32"]`, or `["0.0.0.0/0"]` to be open on purpose. The PR plan reads the
  repository secret `ALB_INGRESS_CIDRS_<ENV>` and the teardown reads the environment one; for those two, unset
  means `0.0.0.0/0`. CI passes it as `TF_VAR_alb_ingress_cidrs_json` and masks each element in the log
  (`scripts/tf/mask-cidrs.sh`). Only IPv4 CIDRs are accepted. A wrong value locks you out of the ALB, never out of
  CI (ADR 0007 S10).
- **Placeholder image.** `container_image` in `terraform.tfvars` is a digest-pinned image with no command, so
  it never serves. The first deployment after a create stalls by design (ADR 0005, F2) until app-deploy sets
  the real image.
- **First apply.** Run `put-secret-value`, then run the `app-deploy` workflow (no forced deployment). The state of `bootstrap/` is not readable by the CI roles.
- **Teardown.** Run the `terraform-destroy` workflow (Run workflow, pick the env, confirm `destroy-<env>`, then
  approve the environment). It plans the destroy, refuses anything but deletes under `module.app_ecs`, applies the
  saved plan and deregisters the task definition revisions (ADR 0006). An admin can still run `plan -destroy` by
  hand; a local `init` here does not disturb `make tf-check`.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11, < 2.0 |
| aws | ~> 6.70 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| app_ecs | ../../modules/app-ecs | n/a |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| aws_account_id | Target AWS account ID. Never committed: CI passes TF_VAR_aws_account_id; locally use the shell or a gitignored *.auto.tfvars. | `string` | n/a | yes |
| aws_region | AWS region for every resource. | `string` | n/a | yes |
| azs | Two availability zones for the public subnets. | `list(string)` | n/a | yes |
| container_image | Container image pinned by digest. A public placeholder that never serves: app-deploy sets the real image by digest. | `string` | n/a | yes |
| desired_count | Number of Fargate tasks. | `number` | n/a | yes |
| env | Environment name. Must equal the directory name of this root (the parity guard checks it). | `string` | n/a | yes |
| log_retention_days | Retention of the application log group. | `number` | n/a | yes |
| prefix | Name prefix. Must equal the bootstrap prefix. | `string` | n/a | yes |
| task_cpu | Task-level CPU units. | `number` | n/a | yes |
| task_memory | Task-level memory in MiB. | `number` | n/a | yes |
| vpc_cidr | CIDR block of the VPC. | `string` | n/a | yes |
| alb_ingress_cidrs_json | JSON list of IPv4 CIDRs allowed to reach the ALB on port 80, e.g. ["198.51.100.7/32"]. CI passes the secret ALB_INGRESS_CIDRS. Empty means 0.0.0.0/0 (ADR 0007 S10). | `string` | `""` | no |
| promotion_target_account_id | Account of promotion_target_env. Never committed: CI passes TF_VAR_promotion_target_account_id from the secret PROMOTION_TARGET_ACCOUNT_ID (env dev) or AWS_ACCOUNT_ID_PROD (PR plan). | `string` | `""` | no |
| promotion_target_env | Environment that promotes this environment's images (ADR 0008 P9): "prod" in dev, empty elsewhere. Set in terraform.tfvars. | `string` | `""` | no |
| secret_recovery_window_days | Secrets Manager recovery window; 0 deletes at once (ADR 0004, Q3). | `number` | `0` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| alb_url | Public URL of the load balancer (plain HTTP). |
| cluster_name | ECS cluster name. |
| ecr_repository_name | ECR repository name. |
| log_group_name | Application log group. |
| secret_name | Secrets Manager secret name. Set its value by hand (put-secret-value). |
| service_name | ECS service name. |
| task_family | Task definition family. |
<!-- END_TF_DOCS -->
