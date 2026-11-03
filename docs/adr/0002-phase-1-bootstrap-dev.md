# ADR 0002: Phase 1 bootstrap dev account

- Status: accepted
- Trust amended by ADR 0007 S2: apply and deploy pin `job_workflow_ref` (file path at `main`) instead of `workflow`; guardrails gain G6 (audit tampering denies); bootstrap gains the trail, alert rule and topic (S8).
- Deploy role policy amended by ADR 0006 G14: `secretsmanager:DescribeSecret` (metadata only) on the app secret.
- Date: 2026-10-22

## Context

PLAN.md Phase 1 creates, once per AWS account, everything that GitHub Actions and Terraform need before any
app infrastructure exists:

- an S3 state bucket,
- the GitHub OIDC provider,
- three GitHub Actions roles (plan, apply, deploy),
- a cost budget.

The admin (IAM Identity Center, profile `sis-dev-admin`) runs it locally. Its state is then moved into the
bucket under `bootstrap/terraform.tfstate`.

Requirements covered:

| ID | What Phase 1 must deliver |
|---|---|
| FR-2 | State bucket (versioning, SSE, public access block, TLS-only policy), GitHub OIDC provider, budget alert at 80% |
| FR-3 | Plan role: trusts `pull_request`; `ReadOnlyAccess` + state read + put/delete of `*.tflock`; explicit deny of `secretsmanager:GetSecretValue` |
| FR-4 | Apply role: trusts `environment:<env>`; state read/write + only the services of `modules/app-ecs`; `iam:PassRole` only on the module's ECS roles; explicit deny of `GetSecretValue` |
| FR-5 | Deploy role: trusts `environment:<env>`; push to one ECR repo; register task definition; describe/update one service; PassRole on the task and execution roles only; no Secrets Manager read |
| NFR-1 | No AWS keys in GitHub; role ARNs and region go into GitHub variables |
| NFR-5 | `.terraform.lock.hcl` committed with `linux_amd64` and dev-machine hashes |
| NFR-7 | `max_session_duration = 3600` on every role |
| NFR-8 | Default tags `Project`, `Env`, `ManagedBy=terraform` |
| NFR-9 | Claude prepares commands; the user runs `apply`, state migration and the GitHub setup |

Constraints carried over from ADR 0001:

- D1: the repo is public.
- D2: no account ID in git.
- D3: region `ap-southeast-1`, prefix `sis`, budget 20 USD.
- D12: agents test offline with `mock_provider`.

The apply and deploy roles are created before the Phase 3 resources exist. So they are scoped by predictable
names, and Phase 3 must use exactly those names (see the name contract).

Findings that change earlier assumptions:

1. GitHub repos created after 2026-07-15 get an OIDC `sub` with immutable IDs in it:
   `repo:OWNER@OWNER_ID/REPO@REPO_ID:...`. The plain `repo:O/R:pull_request` in PLAN §5 no longer matches
   this repo (verified: `use_immutable_subject` is `true`).
2. IAM trust policies accept the GitHub claims `repository_id`, `repository_owner_id`, `ref` and
   `environment` as condition keys.
3. `ReadOnlyAccess` includes `s3:Get*`, `ssm:Get*` and `sqs:Receive*`, so the plan role needs denies beyond
   `GetSecretValue`.
4. The apply role can write ECS role trust policies; inside one account that is enough to assume them. A
   permissions boundary plus a deny of `sts:AssumeRole` closes it.
5. `use_lockfile` became GA in Terraform 1.11, so `required_version >= 1.10` in CODING_STANDARDS is too loose.

## Decision

### Versions, inputs, layout

| # | Decision | Why / source |
|---|---|---|
| B1 | **Terraform** `required_version = ">= 1.11, < 2.0"`. Local and CI use **1.17.0**, the latest stable release on 2026-10-22. CI pins it in Phase 3. | S3 native locking (`use_lockfile`) became GA in 1.11.0, and DynamoDB locking is deprecated. `mock_provider` needs 1.7 or later. |
| B2 | **AWS provider** `version = "~> 6.70"`. 6.70.0 is the latest, published 2026-10-22. The lock file records the exact version and hashes. | `aws_s3_bucket.bucket_namespace` (needed by B8) was added in 6.37.0. |
| B3 | **Lock file**: `terraform providers lock -platform=linux_amd64 -platform=darwin_arm64`. | NFR-5; the dev machine is Darwin arm64 |
| B4 | **How the account ID reaches Terraform.** `accounts/dev.tfvars` is gitignored by the existing `.gitignore`. It holds `aws_account_id`, `budget_email`, `github_owner_id` and `github_repo_id`. A committed `accounts/dev.tfvars.example` has placeholders. `TF_VAR_aws_account_id` still works as an override (D2). The provider sets `allowed_account_ids = [var.aws_account_id]`. Every ARN is built from `data.aws_caller_identity`, never typed in. This refines D2: the ID lives in one gitignored file instead of a shell variable, as `CLAUDE.local.md` already prescribes. | D2, CODING_STANDARDS "No account IDs in code or committed tfvars" |
| B5 | **Variables** (all have `type`, `description`, `validation`): `aws_account_id` (12 digits), `aws_region` (default `ap-southeast-1`), `prefix` (default `sis`, lowercase), `env` (`dev` or `prod`), `github_owner` (default `trungleviet-agilityio`), `github_repo` (default `ship-it-safely`), `github_owner_id` and `github_repo_id` (digits only), `github_immutable_subject` (bool, default `true`, see B12), `budget_email` (`sensitive = true`, email regex), `budget_limit_usd` (default `20`), `budget_alert_threshold_percent` (default `80`). | Standards: validation where a bad value would only fail at apply time |
| B6 | **File layout** under `infra/terraform/bootstrap/`: `versions.tf`, `providers.tf`, `backend.tf`, `variables.tf`, `locals.tf` (name contract, ARNs, OIDC subjects), `data.tf`, `state.tf`, `oidc.tf`, `iam_guardrails.tf`, `iam_ecs_boundary.tf`, `iam_plan.tf`, `iam_apply.tf`, `iam_deploy.tf`, `budget.tf`, `outputs.tf`, `.terraform.lock.hcl`, `accounts/dev.tfvars.example`, `tests/*.tftest.hcl`. Remove `accounts/.gitkeep`. | PLAN §6, Standards "split by concern" |
| B7 | **Provider default tags**: `Project = "ship-it-safely"`, `Env = var.env`, `ManagedBy = "terraform"`. The apply role's EC2 conditions (B14) depend on these exact values, so `envs/dev` in Phase 3 must use the same tags. | NFR-8 |

