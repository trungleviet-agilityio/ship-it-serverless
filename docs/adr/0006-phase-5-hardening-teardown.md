# ADR 0006: Phase 5 hardening and teardown

- Status: accepted
- The deferred rule 9 gaps and the destroy heading are resolved by ADR 0007 S11 and S12; `DeleteTaskDefinitions` is dropped (S14).
- Date: 2026-10-26 (accepted the same day)

## Context

PLAN.md Phase 5 adds `terraform-destroy.yml` (FR-12) and rewrites the README: setup, the trust conditions explained, cost notes, teardown order, and a section on when to move to CodeBuild runners or CodePipeline. PLAN §9 adds the cost and cleanup rules: ALB and Fargate bill by the hour, so `envs/*` is destroyed after every session. At the end of the lab the order is: the destroy workflow per environment, then bootstrap per account (empty the bucket first, move the state back to local).

Requirements covered:

| ID | What Phase 5 must deliver |
|---|---|
| FR-12 | `terraform-destroy.yml`: `workflow_dispatch`, input `env`, gated by an environment |
| Phase 5.2 | README: setup, trust conditions explained, cost notes, teardown order, "When to move to CodeBuild runners / CodePipeline" |
| NFR-2 | `permissions: {}` at workflow level. Per job, only what the job needs. `id-token: write` only on the job that assumes a role |
| NFR-3 | Actions pinned by SHA, tools pinned and checksum-verified (no new actions or tools) |
| NFR-4 | harden-runner is step 1 of every job, `egress-policy: audit` |
| NFR-7 | `max_session_duration = 3600` stays. A job that holds credentials must finish inside the session |
| NFR-9 | Claude never applies, destroys or sets secret values. The user dispatches, approves and re-applies bootstrap |

Facts already established (not re-checked with the user):

- The dev stack is destroyed and bootstrap is live.
- The user has destroyed `envs/dev` by hand four times, with admin credentials (`plan -destroy -out`, then apply of the saved plan). **The apply role has never run a destroy.**
- `terraform-iac` applies with environment `dev`.
- Apply trust pins: `sub ...:environment:dev`, `ref = refs/heads/main`, `workflow` in `[terraform-iac, terraform-destroy]`. **No trust change is needed.**
- `repo-guard` enforces the trigger allowlist (`pull_request`, `push`, `workflow_dispatch`) on every workflow.
- The user's `gh` token has Actions read only, so every dispatch, approval and re-run happens in the web UI.

Repo state read for this ADR (branch `phase-5-hardening-teardown`):

- `terraform-iac.yml` repeats the init block (bucket derivation, `init -lockfile=readonly`, `validate`) and the summary block in `plan` and `apply`. A destroy workflow would make that three copies.
- The `apply` job's "Report the result" text is stale. It still says "a new deployment is forced". ADR 0005 F2 replaced that with "run app-deploy".
- `modules/app-ecs/security_groups.tf` keys the ALB ingress rules by CIDR (`for_each = toset(var.alb_ingress_cidrs)`). That decides L4 below.
- `scripts/ci-requirements.txt` already hash-locks `pyyaml==6.0.3`.
- `docs/reference/CODING_STANDARDS.md` line 191 has broken text: "Terraform in `a checksum-verified Terraform binary (...)`".

Findings from official docs and provider source that shape this ADR:

1. **The apply role can destroy the whole module.** I audited every delete call in provider v6.70.0 (table at G11).
   - `iam:DeleteRole` and `iam:DeleteRolePolicy` both support the `iam:PermissionsBoundary` condition key, so the bounded `IamEcsRolesBounded` statement covers them (IAM Service Reference).
   - ELB delete calls only `DeleteLoadBalancer`, then polls ENIs with `DescribeNetworkInterfaces` for up to 35 minutes. ENI wait errors are logged, not returned.
   - Subnet and security-group deletes run `deleteLingeringENIs`. It only acts on Lambda, Comprehend, DMS, RDS and QuickSight ENIs, so ECS and ELB ENIs are skipped. Subnet delete retries `DependencyViolation` for up to 20 minutes.
   - ECS service delete sends `UpdateService` with desired count 0 (no `taskDefinition`), then `DeleteService`, then waits for `INACTIVE`.
   - Task definition delete only deregisters. An `INACTIVE` revision drops out of state.
   - ECR delete is one `DeleteRepository` call with `force = true` and no image loop. AWS says force has "Amazon ECR delete all of its contents on your behalf". It does not say whether the caller also needs `ecr:BatchDeleteImage`. **This is the one unverified point**, and the checkpoint proves it.
2. **`ForceDeleteWithoutRecovery` is asynchronous.** "There might be a short delay before the secret is permanently deleted"; a quick re-create should back off.
3. **`DescribeTaskDefinition` with only a family returns the latest `ACTIVE` revision.** After deregistration, `INACTIVE` revisions "remain discoverable ... indefinitely" and cost nothing. The apply role already holds `DescribeTaskDefinition` and `DeregisterTaskDefinition` on `*` (B20). So a describe-then-deregister loop can clean the family with no new permission.
4. **`DescribeSecret` "does not include the encrypted secret value".** It returns `VersionIdsToStages`, and leaves out fields that have no value. A shell that was never given a value has no `AWSCURRENT` stage. Secrets Manager recommends `secret:<name>-??????` to match exactly one secret name.
5. **Concurrency.**
   - A group allows one running and one pending job. A newly queued run cancels the existing pending one, and group names are shared across workflows.
   - GitHub added `queue: max` (up to 100 pending) in May 2026. **actionlint 1.7.12 (2026-03-30, the version in `mise.toml`) rejects it**: `parseConcurrency` accepts only `group` and `cancel-in-progress`. `make lint` would fail.
6. **`workflow_dispatch` inputs.** Types are `boolean`, `choice`, `number`, `environment` and `string`, and a `choice` resolves to a string. A destroy cannot be planned before approval: without `environment:` the job gets no token the apply role trusts, and the plan role trusts only `pull_request`.
7. **Prices, ap-southeast-1, on-demand USD:**
   - ALB: 0.0252 per ALB-hour and 0.008 per LCU-hour (Price List API, effective 2026-08-01).
   - Fargate Linux x86: 0.05056 per vCPU-hour and 0.00553 per GB-hour (Price List API, published 2026-10-19).
   - Public IPv4: 0.005 per address-hour (VPC pricing).
   - Secrets Manager: 0.40 per secret-month, prorated hourly.
8. **CodeBuild-hosted runners and CodePipeline.**
   - CodeBuild runs each GitHub Actions job on an ephemeral runner in your account, selected with `runs-on: codebuild-<project>-${{ github.run_id }}-${{ github.run_attempt }}`.
   - GitHub says self-hosted runners "should almost never be used for public repositories".
   - CodePipeline uses a CodeConnections GitHub App source. Its ECS standard deploy action "creates its own revision of the task definition based on the revision used by the Amazon ECS service".

## Decision

### A. Scope: carried-forward items

