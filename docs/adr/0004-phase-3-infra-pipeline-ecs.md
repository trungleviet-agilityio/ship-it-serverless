# ADR 0004: Phase 3 infra pipeline and ECS

- Status: accepted
- L4 (ALB CIDR from a secret) and L-a (YAML-parser trigger allowlist) are resolved by ADR 0007 S10 and S9.
- Date: 2026-10-23 (accepted 2026-10-26)
- L4 (ALB CIDR from a secret) and L-a (YAML-parser trigger allowlist) are deferred to Phase 6 by ADR 0006.
- Partly superseded by ADR 0005 (Phase 4): `container_command` and the placeholder are removed (E6, E13, E17), and after the secret value is set the next step is the `app-deploy` run, not `--force-new-deployment` (B5).

## Context

PLAN.md Phase 3 builds the dev application infrastructure, `modules/app-ecs` called from `envs/dev`, and the infra pipeline `terraform-iac.yml`. A PR plans with the read-only plan role and posts a comment. A merge to `main` applies with the apply role, after approval in GitHub environment `dev`. The user then sets the app secret value by hand. The phase ends with negative tests on the plan role.

Requirements covered:

| ID | What Phase 3 must deliver |
|---|---|
| FR-6 | `envs/dev` uses the S3 backend in its own account (`use_lockfile = true`). Environments differ only through `terraform.tfvars` |
| FR-7 | VPC with 2 public subnets (no NAT, tasks get public IPs). ALB, target group, Fargate service (0.25 vCPU, 0.5 GB, 1 task). ECR (scan on push, immutable tags). Log group with 7-day retention |
| FR-8 | Secret shell `sis/dev/app-api-key` with no value. `secrets[].valueFrom` is the secret ARN. Execution role may `GetSecretValue` on that ARN only. The user sets the value outside git and Terraform |
| FR-9 | `terraform-iac.yml`: on a PR touching `infra/**`, run fmt, init, validate, tflint, plan and a PR comment (plan role, no `environment:`). On push to `main`, apply with `environment: dev` and a required reviewer |
| FR-15 | dev uses ECS `ROLLING` with the deployment circuit breaker and automatic rollback |
| NFR-1 | No AWS keys in GitHub (role ARNs come from GitHub configuration, see E25) |
| NFR-2 | `permissions: {}` at workflow level. Per job, only what the job needs. `id-token: write` only where a role is assumed |
| NFR-3 | Actions pinned by full SHA. Tool versions pinned. Binaries checksum-verified |
| NFR-4 | harden-runner is the first step of every job (`audit`) |
| NFR-5 | `.terraform.lock.hcl` committed for new directories with `linux_amd64` and `darwin_arm64` hashes |
| NFR-7 | Roles keep `max_session_duration = 3600` |
| NFR-8 | Default tags `Project`, `Env`, `ManagedBy=terraform`, identical to bootstrap B7 |
| NFR-9 | Claude never applies, destroys or sets secret values. The user runs every checkpoint command |

Constraints carried over:

- ADR 0001: D1 (public repo, so logs are public), D2 (no account ID in git), D12 (offline tests with `mock_provider`), D14 (orchestrator owns `README.md` and `docs/**`), D15 (thin Makefile), D16 (README with terraform-docs markers in every root and module).
- ADR 0002:
  - B7 tags, B8 bucket name, B10 partial backend.
  - B13 trust, B14 EC2 tag scoping, B15 boundary, B16 guardrails (G5 denies bootstrap state to CI), B20 wildcard list, B23 as amended.
  - The name contract (`resource_names`).
  - Residual risks R1 to R3.
  - Consequences: `ignore_changes = [task_definition]`, and `mask-aws-account-id`.
- ADR 0003: C3 fork and Dependabot skip; C5 runner `ubuntu-24.04`; C6 harden-runner v2.22.2; C8 configure-aws-credentials v6.3.0; C10 (account-bearing values are secrets); C14 zizmor; C15 account-ID hook. Open items M1 and M2 are folded into this phase (user-approved).

Facts already established: bootstrap is applied (state at `bootstrap/terraform.tfstate`), Phase 2 proved the plan role trust, repo secret `AWS_PLAN_ROLE_ARN_DEV` and repo variable `AWS_REGION` exist, and environment `dev` does not exist yet. The apply role inline policy renders to 8,723 of 10,240 characters.

Findings from current docs that shape this ADR:

1. **`event_name` is not an AWS condition key (changes M1).** The IAM GitHub tab lists exactly these keys: `actor`, `actor_id`, `job_workflow_ref`, `repository`, `repository_id`, `repository_owner_id`, `workflow`, `ref`, `environment`, `enterprise_id`. A `StringEquals` on an unsupported key compares against a missing context key, which fails. So the proposed `event_name` condition would lock every PR plan out of the plan role. The documented fix is `ref`:
   - for `pull_request`, `GITHUB_REF` is `refs/pull/<n>/merge`;
   - for `pull_request_target`, it is the default branch.
2. **`job_workflow_ref` is documented only for reusable workflows**, by both AWS and GitHub (GitHub: "For jobs using a reusable workflow"). `workflow` (the workflow name) is a documented AWS key. That allows a partial fix for R2 without reusable workflows.
3. **`hashicorp/setup-terraform` v4.0.1 does not verify the download.** Its source at the pinned SHA calls `getRelease`, `downloadTool` and `extractZip`, never `release.verify`. It fails NFR-3, so CI installs Terraform and tflint with a script that checks pinned SHA-256 values.
4. **The first ECS deployment stalls until the secret has a value.** Secrets are injected when the container starts. The shell has no `AWSCURRENT` value, so tasks fail. ECS docs: "When the deployment circuit breaker does not find a deployment that is in a COMPLETED state, the circuit breaker does not launch new tasks and the deployment is stalled." With desired count 1, the threshold is 3 failures. Recovery is to set the value, then force a new deployment.
5. **The `aws_security_group` default-egress revoke is covered.** The provider removes the default "ALLOW ALL" egress rule on create. The Service Reference lists only `security-group` as the resource of `RevokeSecurityGroupEgress` and `RevokeSecurityGroupIngress`, and the group carries the tags, so `Ec2ManageTagged` allows it. `Authorize*` also needs `security-group-rule`, which is already granted.
6. **The ELB managed policy changed recently.** `ElasticLoadBalancingFullAccess` v10 (edited 2026-10-09) adds `ec2:ValidateSecurityGroupQuotasForInterface` next to the Describe actions. The Service Reference gives it one resource, `security-group`, with tag condition keys. It may be called with the caller's identity when an ALB or ENI gets security groups. It is not `Describe*`, so the apply role lacks it.
7. **ELB condition keys `elasticloadbalancing:Subnet` and `elasticloadbalancing:SecurityGroup` take IDs.** The IDs do not exist when bootstrap is applied, so IAM cannot tie ALB or ECS placement to the tagged VPC (ADR 0002 review item L6).
8. **`aws_ecs_service` defaults:**
   - `deployment_configuration.strategy` defaults to `ROLLING`;
   - `availability_zone_rebalancing` defaults to `ENABLED` on new services;
   - `wait_for_steady_state` defaults to `false`;
   - `sigint_rollback` needs `wait_for_steady_state = true`;
   - the docs ask for `depends_on` on the role policy so service deletion does not get stuck in DRAINING.
9. **Plan output contains ARNs with the account ID.** `::add-mask::` redacts logs only. Text posted to a PR through the API is not masked, and the repo is public.
10. **Secrets Manager `recovery_window_in_days` defaults to 30.** A destroyed secret keeps its name until the window ends, so a re-apply after teardown fails. `0` forces immediate deletion.
11. **`make tf-check` breaks after a real `terraform init`** against S3 in the same checkout ("No valid credential sources found"), because it reuses the directory's `.terraform/`. Phase 3 makes this common: teardown means a real init in `envs/dev`.

## Decision

### A. Bootstrap changes (applied by the user with admin, delivered in PR 1)

| # | Decision | Why / source |
|---|---|---|
| E1 | **M1, redesigned.** Add to the plan role trust: `StringLike token.actions.githubusercontent.com:ref = refs/pull/*/merge`. All other conditions stay `StringEquals`. This is the only `StringLike` in any trust policy, and its wildcard covers only the PR number. `sub`, `repository_id` and `repository_owner_id` stay exact. **Do not add `event_name`** (Finding 1). | Finding 1; IAM condition keys (GitHub tab); events-that-trigger-workflows |
| E2 | **R2, partial fix: pin the workflow name.** Apply trust: `StringEquals workflow` in `["terraform-iac", "terraform-destroy"]`. `terraform-destroy` is the Phase 5 consumer, added now so Phase 5 needs no bootstrap re-apply. Deploy trust: `StringEquals workflow = "app-deploy"`, which binds Phase 4 to `name: app-deploy`. The plan role is not pinned: a PR controls its own workflow file, so a name pin adds nothing there. Workflow names become part of the name contract (add `workflow_names` to the `resource_names` output or a new output). This is not a hard boundary: a reviewed change on `main` could rename a workflow. It does turn "any approved dev job can take either role" into a visible rename in review. `ref = refs/heads/main` stays on both. | Finding 2; ADR 0002 R2 |
| E3 | **Apply policy additions** (the full audit is in the permission table below): (a) new statement `Ec2ValidateSgQuotasOnTaggedGroup`: `ec2:ValidateSecurityGroupQuotasForInterface` on `security-group/*` with `aws:ResourceTag/Project` and `aws:ResourceTag/Env`. It is a precaution (Finding 6), it is tag-scoped and it has no wildcard. (b) Add `iam:ListRoleTags` to `IamEcsRolesRead` (read-only, `role/sis-dev-ecs-*`), so a provider read of role tags cannot fail. About 400 characters more, so roughly 9,100 of 10,240. No other gaps were found. | Findings 5, 6; Service Reference |
| E4 | **Bootstrap is never planned or applied in CI.** G5 denies CI the bootstrap state by design: it holds the budget email, and its trust and guardrails must not be changed by the roles they constrain. CI still checks bootstrap offline (fmt, validate, `terraform test`, tflint). The user applies bootstrap locally with SSO admin. | ADR 0002 B10, B16 |

