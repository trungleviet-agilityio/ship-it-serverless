# modules/app-ecs

The application stack of one environment (ADR 0004, E5 to E15): a two-subnet public VPC, an ALB, an ECR
repository, a log group, a secret shell, two ECS roles, a Fargate cluster, task definition and service.
It declares no provider and no backend; `envs/<env>` supplies both.

![app-ecs runtime diagram](../../../../docs/diagrams/app-ecs.drawio.png)

## What it creates

| Area | Resources |
|---|---|
| Network (FR-7) | VPC, internet gateway, 2 public subnets (`/24` slices of `vpc_cidr`), one route table with a `0.0.0.0/0` route. No NAT, no endpoints |
| Security groups | ALB group and task group, **no inline rules**. Standalone `aws_vpc_security_group_*_rule` resources only, so `default_tags` reach them (the apply role can only change tagged rules). ALB: TCP 80 in from `alb_ingress_cidrs`, container port out to the task group. Tasks: container port in from the ALB group, TCP 443 out |
| ALB | Internet-facing ALB, `ip` target group (health check `health_check_path`, matcher 200), HTTP 80 listener. No HTTPS (PLAN section 2) |
| ECR | Repository with immutable tags, scan on push, `force_delete`; one lifecycle rule (keep the last `ecr_keep_images`) |
| Logs | Log group `/ecs/<prefix>-<env>-app`, 7-day retention |
| Secret (FR-8) | `<prefix>/<env>/app-api-key`, a shell with **no value**. The module never creates a secret version |
| IAM | Execution role (ECR pull on one repository, log writes on one group, `GetSecretValue` on the one secret ARN) and task role (no permissions). Both carry the bootstrap boundary and trust only `ecs-tasks.amazonaws.com` |
| ECS (FR-15) | Cluster, task definition (task-level `cpu`/`memory`, `X86_64`, read-only root, `/tmp` volume, `secrets[].valueFrom` = secret ARN) and service (`ROLLING`, circuit breaker with rollback) |

## Usage

```hcl
module "app_ecs" {
  source = "../../modules/app-ecs"

  prefix          = "sis"
  env             = "dev"
  aws_region      = "ap-southeast-1"
  azs             = ["ap-southeast-1a", "ap-southeast-1b"]
  container_image = "<registry>/<repository>@sha256:<digest>"
}
```

## Constraints

- **Name contract.** Names are `<prefix>-<env>-<thing>` and must equal the bootstrap `resource_names` output:
  the CI apply and deploy roles are scoped by them (ADR 0002). The permissions boundary ARN is built from
  the caller account and partition, never typed in.
- **Task size.** `task_cpu` (256 or 512) and `task_memory` (512 to 1024) are set on the task, not the
  container, because the apply role's `ecs:task-cpu` and `ecs:task-memory` keys read the task level.
- **Secret first deployment.** Secrets are injected at container start. Until someone runs
  `put-secret-value`, tasks fail and the first deployment stalls (circuit breaker). Set the value, then run
  app-deploy. `wait_for_steady_state` is `false` for this reason.
- **`ignore_changes = [task_definition]`.** Phase 4 deploys register new task definition revisions; the
  service must not revert them. Terraform revisions reach the service only through the next deploy.
- **Image.** `container_image` must be pinned by digest. The task definition has no `command`: app-deploy
  replaces only the `image` field of the latest revision (ADR 0005, F2) and fails if a command is present.
  The placeholder image therefore exits at once, and the first deployment after a create stalls until the
  first app-deploy.