### State bucket and backend

| # | Decision | Why / source |
|---|---|---|
| B8 | **Bucket name** `sis-dev-tfstate-<account_id>-ap-southeast-1-an`, with `bucket_namespace = "account-regional"`. That is 46 characters, under the 63 limit. Only this account can ever create a name in its account-regional namespace, so the name cannot be squatted. It is built from `data.aws_caller_identity` and never committed. `force_destroy = false`. | S3 account regional namespaces; S3 security best practices recommend them |
| B9 | **Bucket settings**: versioning `Enabled`. SSE-S3 (`AES256`) with `blocked_encryption_types = ["SSE-C"]`. Public access block with all four flags true. Ownership `BucketOwnerEnforced`. Bucket policy denying `s3:*` when `aws:SecureTransport = false`. Lifecycle (with `filter {}`): noncurrent versions expire after 90 days but the 10 newest are kept (`newer_noncurrent_versions = 10`); incomplete multipart uploads abort after 7 days. **Not KMS**: a customer managed key costs about 1 USD a month plus requests, adds `kms:*` permissions to every role, and adds little for one private bucket. The SSE-S3, ownership and SSE-C settings repeat S3 defaults on purpose, so the code documents them and drift shows up in plans. | S3 defaults: SSE-S3 since 2023-01-05, ACLs disabled by default, SSE-C blocked for new buckets since April 2026 |
| B10 | **Backend** in `backend.tf`, a partial config: `backend "s3" { key = "bootstrap/terraform.tfstate", region = "ap-southeast-1", use_lockfile = true, encrypt = true }`. The bucket is passed with `-backend-config="bucket=..."` because a backend block cannot use variables, and that keeps the account ID out of git. For the **first apply** the user creates a gitignored `backend_override.tf` containing `backend "local" {}`. An override file's backend always wins. After apply, the user deletes it and runs `terraform init -migrate-state`. `envs/dev` (Phase 3) uses key `envs/dev/terraform.tfstate` the same way. | Terraform override-file rules; partial backend config; `*_override.tf` already in `.gitignore` |

### OIDC and trust policies

| # | Decision | Why / source |
|---|---|---|
| B11 | **OIDC provider**: `url = "https://token.actions.githubusercontent.com"`, `client_id_list = ["sts.amazonaws.com"]`, **no `thumbprint_list`**. For GitHub, AWS checks TLS against its own trusted root CAs and keeps any thumbprint without using it. `configure-aws-credentials` defaults its audience to `sts.amazonaws.com`. | Provider docs (`thumbprint_list` optional); IAM thumbprint page; action README |
| B12 | **Subject format: the immutable one with IDs.** `local.gh_sub_prefix = "repo:${github_owner}@${github_owner_id}/${github_repo}@${github_repo_id}"`. If `github_immutable_subject = false` it falls back to `repo:${github_owner}/${github_repo}`. This repo already has `use_immutable_subject = true`. The checkpoint compares GitHub's `sub_claim_prefix` with the Terraform output `oidc_sub_prefix` before Phase 2. | GitHub OIDC reference and 2026-04-23 changelog; GitHub REST OIDC |
| B13 | **Trust conditions.** All use `StringEquals`, except one `StringLike` on the plan role's `ref` (amended after the Phase 2 review, see below). The only `Action` is `sts:AssumeRoleWithWebIdentity`. The principal is the OIDC provider ARN. The `repository_id` and `repository_owner_id` keys are immutable IDs, which AWS recommends over names. Pinning `ref` on apply and deploy means a PR branch that adds `environment: dev` to a job still cannot assume them, even if the environment's branch rule were misconfigured (PR refs are `refs/pull/N/merge`). `job_workflow_ref` is not pinned: AWS documents it for reusable workflows only, and pinning it would tie trust to file paths that do not exist yet. | IAM "Configuring a role for GitHub OIDC"; IAM condition keys, GitHub tab |

Trust table (`<P>` = `gh_sub_prefix`, `<env>` = `dev`):

| Role | `aud` | `sub` | `repository_id` | `repository_owner_id` | `ref` |
|---|---|---|---|---|---|
| `sis-dev-gha-plan` | `sts.amazonaws.com` | `<P>:pull_request` | `var.github_repo_id` | `var.github_owner_id` | `StringLike refs/pull/*/merge` |
| `sis-dev-gha-apply` | `sts.amazonaws.com` | `<P>:environment:dev` | same | same | `refs/heads/main` |
| `sis-dev-gha-deploy` | `sts.amazonaws.com` | `<P>:environment:dev` | same | same | `refs/heads/main` |

**Amended 2026-10-26 (Phase 2 security review, M1).** A `pull_request_target` run gets the same
`sub` (`...:pull_request`) as a `pull_request` run, with secrets and an ID token even for fork PRs. IAM
has no `event_name` condition key for GitHub (the GitHub tab of the IAM condition keys page lists actor,
actor_id, job_workflow_ref, repository, repository_id, repository_owner_id, workflow, ref, environment and
enterprise_id). So the plan role also requires `StringLike token.actions.githubusercontent.com:ref =
refs/pull/*/merge`: a `pull_request` run has ref `refs/pull/<N>/merge`, while a `pull_request_target` run
has the base ref (`refs/heads/main`) and is refused. The wildcard covers only the PR number; `sub`,
`repository_id` and `repository_owner_id` stay `StringEquals`. The user re-applies bootstrap by hand.

All three roles: `max_session_duration = 3600` (NFR-7), path `/`. Role names follow `<prefix>-<env>-<thing>`
from CODING_STANDARDS rather than the `<prefix>-gha-*` shorthand in the PLAN §5 diagram. That keeps the
account's environment visible in CloudTrail and keeps them outside the apply role's IAM scope (`sis-dev-ecs-*`).