**Apply role permission audit for `modules/app-ecs`** (✓ = already allowed; "new" = E3):

| Terraform resource | Calls (create, read, delete) | Apply role statement |
|---|---|---|
| `aws_vpc` | CreateVpc (+tags), ModifyVpcAttribute (DNS), Describe*, DeleteVpc | Ec2CreateTopLevelTagged, Ec2TagOnCreate, Ec2ManageTagged, Ec2Read ✓ |
| `aws_internet_gateway` | CreateInternetGateway, AttachInternetGateway (igw + vpc, both tagged), Detach, Delete | ✓ |
| `aws_subnet` x2 | CreateSubnet (subnet RequestTag + vpc ResourceTag), ModifySubnetAttribute, DeleteSubnet | ✓ |
| `aws_route_table`, `aws_route`, `aws_route_table_association` x2 | CreateRouteTable, CreateRoute, AssociateRouteTable (route-table + subnet + igw, all tagged), Disassociate, Delete | ✓ |
| `aws_security_group` x2 | CreateSecurityGroup, RevokeSecurityGroupEgress (default rule, `security-group` only), DeleteSecurityGroup | ✓ (Finding 5) |
| `aws_vpc_security_group_{ingress,egress}_rule` | Authorize* with tag specs (`security-group` + `security-group-rule`), CreateTags with CreateAction, Revoke* by rule ID | ✓ (rules tagged through `default_tags`) |
| `aws_lb`, `aws_lb_target_group`, `aws_lb_listener` | Create* + AddTags, Modify*Attributes, Describe*, Delete* | ElbManage, ElbRead ✓; ValidateSecurityGroupQuotasForInterface **new** |
| `aws_ecr_repository`, `aws_ecr_lifecycle_policy` | CreateRepository (+TagResource), PutLifecyclePolicy, Get/Describe/ListTags, DeleteRepository (force) | Ecr ✓ |
| `aws_cloudwatch_log_group` | CreateLogGroup (+TagResource), PutRetentionPolicy, DescribeLogGroups, ListTagsForResource, DeleteLogGroup | Logs, LogsRead ✓ |
| `aws_secretsmanager_secret` | CreateSecret (+TagResource), DescribeSecret, GetResourcePolicy, DeleteSecret (force) | SecretShell ✓ (G1 still denies values) |
| `aws_iam_role` x2 + `aws_iam_role_policy` x1 or x2 | CreateRole (boundary + TagRole), PutRolePolicy, GetRole, GetRolePolicy, ListRolePolicies, ListAttachedRolePolicies, ListInstanceProfilesForRole, ListRoleTags, DeleteRolePolicy, DeleteRole | IamEcsRolesBounded, IamEcsRolesRead ✓; ListRoleTags **new** |
| `aws_ecs_cluster` | CreateCluster (+TagResource), DescribeClusters, DeleteCluster, ecs SLR | EcsCluster, ServiceLinkedRoles ✓ |
| `aws_ecs_task_definition` | RegisterTaskDefinition (task-level cpu 256 and memory 512 satisfy the numeric keys), TagResource, PassRole x2, Describe, Deregister | EcsTaskDefRegister, EcsTaskDefTags, PassEcsRoles, EcsTaskDefUnscoped ✓ |
| `aws_ecs_service` | CreateService (+TagResource), DescribeServices, UpdateService, DeleteService | EcsService ✓ |

If the first CI apply still hits AccessDenied, the fix is another bootstrap change. ADR 0002 expects at most one such iteration.

### B. `modules/app-ecs` (no provider, no backend)

| # | Decision |
|---|---|
| E5 | **Layout:** `versions.tf` (same constraints as bootstrap), `variables.tf`, `locals.tf` (names), `data.tf` (`aws_caller_identity`, `aws_partition`, policy documents), `network.tf`, `security_groups.tf`, `alb.tf`, `ecr.tf`, `logs.tf`, `secrets.tf`, `iam.tf`, `ecs.tf`, `outputs.tf`, `README.md` (D16), `.terraform.lock.hcl` (committed, so `make tf-check` leaves no untracked file), `tests/*.tftest.hcl`. **Names** come from `"${var.prefix}-${var.env}"` using the same formulas as bootstrap `locals.tf`: cluster `sis-dev-cluster`, service and family and ECR `sis-dev-app`, log group `/ecs/sis-dev-app`, ALB `sis-dev-alb`, target group `sis-dev-tg`, roles `sis-dev-ecs-exec` and `sis-dev-ecs-task`, secret `sis/dev/app-api-key`. The boundary ARN is built as `arn:<partition>:iam::<caller account>:policy/sis-dev-ecs-boundary`; never typed in. |
| E6 | **Inputs** (all typed, described, validated): `prefix`, `env` (`dev` or `prod`), `aws_region`, `azs` (exactly 2), `vpc_cidr` (default `10.40.0.0/16`), `container_image` (must contain `@sha256:`, NFR-3), `container_command` (`list(string)`, default `null`), `container_port` (8080), `health_check_path` (`/health`), `task_cpu` (default 256, must be at most 512 to match the IAM cap), `task_memory` (default 512, at most 1024), `desired_count` (default 1, 0 to 2), `log_retention_days` (7), `ecr_keep_images` (10), `secret_recovery_window_days` (0, or 7 to 30), `alb_ingress_cidrs` (default `["0.0.0.0/0"]`, see Q1). |
| E7 | **Network:** `aws_vpc` (DNS support and hostnames on); `aws_internet_gateway`; 2 `aws_subnet` with `cidrsubnet(vpc_cidr, 8, i)` in `var.azs` and `map_public_ip_on_launch = false` (ECS assigns task IPs, so nothing else in the subnet gets one); one `aws_route_table` with a standalone `aws_route` `0.0.0.0/0` to the IGW, and 2 associations. No NAT, no endpoints, no flow logs (cost). The VPC's default security group, main route table and NACL stay untouched: they are untagged, so the apply role could not manage them anyway. |
| E8 | **Security groups:** two `aws_security_group` resources with **no inline rules**, plus standalone `aws_vpc_security_group_*_rule` resources only. Standalone rules carry `default_tags`, so B14 can change and delete them by rule ID. ALB SG: ingress TCP 80 from each `alb_ingress_cidrs` entry (`for_each`); egress TCP `container_port` to the task SG only. Task SG: ingress `container_port` from the ALB SG only (`referenced_security_group_id`); egress TCP 443 to `0.0.0.0/0` for image pull, Secrets Manager and Logs. VPC DNS is not filtered by security groups. |
| E9 | **ALB:** `aws_lb` named `sis-dev-alb`, internet-facing, `application`, both subnets, ALB SG, `drop_invalid_header_fields = true`, `enable_deletion_protection = false` (with a comment: the lab is torn down every session). `aws_lb_target_group` named `sis-dev-tg`: `target_type = "ip"`, HTTP, `container_port`, health check `health_check_path`, matcher `200`, interval 15 s, healthy 2, unhealthy 3, `deregistration_delay = 30`. `aws_lb_listener` on HTTP 80 forwards to the target group. HTTPS is out of scope (PLAN §2, see R7). |
| E10 | **ECR:** `aws_ecr_repository` `sis-dev-app`, `image_tag_mutability = "IMMUTABLE"`, `scan_on_push = true`, AES256 (default, written explicitly), `force_delete = true` (teardown every session; the apply role can already delete the repository). `aws_ecr_lifecycle_policy` has **one** rule: `tagStatus any`, `imageCountMoreThan var.ecr_keep_images`, expire. No "expire untagged" rule: Phase 4 buildx output can include untagged index children or attestation manifests, and expiring those could break a pinned digest. |
| E11 | **Logs and secret:** `aws_cloudwatch_log_group` `/ecs/sis-dev-app`, retention 7, no KMS. `aws_secretsmanager_secret` `sis/dev/app-api-key`, AWS managed key, `recovery_window_in_days = var.secret_recovery_window_days` (0, Finding 10, Q3). **No `aws_secretsmanager_secret_version` anywhere** (FR-8; enforced by E28). |
| E12 | **IAM roles** (both carry `permissions_boundary` = the bootstrap boundary ARN; inline policies only; no managed attachments). **Execution role** `sis-dev-ecs-exec`: trust is the `ecs-tasks.amazonaws.com` service principal, as documented on the execution role page. Inline policy `exec`: `ecr:GetAuthorizationToken` on `*` (B20, no resource-level support), ECR pull (`BatchCheckLayerAvailability`, `GetDownloadUrlForLayer`, `BatchGetImage`) on the one repository ARN, `logs:CreateLogStream` and `PutLogEvents` on `<log group arn>:*`, and `secretsmanager:GetSecretValue` on **the exact secret ARN** (FR-8). No `kms:Decrypt`: the AWS managed key needs none. **Task role** `sis-dev-ecs-task`: trust `ecs-tasks.amazonaws.com` with `aws:SourceAccount = <account>` and `ArnLike aws:SourceArn = arn:<p>:ecs:<region>:<account>:*` (the confused-deputy pattern from the task role docs). **No permission policy**: the app makes no AWS calls. |
| E13 | **Task definition** `sis-dev-app`: `FARGATE`, `awsvpc`, task-level `cpu = "256"`, `memory = "512"` (they must be task-level, because the IAM numeric keys `ecs:task-cpu` and `ecs:task-memory` read them), `runtime_platform` `LINUX`/`X86_64`, execution and task role ARNs. One container `app`: `essential`, `user = "10001:10001"` (matches the Dockerfile), `readonlyRootFilesystem = true` with a task-scoped volume `tmp` mounted at `/tmp`, `portMappings` on `container_port`, `environment` `APP_ENV = var.env`, `secrets = [{ name = "APP_API_KEY", valueFrom = aws_secretsmanager_secret.app.arn }]`, `awslogs` to the log group with stream prefix `app`, and `command = var.container_command` (omitted when null). **Placeholder until Phase 4** (set in `envs/dev/terraform.tfvars`): image `public.ecr.aws/docker/library/python:3.13-slim@sha256:<index digest>`. That is the Docker official image mirrored on ECR Public: no Docker Hub limits, no ECR auth, and the same base as `app/Dockerfile`. Command: `["sh","-c","mkdir -p /tmp/www && printf ok > /tmp/www/health && exec python -m http.server 8080 --directory /tmp/www"]`. `GET /health` returns 200, so the ALB health check passes, and the process runs as UID 10001 with a read-only root. | **Amended 2026-10-26 after the first live apply:** the placeholder `sh -c "mkdir -p /tmp/www ..."` failed on Fargate with `mkdir: cannot create directory '/tmp/www': Permission denied`, because a task-scoped volume is owned by root and the container runs as UID 10001. The placeholder is now an inline Python `http.server` that answers `ok` on `/` and `/health` from memory and writes nothing to disk. **Phase 4 note:** the real app must not write to `/tmp` either, or the volume needs a writable owner (for example an init step, or dropping the volume and the read-only root together).
| E14 | **Cluster and service:** `aws_ecs_cluster` `sis-dev-cluster` with `containerInsights = disabled` (cost). `aws_ecs_service` `sis-dev-app`: `launch_type = "FARGATE"`, `desired_count = var.desired_count`, `deployment_controller { type = "ECS" }`, `deployment_configuration { strategy = "ROLLING" }`, `deployment_circuit_breaker { enable = true, rollback = true }`, `deployment_minimum_healthy_percent = 100`, `deployment_maximum_percent = 200`, `health_check_grace_period_seconds = 30`, `availability_zone_rebalancing = "ENABLED"` (the AWS default, written to avoid drift), `enable_execute_command = false`. `network_configuration`: both module subnets, task SG only, `assign_public_ip = true`. `load_balancer` to the target group, container `app`, `container_port`. `wait_for_steady_state = false` (Finding 4: the first deployment cannot become stable before the secret has a value). `depends_on` the listener and the exec role policy (provider note). `lifecycle { ignore_changes = [task_definition] }`, so Phase 4 deploy-role revisions are not reverted (ADR 0002). |
| E15 | **Module outputs:** names (cluster, service, family, ECR, log group, secret name, role names), plus ARNs and URLs for Phase 4 and 7 (`ecr_repository_url`, `secret_arn`, `exec_role_arn`, `task_role_arn`, `target_group_arn`, `alb_dns_name`). |