| Item | Decision | Reason |
|---|---|---|
| Deregister deploy-registered task definitions at teardown (ADR 0005 F23) | **In Phase 5** (G12) | It belongs to teardown and needs no new permission (Finding 3). It also cleans up the revisions left `ACTIVE` by the four admin teardowns |
| Deploy preflight: the secret must have an `AWSCURRENT` version (lessons log 28) | **In Phase 5** (G14, Q1) | It fixes an error the user actually hit, in the re-create flow this phase documents. It is one bootstrap statement on one secret name and reads metadata only |
| Remaining Phase 3 simplifier items | **In Phase 5**, limited to what the destroy workflow would otherwise copy: a shared `tf-init.sh` and a `--title` on the summary (G15). The stale apply message is fixed too | Rule of three: the init and summary blocks would reach three copies |
| Feed `TF_VAR_alb_ingress_cidrs` from a secret (ADR 0004 L4) | **Defer to Phase 6** (Q5) | `for_each = toset(var.alb_ingress_cidrs)` puts the CIDR in the resource address. That address lands in the public PR comment and step summary, and the plan log prints `cidr_ipv4` unmasked, because a JSON-list secret is not masked element by element. Doing this safely needs a module change (key the rules by index), `::add-mask::` for each CIDR, and an empty-secret-means-default rule. R6 is already reduced by teardown after every session and the `/admin` key check |
| Trigger allowlist with a real YAML parser (ADR 0004 L-a) | **Defer to Phase 6** | The new workflow uses a plain block trigger, which the line parser handles. Exploiting the gap needs a deliberately obfuscated workflow merged after review, plus a `dev` approval. Notes for Phase 6: PyYAML 6.0.3 is already in the hash-locked venv, but not on dev machines (use a `language: python` pre-commit hook with `additional_dependencies`). YAML 1.1 parses a bare `on:` key as boolean `true`, so the check must read that key |
| `job_workflow_ref`, harden-runner Q1, Dependabot | Stay in Phase 6 | Unchanged |
| `guard (no AWS)` as a required status check | Stays a user setting | Unchanged |

### B. `terraform-destroy.yml`

| # | Decision | Why / source |
|---|---|---|
| G1 | `name: terraform-destroy`, exactly. This name is already in the apply trust (`workflow_names.apply`), so **no bootstrap trust change**. A `ci-selftest` parity check reads the name from `infra/terraform/bootstrap/locals.tf` | ADR 0004 E2 |
| G2 | **Trigger: only `workflow_dispatch`**, which is in the `repo-guard` allowlist. Two inputs:<br>- `env`: `type: choice`, `options: [dev]`, `required: true`, `default: dev`.<br>- `confirm`: `type: string`, `required: true`, with the description "Type destroy-<env>, for example destroy-dev".<br>Workflow-level `permissions: {}`. Env `TF_IN_AUTOMATION=1`, `TF_INPUT=0` | FR-12; Finding 6; Q3 |
| G3 | **Job `confirm` (no AWS):**<br>- `runs-on: ubuntu-24.04`, `timeout-minutes: 5`, `permissions: {}`. No checkout, no environment, no secrets.<br>- Step 1 is harden-runner (audit).<br>- Step 2 receives `inputs.env`, `inputs.confirm` and `github.ref` through `env:` only and fails with `::error::` unless: the ref is `refs/heads/main`; `env` is in the allowlist `dev` (the job checks this itself rather than relying on the `choice` options); and `confirm` equals `destroy-${env}`.<br>- It never echoes the typed confirmation.<br>Because `destroy` has `needs: confirm`, a typo fails here, before any approval prompt or token exists | NFR-2; the CODING_STANDARDS ban on interpolating inputs in `run:` |
| G4 | **Job `destroy`:**<br>- `needs: confirm`, `if: github.ref == 'refs/heads/main'`, `environment: dev` (hard-coded, as in app-deploy).<br>- `permissions: { contents: read, id-token: write }`, `runs-on: ubuntu-24.04`, `timeout-minutes: 45` (G10).<br>- Job env `ENV: dev`, `TF_DIR: infra/terraform/envs/dev`.<br>- `concurrency: { group: terraform-envs-dev, cancel-in-progress: false }`, the same group as the `terraform-iac` apply job (G8).<br>The environment is hard-coded because the account secret (`AWS_ACCOUNT_ID_DEV`) and the trust are dev-specific today. A dynamic `environment: ${{ inputs.env }}` would look ready for prod without being ready. Phase 7 adds `prod` to the options together with per-environment secrets | FR-12; ADR 0005 F14 pattern |
| G5 | **Steps of `destroy`, in order:**<br>1. harden-runner (audit).<br>2. Checkout with `persist-credentials: false`.<br>3. `scripts/install-ci-tools.sh "$RUNNER_TEMP/tools"`.<br>4. `scripts/check-aws-config.sh sis-dev-gha-apply`, with `ROLE_ARN=secrets.AWS_APPLY_ROLE_ARN`, `ACCOUNT=secrets.AWS_ACCOUNT_ID_DEV`, `REGION=vars.AWS_REGION`.<br>5. configure-aws-credentials: session `gha-destroy-<run_id>-<attempt>`, `mask-aws-account-id: true`, `retry-max-attempts: 3`.<br>6. `scripts/tf-init.sh "$TF_DIR"` (G15).<br>7. `terraform -chdir="$TF_DIR" plan -destroy -lock-timeout=5m -no-color -out=tfplan`, with `TF_VAR_aws_account_id`.<br>8. **Destroy guard** (G6). It writes `deletes=<n>` to `$GITHUB_OUTPUT`.<br>9. Summary: `terraform show -json tfplan \| scripts/tf-plan-summary.sh --title "Terraform destroy plan (dev)" \| scripts/assert-no-account-id.sh` (with `ACCOUNT`), appended to `$GITHUB_STEP_SUMMARY`.<br>10. `if: steps.guard.outputs.deletes != '0'`: `terraform -chdir="$TF_DIR" apply -input=false -lock-timeout=5m -no-color tfplan`.<br>11. `scripts/ecs-deregister-revisions.sh >> "$GITHUB_OUTPUT"` (G12). It runs whether or not anything was deleted.<br>12. `if: always()`: result summary with the role name only (`${arn#*:assumed-role/}`, then `%%/*`), the delete count, the deregistered count and "nothing to destroy" when the count was 0, piped through `assert-no-account-id.sh`.<br>13. `if: always()`: `rm -f "$TF_DIR/tfplan"`. No `upload-artifact` | ADR 0004 E22, E24; ADR 0005 F18 |
| G6 | **Destroy guard: `scripts/tf-destroy-check.sh`** reads `terraform show -json` on stdin and prints only the number of deletes.<br>- It fails unless every entry in `resource_changes` whose actions are not `["no-op"]` or `["read"]` is exactly `["delete"]`, so a create, update, replace or forget is refused.<br>- It fails unless every deleted address starts with `module.app_ecs.`. `envs/<env>` is one module call; a new root resource has to update the guard on purpose.<br>- **Empty stack (Q2):** 0 deletes means the apply step is skipped and the run ends green with `::notice::nothing to destroy`. The end state the user asked for already holds | Mechanical review of the destroy plan, since approval happens before the plan exists (Finding 6) |
| G7 | **The saved destroy plan is applied in the same job, after one approval (Q4).** The job checks and summarizes the same plan file it then applies, with no artifact. On a public repo an artifact would expose ARNs with the account ID. The typed confirmation, the main-only rule, the `dev` approval and the delete-only guard replace a human reading the plan before approval | ADR 0004 E24 and R5 reasoning |
| G8 | **Concurrency:** `terraform-envs-dev` is shared with the `terraform-iac` `apply` job, so a destroy and an apply never overlap or contend for the state lock. **No `queue: max`**, because actionlint 1.7.12 rejects it (Finding 5). Consequence: with one pending slot, a newly queued destroy replaces a pending apply, and the reverse. The replaced run shows as cancelled and the user dispatches again (R10). Revisit when actionlint supports `queue` | Finding 5 |
| G9 | **A race with an in-flight `app-deploy` is harmless, so there is no cross-workflow lock.** app-deploy never touches Terraform state. If it runs during a destroy, its push, describe or update calls fail and the run goes red. The provider's `DeleteService` retries "deployments active". If a deploy slips in after cleanup, it can only leave one `ACTIVE` revision, which the next destroy removes. G12 deregisters only after it confirms the service is gone. The README tells the approver to approve one of `terraform-iac`, `app-deploy` or `terraform-destroy` at a time | Finding 1; ADR 0005 consequence "drift by design" |
| G10 | **`timeout-minutes: 45` stays below the 60-minute role session** (NFR-7, `role-duration-seconds` default 3600), so a stuck destroy fails while it still has credentials and can release the lock. The ALB ENI wait (up to 35 minutes) and subnet retries (up to 20 minutes) usually finish in minutes. If the job is cut off, the user removes a stale lock as admin (README troubleshooting) | Finding 1; NFR-7 |

