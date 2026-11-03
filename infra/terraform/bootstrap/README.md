# bootstrap

Runs **once per AWS account**, locally, with your SSO admin login. It creates what GitHub Actions and
Terraform need before any app infrastructure exists. Design and decisions: [ADR 0002](../../../docs/adr/0002-phase-1-bootstrap-dev.md).

![Bootstrap diagram](../../../docs/diagrams/bootstrap.drawio.png)

| Resource | Name | Notes |
|---|---|---|
| State bucket | `sis-dev-tfstate-<account_id>-ap-southeast-1-an` | Account-regional namespace, versioned, SSE-S3, public access blocked, TLS only |
| GitHub OIDC provider | `token.actions.githubusercontent.com` | Audience `sts.amazonaws.com` |
| Plan role | `sis-dev-gha-plan` | PR jobs only; `ReadOnlyAccess` + `envs/dev` state read + lock file |
| Apply role | `sis-dev-gha-apply` | `environment: dev` on `main`; only the `sis-dev-*` resources of `modules/app-ecs` |
| Deploy role | `sis-dev-gha-deploy` | `environment: dev` on `main`; one ECR repo, one ECS service; may describe (not read) the app secret, so the deploy preflight can check it has a value |
| ECS role boundary | `sis-dev-ecs-boundary` | Every ECS role the apply role creates must carry it |
| Guardrails | `sis-dev-gha-guardrails` | On all three roles: deny secret values, SSM parameters, role chaining, bootstrap state, and any change to the audit trail, alert rule, alert topic and trail bucket |
| Trail | `sis-dev-trail` | Multi-region, management events only, log file validation. No CloudWatch Logs, KMS or data events. Skipped with `create_trail = false` |
| Trail bucket | `sis-dev-cloudtrail-<account_id>-ap-southeast-1-an` | Account-regional namespace, SSE-S3, public access blocked, TLS only, 30-day expiry, `force_destroy = true` |
| Alert rule | `sis-dev-oidc-unexpected` | Fires on `AssumeRoleWithWebIdentity` that is refused (`errorCode`) or succeeds with a `sub` outside the trust |
| Alert topic | `sis-dev-security-alerts` | Email subscription to `budget_email`; confirm it once |
| Budget | `sis-dev-monthly-cost` | 20 USD/month, email at 80% actual |

## Trust conditions

All `StringEquals`, except one `StringLike` on the plan role's `ref` (the only wildcard in any trust policy, and
it covers only the PR number):

| Role | `sub` | `ref` | `job_workflow_ref` | Also checked |
|---|---|---|---|---|
| plan | `repo:OWNER@OWNER_ID/REPO@REPO_ID:pull_request` | `StringLike refs/pull/*/merge` | not pinned (a PR controls its own workflow file) | `aud`, `repository_id`, `repository_owner_id` |
| apply | `repo:OWNER@OWNER_ID/REPO@REPO_ID:environment:<env>` | `StringEquals refs/heads/main` | `OWNER/REPO/.github/workflows/terraform-iac.yml@refs/heads/main` and `.../terraform-destroy.yml@refs/heads/main` | the same |
| deploy | `repo:OWNER@OWNER_ID/REPO@REPO_ID:environment:<env>` | `StringEquals refs/heads/main` | `OWNER/REPO/.github/workflows/app-deploy.yml@refs/heads/main` in the build env (dev); `.../app-promote.yml@refs/heads/main` when `promotion_source_account_id` is set (prod) | the same |

`job_workflow_ref` is a documented IAM condition key. It pins the workflow file path, which a `name:` cannot do:
any merged file can copy a name. A missing or different claim fails closed (AccessDenied). The files are a
contract (`workflow_files` local, `deploy_workflow_file` output): `terraform-iac.yml` and `terraform-destroy.yml` for
apply, `app-deploy.yml` for deploy in dev and `app-promote.yml` in prod (ADR 0008 P7). A promoted env's deploy role
may also pull, and only pull, from the one source repository `sis-<promotion_source_env>-app` (P9). Renaming one needs a bootstrap re-apply. `repo-guard.yml` and `oidc-smoke-test.yml` are never listed.
The match is case sensitive: `github_owner` and `github_repo` in the tfvars must use GitHub's canonical spelling
(checkpoint step A0 reads the real claim and catches a mismatch).