### C. `envs/dev` root

| # | Decision |
|---|---|
| E16 | **Files:**<br>- `versions.tf`, same as bootstrap.<br>- `providers.tf`: `region = var.aws_region`, `allowed_account_ids = [var.aws_account_id]`, `default_tags { tags = local.default_tags }`. `locals.tf` defines `default_tags = { Project = "ship-it-safely", Env = var.env, ManagedBy = "terraform" }`, identical to B7, and a test asserts it.<br>- `backend.tf`: partial `backend "s3" { key = "envs/dev/terraform.tfstate", region = "ap-southeast-1", use_lockfile = true, encrypt = true }`, no `bucket`.<br>- `variables.tf`; `main.tf` with a single `module "app_ecs" { source = "../../modules/app-ecs" ... }`; `outputs.tf`; `terraform.tfvars`; `.terraform.lock.hcl` (`linux_amd64` + `darwin_arm64`); `README.md` (D16); `tests/`. |
| E17 | **`terraform.tfvars` (committed, no account ID):** `aws_region = "ap-southeast-1"`, `prefix = "sis"`, `env = "dev"`, `azs = ["ap-southeast-1a", "ap-southeast-1b"]`, `vpc_cidr`, the placeholder `container_image` and `container_command`, `desired_count = 1`, `task_cpu = 256`, `task_memory = 512`, `log_retention_days = 7`. `aws_account_id` has no default and no tfvars entry. CI passes `TF_VAR_aws_account_id`. Locally it comes from the shell or a gitignored `*.auto.tfvars` (E30). |
| E18 | **Root outputs** never carry the account ID, because apply logs are public: `alb_url` (`http://<dns>`; the DNS name has a random number, not the account), `cluster_name`, `service_name`, `task_family`, `ecr_repository_name`, `log_group_name`, `secret_name`. ARNs and the ECR URL stay module outputs that the root does not re-export. |

### D. `.github/workflows/terraform-iac.yml`

| # | Decision | Why / source |
|---|---|---|
| E19 | **Triggers:**<br>- `pull_request` (`branches: [main]`, `paths`: `infra/**`, `.github/workflows/terraform-iac.yml`, `scripts/tf-check.sh`, `scripts/tf-policy.sh`, `scripts/install-ci-tools.sh`, `scripts/ci-tools.sha256`, `mise.toml`, `.tflint.hcl`, plus the helper scripts `scripts/ci-requirements.txt`, `scripts/check-workflow-triggers.sh`, `scripts/tf-plan-summary.sh`).<br>- `push` (`branches: [main]`, `paths`: `infra/terraform/envs/dev/**`, `infra/terraform/modules/**`, the workflow file). Bootstrap-only merges do not ask for an approval.<br>- `workflow_dispatch` (no inputs): runs only the apply job, to re-create the stack after a teardown without re-running an old commit.<br>`name: terraform-iac`, which matches E2. Never `pull_request_target`. | FR-9; E2 |
| E20 | **Workflow settings:** `permissions: {}`. `concurrency: { group: ${{ github.workflow }}-${{ github.event_name }}-${{ github.ref }}, cancel-in-progress: ${{ github.event_name == 'pull_request' }} }`: stale PR plans are cancelled, applies never are. The apply job also has job-level `concurrency: { group: terraform-envs-dev, cancel-in-progress: false }`. Env `TF_IN_AUTOMATION=1`, `TF_INPUT=0`. Every job: `runs-on: ubuntu-24.04`, a `timeout-minutes`, and harden-runner `dc2769abcc0fcfbadfc1df54081c1608579ef6b2 # v2.22.2` as step 1 with `egress-policy: audit`. | NFR-2, NFR-4; ADR 0003 C5, C6 |
| E21 | **Jobs (PR):**<br>(1) `checks`: no AWS; `contents: read`; runs for fork and Dependabot PRs too. Steps: checkout, install tools (E29), hash-locked pre-commit install, the account-ID guard and the trigger allowlist (L1, L2; also run for every PR by `repo-guard.yml`), `make tf-check` (README markers, policy checks, fmt, offline init and validate, `terraform test` for every directory), `tflint --init` (env `GITHUB_TOKEN: ${{ github.token }}` for the plugin download) and `tflint --recursive`. 10 min.<br>(2) `plan`: `needs: checks`; C3 same-repo and non-Dependabot condition; `contents: read`, `id-token: write`; no `environment:`. Steps: checkout, install tools, check configuration, configure-aws-credentials (plan role), init, plan, summarize. 15 min.<br>(3) `plan-role-guardrails`: negative tests (E26); C3 condition; `id-token: write` only; no checkout. 5 min.<br>(4) `comment`: `needs: plan`; `if: always() && needs.plan.result != 'skipped'` plus the C3 condition; `pull-requests: write` only; no checkout, no AWS. 5 min.<br>The job holding AWS credentials has no write token, and the job with a write token has no AWS credentials. | FR-9; NFR-2; ADR 0003 C3 |
| E22 | **Plan job details:**<br>- Checkout `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1` with `persist-credentials: false`.<br>- "Check configuration": `secrets.AWS_PLAN_ROLE_ARN_DEV` must match `^arn:aws:iam::[0-9]{12}:role/sis-dev-gha-plan$`, `secrets.AWS_ACCOUNT_ID_DEV` must match `^[0-9]{12}$` and equal the ARN's account, `vars.AWS_REGION` must be set. Then `::add-mask::` on the account.<br>- configure-aws-credentials `e1253824e5c10ff9df46874f81ed3ec929e19cfd # v6.3.0` with `mask-aws-account-id: true`, `retry-max-attempts: 3`, session `gha-plan-<run_id>-<attempt>`.<br>- The bucket name is **derived**: `sis-dev-tfstate-${ACCOUNT}-${REGION}-an` (B8 is a locked contract), so there is no bucket secret.<br>- `terraform -chdir=infra/terraform/envs/dev init -lockfile=readonly -backend-config="bucket=$BUCKET"`.<br>- `terraform plan -lock-timeout=5m -no-color -out=tfplan`. The full text plan goes to the masked log.<br>- Summary: `terraform show -json tfplan \| jq` gives counts and one line per changed resource (`actions` + `address`, no attribute values), with deletes and replacements flagged. Any line holding the account ID or another bare 12-digit run fails the job. The summary goes to `$GITHUB_STEP_SUMMARY` and to a job output.<br>- `rm tfplan`. No artifact: plan files hold every value, and artifacts on a public repo can be downloaded by any signed-in user. | Findings 3, 9; NFR-3; ADR 0003 C7 to C9 |
| E23 | **PR comment:** one sticky comment. The body starts with the marker `<!-- terraform-iac:plan:dev -->` and carries the plan job result, the counts, the address table, the commit SHA and a link to the run log. The `comment` job uses the preinstalled `gh api` with `GH_TOKEN: ${{ github.token }}`: it lists the PR's issue comments, PATCHes the one starting with the marker, or POSTs a new one. The body arrives through `env:` from `needs.plan.outputs.summary` and is checked again for 12-digit runs. | Finding 9; GitHub Apps permissions page (issue comment endpoints accept Pull requests: write) |
| E24 | **Apply job:**<br>- Runs on push to `main` or `workflow_dispatch`, with `if: github.ref == 'refs/heads/main'`.<br>- `environment: dev`; `contents: read`, `id-token: write`; 30 min.<br>- Steps: checkout, install tools, check configuration (env secret `AWS_APPLY_ROLE_ARN` must match `role/sis-dev-gha-apply` and repo secret `AWS_ACCOUNT_ID_DEV`), configure-aws-credentials (apply role, session `gha-apply-<run_id>-<attempt>`), init, `plan -out=tfplan`, summary to the step summary, `apply -input=false tfplan`.<br>- Afterwards, write `terraform output -raw alb_url` and the account-free part of `aws sts get-caller-identity --query Arn` to the step summary. configure-aws-credentials masks the whole assumed-role ARN in logs, so the summary is where the user reads which role ran.<br>- **Re-plan inside the approved job, not a saved PR plan.** The PR plan was made against the merge ref and an older state serial, and saving it would need an artifact. The approver relies on the PR comment (R5). | FR-9; ADR 0002 B13 |
| E25 | **GitHub configuration** (amends ADR 0002 B23 and extends ADR 0003 C10). Values holding the account ID are secrets; names and the region are variables.<br>Repo level (the PR plan job has no environment): secret `AWS_PLAN_ROLE_ARN_DEV` (exists); secret `AWS_ACCOUNT_ID_DEV` (**new**); variable `AWS_REGION` (exists).<br>Environment `dev`: secret `AWS_APPLY_ROLE_ARN` (**new**); secret `AWS_DEPLOY_ROLE_ARN` (Phase 4, optional now); required reviewer = the user; `prevent_self_review = false`; deployment branch policy: custom, `main` only.<br>Dropped from B23: `TF_STATE_BUCKET(_DEV)` (derived, E22), environment-level `AWS_ACCOUNT_ID` and `AWS_REGION` (repo values reach environment jobs). This also deviates from NFR-1's literal "variables", as C10 already does. | ADR 0003 C10; GitHub variables render unmasked |