### C. IAM

| # | Decision |
|---|---|
| G11 | **The apply role needs no change for destroy.** Audit of every delete call (provider v6.70.0):<br>- ECS service: `UpdateService`, `DeleteService`, `DescribeServices` (`EcsService`).<br>- Cluster: `DeleteCluster`, `DescribeClusters` (`EcsCluster`).<br>- Task definition: `DeregisterTaskDefinition` (`EcsTaskDefUnscoped`, B20).<br>- ALB, listener, target group: `Delete*` (`ElbManage`, `sis-dev-*` ARNs) and `ec2:DescribeNetworkInterfaces` (`Ec2Read`).<br>- Security group rules: `RevokeSecurityGroup*` on tagged groups. Security groups, route, association, route table, subnets: `Delete*` and `DisassociateRouteTable` (`Ec2ManageTagged`). IGW: `DetachInternetGateway` and `DeleteInternetGateway` (IGW and VPC both tagged). VPC: `DeleteVpc`.<br>- Log group: `DeleteLogGroup` (`Logs`).<br>- Secret: `DeleteSecret` with `ForceDeleteWithoutRecovery` (`SecretShell`; the action takes no condition key that would block it).<br>- IAM: `DeleteRolePolicy` and `DeleteRole` (`IamEcsRolesBounded`; both support `iam:PermissionsBoundary`, Finding 1), `ListInstanceProfilesForRole` (`IamEcsRolesRead`).<br>- ECR: `DeleteLifecyclePolicy`, `DeleteRepository` with force, `DescribeRepositories` (`Ecr`).<br>**Unverified:** whether a forced `DeleteRepository` also needs `ecr:BatchDeleteImage`. Checkpoint step 7 proves it with images present. **Fallback:** if that step shows `AccessDenied` naming `ecr:BatchDeleteImage`, add only that action to the `Ecr` statement (`repository/sis-dev-*`, which grants nothing beyond what force already allows), re-apply bootstrap and run the destroy again. Everything else is already gone by then, so the hourly charges have stopped |
| G12 | **Clean the revisions with the apply role: `scripts/ecs-deregister-revisions.sh`** (`ENV`, default dev, names from `app_names`).<br>(1) Proceed only if `ecs_service_status` (new `lib.sh` helper, G13) returns `MISSING` or `INACTIVE`. `ACTIVE` or `DRAINING` fails with "service still exists; not deregistering".<br>(2) Loop at most 200 times: `aws ecs describe-task-definition --task-definition "$FAMILY" --query taskDefinition.revision --output text` through `run_capture`.<br>&nbsp;&nbsp;- A `ClientException` means no `ACTIVE` revision is left, so stop.<br>&nbsp;&nbsp;- Any other error fails, with the error text redacted.<br>&nbsp;&nbsp;- A revision returned twice fails with "revision N returned again (eventual consistency); re-run the job".<br>&nbsp;&nbsp;- Otherwise run `aws ecs deregister-task-definition --task-definition "$FAMILY:$rev" --query taskDefinition.status --output text`, expect `INACTIVE`, and log `deregistered sis-dev-app:<n>`.<br>(3) Print `DEREGISTERED=<count>` on stdout.<br>No new permission: `DescribeTaskDefinition`, `DeregisterTaskDefinition` (B20 `*`) and `DescribeServices` (`service/sis-dev-cluster/*`). No `DeleteTaskDefinitions`: `INACTIVE` revisions cost nothing. **The deploy role never gets deregister or delete rights** |
| G13 | **ECR images are deleted together with the repository** (`force_delete = true`, ADR 0004 E10). The deploy role needs no cleanup permission. Shared helper `ecs_service_status` in `lib.sh` prints `ACTIVE`, `DRAINING`, `INACTIVE` or `MISSING`. `ClusterNotFoundException`, a `MISSING` failure and an empty result all map to `MISSING`; any other error dies with redacted text. `ecs-preflight.sh` is refactored to use it, so both scripts read service state the same way |
| G14 | **Deploy preflight: refuse a secret that has no value (bootstrap change, Q1).**<br>New statement in `iam_deploy.tf`: `sid = "DescribeAppSecretMetadata"`, actions exactly `["secretsmanager:DescribeSecret"]`, resources exactly `["arn:<p>:secretsmanager:<region>:<acct>:secret:sis/dev/app-api-key-??????"]` (built from `local.resource_names.secret`; Finding 4).<br>G1 still denies `GetSecretValue`, `BatchGetSecretValue`, `PutSecretValue` and `UpdateSecretVersionStage`, so values remain unreadable and unwritable.<br>`ecs-preflight.sh` then checks, in order:<br>(1) the service is `ACTIVE` (helper);<br>(2) `aws secretsmanager describe-secret --secret-id "$SECRET_ID" --query VersionIdsToStages --output json` has a stage `AWSCURRENT`. If not, it fails with "secret sis/dev/app-api-key has no current value: set it with put-secret-value in your own terminal, then Re-run failed jobs". `AccessDeniedException` fails with "deploy role cannot describe the secret: re-apply bootstrap (ADR 0006 G14)". `ResourceNotFoundException` fails with the existing "stack is not up" message;<br>(3) N4, unchanged.<br>Version IDs are never printed. This deviates from FR-5's literal "No Secrets Manager read" for metadata only. FR-5's intent (no value access) holds |

### D. Scripts, workflows and tests