All three roles also require `StringEquals aws:RequestedRegion = <aws_region>`. The key is always in the request
context, and calls to the global STS endpoint carry us-east-1, so those are refused. This keeps every successful
assumption in the region the alert rule watches. A refused probe in another region is not alerted: accepted, it
grants nothing.

IAM has no `event_name` condition key for GitHub OIDC. A `pull_request` run has ref `refs/pull/<N>/merge`; a
`pull_request_target` run has the base ref `refs/heads/main`, so the plan role refuses it even though its `sub`
matches.

The `sub` uses GitHub's immutable format with numeric IDs, so a renamed or re-created repo with the same name
cannot assume the roles. The PR plan job must not set `environment:`, or its `sub` stops being `pull_request`.

## Security alerts

`monitoring.tf` creates a trail and an EventBridge rule (not a CloudWatch metric filter, ADR 0007 S8), about
0 USD a month: the first copy of management events is free, EventBridge ingests them for free, and nothing is
sent to CloudWatch Logs. `AssumeRoleWithWebIdentity` is logged as a read-only event, so the rule opts in with
`ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS`. It emails `budget_email` when:

- a call is refused (any `errorCode`: wrong `sub`, `ref`, `job_workflow_ref`, or a session longer than the cap);
- a call succeeds with a `sub` other than the trusted ones (a trust mistake).

The email is a few plain lines, not the raw event: an input transformer on the target picks the time and region,
the error code (blank on a success, which means the trust let in an unexpected subject), the role, the `sub`, the
session name and the source IP. The full event stays in CloudTrail event history.

The negative tests in `oidc-smoke-test` raise these alerts on purpose. If the account already has a trail, set
`create_trail = false` so management events are not paid for twice; the rule and topic are still created.
The rule is regional: STS calls through the global endpoint are logged in us-east-1 and do not reach it. The
trust refuses them (`aws:RequestedRegion`), so no success can hide there.

## Name contract

The apply and deploy roles are scoped by name and tag before `envs/dev` exists, so `envs/dev` must use the
names in the `resource_names` output and the provider `default_tags` (`Project`, `Env`, `ManagedBy`).
Security group rules must be standalone `aws_vpc_security_group_ingress_rule` / `egress_rule` resources, so
they carry the tags the apply role checks.

## Inputs

`accounts/dev.tfvars` is gitignored: copy `accounts/dev.tfvars.example` and fill in the account ID, budget
email and the two GitHub IDs. No account ID is committed (ADR 0001, D2); a pre-commit hook rejects a bare
12-digit number in every text file except the provider lock file (`.terraform.lock.hcl`).

## Run it (you, never Claude: NFR-9)

1. Fill in `dev.tfvars`, `aws sso login --profile sis-dev-admin`, and check that
   `aws sts get-caller-identity` shows the dev account.
2. First apply on local state, using a gitignored `backend_override.tf` with `backend "local" {}`.
3. Delete the override and move state into the bucket:
   `terraform init -migrate-state -backend-config="bucket=<state_bucket_name>"`. A second plan shows no changes.
4. Create GitHub environment `dev` (you as required reviewer, `main` only) and configure the pipelines from the
   outputs. There is no state bucket setting: the workflows derive the bucket name from the environment, the account
   ID and the region (`scripts/tf/init.sh`).
   - Repo variable: `AWS_REGION`.
   - Environment secrets, the same names in every environment: `AWS_ACCOUNT_ID`, `AWS_APPLY_ROLE_ARN`,
     `AWS_DEPLOY_ROLE_ARN` and `ALB_INGRESS_CIDRS`. The apply fails while `ALB_INGRESS_CIDRS` is empty: set a JSON
     list of CIDRs, or `["0.0.0.0/0"]` to open the ALB on purpose.
   - Repo secrets for the PR plan, one set per environment: `AWS_ACCOUNT_ID_<ENV>`, `AWS_PLAN_ROLE_ARN_<ENV>` and
     `ALB_INGRESS_CIDRS_<ENV>` (optional there; unset means open) (ADR 0003, C10).

   Set a role ARN from the outputs with, for example,
   `terraform output -raw plan_role_arn | gh secret set AWS_PLAN_ROLE_ARN_DEV`. There are no access keys (NFR-1).