### Name contract (Phase 3 must match)

| Thing | Name | ARN pattern the roles allow |
|---|---|---|
| ECS cluster | `sis-dev-cluster` | apply: `cluster/sis-dev-*` |
| ECS service | `sis-dev-app` | apply: `service/sis-dev-cluster/*`; deploy: `service/sis-dev-cluster/sis-dev-app` |
| Task definition family | `sis-dev-app` | apply: `task-definition/sis-dev-*:*`; deploy: `task-definition/sis-dev-app:*` |
| ECR repository | `sis-dev-app` | apply: `repository/sis-dev-*`; deploy: `repository/sis-dev-app` |
| Log group | `/ecs/sis-dev-app` | `log-group:/ecs/sis-dev-*` (and `:*`) |
| ALB / target groups | `sis-dev-alb` / `sis-dev-tg` (max 32 characters) | `loadbalancer/app/sis-dev-*/*`, `targetgroup/sis-dev-*/*`, `listener/app/sis-dev-*/*/*`, `listener-rule/app/sis-dev-*/*/*/*` |
| VPC, subnets, IGW, route table, security groups | names free; must carry B7 tags | ec2 ARNs in `ap-southeast-1` scoped by tag (B14) |
| Task execution role / task role | `sis-dev-ecs-exec` / `sis-dev-ecs-task` | `role/sis-dev-ecs-*`; PassRole only on these two |
| Secret shell | `sis/dev/app-api-key` | `secret:sis/dev/*` |
| ECS permissions boundary (bootstrap-owned) | `sis-dev-ecs-boundary` | not writable by any GitHub role |

`outputs.tf` exposes this as `resource_names` so Phase 3 can be checked against it.

### Permissions

| # | Decision |
|---|---|
| B14 | **EC2 scoping by tag.** EC2 IDs are random, so ARNs cannot be scoped by name. The apply role gets an explicit action list (no `ec2:*`, no `RunInstances`). (a) Create actions are allowed only on the new resource's type ARN (`vpc/*`, `internet-gateway/*`, `subnet/*`, `route-table/*`, `security-group/*`) when `aws:RequestTag/Project = ship-it-safely` and `aws:RequestTag/Env = dev`. Subnets, route tables and security groups also need their parent `vpc/*` to carry those tags (`aws:ResourceTag`). `AuthorizeSecurityGroupIngress`/`Egress` need the target `security-group/*` to carry the tags; the new `security-group-rule/*` is allowed without a condition, because an untagged rule from an inline block or `aws_security_group_rule` has no request tags and the group check is the gate. `ec2:CreateTags` is allowed only on those type ARNs and only with `ec2:CreateAction` set to one of the create actions. (b) Change and delete actions are allowed only when `aws:ResourceTag/Project` and `aws:ResourceTag/Env` match. Standalone security group rules (`aws_vpc_security_group_*_rule`) are changed and deleted by rule ID, so they must carry the `Project` and `Env` tags too (provider `default_tags` cover this). |
| B15 | **Permissions boundary for ECS roles.** Bootstrap creates the managed policy `sis-dev-ecs-boundary`, which allows only: `ecr:GetAuthorizationToken` on `*`; ECR pull actions on `repository/sis-dev-*`; `logs:CreateLogStream` and `logs:PutLogEvents` on `log-group:/ecs/sis-dev-*:*`; `secretsmanager:GetSecretValue` on `secret:sis/dev/*`. The apply role may create or change `role/sis-dev-ecs-*` only with `iam:PermissionsBoundary` equal to that policy ARN. It cannot delete the boundary or edit the policy. The module uses inline policies only, so `AttachRolePolicy` is not granted. |
| B16 | **Shared guardrail policy** `sis-dev-gha-guardrails` (customer managed), attached to all three roles. Explicit denies: (G1) `secretsmanager:GetSecretValue`, `BatchGetSecretValue`, `PutSecretValue`, `UpdateSecretVersionStage` on `*`. (G2) `ssm:GetParameter`, `GetParameters`, `GetParametersByPath`, `GetParameterHistory` on `*`. (G3) `sts:AssumeRole` on `*`, so no role chaining; this stops the apply session itself from using a rewritten trust (R1), not other principals. (G4) all IAM writes (`iam:Create*`, `Put*`, `Update*`, `Delete*`, `Attach*`, `Detach*`, `Tag*`, `Untag*`, `*PermissionsBoundary`, `*PolicyVersion`, `Add*`, `Remove*`) on `role/sis-dev-gha-*`, `policy/sis-dev-gha-*`, `policy/sis-dev-ecs-boundary` and `oidc-provider/*`. (G5) `s3:GetObject*`, `PutObject*`, `DeleteObject*` on `<bucket>/bootstrap/*`, which also keeps the budget email in bootstrap state away from CI. Action wildcards appear only in Deny statements, where they widen protection. |
| B17 | **Plan role** = AWS managed `ReadOnlyAccess` + guardrails + an inline policy. **Allow:** `s3:ListBucket` on the bucket with `StringLike s3:prefix` in `envs/dev/terraform.tfstate` or `env:/*` (the S3 backend lists the `env:/` workspace prefix); `s3:GetObject` on `envs/dev/terraform.tfstate`; `s3:GetObject`, `PutObject`, `DeleteObject` on `envs/dev/terraform.tfstate.tflock`. **Extra deny:** `s3:GetObject`, `s3:GetObjectVersion` with `NotResource` set to those two keys. `ReadOnlyAccess` includes `s3:Get*` across every bucket in the account, and this deny stops that. `ReadOnlyAccess` does not include `GetSecretValue` or `kms:Decrypt`, but it does include `ssm:Get*`, which G2 covers. |
| B18 | **Apply role** = guardrails + inline policy (table below). |
| B19 | **Deploy role** = guardrails + inline policy (table below). No state access. |
| B20 | Allow statements with `Resource = "*"` are permitted only for: `ec2:Describe*`, `elasticloadbalancing:Describe*`, `logs:DescribeLogGroups`, `ecs:DescribeTaskDefinition`, `ecs:DeregisterTaskDefinition`, `ecr:GetAuthorizationToken`. The AWS Service Reference lists no resource type for any of these. A test enforces this list (B24). CODING_STANDARDS records these as approved exceptions. |