| # | Decision |
|---|---|
| G15 | **`scripts/tf-init.sh <envs dir>`**: reads `ACCOUNT` and `REGION` from the environment.<br>- It refuses any directory that is not `infra/terraform/envs/<env>` (bootstrap is never initialized in CI, ADR 0004 E4).<br>- `<env>` must match `^[a-z][a-z0-9]*$`.<br>- It derives the bucket `sis-<env>-tfstate-<ACCOUNT>-<REGION>-an` (B8), runs `terraform -chdir=<dir> init -input=false -lockfile=readonly -backend-config="bucket=<bucket>"`, then `validate -no-color`. It prints nothing else.<br>It is used by the `plan` and `apply` jobs of `terraform-iac.yml` and by `destroy`.<br>`tf-plan-summary.sh` gets an optional `--title <text>`; the default header is unchanged.<br>The `terraform-iac` apply report becomes: "The service stays unhealthy until the secret value is set and app-deploy runs (Run workflow)."<br>Add the new scripts to the `terraform-iac` PR `paths` (the `check_paths` self-test enforces this). Editing `terraform-iac.yml` triggers a push apply on merge. That is intended here: checkpoint step 3 uses it to re-create the stack (lessons log 14) |
| G16 | **`ci-selftest.sh` cases** (stubs, offline) for `tf-destroy-check.sh`, `tf-init.sh`, `ecs-deregister-revisions.sh`, the new preflight branches and `--title`. Structural checks on `terraform-destroy.yml`:<br>- the only trigger is `workflow_dispatch`;<br>- `name:` is in bootstrap `workflow_names.apply`;<br>- `confirm` holds no `id-token`, `environment:`, `secrets.` or checkout, with mutation tests like `build_scan_isolated`;<br>- `environment: dev` and `id-token: write` appear only in `destroy`;<br>- both `destroy` and the `terraform-iac` apply job use the concurrency group `terraform-envs-dev`.<br>Do not call `check_paths` on the destroy workflow, because it has no path filters |
| G17 | **No Makefile target**, no destroy outside the workflow for `envs/*`, and **bootstrap is never destroyed in CI.** G5 of the guardrails denies CI the bootstrap state, so the admin runs that destroy locally (ADR 0001 D15, ADR 0004 E4) |

### E. Teardown order, re-create flow, README, cost

| # | Decision |
|---|---|
| G18 | **Session flow.**<br>- Re-create: Run workflow on `terraform-iac`, approve; `put-secret-value` (one line in your own terminal); Run workflow on `app-deploy`, approve. If the secret was skipped, app-deploy now fails at the preflight with that message instead of a circuit-breaker rollback (G14).<br>- End of session: Run workflow on `terraform-destroy` (env `dev`, confirm `destroy-dev`), then approve.<br>- Wait about a minute before re-creating after a destroy (Finding 2).<br>- Before merging infra PRs during a teardown window, reject the pending apply or merge later (lessons log 14).<br>**End of lab (PLAN §9):**<br>1. `terraform-destroy` per environment (prod first once Phase 7 exists), then confirm it reports "nothing to destroy".<br>2. Bootstrap per account, as admin, locally: move the state to local with a `backend "local" {}` override and `init -migrate-state -force-copy`; check `state list`; delete every object version and delete marker in the bucket (`force_destroy = false`); `plan -destroy -var-file=accounts/dev.tfvars -out`, then apply the saved plan; delete the override and local state files.<br>3. Optionally remove the GitHub environment `dev` and the repo and environment secrets, which now point at deleted roles. Service-linked roles and `INACTIVE` task definitions cost nothing and can stay |
| G19 | **README structure** (orchestrator, D14):<br>1. What this is.<br>2. Architecture (link the diagram).<br>3. Setup (existing).<br>4. One-time AWS and GitHub setup (bootstrap, environment `dev`, secrets table).<br>5. **How the trust works** (table below).<br>6. Pipelines table (add `terraform-destroy`).<br>7. Session flow (G18).<br>8. **Cost** (G20).<br>9. **Teardown order** (session and end of lab, with troubleshooting: stale lock, a cancelled pending run, a secret name still being deleted).<br>10. **When to move to CodeBuild runners or CodePipeline** (below).<br>11. Phases.<br>Trust table columns: condition, value, what it blocks:<br>- `aud = sts.amazonaws.com`: tokens minted for another audience.<br>- immutable `sub` (`repo:OWNER@ID/REPO@ID:pull_request` or `:environment:dev`): other repos, recycled names, the wrong event or environment.<br>- `repository_id` and `repository_owner_id`: the same, as a second check.<br>- plan `ref` StringLike `refs/pull/*/merge`: `pull_request_target` and dispatched runs.<br>- apply and deploy `ref = refs/heads/main`: branch runs that add `environment: dev`.<br>- `workflow` (`terraform-iac`, `terraform-destroy`; `app-deploy`): one approved workflow using the other workflow's role.<br>After the table, the gates outside the trust: environment approval and the main-only branch policy, guardrails G1 to G5, the ECS boundary, exact `PassRole`, and the `repo-guard` trigger allowlist |
| G20 | **Cost table** (ap-southeast-1, on-demand, Finding 7):<br>- ALB 0.0252/h;<br>- LCU 0.008/LCU-h (lab traffic is a small fraction of one LCU, so a full LCU is an upper bound);<br>- Fargate 0.25 vCPU x 0.05056 + 0.5 GB x 0.00553 = 0.0154/h;<br>- public IPv4 3 x 0.005 = 0.015/h (two ALB nodes and one task; a fourth briefly during a rolling deploy);<br>- secret about 0.0006/h.<br>**Total about 0.056 to 0.064 USD per hour, 1.35 to 1.54 per day, 0.17 to 0.19 for a 3-hour session.** Left running for 30 days: about 40 to 46 USD, double the 20 USD budget. The 80% alert (16 USD) fires after about 10 to 12 days. ECR storage, logs, S3 state and the budget cost cents. GitHub-hosted minutes are free on a public repo |
| G21 | **"When to move to CodeBuild runners or CodePipeline"** (README, from Finding 8):<br>**CodeBuild-hosted runners** keep the same workflows, with `runs-on: codebuild-<project>-${{ github.run_id }}-${{ github.run_attempt }}`. Move when jobs need private VPC access (database migrations, private endpoints), larger, ARM or GPU compute, or in-VPC egress control. They cost build minutes, while hosted minutes are free here. Trade-offs:<br>- GitHub says self-hosted runners should almost never run on public repos, and this repo is public (D1).<br>- The project service role gives credentials to any job that targets the label, which bypasses the `sub`, `ref` and `workflow` trust. If you move, give the service role nothing beyond logs and keep assuming the OIDC roles from the job.<br>- A GitHub connection credential lives in AWS.<br>**CodePipeline (V2)** fits when the organisation requires AWS-native approvals and audit (CloudTrail), cross-account promotion with only AWS identities (Phase 7 prod), or deploys that must not depend on GitHub Actions availability. Pieces: a CodeConnections GitHub App source with push, PR and tag triggers, a manual approval action, the ECS standard deploy action (`imagedefinitions.json`), or CodeDeploy for blue/green. Note that its ECS action builds from the service's current revision, not Terraform's latest family revision (contrast with ADR 0005 F3). **For this lab: stay on GitHub-hosted runners and Actions** |

### Least privilege summary

| Item | Value | Wildcards |
|---|---|---|
| `confirm` job | `permissions: {}`, no secrets, no checkout, no AWS | none |
| `destroy` job | `contents: read`, `id-token: write`; environment `dev`; secrets `AWS_APPLY_ROLE_ARN` (env) and `AWS_ACCOUNT_ID_DEV` | none added |
| Apply role | Trust unchanged (`workflow` already includes `terraform-destroy`). Policy unchanged (G11) | existing B20 only |
| Deploy role | + `secretsmanager:DescribeSecret` on `secret:sis/dev/app-api-key-??????`; G1 still denies value read and write | `??????` matches the 6-character random suffix only |
| `iam:PassRole` | unchanged; destroy passes no role | none |
| Bootstrap trust | unchanged | n/a |