The exact commands are in [ADR 0002](../../../docs/adr/0002-phase-1-bootstrap-dev.md#checkpoint-commands-user-runs-claude-never-does-nfr-9).
Later inits pass the same `-backend-config="bucket=..."`.

Done by hand outside Terraform (once per account): S3 Block Public Access at the account level
(`aws s3control put-public-access-block`, all four flags true).

## Teardown

After every `envs/*` is destroyed: migrate state back to local with the override file, empty every object
version in the bucket, then `terraform destroy -var-file=accounts/dev.tfvars`. The bucket has
`force_destroy = false`, so a non-empty bucket stops the destroy.

## Tests

`terraform test` with `mock_provider` (offline, no AWS) covers trust conditions, the state bucket, IAM scoping,
the trail, alert rule and topic, the budget and input validation. Run `make tf-check` from the repo root.

## Reference

Generated by `terraform-docs` (`make docs`); do not edit between the markers.

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
| [aws_budgets_budget.monthly](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/budgets_budget) | resource |
| [aws_cloudtrail.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudtrail) | resource |
| [aws_cloudwatch_event_rule.oidc_unexpected](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.security_alerts](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_iam_openid_connect_provider.github](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_openid_connect_provider) | resource |
| [aws_iam_policy.ecs_boundary](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.guardrails](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.apply](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.deploy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.plan](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.apply](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.deploy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.plan](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.guardrails](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.plan_read_only](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_s3_bucket.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket.trail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_lifecycle_configuration.trail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_ownership_controls.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_ownership_controls.trail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_policy.trail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_public_access_block.trail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.trail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_sns_topic.security_alerts](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic) | resource |
| [aws_sns_topic_policy.security_alerts](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_policy) | resource |
| [aws_sns_topic_subscription.security_email](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_subscription) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| aws_account_id | Target AWS account ID. Comes from the gitignored accounts/dev.tfvars or TF_VAR_aws_account_id. | `string` | n/a | yes |
| budget_email | Address that receives the budget alert. | `string` | n/a | yes |
| github_owner_id | Immutable numeric ID of the GitHub owner (gh api repos/OWNER/REPO --jq .owner.id). | `string` | n/a | yes |
| github_repo_id | Immutable numeric ID of the GitHub repository (gh api repos/OWNER/REPO --jq .id). | `string` | n/a | yes |
| aws_region | AWS region for every resource. | `string` | `"ap-southeast-1"` | no |
| budget_alert_threshold_percent | Percentage of the budget at which the actual-cost alert fires. | `number` | `80` | no |
| budget_limit_usd | Monthly cost budget in USD. | `number` | `20` | no |
| create_trail | Create the CloudTrail trail and its bucket. Set false when the account already has a trail, so management events are not paid for twice. The alert rule is created either way. | `bool` | `true` | no |
| env | Environment name. | `string` | `"dev"` | no |
| github_immutable_subject | Use the OIDC sub format with immutable IDs. Set false only to fall back to name-based subjects. | `bool` | `true` | no |
| github_owner | GitHub user or organization that owns the repository. | `string` | `"trungleviet-agilityio"` | no |
| github_repo | GitHub repository name. | `string` | `"ship-it-safely"` | no |
| prefix | Name prefix for every resource. | `string` | `"sis"` | no |
| promotion_source_account_id | Account that builds the images this environment promotes (ADR 0008 P9). Null for the build environment (dev). Set in a promoted environment (prod): its deploy role may then pull from the source repository, and it trusts app-promote.yml instead of app-deploy.yml (P7). | `string` | `null` | no |
| promotion_source_env | Environment name of the promotion source; names its repository <prefix>-<env>-app. | `string` | `"dev"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| apply_role_arn | Role for apply jobs in this environment. |
| aws_region | Region of every resource. |
| deploy_role_arn | Role for deploy jobs in this environment. |
| deploy_workflow_file | Workflow file the deploy role trusts (app-deploy.yml in the build env, app-promote.yml in a promoted env). |
| ecs_permissions_boundary_arn | Boundary that every ECS task and execution role must carry. |
| oidc_provider_arn | GitHub OIDC provider. |
| oidc_sub_prefix | Must equal sub_claim_prefix reported by the GitHub OIDC API. |
| plan_role_arn | Role for pull_request plan jobs. |
| resource_names | Name contract that envs/dev must follow (ADR 0002). |
| security_alerts_topic_name | SNS topic that receives unexpected GitHub OIDC assumption alerts. Confirm the email subscription once. |
| state_bucket_name | Terraform state bucket. |
| workflow_files | Workflow files the apply and deploy roles trust through job_workflow_ref. Each must exist under .github/workflows/. |
<!-- END_TF_DOCS -->