**Apply role (`sis-dev-gha-apply`) inline policy**

| Sid | Actions | Resource | Condition |
|---|---|---|---|
| StateRW | `s3:ListBucket` | bucket | `StringLike s3:prefix` in `envs/dev/terraform.tfstate`, `env:/*` |
| | `s3:GetObject`, `s3:PutObject` | `<bucket>/envs/dev/terraform.tfstate` | |
| | `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` | `<bucket>/envs/dev/terraform.tfstate.tflock` | |
| Ec2Read | `ec2:Describe*` | `*` | (no resource-level support) |
| Ec2CreateTopLevelTagged | `ec2:CreateVpc`, `CreateInternetGateway` | `vpc/*`, `internet-gateway/*` | `aws:RequestTag/Project`, `aws:RequestTag/Env` |
| Ec2CreateChildTagged | `ec2:CreateSubnet`, `CreateRouteTable`, `CreateSecurityGroup` | `subnet/*`, `route-table/*`, `security-group/*` | `aws:RequestTag/Project`, `aws:RequestTag/Env` |
| Ec2CreateChildInTaggedVpc | same three | `vpc/*` | `aws:ResourceTag/Project`, `aws:ResourceTag/Env` |
| Ec2AuthorizeRulesOnTaggedGroup | `ec2:AuthorizeSecurityGroupIngress`, `AuthorizeSecurityGroupEgress` | `security-group/*` | `aws:ResourceTag/Project`, `aws:ResourceTag/Env` |
| Ec2AuthorizeRuleResource | same two | `security-group-rule/*` | none (the group statement gates it) |
| Ec2TagOnCreate | `ec2:CreateTags` | the six type ARNs above | `ec2:CreateAction` in the create and authorize actions |
| Ec2ManageTagged | `ec2:DeleteVpc`, `ModifyVpcAttribute`, `DeleteSubnet`, `ModifySubnetAttribute`, `AttachInternetGateway`, `DetachInternetGateway`, `DeleteInternetGateway`, `DeleteRouteTable`, `CreateRoute`, `ReplaceRoute`, `DeleteRoute`, `AssociateRouteTable`, `DisassociateRouteTable`, `DeleteSecurityGroup`, `RevokeSecurityGroupIngress`, `RevokeSecurityGroupEgress`, `ModifySecurityGroupRules`, `UpdateSecurityGroupRuleDescriptionsIngress`, `UpdateSecurityGroupRuleDescriptionsEgress`, `CreateTags`, `DeleteTags` | same | `aws:ResourceTag/Project`, `aws:ResourceTag/Env` |
| ElbRead | `elasticloadbalancing:Describe*` | `*` | |
| ElbManage | `CreateLoadBalancer`, `DeleteLoadBalancer`, `ModifyLoadBalancerAttributes`, `SetSecurityGroups`, `SetSubnets`, `CreateTargetGroup`, `DeleteTargetGroup`, `ModifyTargetGroup`, `ModifyTargetGroupAttributes`, `CreateListener`, `DeleteListener`, `ModifyListener`, `ModifyListenerAttributes`, `CreateRule`, `DeleteRule`, `ModifyRule`, `AddTags`, `RemoveTags` | the four `sis-dev-*` ELB ARN patterns | none (names in ARNs) |
| EcsCluster | `ecs:CreateCluster`, `DeleteCluster`, `DescribeClusters`, `UpdateCluster`, `UpdateClusterSettings`, `PutClusterCapacityProviders`, `TagResource`, `UntagResource`, `ListTagsForResource` | `cluster/sis-dev-*` | |
| EcsService | `ecs:CreateService`, `UpdateService`, `DeleteService`, `DescribeServices`, `TagResource`, `UntagResource`, `ListTagsForResource` | `service/sis-dev-cluster/*` | |
| EcsTaskDef | `ecs:RegisterTaskDefinition`, `TagResource`, `ListTagsForResource` | `task-definition/sis-dev-*:*` | `NumericLessThanEquals` `ecs:task-cpu` 512, `ecs:task-memory` 1024 (on Register, as a cost guard) |
| EcsTaskDefUnscoped | `ecs:DescribeTaskDefinition`, `ecs:DeregisterTaskDefinition` | `*` | (no resource-level support) |
| Ecr | `ecr:CreateRepository`, `DeleteRepository`, `DescribeRepositories`, `DescribeImages`, `PutImageScanningConfiguration`, `PutImageTagMutability`, `PutLifecyclePolicy`, `GetLifecyclePolicy`, `DeleteLifecyclePolicy`, `GetRepositoryPolicy`, `TagResource`, `UntagResource`, `ListTagsForResource` | `repository/sis-dev-*` | |
| Logs | `logs:CreateLogGroup`, `DeleteLogGroup`, `PutRetentionPolicy`, `DeleteRetentionPolicy`, `TagResource`, `UntagResource`, `TagLogGroup`, `ListTagsForResource`, `ListTagsLogGroup` | `log-group:/ecs/sis-dev-*` and `log-group:/ecs/sis-dev-*:*` | |
| LogsRead | `logs:DescribeLogGroups` | `*` | |
| SecretShell | `secretsmanager:CreateSecret`, `DeleteSecret`, `DescribeSecret`, `GetResourcePolicy`, `UpdateSecret`, `TagResource`, `UntagResource` | `secret:sis/dev/*` | (G1 denies reading values and `PutSecretValue`; `CreateSecret` and `UpdateSecret` can still set a value, see R1) |
| IamEcsRolesBounded | `iam:CreateRole`, `PutRolePolicy`, `DeleteRolePolicy`, `PutRolePermissionsBoundary`, `UpdateAssumeRolePolicy`, `DeleteRole` | `role/sis-dev-ecs-*` | `iam:PermissionsBoundary = arn:aws:iam::<acct>:policy/sis-dev-ecs-boundary` |
| IamEcsRolesRead | `iam:GetRole`, `GetRolePolicy`, `ListRolePolicies`, `ListAttachedRolePolicies`, `ListInstanceProfilesForRole`, `TagRole`, `UntagRole`, `UpdateRole`, `UpdateRoleDescription` | `role/sis-dev-ecs-*` | |
| PassEcsRoles | `iam:PassRole` | exactly `role/sis-dev-ecs-exec`, `role/sis-dev-ecs-task` | `iam:PassedToService = ecs-tasks.amazonaws.com` |
| ServiceLinkedRoles | `iam:CreateServiceLinkedRole` | `role/aws-service-role/ecs.amazonaws.com/*`, `role/aws-service-role/elasticloadbalancing.amazonaws.com/*` | `iam:AWSServiceName` in those two |
| DenyBoundaryRemoval (Deny) | `iam:DeleteRolePermissionsBoundary` | `*` | |