## Alternatives considered

- **Plan in one approved job, apply in a second approved job.** The approver would see the destroy plan first. It needs two approvals and passes either a plan artifact (ARNs with the account ID on a public repo) or a re-plan, so the reviewed plan would not be the applied one. Rejected for G7 plus the G6 guard.
- **`terraform destroy -auto-approve`.** No saved plan to check, so G6 could not refuse a non-delete change. Rejected.
- **Confirmation equal to the environment name (`dev`).** It is also the default of `env`, so it is easy to type by reflex. Rejected for `destroy-dev` (Q3).
- **`environment: ${{ inputs.env }}`.** Ready for prod in shape, but the secrets and trust are dev-only today. Deferred to Phase 7.
- **`queue: max` on the shared group.** actionlint 1.7.12 rejects it. Deferred.
- **A GitHub API check that no app-deploy run is active** (`actions: read`). One more token scope and script, and still subject to time-of-check races. The race outcomes are harmless (G9). Rejected.
- **Deregister revisions with `ListTaskDefinitions`.** Deterministic, but adds a `*` action to the apply role and to B20. Rejected for the describe loop.
- **Give the deploy role deregister or ECR delete rights.** Widens FR-5 for no gain, because the apply role already has them. Rejected.
- **Turn on Container Insights or check readiness through the ELB in the preflight.** Out of scope; ADR 0005 Q6 stands.
- **Wire the ALB CIDR secret now.** It leaks a personal IP through for_each addresses and unmasked plan values (A, Q5). Deferred.
- **Add `ecr:BatchDeleteImage` pre-emptively.** It grants nothing new beyond force delete, but it would be an unverified permission. Rejected; the fallback in G11 covers it.
- **A Makefile `destroy` target or a local destroy script.** Breaks D15 and NFR-9. Rejected.

## Consequences

- **First destroy by the apply role.** Checkpoint step 7 is the first time the role deletes anything. Expect at most one bootstrap iteration (ECR force, G11).
- **The secret value is lost on every destroy** (`recovery_window_in_days = 0`, ADR 0004 Q3). After each re-create, `put-secret-value` is needed, and G14 now enforces that order.
- **R9 (new):** an approved dispatch from `main` destroys dev. Gates: the typed confirmation, the `dev` approval, the main-only branch policy, and the trust `ref` and `workflow` pins. Accepted; this is the purpose of the workflow.
- **R10 (new):** with one pending slot, a pending destroy and a pending apply can replace each other (G8). The cancelled run is visible; dispatch it again.
- **R2 is unchanged:** the `workflow` pin is the writer-controlled `name:`.
- **Merging this PR starts two gated runs.** `terraform-iac` starts because `terraform-iac.yml` changed. `app-deploy` starts because `ecs-preflight.sh` and `lib.sh` are in its paths. The checkpoint uses both.
- **Lessons:**
  - Workflow files that contain the infra command words must be written with Write or Edit, never a Bash heredoc (lessons log 23, 30).
  - The orchestrator prints real commands with the account ID from `CLAUDE.local.md` (lessons log 6). This ADR keeps placeholders.
- **Docs follow-up (orchestrator):** see "Orchestrator docs list".

## Decision log (open questions resolved)

The user delegated these choices ("decide by best practice and record pros and cons"). The orchestrator accepted
every recommendation below on 2026-10-26; the pro and con of each are recorded as the decision record. Q1 is the
only one that changes bootstrap, so it adds one re-apply to the checkpoint.


| Q | Recommendation | Pro | Con |
|---|---|---|---|
| Q1 | Add `DescribeSecret` (metadata only, one secret name) to the deploy role and fail the preflight without `AWSCURRENT` (G14) | Stops the error the user hit (a rollout that ends in a circuit-breaker rollback); the message names the fix; no value access | One bootstrap re-apply; deviates from FR-5's literal "No Secrets Manager read" |
| Q2 | Empty stack: skip the apply, end green with a notice, still clean the revisions | Green always means "nothing of dev is running"; a second dispatch is idempotent and safe | A user who expected something to delete gets no red signal; the summary states "nothing to destroy" |
| Q3 | Confirmation phrase `destroy-<env>` (`destroy-dev`) | Hard to type by accident; carries over to `destroy-prod` in Phase 7 | A few more keystrokes than `dev` |
| Q4 | One approval, then plan, guard and apply in the same job (G7) | One click; no plan artifact on a public repo; the checked plan is the applied plan | The approver approves before seeing the plan, so the mechanical guard replaces human review |
| Q5 | Defer the ALB CIDR secret to Phase 6, with the index-key and mask design | No IP leak through addresses or plan logs; Phase 5 stays small | The ALB stays open to `0.0.0.0/0` (R6) until then; mitigated by teardown and the `/admin` key |
| Q6 | Clean `ACTIVE` revisions in every destroy (G12) | Clean slate; closes F23; no new permission | One more script; a revision registered by a racing deploy can remain until the next destroy |

**Verify findings (decided by the orchestrator on 2026-10-26, same delegation):**

| Finding | Decision | Pro | Con |
|---|---|---|---|
| Reviewer M: the apply role may also need `ecr:BatchDeleteImage` for a forced repository delete | **No change.** The ECR `DeleteRepository` API reference says that with `force` ECR deletes the contents "on your behalf"; checkpoint step 7 still stops on that AccessDenied | No pre-emptive permission | If the documentation is wrong, one bootstrap round at the checkpoint |
| Security L3: `ecs_service_status` mapped any unexpected answer to MISSING, letting the revision cleanup run against a live service | **Fix**: only `None`, `MISSING` or empty mean MISSING; anything else fails. The helper sets `SERVICE_STATUS` instead of printing | Fails closed; callers cannot forget `|| exit 1` | A future ECS status needs a one-line update |
| Security L4: the result summary printed planned deletes as done after a failed apply | **Fix**: it reports "N planned; apply failed" unless the apply step succeeded | An approver skimming a red run cannot conclude the stack is gone | None worth noting |
| Security I1: destroy-time provisioners and `action_invocations` never appear in `resource_changes` | **Fix**: the guard refuses any `action_invocations`, and `tf-policy.sh` bans `provisioner` and `data "external"` in modules and envs | Closes a code-execution path a reviewed merge could add | Those Terraform features become unavailable in this repo without a policy change |
| Security L1, L2: README `force-unlock` and bucket emptying had no preconditions | **Fix (docs)**: check no run is active and the lock matches the dead run; check `state list` is empty and only bootstrap resources remain; name the bucket and the 1000-key batch limit | Prevents two writers on the state and deleting the last record of live resources | Longer instructions |
| Reviewer: summary after the guard, lost count on a mid-loop failure, no retry on ECS eventual consistency | **Fix**: summary first, count from an EXIT trap, one retry after a short sleep | A refused plan still shows its table; a partial cleanup reports what it did; fewer false reds | Slightly longer cleanup script |
| Simplifier: `ENV` as the one key, `tf-init.sh` by ENV, `assert_denied`, N2 and N3 into a tested script, one account-ID regex, one role-name helper, split `ci-selftest.sh` by area, ARN locals | **Fix now** (senior clean-code standard) | Prod in Phase 7 becomes a short addition, not a copy; every guard is tested offline | A large mechanical diff in this phase |
| Security re-check Low: policy rule 9 misses unquoted labels (`provisioner local-exec {`), `*.tf.json` files and remote module sources | **Defer to Phase 6** (two fix rounds used): match optional quotes, scan `*.tf.json`, require local module sources, with self-tests | Phase 5 ships with the guard and the quoted-form rule; the gap needs a reviewed merge plus an approval | Until then a reviewer must spot an unquoted provisioner by eye |
| Security re-check cosmetic: a failed destroy still has the heading "Destroyed" | **Defer to Phase 6** with the item above | The body already says "planned; apply failed" | A skimmer could misread the heading on a red run |
| Simplifier: composite action for the AWS preamble of every job | **Defer to Phase 7** | Each job's role, environment and `id-token` stay visible in its own file; pin and zizmor checks need no extension now | About 60 duplicated workflow lines remain until prod forces the refactor |

