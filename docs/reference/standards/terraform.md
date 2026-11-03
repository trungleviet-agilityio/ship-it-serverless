# Terraform standards

Infrastructure as code under `infra/terraform/`. Part of the [standards index](README.md); anything a linter enforces is not repeated.

## Layout

- Each root and module has `versions.tf` (`required_version = ">= 1.11, < 2.0"`, since `use_lockfile` is GA
  from 1.11; providers pinned with `~>`),
  `variables.tf`, `outputs.tf`, and resource files split by concern (`oidc.tf`, `iam_plan.tf`).
- Environments differ only through `terraform.tfvars` (FR-6). Shared logic lives in
  `modules/app-lambda` (ADR 0012).
- Roots (`bootstrap/`, `envs/<env>/`) own `providers.tf`, the partial `backend.tf` and their inputs.
  `envs/<env>` stays thin: one `module` call plus variables and outputs. Modules declare
  `required_providers` but never a `provider` or `backend` block.

## READMEs (ADR 0001, D16)

- Every root and module has a `README.md`. Hand-write what the tables cannot say: purpose, what it
  creates, how to run it (or a usage block for a module), constraints such as name contracts, and
  teardown.
- End it with an empty `<!-- BEGIN_TF_DOCS -->` / `<!-- END_TF_DOCS -->` pair; the `terraform_docs`
  hook fills it from `.terraform-docs.yml` (`make docs`). Never edit between the markers.
- `make tf-check` fails when a directory with `.tf` files has no README or no markers.
- `.terraform.lock.hcl` is committed with `linux_amd64` and dev-machine hashes (NFR-5).

## Naming and inputs

- Resource and variable names are `snake_case`. AWS resource names use `<prefix>-<env>-<thing>`,
  including GitHub Actions roles (`sis-dev-gha-plan`). The prefix comes from `project.env` (ADR 0011);
  Terraform holds copies of it (bootstrap `prefix` default, `envs/*/terraform.tfvars`) that
  `scripts/project.sh check` keeps equal. Tests assert names through `var.prefix`, or pin `prefix = "sis"`
  as a fixture, never through the committed value. Names `envs/<env>` creates must match the
  bootstrap `resource_names` output, because the apply and deploy roles are scoped by them
  (ADR 0002).
- Every variable has a `type` and a `description`; add `validation` where a bad value would only
  fail at apply time. Mark secret-adjacent inputs `sensitive = true`.
- No account IDs in code or committed tfvars (ADR D2). Read them from
  `data "aws_caller_identity"` and guard with `allowed_account_ids`.
- Provider `default_tags`: `Project`, `Env`, `ManagedBy = "terraform"` (NFR-8).

## IAM

- Build policies with `data "aws_iam_policy_document"`, not inline JSON strings.
- No `*` in `Action` or `Resource` of an Allow unless the API does not support resource-level
  permissions; then add a comment naming the API and, where possible, a condition. The approved
  list (ADR 0002 B20, rewritten by ADR 0012): `ecr:GetAuthorizationToken`, `cloudwatch:GetMetricStatistics`,
  `logs:DescribeLogGroups` and the CloudWatch Logs delivery and resource-policy actions that HTTP API access
  logging needs. A `terraform test` enforces it.
- Action wildcards are fine in Deny statements, where they widen protection.
- Resources with random IDs (HTTP APIs) are scoped by the region-wide `/apis` path; Lambda, logs, alarms and
  roles are scoped by `<prefix>-<env>-` names.
- The deploy role holds no `iam:PassRole` at all and carries an explicit Deny on it; `lambda:DeleteFunction`
  is allowed only on qualified ARNs (`function:<name>:*`), so it prunes versions but never deletes the function.
- IAM roles that a GitHub role creates carry the bootstrap permissions boundary
  (`iam:PermissionsBoundary` condition).
- `iam:PassRole` names the exact role ARNs and sets `iam:PassedToService`.
- The deploy role may call `secretsmanager:DescribeSecret` (metadata only) on the one app secret, matched as
  `<prefix>/<env>/app-api-key-??????`, so the deploy preflight can refuse a secret with no value (ADR 0006 G14).
- Plan, apply and deploy roles carry an explicit deny on `secretsmanager:GetSecretValue`
  (FR-3, FR-4, FR-5), through the shared guardrail policy.
- OIDC trust policies match `sub` exactly (`StringEquals`, never a wildcard on the repo) and check
  `aud = sts.amazonaws.com`, `repository_id` and `repository_owner_id`. The `sub` uses GitHub's
  immutable format `repo:OWNER@OWNER_ID/REPO@REPO_ID:...`. Apply and deploy roles also pin
  `ref = refs/heads/main`. The plan role pins `StringLike ref = refs/pull/*/merge`, the only
  `StringLike` allowed in a trust policy, so a `pull_request_target` run (base ref) is refused.
  IAM has no `event_name` key for GitHub. Apply and deploy roles also pin `job_workflow_ref` to
  the workflow file at `main` (`terraform-iac.yml`, `terraform-destroy.yml`; `app-deploy.yml`);
  the bootstrap `workflow_files` local is the contract, and renaming a file needs a re-apply
  (ADR 0007 S2). Role `max_session_duration = 3600` (NFR-7).

## Secrets and state

- Terraform creates secret shells only, never values, so nothing secret lands in state (FR-8).
- State buckets: versioning, SSE, public access block, TLS-only policy; `use_lockfile = true`.
- Backend blocks are partial: the bucket name holds the account ID, so it comes from
  `-backend-config="bucket=..."` at init time, never from a committed file.

## Testing

- `terraform test` with `mock_provider` for module logic, since agents have no AWS credentials
  (ADR D12). The real plan runs in CI with the plan role.