**Deploy role (`sis-dev-gha-deploy`) inline policy**

| Sid | Actions | Resource | Condition |
|---|---|---|---|
| EcrAuth | `ecr:GetAuthorizationToken` | `*` | (no resource-level support) |
| EcrPushOneRepo | `ecr:BatchCheckLayerAvailability`, `InitiateLayerUpload`, `UploadLayerPart`, `CompleteLayerUpload`, `PutImage`, `BatchGetImage`, `GetDownloadUrlForLayer`, `DescribeImages` | `repository/sis-dev-app` | |
| RegisterTaskDef | `ecs:RegisterTaskDefinition`, `ecs:TagResource` | `task-definition/sis-dev-app:*` | Register: `ecs:task-cpu <= 512`, `ecs:task-memory <= 1024`; Tag: `ecs:CreateAction = RegisterTaskDefinition` |
| DescribeTaskDef | `ecs:DescribeTaskDefinition` | `*` | (no resource-level support) |
| DeployOneService | `ecs:UpdateService`, `ecs:DescribeServices` | `service/sis-dev-cluster/sis-dev-app` | UpdateService: `ArnLike ecs:task-definition = task-definition/sis-dev-app:*` |
| PassTaskRoles | `iam:PassRole` | exactly `role/sis-dev-ecs-exec`, `role/sis-dev-ecs-task` | `iam:PassedToService = ecs-tasks.amazonaws.com` |
| DescribeAppSecretMetadata (added by ADR 0006 G14) | `secretsmanager:DescribeSecret` | `secret:sis/dev/app-api-key-??????` | (metadata only; G1 still denies value read and write) |

ECS condition key types (`ecs:task-cpu` and `ecs:task-memory` numeric, `ecs:task-definition` an ARN) come from
the official Service Reference JSON.

### Budget, outputs, tests

| # | Decision |
|---|---|
| B21 | `aws_budgets_budget` named `sis-dev-monthly-cost`: `budget_type = "COST"`, `limit_amount = "20"`, `limit_unit = "USD"`, `time_unit = "MONTHLY"`. One `notification` block: `GREATER_THAN`, threshold `80`, `PERCENTAGE`, `ACTUAL`, `subscriber_email_addresses = [var.budget_email]`. `account_id` is omitted, so it uses the caller's account. |
| B22 | Outputs: `state_bucket_name`, `plan_role_arn`, `apply_role_arn`, `deploy_role_arn`, `oidc_provider_arn`, `ecs_permissions_boundary_arn`, `oidc_sub_prefix`, `aws_region`, `resource_names` (the name contract). None are sensitive. They contain the account ID, which is not a secret, but the user copies them into GitHub variables only. |
| B23 | GitHub variables (NFR-1, never secrets). Amended by ADR 0003 C10: `AWS_PLAN_ROLE_ARN_DEV` is a repo secret, so the account ID stays out of public logs. Environment `dev`: `AWS_REGION`, `AWS_APPLY_ROLE_ARN`, `AWS_DEPLOY_ROLE_ARN`, `TF_STATE_BUCKET`, `AWS_ACCOUNT_ID`. Repo level, because the PR plan job has no environment: `AWS_PLAN_ROLE_ARN_DEV`, `TF_STATE_BUCKET_DEV`, `AWS_ACCOUNT_ID_DEV`, `AWS_REGION`. The bucket and account variables are first used in Phase 3 (`-backend-config` and `TF_VAR_aws_account_id`, D2). Environment `dev` gets: required reviewer = the user, `prevent_self_review = false` (solo lab), and a custom deployment branch policy allowing only `main`. |
| B24 | **Tests**: `terraform test` with `mock_provider "aws"` (D12). Use `mock_data "aws_caller_identity"` with `account_id = "123456789012"`, `mock_data "aws_partition"` with `partition = "aws"`, and `mock_data "aws_iam_policy_document"` with `json = "{}"`. Assertions read locals and the `statement` arguments of the policy documents. Mocks keep configured arguments; only computed ones such as `json` are faked. Use `command = plan` and `override_during = plan`. |
| B25 | **Account-ID commit guard** (widened by ADR 0003 C15 and the 2026-10-26 M2 decision: it now scans every text file except the provider lock file, with alphanumeric boundaries, and allows `123456789012`, `111111111111` and `222222222222`; the original scope follows): a local `pygrep` hook in `.pre-commit-config.yaml` rejects a bare 12-digit number in `^infra/.*\.(tf|hcl|tfvars\.example)$`. It excludes `.terraform.lock.hcl` and allows the AWS doc example `123456789012`. Regex: `(?<![0-9])(?!123456789012)[0-9]{12}(?![0-9])`. gitleaks does not look for account IDs. |

## Alternatives considered

- **Global bucket name with a random suffix (`bucket_prefix`).** No account ID in the name, but the name can
  be squatted after deletion, and the backend config then needs an unpredictable value. Rejected in favor of
  the account-regional namespace, which AWS now recommends.
- **SSE-KMS with a customer managed key.** Better audit, but about 1 USD a month, `kms:*` on every role, and a
  key policy to maintain. Rejected for the lab (B9).
- **DynamoDB locking.** Deprecated since Terraform 1.11. Rejected.
- **Committing a backend `bucket` value, or the account ID in a committed tfvars.** Breaks D2. Rejected.
- **A two-commit bootstrap (no backend block first, then add it).** Works, but needs a second PR just for
  migration. The gitignored override file does it in one PR.