## Checkpoint commands (the user runs these; Claude never does, NFR-9)

Placeholders: `<DEV_ACCOUNT_ID>` (the orchestrator fills it from `CLAUDE.local.md` when printing) and `<PR>`. Each line is self-contained (lessons log 5). Run long waits in your own terminal.

**0. Bootstrap re-apply from the PR branch, before merge (G14)**

```bash
git switch phase-5-hardening-teardown && git pull
aws sso login --profile sis-dev-admin
AWS_PROFILE=sis-dev-admin terraform -chdir=infra/terraform/bootstrap init -backend-config="bucket=sis-dev-tfstate-<DEV_ACCOUNT_ID>-ap-southeast-1-an"
AWS_PROFILE=sis-dev-admin terraform -chdir=infra/terraform/bootstrap plan -var-file=accounts/dev.tfvars -out=bootstrap.tfplan
# Expect: 0 to add, 1 to change (aws_iam_role_policy.deploy), 0 to destroy
AWS_PROFILE=sis-dev-admin terraform -chdir=infra/terraform/bootstrap apply bootstrap.tfplan
rm infra/terraform/bootstrap/bootstrap.tfplan
AWS_PROFILE=sis-dev-admin aws iam get-role-policy --role-name sis-dev-gha-deploy --policy-name deploy --query 'PolicyDocument.Statement[].Sid'
# expect DescribeAppSecretMetadata in the list
AWS_PROFILE=sis-dev-admin aws iam simulate-principal-policy --policy-source-arn arn:aws:iam::<DEV_ACCOUNT_ID>:role/sis-dev-gha-deploy \
  --action-names secretsmanager:DescribeSecret secretsmanager:GetSecretValue \
  --resource-arns arn:aws:secretsmanager:ap-southeast-1:<DEV_ACCOUNT_ID>:secret:sis/dev/app-api-key-AbCdEf \
  --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text
# expect: DescribeSecret allowed, GetSecretValue explicitDeny
```

**1. Read the PR checks** (read-only token works)

```bash
gh pr checks <PR> --repo trungleviet-agilityio/ship-it-safely --watch
# repo-guard guard, terraform-iac checks, plan, plan-role-guardrails, comment: green; plan comment shows add 27, change 0, destroy 0 while dev is torn down (0 changes if it is up)
```

**2. Merge.** Web UI: open the PR, then Squash and merge (or `gh pr merge <PR> --squash` if your token allows it).

**3. Re-create the stack (the push run from the merge).** Web UI: Actions > terraform-iac > the newest push run > Review deployments > tick `dev` > Approve and deploy. Wait for green; the job summary shows the ALB URL.

**4. Negative test N5: deploy before the secret has a value.** Web UI: Actions > app-deploy > the newest push run > Review deployments > Approve. Expect the `deploy` job to fail at "Preflight" with "secret sis/dev/app-api-key has no current value". Then confirm that no revision was registered and no rollout started:

```bash
AWS_PROFILE=sis-dev-admin aws ecs describe-services --region ap-southeast-1 --cluster sis-dev-cluster --services sis-dev-app --query 'services[0].deployments[].[status,rolloutState,taskDefinition]' --output text | sed -E 's/[0-9]{12}/<acct>/g'
# only the Terraform revision's deployment
```

**5. Set the secret, then re-run the deploy**

```bash
V="$(openssl rand -hex 24)"; AWS_PROFILE=sis-dev-admin aws secretsmanager put-secret-value --region ap-southeast-1 --secret-id sis/dev/app-api-key --secret-string "$V" --query VersionId --output text; unset V
```

Web UI: the same app-deploy run > Re-run jobs > Re-run failed jobs > approve `dev`. Expect green. Then:

```bash
ALB="$(AWS_PROFILE=sis-dev-admin aws elbv2 describe-load-balancers --region ap-southeast-1 --names sis-dev-alb --query 'LoadBalancers[0].DNSName' --output text)"; curl -fsS "http://${ALB}/version"; echo
```

**6. Negative test N6: a wrong confirmation never reaches approval.** Web UI: Actions > terraform-destroy > Run workflow > branch `main`, env `dev`, confirm `dev` > Run workflow. Expect `confirm (no AWS)` to fail with "confirmation must be destroy-dev", `destroy` to be skipped, and no approval prompt.

**7. Destroy.** Web UI: Run workflow again with confirm `destroy-dev`, then Review deployments > `dev` > Approve and deploy. Expect green. The summary should show:

- a destroy count of about 30, every address under `module.app_ecs`;
- the deregistered revision count (including revisions left over from earlier admin teardowns);
- role `sis-dev-gha-apply`.

If it fails on ECR with `AccessDenied` for `ecr:BatchDeleteImage`, stop and report it (G11 fallback).

```bash
RUN_ID="$(gh run list --repo trungleviet-agilityio/ship-it-safely --workflow terraform-destroy.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run view "$RUN_ID" --repo trungleviet-agilityio/ship-it-safely --log | grep -c '<DEV_ACCOUNT_ID>'      # expect 0
```

**8. Verify that nothing is left (admin, read-only)**

```bash
AWS_PROFILE=sis-dev-admin aws ecs describe-clusters --region ap-southeast-1 --clusters sis-dev-cluster --query 'clusters[0].status' --output text   # INACTIVE or None
AWS_PROFILE=sis-dev-admin aws elbv2 describe-load-balancers --region ap-southeast-1 --names sis-dev-alb 2>&1 | grep -o LoadBalancerNotFound
AWS_PROFILE=sis-dev-admin aws ec2 describe-vpcs --region ap-southeast-1 --filters Name=tag:Project,Values=ship-it-safely Name=tag:Env,Values=dev --query 'length(Vpcs)' --output text   # expect 0
AWS_PROFILE=sis-dev-admin aws ecs list-task-definitions --region ap-southeast-1 --family-prefix sis-dev-app --status ACTIVE --query 'taskDefinitionArns' --output text   # expect empty
AWS_PROFILE=sis-dev-admin aws ecr describe-repositories --region ap-southeast-1 --repository-names sis-dev-app 2>&1 | grep -o RepositoryNotFoundException
AWS_PROFILE=sis-dev-admin aws secretsmanager describe-secret --region ap-southeast-1 --secret-id sis/dev/app-api-key 2>&1 | grep -o ResourceNotFoundException
```

Ask each service, not the Resource Groups Tagging API: it keeps listing deleted clusters, services and
security-group rules for a while, and lists `INACTIVE` (deregistered) task definitions until they are deleted with
`DeleteTaskDefinitions` (checkpoint run, 2026-10-26). `INACTIVE` revisions cost nothing and cannot run.