### E. Negative tests

| # | Decision |
|---|---|
| E26 | **In CI (`plan-role-guardrails` job, every same-repo PR).** The plan role only trusts `pull_request` tokens, so these cannot run as `workflow_dispatch`. One shell step, after configure-aws-credentials with the plan role and the account masked. Each call captures its exit code with `\|\| rc=$?` and sends stdout to `/dev/null`.<br>N2: `aws secretsmanager get-secret-value --secret-id sis/dev/app-api-key`. Pass only on `AccessDeniedException`. Success fails the job ("plan role read a secret value"). `ResourceNotFoundException` emits `::warning::` ("secret does not exist yet; inconclusive, the checkpoint simulator covers it") and passes. Any other error fails.<br>N3: `aws ec2 create-vpc --cidr-block 10.255.0.0/16 --dry-run`. Pass only on `UnauthorizedOperation`. `DryRunOperation` fails the job ("plan role could create a VPC"). Dry-run creates nothing either way.<br>Nothing that writes for real is tried (for example `s3:PutObject` on the state key), because a wrong pass would damage state.<br>**At the checkpoint (admin, read-only):** `aws iam simulate-principal-policy` against the plan role. `GetSecretValue` on the real secret ARN must be `explicitDeny`. Create actions must be `implicitDeny`. |

### F. Repo tooling

| # | Decision |
|---|---|
| E27 | **`scripts/tf-check.sh` isolation (fix 3):**<br>- Create `tmp_root="$(mktemp -d)"` with `trap 'rm -rf "$tmp_root"' EXIT`.<br>- Export `TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$tmp_root/plugin-cache}"` (create it).<br>- For each directory, run `init -backend=false`, `validate` and `test` with `TF_DATA_DIR="$tmp_root/data/<dir with / replaced by _>"` (absolute).<br>- The directory's own `.terraform/` is never read or written, so a real S3 init in `bootstrap/` or `envs/dev/` no longer breaks `make tf-check`.<br>- The lock file still lives in the config directory and is honored.<br>- bash 3.2 rules apply. |
| E28 | **`scripts/tf-policy.sh [root]`** (called first by `tf-check.sh`, default root `infra/terraform`). Grep-level rules that `terraform test` cannot express. Each failure is collected and the run ends with a summary:<br>(1) no `aws_secretsmanager_secret_version`;<br>(2) no `aws_security_group_rule` and no inline `ingress {` or `egress {` blocks under `modules/`;<br>(3) no `AmazonECSTaskExecutionRolePolicy` and no `aws_iam_role_policy_attachment` under `modules/`;<br>(4) each `resource "aws_iam_role"` under `modules/` has a `permissions_boundary`;<br>(5) no `bucket =` in any `backend.tf`, and `envs/*/backend.tf` has `use_lockfile = true` and `key = "envs/<dir>/terraform.tfstate"`;<br>(6) no `provider "` or `backend "` block under `modules/`. |
| E29 | **`scripts/install-ci-tools.sh <dest>` + `scripts/ci-tools.sha256`.** Versions come from `mise.toml` (one source of truth). Each download is saved under a versioned name, so a version bump without a checksum update fails with "no checksum for X":<br>- `terraform_<v>_linux_amd64.zip` from `releases.hashicorp.com`;<br>- tflint `tflint_linux_amd64.zip` from the GitHub release, saved as `tflint_<v>_linux_amd64.zip`.<br>Then `sha256sum -c` against the checked-in file, unzip into `<dest>`, add it to `$GITHUB_PATH` when set, and print `terraform version` and `tflint --version`.<br>Pinned values (from the official files):<br>- `c168cab7c637a8769fdb90089ddd19de701bc6ff8aca64dc2e2185fe46f59f67  terraform_1.17.0_linux_amd64.zip`<br>- `d4c545ed2e29d6338604b586f34f544f380f70f243aa72f7b484713835eaec61  tflint_0.65.0_linux_amd64.zip`<br>Providers are verified by `init -lockfile=readonly` against the lock file. tflint verifies its own ruleset plugin download (`.tflint.hcl` pins 0.49.0). `setup-terraform` is not used (Finding 3). |
| E30 | **M2, account-ID guard and ignores.** Hook `no-aws-account-id`: drop the `files` filter and scan every tracked text file (`types: [text]`). Keep `exclude: (^\|/)\.terraform\.lock\.hcl$`. New `entry` (as built): `(?<![0-9A-Za-z])(?!123456789012|111111111111|222222222222)[0-9]{12}(?![0-9A-Za-z])`, an explicit allowlist instead of the repeated-digit lookahead first proposed. That allows the AWS doc example and repeated-digit placeholders such as `111111111111` and `222222222222` in `PLAN.md`, and keeps alphanumeric boundaries so 40-hex SHA pins and 64-hex digests pass. Rename it "no bare 12-digit AWS account ID in tracked files". **`.gitignore`** adds: `*.tfbackend`, `!*.tfbackend.example`, `*.tfvars.json`, `infra/terraform/envs/*/*.auto.tfvars`, `*.tfplan.json`, `tfplan.json`. `envs/dev/terraform.tfvars` stays committed, and the guard now covers it. **Owner:** `devops-engineer` edits `.gitignore` in this phase, because these lines are Terraform tooling tied to the hook. The orchestrator records in `CLAUDE.md` that `.gitignore` belongs to `devops-engineer` (repo tooling), with app lines proposed by `backend-dev`. |
| E31 | **Delivery in two PRs.** **PR 1** (`phase-3a-bootstrap-guardrails`): E1 to E3, E27, E28, E30 and the bootstrap tests. No workflow. The user applies bootstrap from the PR branch, checks it, merges. **PR 2** (`phase-3-infra-pipeline-ecs`, rebased on `main` after PR 1): module, `envs/dev`, E29 and the workflow. PR 2's own plan run is the live proof that E1 did not break PR plans. Merging PR 2 triggers the first apply. |

### Least privilege summary

| Role | Trust after this phase (all `StringEquals` unless noted) | Change |
|---|---|---|
| `sis-dev-gha-plan` | `aud`; `sub = <P>:pull_request`; `repository_id`; `repository_owner_id`; `ref` **StringLike** `refs/pull/*/merge` | E1 |
| `sis-dev-gha-apply` | `aud`; `sub = <P>:environment:dev`; IDs; `ref = refs/heads/main`; `workflow` in `terraform-iac`, `terraform-destroy` | E2; policy + E3 |
| `sis-dev-gha-deploy` | same as apply but `workflow = app-deploy` | E2 |
| `sis-dev-ecs-exec` | `ecs-tasks.amazonaws.com`; boundary; inline: ECR auth `*` (B20), pull on one repository, logs on one group, `GetSecretValue` on one secret ARN | new |
| `sis-dev-ecs-task` | `ecs-tasks.amazonaws.com` + `aws:SourceAccount`, `aws:SourceArn`; boundary; no permissions | new |

Wildcards: `ecr:GetAuthorizationToken` on `*` in the execution role (B20, no resource-level support). The `ref` wildcard on the plan role covers only the PR number. No new `iam:PassRole`; the module passes exactly the two roles that bootstrap allows.

## Alternatives considered