- **The old name-based `sub` (`repo:O/R:...`) only.** Names can be recycled after a rename or deletion. Kept
  only as a fallback toggle (`github_immutable_subject = false`).
- **`StringLike` on `sub` with `repo:O/R:*`.** Too broad: any branch or event could assume any role. Rejected.
- **Pinning `job_workflow_ref` to separate apply from deploy.** AWS documents it for reusable workflows only.
  Revisit if the workflows become reusable (see R2).
- **A custom read-only policy instead of `ReadOnlyAccess` for plan.** Tighter, but FR-3 names
  `ReadOnlyAccess`, and a hand-written list breaks whenever Terraform reads a new attribute. Kept
  `ReadOnlyAccess` and added targeted denies (B16, B17).
- **Attaching `ReadOnlyAccess` to the apply role for refresh reads.** FR-4 says "only the services in
  modules/app-ecs". Rejected in favor of per-service read actions.
- **`AmazonECSTaskExecutionRolePolicy` (AWS managed) on the execution role.** It allows ECR and Logs on `*`.
  Rejected: inline policies under the boundary.
- **A CloudTrail trail in Phase 1.** CloudTrail Event history already keeps 90 days of management events,
  including `AssumeRoleWithWebIdentity`, at no cost. A trail adds S3 storage and is only needed for the stretch
  metric filter in NFR-7. Deferred (Q2).
- **A FORECASTED 100% budget alert.** Not required by FR-2. Optional (Q3).

## Consequences

- **Phase 3 is bound to the name contract and tags.** Any other name or missing tag gives AccessDenied in the
  first CI apply. Missing actions surface the same way, and the fix is a bootstrap change that the user applies
  with admin. Expect one iteration at most. The reviewer should diff Phase 3 names against `resource_names`.
- **Phase 3 task definition ownership.** Terraform should own the first task definition and use
  `lifecycle { ignore_changes = [task_definition] }` on the service, so deploy-role revisions are not reverted
  by apply.
- **Phases 2 to 4.** Set `mask-aws-account-id: true` on `aws-actions/configure-aws-credentials`. The account
  ID is not masked by default, and Actions logs on a public repo are public. GitHub variables are not masked
  either.
- **Fork and Dependabot PRs.** For `pull_request` runs from forks, GitHub turns write permissions into read, so
  `id-token: write` is unavailable and those runs cannot assume the plan role. Dependabot PRs likely behave the
  same; Phase 6 should verify and skip the plan job for them. Never use `pull_request_target` with
  `id-token: write`.
- **Residual risk R1.** The apply role can write the trust policy of `sis-dev-ecs-*` roles. G3 (deny
  `sts:AssumeRole`) stops it from assuming them itself. B15 caps what those roles can do. A malicious trust
  change pointing at an outside principal would still expose `GetSecretValue` on `sis/dev/*`. That principal
  can be another GitHub repo federated through the same OIDC provider, so no AWS account is needed. The apply
  role can also set a secret value through `CreateSecret`/`UpdateSecret` (no confidentiality loss) and raise
  `MaxSessionDuration` on those roles with `iam:UpdateRole`. Mitigations: PR review of the plan, environment
  approval, and the `ref = main` pin. Accepted for the lab.
- **Residual risk R2.** Apply and deploy share the same trust (`environment:dev` on `main`), as FR-4 and FR-5
  require. Any approved job in `dev` can pick either ARN. Possible fixes later: separate environments (`dev`
  and `dev-deploy`) or reusable workflows with `job_workflow_ref`.
- **Residual risk R3.** Deploy can run any image with the execution role, and the execution role injects the
  app secret. This is inherent to CD and is gated by environment approval.
- **Budget email** lives in gitignored `dev.tfvars` and in bootstrap state (encrypted, versioned, and denied to
  CI by G5). `ReadOnlyAccess` includes Budgets read, so the plan role could see the subscriber email through
  the Budgets API. Low impact.
- **Docs follow-up for the orchestrator (D14):** update CODING_STANDARDS (`required_version >= 1.11`, the B20
  wildcard exceptions, Deny wildcards allowed, role naming), and the README setup section.
- **Teardown (PLAN §9).** Copy state back to local (`terraform init -migrate-state` with the override file),
  empty all object versions, then `terraform destroy -var-file=accounts/dev.tfvars`. `force_destroy = false`
  stops an accidental delete while objects remain. The account-regional name can be re-created only by this
  account.

## Checkpoint commands (user runs; Claude never does, NFR-9)

Placeholders: `<DEV_ACCOUNT_ID>` and `<BUDGET_EMAIL>` (from `CLAUDE.local.md`).

**0. Inputs and pre-checks**

```bash
REPO=trungleviet-agilityio/ship-it-safely
cd infra/terraform/bootstrap

# Immutable IDs for dev.tfvars
gh api "repos/${REPO}" --jq '{repo_id: .id, owner_id: .owner.id}'
# Must show use_immutable_subject: true
gh api "repos/${REPO}/actions/oidc/customization/sub"

cp accounts/dev.tfvars.example accounts/dev.tfvars
# Edit accounts/dev.tfvars: aws_account_id = "<DEV_ACCOUNT_ID>", budget_email = "<BUDGET_EMAIL>",
# github_owner_id = "<owner_id>", github_repo_id = "<repo_id>"

aws sso login --profile sis-dev-admin
export AWS_PROFILE=sis-dev-admin
aws sts get-caller-identity --query Account --output text      # must print <DEV_ACCOUNT_ID>
aws iam list-open-id-connect-providers                          # if GitHub's provider already exists, tell Claude (it must be imported)
```

**1. First apply on local state**

```bash
printf 'terraform {\n  backend "local" {}\n}\n' > backend_override.tf
terraform init
terraform plan -var-file=accounts/dev.tfvars -out=bootstrap.tfplan
terraform apply bootstrap.tfplan
terraform output oidc_sub_prefix        # must equal sub_claim_prefix from step 0
```

**2. Migrate state into the bucket**