**9. N7: idempotent second run.** Web UI: Run workflow with `destroy-dev` again, then approve. Expect green with the notice "nothing to destroy" and 0 revisions deregistered.

**10. Optional: harden-runner exposure (ADR 0005 Q1).** Open the insights link of the `destroy` job in a logged-out browser and search for the account ID. Report the result.

Re-create next session: G18. Bootstrap teardown happens only at the end of the lab: G18, steps 1 to 3 (commands in the README).

## Sources

- IAM Service Reference (DeleteRole and DeleteRolePolicy condition keys): https://servicereference.us-east-1.amazonaws.com/v1/iam/iam.json
- ECR DeleteRepository (force): https://docs.aws.amazon.com/AmazonECR/latest/APIReference/API_DeleteRepository.html
- ECR deleting a repository: https://docs.aws.amazon.com/AmazonECR/latest/userguide/repository-delete.html
- Provider v6.70.0 source:
  - https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/v6.70.0/internal/service/ecr/repository.go
  - https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/v6.70.0/internal/service/elbv2/load_balancer.go
  - https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/v6.70.0/internal/service/ec2/vpc_subnet.go
  - https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/v6.70.0/internal/service/ec2/vpc_network_interface.go
  - https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/v6.70.0/internal/service/ecs/service.go
  - https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/v6.70.0/internal/service/ecs/task_definition.go
- ECS DescribeTaskDefinition: https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_DescribeTaskDefinition.html
- ECS DeregisterTaskDefinition: https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_DeregisterTaskDefinition.html
- Secrets Manager DescribeSecret: https://docs.aws.amazon.com/secretsmanager/latest/apireference/API_DescribeSecret.html
- Secrets Manager DeleteSecret: https://docs.aws.amazon.com/secretsmanager/latest/apireference/API_DeleteSecret.html
- Secrets Manager identity policies (`-??????`): https://docs.aws.amazon.com/secretsmanager/latest/userguide/auth-and-access_iam-policies.html
- GitHub concurrency (pending, `queue`): https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency
- GitHub workflow syntax (dispatch inputs, `queue`): https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax
- GitHub secure use (self-hosted runners on public repos): https://docs.github.com/en/actions/reference/security/secure-use
- Seen in search results only (not opened): https://github.blog/changelog/2026-05-07-github-actions-concurrency-groups-now-allow-larger-queues
- actionlint releases: https://github.com/rhysd/actionlint/releases
- actionlint v1.7.12 `parseConcurrency`: https://raw.githubusercontent.com/rhysd/actionlint/v1.7.12/parse.go
- Prices:
  - ELB price list, ap-southeast-1: https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AWSELB/current/ap-southeast-1/index.json
  - ECS (Fargate) price list, ap-southeast-1: https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonECS/current/ap-southeast-1/index.json
  - https://aws.amazon.com/elasticloadbalancing/pricing/
  - https://aws.amazon.com/fargate/pricing/
  - https://aws.amazon.com/vpc/pricing/
  - https://aws.amazon.com/secrets-manager/pricing/
- CodeBuild-hosted GitHub Actions runner: https://docs.aws.amazon.com/codebuild/latest/userguide/action-runner.html
- CodePipeline GitHub connections: https://docs.aws.amazon.com/codepipeline/latest/userguide/connections-github.html
- CodePipeline ECS deploy action: https://docs.aws.amazon.com/codepipeline/latest/userguide/action-reference-ECS.html
- Latest releases (pins unchanged since ADR 0005):
  - https://api.github.com/repos/step-security/harden-runner/releases/latest (v2.22.2)
  - https://api.github.com/repos/aws-actions/configure-aws-credentials/releases/latest (v6.3.0, `e1253824e5c10ff9df46874f81ed3ec929e19cfd`)
  - https://api.github.com/repos/actions/checkout/releases/latest (v7.0.1)

## Build briefs

> **As built (fix rounds, 2026-10-26):** `scripts/tf-init.sh` takes no argument and derives `infra/terraform/envs/$ENV`
> from `ENV` (validated by `valid_env`, so bootstrap is unreachable); workflows export `TF_DIR` in a step;
> `tf-destroy-check.sh` and `ecs-deregister-revisions.sh` are not in the `terraform-iac` path filter because that
> workflow never runs them; self-test cases live in `scripts/selftest/<area>.sh`, run by `scripts/ci-selftest.sh`.
> Where the brief below differs, the verify table above and the code win.


### devops-engineer (owns `infra/**`, `.github/**`, `scripts/**`, `Makefile`, `.pre-commit-config.yaml`)

**Goal:** G1 to G16. Do not edit `README.md`, `docs/**`, `PLAN.md`, `CLAUDE.md` or `app/**`. Never run `terraform apply`, `destroy`, `import` or `state`, any `gh secret`, `gh variable` or `gh workflow run`, or a merge. Write workflow and script files with Write or Edit, not Bash heredocs (guard hook, lessons log 23). Branch with `git switch -c <new> phase-5-hardening-teardown` (lessons log 25).

**Verify pins before use (NFR-3).** If anything differs, stop and report.

```bash
git ls-remote https://github.com/step-security/harden-runner 'refs/tags/v2.22.2*'           # dc2769abcc0fcfbadfc1df54081c1608579ef6b2
git ls-remote https://github.com/actions/checkout 'refs/tags/v7.0.1*'                      # 3d3c42e5aac5ba805825da76410c181273ba90b1
git ls-remote https://github.com/aws-actions/configure-aws-credentials 'refs/tags/v6.3.0*' # e1253824e5c10ff9df46874f81ed3ec929e19cfd
```

**Files**

- New: `.github/workflows/terraform-destroy.yml` (G1 to G10).
- Edit: `.github/workflows/terraform-iac.yml`. Use `scripts/tf-init.sh "$TF_DIR"` in `plan` and `apply`; fix the apply report text; add `scripts/tf-init.sh`, `scripts/tf-destroy-check.sh` and `scripts/ecs-deregister-revisions.sh` to the PR `paths`. Keep the apply job concurrency group `terraform-envs-dev`, with no `queue`.
- New: `scripts/tf-init.sh`, `scripts/tf-destroy-check.sh`, `scripts/ecs-deregister-revisions.sh`.
- Edit:
  - `scripts/tf-plan-summary.sh` (`--title`);
  - `scripts/lib.sh` (`ecs_service_status`);
  - `scripts/ecs-preflight.sh` (helper and the `AWSCURRENT` check, G14);
  - `scripts/ci-selftest.sh` (G16).
- Edit:
  - `infra/terraform/bootstrap/iam_deploy.tf` (`DescribeAppSecretMetadata`);
  - `infra/terraform/bootstrap/tests/iam.tftest.hcl`;
  - `infra/terraform/bootstrap/README.md` (deploy policy table);
  - `infra/terraform/envs/dev/README.md` and `infra/terraform/README.md` (teardown now through `terraform-destroy`).
- No change to `app-deploy.yml`, `Makefile`, `mise.toml` or the trust.

**Workflow shape (load-bearing parts)**