- **`event_name = pull_request` on the plan role (the original M1).** Not an AWS key, so it would fail closed and block every plan. Rejected for `ref` (Finding 1).
- **`job_workflow_ref` or `workflow_ref` pins.** `workflow_ref` is not in the AWS key list. `job_workflow_ref` is documented only for reusable workflows. Revisit if the workflows become reusable.
- **Separate GitHub environments (`dev` and `dev-deploy`) to split apply from deploy (R2).** Stronger, but adds a second approval per merge and more setup. The `workflow` pin is cheaper; keep the split for prod (Phase 7).
- **`hashicorp/setup-terraform`.** Pinned by SHA, but it does not verify the Terraform zip (Finding 3). Rejected for E29. `mise` in CI with a lock file was also considered: it adds another third-party action and its checksum behavior varies per tool backend.
- **Upload the PR plan and apply it on merge.** The plan is stale against main's state, and the artifact would hold every value on a public repo. Rejected.
- **Two approvals on main (plan job, then apply job, both in `dev`).** The approver would see main's exact plan, at the cost of two clicks and a plan artifact. Rejected for the lab (R5).
- **Post the full plan text with the account ID replaced by `sed`.** Fragile: other encodings or IDs could slip through. The summary-only comment keeps attribute values out of the PR.
- **`wait_for_steady_state = true`.** The first apply would fail because the secret has no value (Finding 4). Rejected. Revisit after Phase 4 so applies prove service health.
- **`desired_count = 0` until the secret is set.** Contradicts FR-7 ("1 task") and needs a second apply. Rejected for a manual force-new-deployment.
- **nginx or other "hello" images as the placeholder.** They listen on port 80 and return 404 on `/health`, so the target group would need different settings from the app. The Python base image with a one-line server matches port, path and user.
- **Docker Hub image.** Unauthenticated pull limits. ECR Public is preferred (ECS docs).
- **`recovery_window_in_days = 7` or more.** Keeps the value across teardowns, but re-apply then fails on the name until the user runs restore and import. Rejected for the lab (Q3).
- **ECR "expire untagged after 1 day" rule.** Risky with index children and attestations from Phase 4 buildx. Rejected.
- **Fixing L6 with `elasticloadbalancing:Subnet` and `SecurityGroup` conditions.** They need IDs that do not exist at bootstrap time (Finding 7). Accepted as R4.
- **Plan `bootstrap/` in CI.** The plan role is denied bootstrap state on purpose (G5), and admin applies it (E4).
- **One PR for everything.** It works, but the bootstrap would be applied from unmerged code, and PR 2's plan would not test the new plan trust. Rejected for E31.
- **ARM64 Fargate (cheaper).** Phase 4 builds on x86 runners. Kept `X86_64` (Q6).

## Consequences

- **Phase 4 contracts:**
  - (a) The workflow must be named `app-deploy` (E2).
  - (b) Its `UpdateService` must pass `taskDefinition`, because the deploy role's `ecs:task-definition` condition fails on a request without it. Never use `--force-new-deployment` alone with the deploy role.
  - (c) Phase 4 first removes `container_command` from `envs/dev/terraform.tfvars` (infra PR). Then the deploy job renders from the latest revision and swaps only the image; otherwise the app image would run the placeholder command.
  - (d) Terraform registers new task definition revisions when its inputs change. With `ignore_changes`, they reach the service only through the next deploy.
- **First apply leaves the service stalled** until the secret value is set and the user forces a new deployment (checkpoint step B5). Expected, not a failure of the apply.
- **Residual risk R4 (L6, decision for the user):** the apply role can point the ALB or the service at any subnet or security group in the region, for example in the default VPC, because placement is not tag-checked. Mitigations: module tests pin the wiring to module resources, PR review of the plan, and environment approval. Impact: the app could run in a network the lab does not control. Roles and the secret scope are unchanged.
- **R5:** the apply job applies a fresh plan of `main` that the approver has not seen. The reviewed artifact is the PR comment. The apply job's step summary shows what was applied.
- **R6:** the public ALB is plain HTTP, so `X-API-Key` for `/admin` crosses the internet unencrypted. The key is a lab value, rotated every session because recovery is 0 and a new value is set on each re-create. Restricting `alb_ingress_cidrs` (Q1) reduces exposure. TLS stays out of scope (PLAN §2).
- **R7:** harden-runner `audit` telemetry, as in ADR 0003.
- **Account ID exposure:** masked in logs. Never in comments, summaries, outputs or committed files. The guard now covers all tracked text.
- **Cost (estimate, not taken from a price page; check the AWS Pricing Calculator for ap-southeast-1):** the ALB hourly charge plus LCUs, Fargate 0.25 vCPU and 0.5 GB, and about 3 public IPv4 addresses (2 for the ALB, 1 for the task). That is roughly 1 to 2 USD per day while up, which would cross the 16 USD budget alert in under two weeks if left running. Secrets Manager, ECR storage and logs are cents. **Tear down after every session** (step B8) until Phase 5's destroy workflow exists.
- **Teardown order:** `envs/dev` destroy (user, admin, locally) first; bootstrap only when the lab ends (ADR 0002). A local `terraform init` in `envs/dev` for teardown no longer breaks `make tf-check` (E27).
- **Re-create after teardown:** `gh workflow run terraform-iac.yml --ref main`, approve, then steps B5 and B6 again (the value was deleted with the secret).
- **Docs follow-up for the orchestrator (D14):**
  - Mark ADR 0002 B13 amended by E1 and E2, B23 amended by E25, and the apply table amended by E3.
  - Mark ADR 0003 C10 extended by E25, and M1 and M2 resolved here.
  - CODING_STANDARDS:
    - the plan-role `ref` `StringLike` exception;
    - the `workflow` pins;
    - "no `setup-terraform`; install with pinned checksums";
    - standalone SG rules only;
    - task-level cpu and memory;
    - the account-ID guard covers all tracked text;
    - `.gitignore` owner.
  - `CLAUDE.md` ownership table (`.gitignore`).
  - README: a Phase 3 section (pipeline, secret step, cost, teardown).
  - Optionally a Phase 3 diagram.

## Decision log (open questions resolved)

On 2026-10-26 the user delegated these choices to the orchestrator: "decide by best practice, and record a
pro and a con for each". Each entry below can be reversed in a later ADR. Q2 also absorbs the user's
decisions on the Phase 2 findings (M1, M2), which this PR 1 now carries.

| Q | Decision | Pro | Con | Reversal cost |
|---|---|---|---|---|
| Q1 | ALB ingress `0.0.0.0/0` on port 80 | The ALB URL works from any network (laptop, phone, CI checks) with no personal data in the repo or secrets; matches PLAN §2 (public ALB) | The app is reachable by anyone, so scanners will hit `/` and `/admin`; mitigated by the key check on `/admin` (constant-time compare), no data behind the app and teardown after every session | Low: set `alb_ingress_cidrs` (a repo secret passed as `TF_VAR_alb_ingress_cidrs`) and re-apply |
| Q2 | Two PRs (E31). **PR 1** = this branch: Phase 2 findings M1 (E1) and M2 (E30), E2, E3, E27, E28 and their tests. **PR 2** = module, `envs/dev`, E29, `terraform-iac.yml` | One bootstrap re-apply covers every trust and policy change; PR 2's own plan run then proves E1 did not lock out PR plans; small, reviewable diffs | Two review and merge cycles; PR 2 must be rebased on `main` after PR 1 merges | Low |
| Q3 | Secret `recovery_window_in_days = 0` | Teardown and re-create in one session work without "secret scheduled for deletion" errors; no manual restore or import | The value is gone at teardown: the user sets it again each session with `put-secret-value`, and an accidental destroy cannot be undone | Low: set `secret_recovery_window_days` (7 to 30) |
| Q4 | Accept **R4**: IAM does not check which subnets and security groups the ALB and ECS service use | No IAM condition can express it (the ELB and ECS keys take IDs that do not exist when bootstrap is applied); a fake fix would add complexity without protection | An approved apply could place the ALB or tasks in another VPC's subnets; mitigated by PR plan review, the `dev` environment approval and a dedicated dev account with no other VPCs in use | Medium: needs an SCP or a post-apply check if the account ever hosts other workloads |
| Q5 | Accept **E2**: pin `workflow` names on the apply (`terraform-iac`, `terraform-destroy`) and deploy (`app-deploy`) trust | Closes most of R2: an approved job in another workflow can no longer pick the apply or deploy role; costs one condition per role | The `workflow` claim is the file's `name:`, which any writer can set, so it narrows mistakes more than attacks; Phase 4 and 5 must use exactly these names or a bootstrap change is needed | Low: edit the list and re-apply bootstrap |
| Q6 | Fargate `X86_64` | Matches the GitHub `ubuntu-24.04` x86 runners, so Phase 4 builds natively with no QEMU or multi-arch manifest; the `python:3.13-slim` digest already resolves for amd64 | About 20% more expensive per vCPU-hour than Graviton (`ARM64`); a few cents per session at 0.25 vCPU | Low: switch `runtime_platform` and build `linux/arm64` |
| Q7 | Add a `main` branch ruleset: require a pull request, block force pushes and deletions; plan checks stay non-required | Nothing reaches the apply job without a reviewed plan comment; protects the state history behind the `ref = refs/heads/main` trust pin | Solo friction: even one-line fixes need a PR; required approvals are set to 0 because GitHub does not count self-approval, so review is still on the honour system | Low: delete or relax the ruleset in Settings |

**PR 1 verify findings (decided by the orchestrator on 2026-10-26, same delegation):**