```bash
BUCKET="$(terraform output -raw state_bucket_name)"
rm backend_override.tf
terraform init -migrate-state -backend-config="bucket=${BUCKET}"     # answer yes
terraform plan -var-file=accounts/dev.tfvars                          # expect: No changes
aws s3 ls "s3://${BUCKET}/bootstrap/"                                 # terraform.tfstate present
rm -f terraform.tfstate terraform.tfstate.backup bootstrap.tfplan     # only after the two checks above pass
# Later runs: terraform init -backend-config="bucket=sis-dev-tfstate-<DEV_ACCOUNT_ID>-ap-southeast-1-an"
```

**3. GitHub environment `dev` and variables**

```bash
MY_ID="$(gh api user --jq .id)"
gh api -X PUT "repos/${REPO}/environments/dev" --input - <<EOF
{"reviewers":[{"type":"User","id":${MY_ID}}],"prevent_self_review":false,
 "deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
EOF
gh api -X POST "repos/${REPO}/environments/dev/deployment-branch-policies" -f name=main -f type=branch

gh variable set AWS_REGION          --env dev --repo "$REPO" --body ap-southeast-1
gh variable set AWS_APPLY_ROLE_ARN  --env dev --repo "$REPO" --body "$(terraform output -raw apply_role_arn)"
gh variable set AWS_DEPLOY_ROLE_ARN --env dev --repo "$REPO" --body "$(terraform output -raw deploy_role_arn)"
gh variable set TF_STATE_BUCKET     --env dev --repo "$REPO" --body "${BUCKET}"
gh variable set AWS_ACCOUNT_ID      --env dev --repo "$REPO" --body "<DEV_ACCOUNT_ID>"

gh variable set AWS_REGION            --repo "$REPO" --body ap-southeast-1
# Superseded by ADR 0003 C10: AWS_PLAN_ROLE_ARN_DEV is a repo secret, not a variable
terraform output -raw plan_role_arn | gh secret set AWS_PLAN_ROLE_ARN_DEV --repo "$REPO"
gh variable set TF_STATE_BUCKET_DEV   --repo "$REPO" --body "${BUCKET}"
gh variable set AWS_ACCOUNT_ID_DEV    --repo "$REPO" --body "<DEV_ACCOUNT_ID>"
```

**4. Spot checks (read-only)**

```bash
aws iam get-role --role-name sis-dev-gha-plan  --query 'Role.[MaxSessionDuration,AssumeRolePolicyDocument]'
aws iam get-role --role-name sis-dev-gha-apply --query 'Role.AssumeRolePolicyDocument'
aws s3api get-bucket-policy --bucket "${BUCKET}"
aws s3api get-public-access-block --bucket "${BUCKET}"
aws budgets describe-budgets --account-id <DEV_ACCOUNT_ID> --query 'Budgets[].BudgetName'
```

## Open questions (resolved)

Resolved while drafting: the dev machine is `darwin_arm64` (B3), and the repo was created on 2026-10-22 with
`use_immutable_subject = true` (B12).

Answered by the user on 2026-10-22:

- **Q1.** The dev account has no GitHub OIDC provider yet, so no import is needed. The step 0 check stays as a
  safety net.
- **Q2.** CloudTrail: rely on the free Event history now; add a trail with the metric filter in the stretch
  phase (NFR-7).
- **Q3.** No FORECASTED budget notification; only the required 80% ACTUAL one (B21).
- **Q4.** Residual risks R1 to R3 are accepted for the lab.

## Sources

- Terraform releases: https://releases.hashicorp.com/terraform/
- Terraform 1.11 changelog (S3 locking GA): https://raw.githubusercontent.com/hashicorp/terraform/v1.11/CHANGELOG.md
- AWS provider versions: https://registry.terraform.io/v2/providers/hashicorp/aws?include=provider-versions
- AWS provider v6.37.0 (`bucket_namespace`): https://github.com/hashicorp/terraform-provider-aws/releases/tag/v6.37.0
- `aws_s3_bucket`: https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/main/website/docs/r/s3_bucket.html.markdown
- `aws_s3_bucket_server_side_encryption_configuration`: https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/main/website/docs/r/s3_bucket_server_side_encryption_configuration.html.markdown
- `aws_iam_openid_connect_provider`: https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/main/website/docs/r/iam_openid_connect_provider.html.markdown
- `aws_budgets_budget`: https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/main/website/docs/r/budgets_budget.html.markdown
- S3 backend: https://developer.hashicorp.com/terraform/language/backend/s3
- Backend configuration (partial config, migration): https://developer.hashicorp.com/terraform/language/backend
- Override files: https://developer.hashicorp.com/terraform/language/files/override
- Terraform tests: https://developer.hashicorp.com/terraform/language/tests
- Terraform test mocking: https://developer.hashicorp.com/terraform/language/tests/mocking
- S3 account regional namespaces: https://docs.aws.amazon.com/AmazonS3/latest/userguide/gpbucketnamespaces.html
- S3 security best practices: https://docs.aws.amazon.com/AmazonS3/latest/userguide/security-best-practices.html
- S3 Object Ownership: https://docs.aws.amazon.com/AmazonS3/latest/userguide/about-object-ownership.html
- SSE-KMS and default encryption: https://docs.aws.amazon.com/AmazonS3/latest/userguide/UsingKMSEncryption.html
- IAM role for OIDC / GitHub: https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_create_for-idp_oidc.html
- IAM OIDC condition keys (GitHub tab): https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_iam-condition-keys.html
- OIDC thumbprints: https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc_verify-thumbprint.html
- Permissions boundaries: https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html
- EC2 tag-on-create: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/supported-iam-actions-tagging.html
- ReadOnlyAccess managed policy: https://docs.aws.amazon.com/aws-managed-policy/latest/reference/ReadOnlyAccess.html
- Service Reference JSON: https://servicereference.us-east-1.amazonaws.com/v1/ecs/ecs.json, https://servicereference.us-east-1.amazonaws.com/v1/ecr/ecr.json, https://servicereference.us-east-1.amazonaws.com/v1/iam/iam.json, https://servicereference.us-east-1.amazonaws.com/v1/secretsmanager/secretsmanager.json, https://servicereference.us-east-1.amazonaws.com/v1/elasticloadbalancing/elasticloadbalancing.json, https://servicereference.us-east-1.amazonaws.com/v1/logs/logs.json
- GitHub OIDC reference: https://docs.github.com/en/actions/reference/security/oidc
- GitHub immutable subject changelog: https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens
- GitHub REST OIDC: https://docs.github.com/en/rest/actions/oidc
- GitHub REST environments: https://docs.github.com/en/rest/deployments/environments
- GitHub REST deployment branch policies: https://docs.github.com/en/rest/deployments/branch-policies
- Workflow syntax (fork PR permissions): https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax
- `gh variable set`: https://cli.github.com/manual/gh_variable_set
- configure-aws-credentials README: https://raw.githubusercontent.com/aws-actions/configure-aws-credentials/main/README.md
- amazon-ecs-deploy-task-definition README: https://raw.githubusercontent.com/aws-actions/amazon-ecs-deploy-task-definition/master/README.md
- tflint-ruleset-aws releases (0.49.0 is current, matching `.tflint.hcl`): https://github.com/terraform-linters/tflint-ruleset-aws/releases