```yaml
name: terraform-destroy
on:
  workflow_dispatch:
    inputs:
      env: { description: Environment to destroy, type: choice, options: [dev], required: true, default: dev }
      confirm: { description: "Type destroy-<env>, for example destroy-dev", type: string, required: true }
permissions: {}
env: { TF_IN_AUTOMATION: "1", TF_INPUT: "0" }
jobs:
  confirm:    # name "confirm (no AWS)", permissions: {}, timeout 5, harden-runner, inputs via env only, no checkout
  destroy:    # needs confirm; if main; environment: dev; concurrency terraform-envs-dev (no cancel, no queue);
              # contents: read + id-token: write; timeout 45; env ENV=dev, TF_DIR=infra/terraform/envs/dev; steps G5
```

**Tests first (red, then green)**

1. `tf-destroy-check.sh` (fixtures in `ci-selftest`):
   - all deletes under `module.app_ecs.` print `N`;
   - an empty `resource_changes` prints `0`;
   - `no-op` and `read` entries are ignored;
   - a `create`, an `update`, a replace (`["delete","create"]`), a `forget`, and a delete of `aws_s3_bucket.x` (outside the module) each fail with a named message.
2. `tf-plan-summary.sh --title "Terraform destroy plan (dev)"` changes only the header, and the default header is unchanged.
3. `tf-init.sh` with a stub `terraform`:
   - called with `-lockfile=readonly` and `-backend-config=bucket=sis-dev-tfstate-123456789012-ap-southeast-1-an`, then `validate`;
   - `infra/terraform/bootstrap` is refused;
   - an uppercase env dir is refused;
   - missing `ACCOUNT` or `REGION` fails;
   - no arguments prints usage.
4. `ecs-deregister-revisions.sh` with stub `aws`:
   - service `ACTIVE` or `DRAINING` fails with "still exists";
   - `ClusterNotFoundException` then revisions 9, 8, 7, then `ClientException`: deregisters three in order and prints `DEREGISTERED=3`;
   - a repeated revision fails with "returned again";
   - describe `AccessDeniedException` fails with the account redacted;
   - a deregister error fails;
   - the iteration cap fails;
   - `ENV=prod` derives `sis-prod-app`.
5. `ecs-preflight.sh`:
   - `VersionIdsToStages` with `AWSCURRENT` passes;
   - missing, `{}` or only `AWSPENDING` fails with "has no current value";
   - DescribeSecret `AccessDeniedException` fails with "re-apply bootstrap";
   - `ResourceNotFoundException` fails with "not up";
   - the existing N4 cases still pass;
   - no version ID appears in the output.
6. `ecs_service_status`: `ACTIVE`, `DRAINING`, `INACTIVE`, `None`, `ClusterNotFoundException`, a `MISSING` failure, and throttling (dies, redacted).
7. Workflow structure (G16), with mutation tests that add `id-token: write`, `environment: dev` or `secrets.X` to `confirm` and must fail. Name parity with bootstrap `workflow_names.apply`. Concurrency group parity with `terraform-iac` apply.
8. Bootstrap `iam.tftest.hcl`:
   - deploy statement `DescribeAppSecretMetadata` has actions exactly `["secretsmanager:DescribeSecret"]` and resources exactly `["arn:aws:secretsmanager:ap-southeast-1:123456789012:secret:sis/dev/app-api-key-??????"]`;
   - no other `secretsmanager:` action in the deploy policy;
   - the guardrail still denies `GetSecretValue`;
   - the B20 and no-broad-allow tests still pass.
9. In the scratchpad: a bad copy of the destroy workflow with `${{ inputs.confirm }}` inside `run:`, a tag-pinned `uses:` and workflow-level `id-token: write` must fail `uvx zizmor@1.31.1 --offline` and `actionlint`. A copy with `queue: max` must fail actionlint (records Finding 5). Then the real file must be clean.

**Checks that define done**

- `make check` is green.
- `pre-commit run zizmor --all-files` has no findings and no ignore comments.
- `scripts/check-workflow-triggers.sh` passes.
- `terraform fmt -check -recursive infra/terraform`, `make tf-check` and `tflint --recursive` are clean.
- Grep checks on `terraform-destroy.yml`:
  - `name: terraform-destroy`;
  - the only trigger is `workflow_dispatch`;
  - top-level `permissions: {}`, and `permissions: {}` on `confirm`;
  - `environment: dev`, `id-token: write` and `secrets.` only in `destroy`;
  - harden-runner is step 1 with `egress-policy: audit` in both jobs;
  - `runs-on: ubuntu-24.04`, `timeout-minutes` 5 and 45;
  - `persist-credentials: false`;
  - `mask-aws-account-id: true`;
  - `plan -destroy` with `-out=tfplan`, applied from `tfplan`;
  - no `-auto-approve`, no `upload-artifact`, no `queue:`, no `${{` inside `run:`.
- No account ID anywhere. `git status` shows no state files, plan files, tfvars or scratch files.
- Commits (follow `pr-conventions`):
  - `infra(bootstrap): deploy role may describe the app secret metadata`
  - `fix(scripts): deploy preflight refuses a secret without a current value`
  - `chore(scripts): shared terraform init, destroy plan guard and revision cleanup`
  - `ci(workflows): approval-gated terraform destroy for dev`
  - `ci(workflows): reuse the terraform init script in terraform-iac`
- Hand back the checkpoint commands from this ADR unchanged.

### backend-dev

Not needed in Phase 5.

### Orchestrator docs list (D14, after the merge)

- **`README.md`:**
  - restructure per G19;
  - the trust table and the gates outside the trust;
  - a `terraform-destroy` row in the pipelines table;
  - the session flow (G18, including the N5 preflight message);
  - the cost table (G20, with sources);
  - teardown order with the end-of-lab bootstrap commands (state migration with a local override, deleting all object versions and delete markers with `list-object-versions` and `delete-objects`, then `plan -destroy` and apply of the saved plan);
  - troubleshooting: stale lock (admin `force-unlock`, user only), a pending run replaced in the shared group, re-creating while the secret is still being deleted;
  - the CodeBuild and CodePipeline section (G21);
  - replace "a local, admin-run destroy until Phase 5" and the "ADR 0004 B5" pointer.
- **`PROGRESS.md`:**
  - Phase 5 row (ADR 0006, PR, checkpoint results N5, N6, destroy, N7);
  - live state "Destroyed by terraform-destroy";
  - the re-create and teardown lines;
  - open items: close F23, the AWSCURRENT preflight and the simplifier re-check; move L4 (with the index-key and mask design) and L-a (PyYAML, `on` parsed as `true`) to Phase 6; add "re-evaluate `queue: max` when actionlint supports it" and, if it occurred, the G11 ECR fallback.
- **`docs/reference/CODING_STANDARDS.md`:**
  - fix the broken Tool versions line (line 191);
  - destructive workflows: dispatch only, typed confirmation in a credential-free job before the approval, a delete-only guard on the saved plan, applied in the same job;
  - one concurrency group per state (`terraform-envs-<env>`) shared by every job that writes it; no `queue:` until actionlint accepts it;
  - jobs that hold AWS credentials time out below the 60-minute session;
  - the deploy role's `DescribeSecret` exception (metadata only, `-??????` name match).
- **ADRs:**
  - ADR 0005: F23 resolved by ADR 0006 G12;
  - ADR 0004: L4 and L-a deferred to Phase 6 by ADR 0006;
  - ADR 0002: deploy policy table amended by G14.
- **`PLAN.md` (optional):** an FR-5 note pointing at G14.