| Finding | Decision | Pro | Con |
|---|---|---|---|
| Security M1: the apply role could create a new `sis-dev-ecs-*` role, or re-trust one, to an outside principal and read the app secret through the boundary | **Fix now (PR 1):** IAM writes and reads on ECS roles are scoped to the two exact ARNs (`sis-dev-ecs-exec`, `sis-dev-ecs-task`); a `tf-policy.sh` rule rejects any non-`ecs-tasks` principal in module role trust | Removes the "new role" path entirely, and a bad trust edit fails `make tf-check` before review; rides the bootstrap re-apply that PR 1 needs anyway | Re-trusting one of the two exact roles is still possible in a merged, approved apply (R1, accepted in ADR 0002); a third ECS role later needs a bootstrap change |
| Security L1: apply and deploy trust cannot tell `push` from `pull_request_target`, `issue_comment` or `workflow_run` on `main` | **Defer to PR 2:** a trigger allowlist check on `terraform-iac.yml` (only `pull_request`, `push`, `workflow_dispatch`) plus zizmor's dangerous-triggers audit; no `actor_id` pin | No risk of locking the user out of apply with a wrong or changed GitHub user ID; the risky triggers are blocked where they would be written | Defense stays in the repo (pre-commit and CI), not in IAM, so a direct push that skips both still relies on the `dev` approval click |
| Security L2: the account-ID hook does not run in CI | **Defer to PR 2:** the `checks` job runs `pre-commit run no-aws-account-id --all-files` | Catches `--no-verify` commits and web-editor edits before merge | Needs the pre-commit install step in CI (pinned, adds about 20 s) |
| Security L3: binary files (screenshots, PDF, DOCX) and odd encodings skip the hook | **Accept for the lab** | No extra hook to maintain; the repo has no binaries that could hold console output today | A console screenshot added later could leak the account ID; reviewers must check images by eye |
| Security L4: lock-file exclude was unanchored; URL-encoded ARNs (`%3A<id>`) slip past the letter boundary | **Fix the exclude now** (`(^\|/)\.terraform\.lock\.hcl$`); **accept** the URL-encoding gap | The exclude can no longer exempt a file named `x.terraform.lock.hcl` | A pasted console URL with an encoded ARN would not be caught |
| Security L5: auto or extra `*.tfvars` outside `bootstrap/accounts/` could be committed with the account ID or the budget email | **Fix now:** ignore `infra/terraform/**/*.tfvars` and `**/*.auto.tfvars`, except `envs/*/terraform.tfvars` and `*.tfvars.example` | The email (which no hook detects) cannot be committed through a stray tfvars file | A new committed tfvars name needs an explicit negation in `.gitignore` |
| Security re-check Low: `tf-policy.sh` rule 7 is grep-level and misses spellings such as `type = "*"`, a `jsonencode` `AWS =` key or identifiers from a variable | **Defer to PR 2:** a `terraform test` in `modules/app-ecs` asserts every role trust statement is exactly `type = "Service"`, `identifiers = ["ecs-tasks.amazonaws.com"]`; rule 7 stays as a cheap first filter | A plan-level test checks the evaluated value, so no spelling or indirection can slip past it | Until PR 2 lands there is no module to protect, so nothing is exposed; the grep rule alone would give false confidence if kept as the only check |
| Reviewer Lows: README hook text, Makefile help, `tf-policy.sh` gaps (env without `backend.tf`, `dynamic "ingress"`), order-sensitive test | **Fix now** | Docs match the code; policy rules fail closed on the shapes Phase 3 will add | None worth noting |

**PR 2 verify findings (decided by the orchestrator on 2026-10-26, same delegation):**