## Build briefs

### devops-engineer (owns `infra/**`, `.github/**`, `.tflint.hcl`, `.pre-commit-config.yaml`)

**Goal:** implement B1 to B25 in `infra/terraform/bootstrap/`. No workflows this phase, and do not touch
`.github/**`. Do not edit `README.md`, `docs/**` or `.gitignore`; the existing ignore rules already cover
`accounts/*.tfvars` and `*_override.tf`.

**Files to create**

- `infra/terraform/bootstrap/`: `versions.tf`, `providers.tf`, `backend.tf`, `variables.tf`, `locals.tf`,
  `data.tf`, `state.tf`, `oidc.tf`, `iam_guardrails.tf`, `iam_ecs_boundary.tf`, `iam_plan.tf`, `iam_apply.tf`,
  `iam_deploy.tf`, `budget.tf`, `outputs.tf`, `.terraform.lock.hcl`.
- `infra/terraform/bootstrap/accounts/dev.tfvars.example` with placeholders only (prefer `"<DEV_ACCOUNT_ID>"`
  strings). Delete `accounts/.gitkeep`.
- `infra/terraform/bootstrap/tests/`: `state.tftest.hcl`, `trust.tftest.hcl`, `iam.tftest.hcl`,
  `budget.tftest.hcl`, `validation.tftest.hcl`.
- `.pre-commit-config.yaml`: add the B25 `pygrep` local hook.

**Rules**

- Build every policy with `data "aws_iam_policy_document"`.
- Keep subjects, ARNs and names in `locals.tf` so tests can assert them.
- Build every ARN from `data.aws_caller_identity.current.account_id` and
  `data.aws_partition.current.partition`. Never type an account ID, and use only `123456789012` in tests.
- Use `var.aws_region` instead of the `aws_region` data source.

**Tests to write first (red, then green)**

1. `trust.tftest.hcl`:
   - The `sub` for plan equals `repo:trungleviet-agilityio@111/ship-it-safely@222:pull_request` (test vars
     `github_owner_id = "111"`, `github_repo_id = "222"`). Apply and deploy end with `:environment:dev`.
   - Every trust condition uses `StringEquals`. `aud = sts.amazonaws.com`. `repository_id` and
     `repository_owner_id` are present on all three roles.
   - `ref = refs/heads/main` on apply and deploy only.
   - No `sub` value contains `*`. All three roles have `max_session_duration == 3600`.
   - With `github_immutable_subject = false`, the prefix is `repo:trungleviet-agilityio/ship-it-safely`.
2. `state.tftest.hcl`:
   - The bucket is named `sis-dev-tfstate-123456789012-ap-southeast-1-an`, with
     `bucket_namespace == "account-regional"` and `force_destroy == false`.
   - Versioning is `Enabled`. SSE is `AES256` with `SSE-C` blocked. All four public access block flags are
     true. Ownership is `BucketOwnerEnforced`.
   - The bucket policy has a Deny on `aws:SecureTransport = false`.
   - Lifecycle sets 90 days for noncurrent versions, keeps 10, and aborts multipart uploads after 7 days.
3. `iam.tftest.hcl`:
   - The guardrail Deny includes `secretsmanager:GetSecretValue`, `BatchGetSecretValue`, `PutSecretValue`,
     `ssm:GetParameter*` and `sts:AssumeRole`, and is attached to all three roles.
   - Plan has `ReadOnlyAccess` attached and the `NotResource` S3 deny.
   - Every `iam:PassRole` statement lists exactly the `sis-dev-ecs-exec` and `sis-dev-ecs-task` ARNs, with
     `iam:PassedToService = ecs-tasks.amazonaws.com`.
   - Deploy's ECR resources are exactly `[repository/sis-dev-app]`.
   - Apply's IAM create statements require `iam:PermissionsBoundary` equal to the boundary ARN.
   - No Allow statement has `actions = ["*"]`. Any Allow with `resources = ["*"]` uses only actions from the
     B20 allowlist.
4. `budget.tftest.hcl`: limit `"20"` USD `MONTHLY` `COST`; notification `GREATER_THAN` 80 `PERCENTAGE`
   `ACTUAL` sent to `var.budget_email`.
5. `validation.tftest.hcl` (`expect_failures`): 11-digit account ID, `env = "qa"`, bad email, non-numeric
   GitHub IDs.

All tests use `mock_provider "aws"` with `override_during = plan` and the `mock_data` defaults from B24, and
run with `command = plan`.

**Checks that define done** (run in `infra/terraform/bootstrap` unless noted)

- `terraform fmt -check -recursive infra/terraform` (from the repo root)
- `terraform init -backend=false && terraform validate`
- `terraform test`: all pass
- `tflint --init && tflint --recursive` (from the repo root)
- `terraform providers lock -platform=linux_amd64 -platform=darwin_arm64`: the lock file is committed with both
- `pre-commit run --all-files`: green, including the new account-ID guard
- `git status` shows no `*.tfvars` (only `.example`), no state, no plan files
- Commit: `infra(bootstrap): state bucket, oidc provider, gha roles and budget`
- Hand back the checkpoint commands from this ADR unchanged. Never run `terraform apply`, `import`, or any
  `state` subcommand (NFR-9).

### backend-dev

Not needed in Phase 1.