- **Secret recovery window.** Defaults to 0 so a torn-down stack can be re-created in the same session.
- **ALB ingress.** Open to `0.0.0.0/0` by default (ADR 0004, Q1); the listener is plain HTTP (R6).
  `alb_ingress_cidrs` is `sensitive` (it can be a maintainer address from a CI secret). The rules are indexed
  (`alb_http[0]`, ...) and their descriptions hold no CIDR, so neither plan output nor state keys reveal it
  (ADR 0007 S35).

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
| [aws_cloudwatch_log_group.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_ecr_lifecycle_policy.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_lifecycle_policy) | resource |
| [aws_ecr_repository.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_repository) | resource |
| [aws_ecr_repository_policy.promotion](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_repository_policy) | resource |
| [aws_ecs_cluster.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_cluster) | resource |
| [aws_ecs_service.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_service) | resource |
| [aws_ecs_task_definition.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_task_definition) | resource |
| [aws_iam_role.exec](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.task](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.exec](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_internet_gateway.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/internet_gateway) | resource |
| [aws_lb.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb) | resource |
| [aws_lb_listener.http](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_listener) | resource |
| [aws_lb_target_group.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_target_group) | resource |
| [aws_route.internet](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route) | resource |
| [aws_route_table.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table_association.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_secretsmanager_secret.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_security_group.alb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_security_group.task](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_subnet.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_vpc.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc) | resource |
| [aws_vpc_security_group_egress_rule.alb_to_task](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_egress_rule.task_https](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.alb_http](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.task_from_alb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| aws_region | AWS region of the stack. Used for the awslogs driver and the task role trust. | `string` | n/a | yes |
| azs | Exactly two availability zones, one public subnet each. | `list(string)` | n/a | yes |
| container_image | Container image pinned by digest (NFR-3). | `string` | n/a | yes |
| env | Environment name. | `string` | n/a | yes |
| prefix | Name prefix for every resource. Must equal the bootstrap prefix (name contract, ADR 0002). | `string` | n/a | yes |
| alb_ingress_cidrs | CIDR blocks allowed to reach the ALB on port 80. Open by default (ADR 0004, Q1); restrict it when the lab is not being demoed. | `list(string)` | ```[ "0.0.0.0/0" ]``` | no |
| container_port | Port the container listens on. | `number` | `8080` | no |
| desired_count | Number of tasks. | `number` | `1` | no |
| ecr_keep_images | Number of images the ECR lifecycle rule keeps. | `number` | `10` | no |
| health_check_path | HTTP path the load balancer probes. | `string` | `"/health"` | no |
| log_retention_days | Retention of the application log group. | `number` | `7` | no |
| promotion_target_account_id | Account of promotion_target_env. Required when promotion_target_env is set, ignored otherwise; sensitive so it never prints in a public plan. | `string` | `""` | no |
| promotion_target_env | Environment that promotes images from this repository (ADR 0008 P9), e.g. "prod" in dev. Empty: no repository policy. | `string` | `""` | no |
| secret_recovery_window_days | Secrets Manager recovery window. 0 deletes at once, so a torn-down stack can be re-created (ADR 0004, Q3). | `number` | `0` | no |
| task_cpu | Task-level CPU units. The apply role caps this at 512 (ecs:task-cpu). | `number` | `256` | no |
| task_memory | Task-level memory in MiB. The apply role caps this at 1024 (ecs:task-memory). | `number` | `512` | no |
| vpc_cidr | CIDR block of the VPC. Subnets are /24 slices of it. | `string` | `"10.40.0.0/16"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| alb_dns_name | ALB DNS name. |
| cluster_name | ECS cluster name. |
| ecr_repository_name | ECR repository name. |
| ecr_repository_url | ECR repository URL (holds the account ID, so the root does not re-export it). |
| exec_role_arn | Task execution role ARN. |
| exec_role_name | Task execution role name. |
| log_group_name | Application log group. |
| secret_arn | Secret ARN used in secrets[].valueFrom. |
| secret_name | Secrets Manager secret name. |
| service_name | ECS service name. |
| target_group_arn | Target group ARN. |
| task_family | Task definition family. |
| task_role_arn | Task role ARN. |
| task_role_name | Task role name. |
<!-- END_TF_DOCS -->