| Finding | Decision | Pro | Con |
|---|---|---|---|
| Reviewer M1: `ecs:RegisterTaskDefinition` may lack resource-level support or the cpu and memory keys | **No change.** Checked against the ECS Service Reference JSON: the action takes the `task-definition` resource and both `ecs:task-cpu` and `ecs:task-memory` | Keeps the per-family scope and the cost cap | None; the claim was a false positive |
| Security M1: the trigger allowlist checked only `terraform-iac.yml`, but the trust pins the writer-controlled `name:` of any workflow file | **Fix now:** the allowlist scans every workflow (quoted keys too), and a new path-unfiltered `repo-guard.yml` (no secrets, `contents: read`) runs it with zizmor, the account-ID guard and the CI self-tests on every PR | A workflow named `terraform-iac` with a dangerous trigger now fails a check that always runs, whatever files the PR touches | One more workflow run per PR (about a minute); still bypassable by a direct push if the `main` ruleset is off |
| Security L1, reviewer L2: account-ID guard and CI self-tests did not run on PRs outside the Terraform paths | **Fix now** through `repo-guard.yml` | README, docs and app changes are checked too | Same extra run as above |
| Security L2: the summary check matched only 12-digit runs with non-alphanumeric boundaries | **Fix now:** plan and apply summaries also fail on the exact account value from the secret | Catches an account ID glued to letters in an address | The comment job (no secrets) still relies on the regex alone |
| Security L3: module tests checked the policy documents, not the roles that use them | **Fix now:** distinct mocked JSON per document and assertions that each role and the exec policy use exactly those documents; rule 7 also catches unquoted `AWS =`, `Federated =` and `*` principals | A swapped or inline trust fails `make tf-check` | Tests depend on `override_data`, so a provider schema change could need test edits |
| Security L4: no wiring to narrow the ALB CIDRs without committing an IP | **Defer to Phase 5 hardening** (moved again to Phase 6 by ADR 0006); Q1 keeps `0.0.0.0/0` | No half-wired secret that could silently be empty | Narrowing today means committing a CIDR or editing the workflow |
| Reviewer L1: cancelling a PR plan could leave a stale S3 lock | **Fix now:** PR plans queue instead of being cancelled | No `force-unlock` after quick successive pushes | A stale plan finishes before the newest one starts |
| Reviewer L3: the dev outputs test was vacuous | **Fix now:** assert the exact output set, plus a policy rule that root outputs never reference ARNs, repository URLs or account IDs | Prevents an account-bearing output from reaching public apply logs | The output list must be edited in two places when Phase 4 adds outputs |
| Re-check L-a: the trigger allowlist is a line parser and misses a flow list split across lines or explicit `? key` YAML | **Defer to Phase 5 hardening** (moved again to Phase 6 by ADR 0006; a YAML parser from the hash-locked venv) | No new runtime dependency for `make lint` on dev machines; the risky shape needs a merged, reviewed workflow plus a `dev` approval | A deliberately obfuscated trigger written by a writer could pass the check until then |
| Re-check L-b: `repo-guard` is advisory; the ruleset requires a PR but no status checks | **User, at the checkpoint:** add `guard (no AWS)` and `checks (no AWS)` as required status checks in the `main` ruleset (B2) | A failing guard or a PR that weakens the guard script can no longer be merged with green-looking review | Path-filtered `checks` would stay Pending on PRs that do not touch Terraform; keep only `guard` required if that blocks docs PRs |
| Re-check L-c: no test that the exec inline policy is attached to the execution role | **Fix now** (test asserts the policy's role is the exec role, with distinct mocked IDs) | Swapping the attachment to the task role, which the app process uses, fails `make tf-check` | None worth noting |
| Code simplifier (10 suggestions, about 100 lines) | **Defer** to a later refactor PR | The reviewed, security-checked shape lands first | The workflow keeps three copies of the configuration check for now |

Defaults the orchestrator kept from the architect's recommendations without a separate question: no
`wait_for_steady_state` on the first apply (Finding 4), no HTTPS (PLAN §2), Container Insights off (cost),
and CloudTrail Event history instead of a trail (ADR 0002 Q2).

## Checkpoint commands (the user runs these; Claude never does, NFR-9)

Placeholders: `<DEV_ACCOUNT_ID>` (from `CLAUDE.local.md`), `<PR1>`, `<PR2>`, `<RUN_ID>`.

```bash
REPO=trungleviet-agilityio/ship-it-safely
BUCKET="sis-dev-tfstate-<DEV_ACCOUNT_ID>-ap-southeast-1-an"
```

### Part A: after PR 1 is open (bootstrap re-apply for E1 to E3)

**A1. Apply the bootstrap change from the PR 1 branch**

```bash
git switch phase-3a-bootstrap-guardrails && git pull
aws sso login --profile sis-dev-admin
export AWS_PROFILE=sis-dev-admin
cd infra/terraform/bootstrap
terraform init -backend-config="bucket=${BUCKET}"
terraform plan -var-file=accounts/dev.tfvars -out=bootstrap.tfplan
# Expect: 0 to add, 0 to destroy. In-place updates only:
#   aws_iam_role.plan / .apply / .deploy (assume_role_policy) and aws_iam_role_policy.apply
terraform apply bootstrap.tfplan
rm bootstrap.tfplan
aws iam get-role --role-name sis-dev-gha-plan  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition'
aws iam get-role --role-name sis-dev-gha-apply --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition'
# plan: StringLike ref refs/pull/*/merge; apply: workflow [terraform-iac, terraform-destroy]
cd ../../..
```

**A2. Merge PR 1, then check that the plan role still refuses non-PR tokens (N1)**

```bash
gh pr merge <PR1> --repo "$REPO" --squash
gh workflow run oidc-smoke-test.yml --repo "$REPO" --ref main
sleep 15
RUN_ID="$(gh run list --repo "$REPO" --workflow oidc-smoke-test.yml --event workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run watch "$RUN_ID" --repo "$REPO" --exit-status     # success = refused as designed
```

The positive proof (the plan role still works for a PR) is PR 2's `plan` job (B3).

### Part B: GitHub setup, PR 2, apply, secret, tests, teardown

**B1. Environment `dev` and secrets (E25).** If your `gh` token cannot write these, first try `gh auth refresh -h github.com -s repo`, or use the web UI below.

```bash
MY_ID="$(gh api user --jq .id)"
gh api -X PUT "repos/${REPO}/environments/dev" --input - <<EOF
{"reviewers":[{"type":"User","id":${MY_ID}}],"prevent_self_review":false,
 "deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
EOF
gh api -X POST "repos/${REPO}/environments/dev/deployment-branch-policies" -f name=main -f type=branch

terraform -chdir=infra/terraform/bootstrap output -raw apply_role_arn | gh secret set AWS_APPLY_ROLE_ARN --env dev --repo "$REPO"
printf '%s' '<DEV_ACCOUNT_ID>' | gh secret set AWS_ACCOUNT_ID_DEV --repo "$REPO"

gh secret list --repo "$REPO"              # AWS_PLAN_ROLE_ARN_DEV, AWS_ACCOUNT_ID_DEV
gh secret list --env dev --repo "$REPO"    # AWS_APPLY_ROLE_ARN
gh variable list --repo "$REPO"            # AWS_REGION = ap-southeast-1
```

Web UI equivalent:

1. Repo **Settings > Environments > New environment**, name `dev`, **Configure environment**.
2. **Required reviewers**: tick it, add yourself, leave **Prevent self-review** unticked, **Save protection rules**.
3. **Deployment branches and tags**: choose **Selected branches and tags**, then **Add deployment branch or tag rule**: type Branch, pattern `main`.
4. **Environment secrets > Add environment secret**: `AWS_APPLY_ROLE_ARN` = the output of `terraform -chdir=infra/terraform/bootstrap output -raw apply_role_arn`.
5. **Settings > Secrets and variables > Actions > Repository secrets > New repository secret**: `AWS_ACCOUNT_ID_DEV` = the dev account ID.

**B2. Ruleset on `main` (decided, Q7):** Settings > Rules > Rulesets > New branch ruleset, target `main`, tick "Require a pull request before merging".

**B3. Read the PR 2 plan (the orchestrator opens PR 2)**

```bash
gh pr checks <PR2> --repo "$REPO" --watch          # checks, plan, plan-role-guardrails, comment: all green
gh pr view <PR2> --repo "$REPO" --comments | grep -A60 'terraform-iac:plan:dev'
# Expect about 30 to add, 0 to change, 0 to destroy; every address under module.app_ecs
RUN_ID="$(gh run list --repo "$REPO" --workflow terraform-iac.yml --branch phase-3-infra-pipeline-ecs --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run view "$RUN_ID" --repo "$REPO" --log | grep -c '<DEV_ACCOUNT_ID>'      # expect 0
gh run view "$RUN_ID" --repo "$REPO" --log | grep -E 'Denied as designed'    # N2 and N3 lines
```

**B4. Merge and approve the apply**

```bash
gh pr merge <PR2> --repo "$REPO" --squash
sleep 15
RUN_ID="$(gh run list --repo "$REPO" --workflow terraform-iac.yml --event push --limit 1 --json databaseId --jq '.[0].databaseId')"
ENV_ID="$(gh api "repos/${REPO}/actions/runs/${RUN_ID}/pending_deployments" --jq '.[0].environment.id')"
gh api -X POST "repos/${REPO}/actions/runs/${RUN_ID}/pending_deployments" \
  -F "environment_ids[]=${ENV_ID}" -f state=approved -f comment='phase 3 first apply'
gh run watch "$RUN_ID" --repo "$REPO" --exit-status
```

Web UI: open the run and click **Review deployments**, tick `dev`, **Approve and deploy**. Then open the job summary for the ALB URL and the role line `assumed-role/sis-dev-gha-apply/...`.

**B5. Set the secret value, then start a fresh deployment (Finding 4)**

```bash
export AWS_PROFILE=sis-dev-admin AWS_REGION=ap-southeast-1
APP_API_KEY_VALUE="$(openssl rand -hex 24)"     # keep a copy in your Keychain (kc) for the /admin test in Phase 4
aws secretsmanager put-secret-value --secret-id sis/dev/app-api-key \
  --secret-string "$APP_API_KEY_VALUE" --query VersionId --output text
unset APP_API_KEY_VALUE
aws ecs update-service --cluster sis-dev-cluster --service sis-dev-app --force-new-deployment \
  --query 'service.deployments[0].rolloutState' --output text
aws ecs wait services-stable --cluster sis-dev-cluster --services sis-dev-app
```

**B6. Smoke check**

```bash
ALB="$(aws elbv2 describe-load-balancers --names sis-dev-alb --query 'LoadBalancers[0].DNSName' --output text)"
curl -fsS "http://${ALB}/health"; echo                    # ok
aws ecs describe-task-definition --task-definition sis-dev-app \
  --query 'taskDefinition.{cpu:cpu,memory:memory,secrets:containerDefinitions[0].secrets[].name,image:containerDefinitions[0].image}'
# secrets: ["APP_API_KEY"]; image pinned by @sha256
```

**B7. Negative tests, admin side (read-only)**

```bash
PLAN_ROLE_ARN="$(terraform -chdir=infra/terraform/bootstrap output -raw plan_role_arn)"
SECRET_ARN="$(aws secretsmanager describe-secret --secret-id sis/dev/app-api-key --query ARN --output text)"
aws iam simulate-principal-policy --policy-source-arn "$PLAN_ROLE_ARN" \
  --action-names secretsmanager:GetSecretValue --resource-arns "$SECRET_ARN" \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text
# expect: secretsmanager:GetSecretValue  explicitDeny
aws iam simulate-principal-policy --policy-source-arn "$PLAN_ROLE_ARN" \
  --action-names ec2:CreateVpc ecs:CreateCluster ecr:CreateRepository iam:CreateRole secretsmanager:CreateSecret elasticloadbalancing:CreateLoadBalancer \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text
# expect: implicitDeny on every line
aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=GetSecretValue \
  --max-results 5 --output json \
  | jq -r '.Events[].CloudTrailEvent | fromjson | [.eventTime, (.errorCode // "OK"), .userIdentity.arn] | @tsv'
# expect: AccessDenied from assumed-role/sis-dev-gha-plan/gha-guard-... (from the PR 2 run)
```

**B8. Teardown after the session (until Phase 5)**

```bash
export AWS_PROFILE=sis-dev-admin TF_VAR_aws_account_id=<DEV_ACCOUNT_ID>
terraform -chdir=infra/terraform/envs/dev init -backend-config="bucket=${BUCKET}"
terraform -chdir=infra/terraform/envs/dev plan -destroy -out=destroy.tfplan
terraform -chdir=infra/terraform/envs/dev apply destroy.tfplan
rm infra/terraform/envs/dev/destroy.tfplan
aws resourcegroupstaggingapi get-resources --tag-filters Key=Project,Values=ship-it-safely Key=Env,Values=dev \
  --query 'ResourceTagMappingList[].ResourceARN' --output text | tr '\t' '\n' | grep -Ev ':(iam|s3|budgets)::' || echo "only bootstrap resources left"
```

Re-create next session: `gh workflow run terraform-iac.yml --repo "$REPO" --ref main`, approve, then B5 and B6.

## Sources

- IAM condition keys, OIDC and GitHub tab: https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_iam-condition-keys.html
- GitHub OIDC reference: https://docs.github.com/en/actions/reference/security/oidc
- Events that trigger workflows (`GITHUB_REF` for `pull_request`, `pull_request_target`, `push`): https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows
- `aws_ecs_service`: https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/main/website/docs/r/ecs_service.html.markdown
- ECS deployment circuit breaker: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deployment-circuit-breaker.html
- ECS task execution role: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_execution_IAM_role.html
- ECS task IAM role (confused deputy trust): https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-iam-roles.html
- ECS secrets through Secrets Manager: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/secrets-envvar-secrets-manager.html
- EC2 Service Reference JSON (Authorize*, Revoke*, ValidateSecurityGroupQuotasForInterface): https://servicereference.us-east-1.amazonaws.com/v1/ec2/ec2.json
- ELB Service Reference JSON (condition keys, dependent actions): https://servicereference.us-east-1.amazonaws.com/v1/elasticloadbalancing/elasticloadbalancing.json
- ElasticLoadBalancingFullAccess v10: https://docs.aws.amazon.com/elasticloadbalancing/latest/userguide/elb-api-permissions.html (redirects to the managed policy reference)
- `aws_ecr_repository`: https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/main/website/docs/r/ecr_repository.html.markdown
- `aws_secretsmanager_secret`: https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/main/website/docs/r/secretsmanager_secret.html.markdown
- `aws_security_group` (default egress removal, standalone rules): https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/main/website/docs/r/security_group.html.markdown
- setup-terraform releases: https://github.com/hashicorp/setup-terraform/releases
- setup-terraform v4.0.1 tag ref: https://api.github.com/repos/hashicorp/setup-terraform/git/ref/tags/v4.0.1
- setup-terraform source at v4.0.1 (no verify): https://raw.githubusercontent.com/hashicorp/setup-terraform/dfe3c3f87815947d99a8997f908cb6525fc44e9e/lib/setup-terraform.js
- setup-terraform README: https://raw.githubusercontent.com/hashicorp/setup-terraform/main/README.md
- js-releases README: https://raw.githubusercontent.com/hashicorp/js-releases/main/README.md
- Terraform releases (1.17.0 latest): https://releases.hashicorp.com/terraform/
- Terraform 1.17.0 SHA256SUMS: https://releases.hashicorp.com/terraform/1.17.0/terraform_1.17.0_SHA256SUMS
- tflint v0.65.0 (latest): https://github.com/terraform-linters/tflint/releases/tag/v0.65.0
- tflint v0.65.0 checksums: https://github.com/terraform-linters/tflint/releases/download/v0.65.0/checksums.txt
- actions/checkout releases: https://github.com/actions/checkout/releases
- actions/checkout v7.0.1 tag ref: https://api.github.com/repos/actions/checkout/git/ref/tags/v7.0.1
- harden-runner releases (v2.22.2 still latest): https://github.com/step-security/harden-runner/releases
- configure-aws-credentials releases (v6.3.0 still latest): https://github.com/aws-actions/configure-aws-credentials/releases
- GitHub App permissions (issue comment endpoints under Pull requests write): https://docs.github.com/en/rest/authentication/permissions-required-for-github-apps
- Review pending deployments: https://docs.github.com/en/rest/actions/workflow-runs#review-pending-deployments-for-a-workflow-run
- `gh secret set`: https://cli.github.com/manual/gh_secret_set

## Build briefs

### devops-engineer

**Owns:** `infra/**` (including every README per D16), `.github/**`, `.pre-commit-config.yaml`, `.tflint.hcl`, `Makefile`, `scripts/**`, and `.gitignore` for this phase (E30).

**Do not edit:** `README.md`, `docs/**`, `PLAN.md`, `CLAUDE.md`, `app/**`.

Work on two branches, as in E31:

- PR 1: E1 to E3, E27, E28, E30.
- PR 2: E5 to E24, E26, E29.

Never run `terraform apply`, `import` or `state`, any `gh secret` / `gh variable` / `gh workflow run`, or a merge.

**Verify pins before use (NFR-3).** If anything differs from this ADR, stop and report; do not substitute.

```bash
git ls-remote https://github.com/actions/checkout 'refs/tags/v7.0.1*'                     # 3d3c42e5aac5ba805825da76410c181273ba90b1
git ls-remote https://github.com/step-security/harden-runner 'refs/tags/v2.22.2*'          # dc2769abcc0fcfbadfc1df54081c1608579ef6b2
git ls-remote https://github.com/aws-actions/configure-aws-credentials 'refs/tags/v6.3.0*' # e1253824e5c10ff9df46874f81ed3ec929e19cfd
curl -fsSL https://releases.hashicorp.com/terraform/1.17.0/terraform_1.17.0_SHA256SUMS | grep linux_amd64
curl -fsSL https://github.com/terraform-linters/tflint/releases/download/v0.65.0/checksums.txt | grep linux_amd64
docker buildx imagetools inspect public.ecr.aws/docker/library/python:3.13-slim   # record the index digest; confirm it lists linux/amd64
```

**Files**

PR 1:

- `infra/terraform/bootstrap/`:
  - `locals.tf`: trust map gains `ref_like` for plan and `workflows` for apply and deploy; workflow-name contract.
  - `oidc.tf`: dynamic `StringLike ref` and `StringEquals workflow` conditions.
  - `iam_apply.tf`: `Ec2ValidateSgQuotasOnTaggedGroup`, and `iam:ListRoleTags` in `IamEcsRolesRead`.
  - `outputs.tf`: workflow names.
  - `README.md`: the trust table.
  - Tests.
- `scripts/tf-check.sh` (E27), new `scripts/tf-policy.sh` (E28).
- `.pre-commit-config.yaml` (E30), `.gitignore` (E30).

PR 2:

- `infra/terraform/modules/app-ecs/**` (E5 to E15, plus README, lock file and tests).
- `infra/terraform/envs/dev/**` (E16 to E18, plus README, lock file and tests). Delete both `.gitkeep` files.
- `.github/workflows/terraform-iac.yml` (E19 to E24, E26).
- `scripts/install-ci-tools.sh` and `scripts/ci-tools.sha256` (E29).
- `infra/terraform/README.md`: Commands table and the `envs/dev` row.

**Tests to write first (red, then green)**

1. Bootstrap (`trust.tftest.hcl`, `iam.tftest.hcl`):
   - Plan trust has exactly one `StringLike`, on `token.actions.githubusercontent.com:ref`, with values exactly `["refs/pull/*/merge"]`. Every other condition on all three roles is `StringEquals`.
   - Apply `workflow` is exactly `["terraform-iac", "terraform-destroy"]`, deploy `["app-deploy"]`, and plan has no `workflow` condition.
   - Every trust condition variable is in the documented set: `aud`, `sub`, `repository_id`, `repository_owner_id`, `ref`, `workflow`. This guards against `event_name`.
   - The new EC2 statement has exactly that one action on `security-group/*`, with `ResourceTag` Project and Env.
   - `iam:ListRoleTags` is on `role/sis-dev-ecs-*`.
   - Existing B20 and no-broad-allow tests still pass.
2. `scripts/tf-policy.sh`: build scratch fixtures (outside the repo) for each of the six rules, and confirm each fails with a named message. The real tree passes.
3. `scripts/tf-check.sh` isolation:
   - In a scratch copy of `infra/terraform/bootstrap`, write `.terraform/terraform.tfstate` declaring `"backend": {"type": "s3", ...}`.
   - Run `env -u AWS_PROFILE AWS_EC2_METADATA_DISABLED=true scripts/tf-check.sh <scratch dir>`. It fails before the fix and passes after.
   - After `make tf-check`, no new `.terraform/` appears under `infra/` (`git status --ignored`).
4. Account-ID hook:
   - A scratch file `docs-zz.md` (never committed) with an IAM ARN holding any real-looking 12-digit account ID (built at test time) fails.
   - `111111111111`, `123456789012`, a 40-hex SHA with a 12-digit run, and a `sha256:` digest pass.
   - `pre-commit run --all-files` passes on the whole repo. If a false positive appears, report it; do not widen the allowlist silently.
5. Module `tests/` with `mock_provider "aws"` (`override_during = plan`; mock `aws_caller_identity` = `123456789012`, `aws_partition` = `aws`, `aws_iam_policy_document` json `{}`, and a `mock_resource "aws_secretsmanager_secret"` with a fixed ARN):
   - Names equal the bootstrap contract strings, and role names start with `sis-dev-ecs-`.
   - ECR: IMMUTABLE, `scan_on_push`, `force_delete`; the lifecycle JSON has one rule, `tagStatus any`, count 10.
   - Log retention 7. Secret name `sis/dev/app-api-key`, recovery window 0.
   - Task definition: FARGATE, awsvpc, cpu `"256"`, memory `"512"`, `X86_64`. Decoded container JSON: name `app`, port 8080, `user` `10001:10001`, `readonlyRootFilesystem` true, `/tmp` mount. `secrets` is exactly `[{name = "APP_API_KEY", valueFrom = <mock secret arn>}]`, and no environment entry is named `APP_API_KEY`. `awslogs-group` is the log group.
   - Both roles have `permissions_boundary == arn:aws:iam::123456789012:policy/sis-dev-ecs-boundary`.
   - Exec policy: `GetSecretValue` resources exactly `[<mock secret arn>]`. The only `*` resource is with `ecr:GetAuthorizationToken`. ECR pull is on the one repository ARN, logs on `<group arn>:*`.
   - Task role trust has the SourceAccount and SourceArn conditions. Task role has no policy.
   - Service: FARGATE, desired 1, circuit breaker enable and rollback true, strategy `ROLLING`, `assign_public_ip` true, subnets equal the module subnet IDs, security groups exactly `[task sg]`, `load_balancer` container `app` port 8080.
   - SG rules: task ingress only from the ALB SG on 8080, task egress only 443, ALB ingress only 80.
   - ALB is not internal and `drop_invalid_header_fields` is true. The target group is type `ip`, port 8080, path `/health`, matcher `200`.
   - Validation failures (`expect_failures`): `task_cpu = 1024`, `task_memory = 2048`, `azs` of length 1, `env = "qa"`, an image without `@sha256:`.
6. `envs/dev/tests/`: `local.default_tags` equals `{Project = "ship-it-safely", Env = "dev", ManagedBy = "terraform"}`. A plan with `aws_account_id = "123456789012"` and the committed tfvars succeeds under mocks. An 11-digit account fails validation.
7. Workflow, in the scratch dir: a bad copy with `pull_request_target`, a tag-pinned `uses:`, workflow-level `id-token: write` and `${{ github.event.pull_request.title }}` in `run:` must fail `actionlint` and `uvx zizmor@1.31.1 --offline`. Then write the real workflow until both are clean.
8. `install-ci-tools.sh`: on a scratch copy with one corrupted hash, the script fails. With a bumped version in a scratch `mise.toml`, it fails with "no checksum". With the real files it passes (on macOS it may verify and unzip without running the linux binaries; gate the version print on `uname`).

**Checks that define done**

- `make check` green (lint with pre-commit, hadolint, shellcheck and actionlint; test; tf-check with policy checks and `terraform test` in bootstrap, module and `envs/dev`).
- `pre-commit run zizmor --all-files`: no findings, no ignore comments.
- `tflint --init && tflint --recursive` from the repo root: clean.
- Lock files in `modules/app-ecs` and `envs/dev`: `terraform providers lock -platform=linux_amd64 -platform=darwin_arm64`, committed.
- Grep checks on `terraform-iac.yml`:
  - `name: terraform-iac`;
  - top-level `permissions: {}`;
  - no `pull_request_target`, no `setup-terraform`;
  - every `uses:` is `owner/repo@<40 hex> # vX.Y.Z`;
  - no `${{` inside any `run:`;
  - harden-runner is step 1 with `egress-policy: audit` in every job;
  - `mask-aws-account-id: true` in every configure step;
  - `runs-on: ubuntu-24.04` and `timeout-minutes` everywhere;
  - `environment: dev` only on the apply job;
  - `id-token: write` only on `plan`, `plan-role-guardrails` and `apply`;
  - `pull-requests: write` only on `comment`;
  - `persist-credentials: false` on every checkout;
  - no `upload-artifact`.
- Name contract: every name in the module equals bootstrap `resource_names`, and the workflow name equals E2.
- No account ID anywhere (the hook passes). `git status` shows no `*.tfvars` other than `envs/dev/terraform.tfvars`, no state, no plan files, no scratch files.
- Commits (follow the `pr-conventions` skill):
  - PR 1:
    - `infra(bootstrap): pin plan role to pr merge refs and gha roles to workflow names`
    - `fix(scripts): isolate terraform data dir in tf-check`
    - `chore(repo): widen account-id guard and terraform ignores`
  - PR 2:
    - `infra(app-ecs): fargate service with secrets manager injection`
    - `infra(envs-dev): dev root with s3 backend and placeholder image`
    - `ci(workflows): terraform plan on pr and gated apply on main`
- Hand back the checkpoint commands from this ADR unchanged.

### backend-dev

Not needed in Phase 3.
