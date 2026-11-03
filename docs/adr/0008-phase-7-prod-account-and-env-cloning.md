# ADR 0008: Phase 7 prod account, built-in blue/green, and one-command environment cloning

- Status: accepted (Q1 answered 2026-11-02, ADR 0010 T9; Q2 to Q15 take the recommended answers)
- Date: 2026-10-27
- Amended 2026-10-27 (user): P1 keeps the PLAN layout, one thin root per environment, instead of one shared
  root. The clone script copies a root; the parity guard keeps the copies identical (sections B and C).
- Amended 2026-10-30 (user): amendment W (workflow display names) and amendment S (PR B scope: no `BLUE_GREEN`,
  rollback by promote). Both are below the verify sections.

## Context

### Goal

Phase 7 adds a second AWS account (`prod`) under AWS Organizations. Prod is bootstrapped from the same code as dev. It runs the same `modules/app-ecs` with its own values, state, secrets and roles. Prod receives the exact image digest that dev built and scanned, and it deploys with ECS built-in `BLUE_GREEN`: an ALB with two target groups, a bake time, and a rollback driven by a CloudWatch alarm. The user also asked for a way to clone an environment easily. Neither feature may weaken what is already in place: NFR-9 (no apply, destroy or secret commands by Claude), no account IDs in git, file-pinned OIDC trust, and harden-runner block mode on every job that holds credentials.

### Requirements

| ID | What Phase 7 must deliver | State found (branch `phase-7-prod-account` at `d39b84c`) |
|---|---|---|
| FR-6 | `envs/<env>` uses an S3 backend in its own account with `use_lockfile`. Values differ only through tfvars | `envs/dev` is a full root of 10 files. Its backend key `envs/dev/terraform.tfstate` and `env = "dev"` are hard-coded in two files. There is no `envs/prod` |
| FR-13 | Prod account in Organizations, bootstrapped with `accounts/prod.tfvars`. Same digest dev ECR to prod ECR. Trigger by dispatch or release tag. `prod` environment with a reviewer | Not started. Bootstrap `env` validation allows `dev` or `prod`. Deploy scripts are already parameterized by `ENV`, and their self-tests already cover `prod` (`tf-init`, `render-task-def`, `ecs-preflight`, `ecs-deregister-revisions`) |
| FR-15 | Dev `ROLLING` with circuit breaker. Prod `BLUE_GREEN` with ALB, two target groups, bake time and alarm rollback | Dev is `ROLLING` with circuit breaker and rollback. The module has one target group, and the listener's default action forwards to it |
| NFR-1 | Account-bearing values are secrets, repo level for PR plans and environment level for apply and deploy | Repo: `AWS_ACCOUNT_ID_DEV`, `AWS_PLAN_ROLE_ARN_DEV`, `ALB_INGRESS_CIDRS_DEV`. Env `dev`: `AWS_APPLY_ROLE_ARN`, `AWS_DEPLOY_ROLE_ARN`. Environment jobs also read the repo secret `AWS_ACCOUNT_ID_DEV` |
| NFR-2, NFR-4 | Explicit permissions. harden-runner first, block on credentialed jobs | `scripts/guard/harden_runner_policy.py` accepts only `vars.AWS_REGION`, `secrets.AWS_ACCOUNT_ID_DEV` and `env.ENV` in credentialed endpoints |
| NFR-3 | New tools pinned by version and checksum | crane is new (P9) |
| NFR-5 | Lock files, Dependabot | Dependabot `directories` include `/infra/terraform/envs/*` |
| NFR-7 | Session cap, trail and alert per account | Bootstrap creates the trail, the rule and the SNS email per account |
| NFR-8 | Default tags | Same locals in bootstrap and the env root |
| NFR-9 | User runs apply, destroy, secrets and Organizations | Unchanged. The clone script never runs `terraform`, `aws` or `gh` |

### Findings from official docs

1. **Provider.** `hashicorp/aws` v6.70.0 (2026-10-21) is the latest release, and it is the version in the lock files. Its `aws_ecs_service` docs document the following:
   - `deployment_configuration.strategy`: `ROLLING`, `BLUE_GREEN`, `LINEAR`, `CANARY`.
   - `bake_time_in_minutes`: 0 to 1440, used with `BLUE_GREEN`, `LINEAR` and `CANARY`.
   - `lifecycle_hook` (`AWS_LAMBDA` or `PAUSE`).
   - `alarms { alarm_names, enable, rollback }`.
   - `load_balancer.advanced_configuration`, which is "Required when using `BLUE_GREEN`": `alternate_target_group_arn`, `production_listener_rule`, `role_arn` ("allows ECS to manage the target groups"), and an optional `test_listener_rule`.
   - `deployment_controller.type` (`ECS` default) and `sigint_rollback`, which needs `wait_for_steady_state = true`.
2. **ECS blue/green.**
   - The deployment controller must be `ECS`.
   - The traffic shift is "an immediate (all-at-once) shift".
   - Bake time is "the duration when both blue and green service revisions are running simultaneously after the production traffic has shifted". Blue/green "may double your resource usage during deployments".
   - The lifecycle stages are `RECONCILE_SERVICE`, `PRE_SCALE_UP`, `SCALE_UP`, `POST_SCALE_UP`, `TEST_TRAFFIC_SHIFT`, `POST_TEST_TRAFFIC_SHIFT`, `PRE_PRODUCTION_TRAFFIC_SHIFT`, `PRODUCTION_TRAFFIC_SHIFT`, `POST_PRODUCTION_TRAFFIC_SHIFT`, `BAKE_TIME` and `CLEAN_UP`.
   - An ALB setup needs two IP target groups and a production listener rule; a test rule is optional. ECS rewrites the rule weights during a deployment.
3. **Failure detection.** The current failure-detection page says the circuit breaker and CloudWatch alarms "only support rolling update deployment and blue/green deployment types", that "either can trigger deployment failure", and that "the rollback method requires a previous deployment in COMPLETED state". The older alarm page says alarms are for "the rolling update (`ECS`) deployment controller". `BLUE_GREEN` runs on that controller, so the two pages agree. The alarm page also says: "If an alarm is in the `ALARM` state at the beginning of a deployment, Amazon ECS will not monitor alarms for the duration of that deployment". It recommends `HTTPCode_ELB_5XX_Count`.
4. **Load balancer infrastructure role.**
   - Trust: `ecs.amazonaws.com`, `sts:AssumeRole`, with no condition in the AWS example.
   - The managed policy `AmazonECSInfrastructureRolePolicyForLoadBalancers` is at v6 (edited 2026-02-12). It allows ELB `Describe{Listeners,Rules,TargetGroups,TargetHealth}` on `*`, `Register/DeregisterTargets` on `targetgroup/*/*`, `ModifyListener` on `listener/app/*/*/*` and `listener/net/*/*/*`, and `ModifyRule` on `listener-rule/app/*/*/*/*`.
   - Whoever creates or updates the service needs `iam:PassRole` on it with `iam:PassedToService = ecs.amazonaws.com`.
5. **Service deployments API.**
   - `ServiceDeployment.status` values: `PENDING`, `SUCCESSFUL`, `STOPPED`, `STOP_REQUESTED`, `IN_PROGRESS`, `ROLLBACK_REQUESTED`, `ROLLBACK_IN_PROGRESS`, `ROLLBACK_SUCCESSFUL`, `ROLLBACK_FAILED`. It also carries `lifecycleStage`, `statusReason` and `targetServiceRevision`.
   - IAM (service reference): `ListServiceDeployments` on `service`. `DescribeServiceDeployments` on `service` and `service-deployment/${Cluster}/${Service}/${Id}`. `DescribeServiceRevisions` on `service` and `service-revision/${Cluster}/${Service}/${Id}`.
   - `UpdateService` keeps the `ecs:task-definition` condition key.
6. **CloudWatch.** `PutMetricAlarm`, `DeleteAlarms`, `DescribeAlarms` and `SetAlarmState` support the `alarm` resource type. The tag actions support `alarm` too.
7. **ECR.**
   - `GetAuthorizationToken` returns a token that "can be used to access any Amazon ECR registry that your IAM principal has access to".
   - A cross-account pull needs a repository policy in the source account that allows `ecr:BatchGetImage` and `ecr:GetDownloadUrlForLayer`. The puller also needs `GetAuthorizationToken` in its own IAM policy.
   - `crane copy` "copies a remote image from src to dst while retaining the digest value".
   - go-containerregistry v0.22.1 (2026-09-04) ships `checksums.txt` and an in-toto provenance file. GitHub reports these asset digests:
     - `go-containerregistry_Linux_x86_64.tar.gz` `sha256:0ab7a1d6932a213aed964ce97666c3077fe691c8606413674a8b3e0b9ec4cda0`;
     - `go-containerregistry_Darwin_arm64.tar.gz` `sha256:2231fc8df8806d20d680ff1225db44e095a55dd6ac1ae8eced4faf4b278b78fb`.
8. **GitHub.**
   - The OIDC `sub` is `repo:O/R:environment:<name>` when a job references an environment, and `...:pull_request` only without one.
   - Reusable workflows: "Jobs using the matrix strategy can call a reusable workflow". For `./.github/workflows/x.yml`, "the called workflow is from the same commit as the caller". To use environment secrets in a reusable workflow, "set `environment` on the job in the reusable workflow", and "the caller workflow must still pass the secret". Workflow-level `env` is not propagated.
   - Environment variables take precedence over repository variables. The secrets docs I opened do not state a precedence rule for secrets, so this ADR never reuses one secret name across levels.
   - Required reviewers: up to six; "prevent self-review" is optional. Environment secrets are withheld until approval and are available on public repos on the free plan.
9. **Terraform workspaces** "are not a suitable isolation mechanism" when each deployment has its own backend credentials.
10. **Organizations.**
    - `create-account` creates `OrganizationAccountAccessRole` in the new member account.
    - The root user email must be unique.
    - Member accounts are created in the root and can be moved to OUs.
11. **zizmor** has an `overprovisioned-secrets` audit ("excessive sharing of the `secrets` context") and a `secrets-inherit` audit.

### Repo facts that shape the design

- About 38 workflow lines are dev-specific: literal `environment: dev`, the `secrets.AWS_ACCOUNT_ID_DEV` hosts, the `terraform-envs-dev` groups and `options: [dev]`.
- The trigger allowlist (`scripts/guard/workflow_triggers.py`) accepts only `pull_request`, `push` and `workflow_dispatch`, so a reusable workflow (`workflow_call`) needs a policy change.
- `scripts/ecs/render-task-def.sh` replaces only the image of the **latest ACTIVE revision**. A revision the user registers by hand would therefore carry over into the next deploy (relevant to the P16 demo).
- Two Phase 7 items were deferred: the YAML loader for the workflow self-tests (ADR 0007), and the composite action for the AWS preamble (ADR 0006).
- `scripts/guard/harden_runner_policy.py` N1 Low ("refuse `secrets` expressions in audit jobs") is due "when the policy is next touched".

### Evaluation of the reference clone script (`create_environment.sh <name>`)

| Behavior of the reference | Effect in this repo |
|---|---|
| Must run from `scripts/`, with relative paths | Run from anywhere else, it fails or writes to the wrong place. Our scripts resolve `$ROOT` in `lib.sh` |
| `cp -r environments/dev/* environments/<name>/` | `*` skips dotfiles, so `.terraform.lock.hcl` is **not** copied. CI runs `init -lockfile=readonly`, so the new env fails (NFR-5). It does copy gitignored local files if present (`*.auto.tfvars` with the account ID, a local `terraform.tfstate`, `tfplan`), plus `tests/dev.tftest.hcl` whose dev asserts fail for the new env |
| `sed` on `default = "dev"` in `variables.tf` | Our root variables have no defaults; `env` lives in `terraform.tfvars`. The sed matches nothing and succeeds silently, so the clone keeps `env = "dev"` and would plan dev's names in the new account |
| `sed` on `key = "dev/terraform.tfstate"` in `terraform.tf` | Our key is `envs/dev/terraform.tfstate` in `backend.tf`. It matches nothing, so the clone **writes to dev's state key** (in the new account's bucket) |
| `sed -i` | GNU and BSD (macOS) syntax differ |
| No name validation | `Dev`, `a b` and `../x` reach paths and AWS names |
| Not atomic | A failure halfway leaves a partial directory, and the "exists" check then blocks a retry |
| Prints "terraform init" | Our init needs `-backend-config=bucket=...`, and only after the account is bootstrapped |
| Not covered | `vpc_cidr`, bootstrap `accounts/<env>.tfvars`, the GitHub environment and secrets, the workflow env lists, harden-runner hosts, the OIDC trust, the README (D16) |

Verdict: the idea (one command plus printed next steps) is right. The mechanism (copying a directory and blind `sed`) is wrong for this repo. Its worst failure is that it **succeeds silently** with dev's env name and state key.

## Decision

### A. Decisions

| # | Decision | Alternatives | Pro | Con |
|---|---|---|---|---|
| P1 | **One thin root per environment (PLAN layout).** `envs/dev/` and `envs/prod/` each hold `main.tf`, `variables.tf`, `locals.tf`, `providers.tf`, `versions.tf`, `outputs.tf`, `backend.tf`, `.terraform.lock.hcl`, `README.md`, `tests/envs.tftest.hcl` and a committed `terraform.tfvars`. Every root calls `modules/app-ecs`. The parity guard (P3) allows only four differences: `terraform.tfvars`, the `key` line of `backend.tf`, `versions.tf` and `.terraform.lock.hcl` | (s) One shared root with `<env>.tfvars` per env. (w) Terraform workspaces | Matches PLAN 7.3 and FR-6 as written, and HashiCorp's guidance to keep environments with separate accounts and credentials in separate configurations. **Staged upgrades:** each env has its own lock file, so Dependabot opens the provider bump for dev first, and prod follows after dev is proven. No migration: `envs/dev/` and its state key stay as they are | About 150 lines are copied per env. They cannot drift, because the parity guard fails a PR on any other difference. (s) would remove the copies, but a provider or Terraform bump would reach prod in the same merge as dev. (w) was rejected per Finding 9 |
| P2 | **Clone tool `scripts/tf/new-env.sh` with `make new-env`** (spec in C). It generates the root `envs/<env>/` from `envs/<from>/`, `bootstrap/accounts/<env>.tfvars.example` and the gitignored `accounts/<env>.tfvars` with placeholders. It rewrites only named keys, refuses clearly on any doubt, and prints the user-run steps. It never runs `terraform`, `aws`, `gh` or `git` writes | The reference script as is. Docs only, no script. A script that also edits workflows and runs `gh` | One command, deterministic, testable offline, atomic. The workflow wiring is left to a reviewed diff that the parity guard enforces | Wiring is still manual (about 15 lines per env, printed by the script) |
| P3 | **Environment parity guard** in repo-guard and `make lint` (`scripts/guard/env_parity.py` on the shared YAML loader). The env set `E` is the directories under `envs/`. Each root must be byte-identical to `envs/dev/` except the four files P1 allows, and must have `env = "<name>"` and `key = "envs/<name>/terraform.tfstate"`, a unique `vpc_cidr`, an `accounts/<name>.tfvars.example`, and an entry in every workflow env list (D) | No guard | A half-cloned env fails `guard (no AWS)` with a message naming the missing piece | One more helper with fixtures |
| P4 | **Env name rule** `^[a-z][a-z0-9]{1,7}$` everywhere (`lib.sh valid_env`, bootstrap and module `env` validation). The script also refuses `local`, `bootstrap`, `modules`, `tests`, `shared`, `all`, `env` | Keep the `["dev","prod"]` allowlist in Terraform | A third env needs no Terraform edit. The 8-character cap keeps every AWS name in limits: the CloudTrail bucket `sis-<env>-cloudtrail-<acct>-<region>-an` is at most 63 characters, the ALB and target group names at most 32 | The allowlist added no security (an env still needs bootstrap, a trust and a GitHub environment) but was easy to read |
| P5 | **Secret names** (table in H). Environment jobs read **environment-level, env-agnostic** names: `AWS_ACCOUNT_ID`, `AWS_APPLY_ROLE_ARN`, `AWS_DEPLOY_ROLE_ARN`, `ALB_INGRESS_CIDRS`, plus `PROMOTION_TARGET_ACCOUNT_ID` in `dev` only. PR plan jobs (no environment) read **repo-level, suffixed** names `AWS_ACCOUNT_ID_<ENV>`, `AWS_PLAN_ROLE_ARN_<ENV>` and `ALB_INGRESS_CIDRS_<ENV>`. No name exists at two levels | One suffixed repo set for everything (today's dev model) | A parametrized job never needs `secrets[...]` with a computed name. No dependence on secret precedence (Finding 8) | The account ID is stored twice per env (repo and environment). `scripts/aws/check-config.sh` already fails on a mismatch with the role ARN |
| P6 | **Workflow parametrization.** (1) Environment-gated jobs stay in **top-level files**, parametrized by a `workflow_dispatch` choice input `env`: `environment: ${{ inputs.env \|\| 'dev' }}`, concurrency `terraform-envs-<env>`, workflow `env.ENV` from the same expression, validated by a step. Push to `main` still applies **dev only**. (2) The PR plan (no environment) moves to **one reusable workflow** `reusable-terraform-plan.yml` (plan, plan-role guardrails, sticky comment), called **once per env** from `terraform-iac.yml` with explicit secret mapping, never `secrets: inherit`. (3) `app-deploy.yml` stays the dev build-and-deploy file. Prod gets `app-promote.yml` (P9, P10). (4) No composite action: harden-runner must be step 1 with a per-job allowlist, and only 3 short preamble steps remain. The ADR 0006 deferred item is closed | (c1) Everything reusable, including apply and deploy. (c3) A workflow file per env. (c4) A matrix with `secrets[format(...)]` | The trust pin (`job_workflow_ref`) stays on the **top-level file** that holds the credentialed job, which is the strongest pin. The dev-only literals collapse to one choice list per file. Adding an env costs one 10-line caller job and three choice entries | Two patterns (top-level for env jobs, reusable for PR plan). (c1) would move the pin to the callee, which any merged caller on `main` can invoke, and environment secrets in callees still need passing (Finding 8). (c4) is flagged by zizmor's `overprovisioned-secrets` and by our endpoint policy |
| P7 | **OIDC trust shape unchanged.** `aud`, `sub`, `repository_id`, `repository_owner_id`, `ref = refs/heads/main` (apply, deploy) or `refs/pull/*/merge` (plan), `aws:RequestedRegion`, and `job_workflow_ref` on apply and deploy. The `workflow_files` local derives the deploy file: `app-deploy.yml` when `promotion_source_account_id` is null (dev, the build env), `app-promote.yml` otherwise (prod). Apply stays `terraform-iac.yml` plus `terraform-destroy.yml`. The plan role never pins a workflow, so the reusable plan needs no trust change | Pin the reusable callee. A tag `ref` for prod | No new trust concept. Dev trust does not change, so PR A needs **no bootstrap re-apply** | A third promoted env reuses `app-promote.yml` (intended) |
| P8 | **Policy updates (repo-guard).** Trigger allowlist: `workflow_call` only in `reusable-*.yml`, and such files carry nothing else. harden-runner policy: (1) a job with `uses:` (a reusable call) has no steps, so it is checked through its callee, and must not use `secrets: inherit`. (2) Credentialed endpoints may use only `vars.AWS_REGION`, `env.ENV` and `secrets.AWS_ACCOUNT_ID`. `secrets.AWS_ACCOUNT_ID_DEV` is allowed **only** in `app-promote.yml` job `promote`, for the source registry host. (3) The N1 Low item: audit jobs may not reference `secrets` in any form in endpoints (`secrets.`, `secrets[`, `toJSON(secrets)`), nor an `env` value built from a secret. (4) The workflow self-tests move from `sed` ranges to the YAML loader (ADR 0007 deferred) | Leave the policies as they are | Reusable workflows cannot widen triggers. One account expression per env job. Closes two carried items | More rules and fixtures |
| P9 | **Promotion = `crane copy` by digest, dev ECR to prod ECR, in the approved prod job.** The dev repository gets a **pull-only** repository policy: Principal is the prod account root, with Condition `StringEquals aws:PrincipalArn = arn:aws:iam::<prod>:role/sis-prod-gha-deploy` and actions `ecr:BatchGetImage` and `ecr:GetDownloadUrlForLayer`. The prod deploy role gets a matching identity statement on the one dev repository ARN. crane v0.22.1 is installed by `scripts/ci/install-tools.sh` (checksum-verified, `mise.toml` pin), with `DOCKER_CONFIG` in `$RUNNER_TEMP` (deleted after). No Docker is needed, so the job keeps `disable-sudo-and-containers: true` | (r) ECR cross-account replication. (d) `docker pull` and `push`. (l) An AWS CLI layer-by-layer copy. (x) Prod tasks pull straight from dev ECR. (art) Pass the image as an artifact from a dev-role job | Digest preserved by design (Finding 7). Prod never depends on dev at run time. Least privilege: one repo, two read actions, one principal | (r) replicates **every** dev push and keeps the source **repository name** (`sis-dev-app` would appear in prod, off the name contract and the boundary, and outside Terraform). (d) Docker recompresses layers, so the digest can change. (l) is about 100 lines of blob handling. (x) breaks when dev is torn down. (art) needs dev-role trust for a prod workflow and a public 1-day artifact. Cost of P9: the dev apply role gains `SetRepositoryPolicy` (R21), and a new tool to pin |
| P10 | **Prod release trigger = `workflow_dispatch` on `main`** with input `sha` (40 hex). A credential-free `resolve` job checks that the SHA is an ancestor of `origin/main` and that an `app-deploy` run for that SHA on `main` **succeeded** (`gh run list --workflow app-deploy.yml --commit <sha> --branch main`, `actions: read`). Only then does `promote` start | Tag `v*` (`on.push.tags`) | Keeps `ref = refs/heads/main` (`StringEquals`) on the prod trust, with no tag ruleset needed. "Promote what was green in dev" becomes a check, not a habit | No release object. Tags stay an optional later step (needs `StringLike ref` and a tag ruleset) |
| P11 | **Prod `BLUE_GREEN` in `modules/app-ecs`** behind `deployment_strategy` (`ROLLING` default, or `BLUE_GREEN`), detailed in E. Dev stays `ROLLING` with an unchanged resource shape | A separate prod module | One module, FR-6 | Conditional (`count` and `dynamic`) code paths, each covered by a test |
| P12 | **ECS load balancer infrastructure role** `sis-<env>-ecs-elb`, created by **bootstrap** (admin). Its inline policy is the managed policy's action set scoped to `sis-<env>-*`: ELB Describe on `*` (no resource-level support), `Register/DeregisterTargets` on `targetgroup/sis-<env>-*/*`, `ModifyListener` on `listener/app/sis-<env>-*/*/*`, `ModifyRule` on `listener-rule/app/sis-<env>-*/*/*/*`. Trust exactly as AWS documents it. Guardrail G4 protects it | Attach the AWS managed policy. Have the module (apply role) create the role | The apply role never creates a role with ELB write rights. The policy reaches only this env's ALB, while the managed policy covers every ALB and NLB in the account | AWS has edited the managed policy 6 times. A future ECS need fails closed (R20). The fallback is to attach the managed policy |
| P13 | **Uniform bootstrap** in every account: the infra role, the apply alarm statements, `PassRole` on the infra role, and the deploy service-deployment reads. Only the cross-account ECR read and the deploy workflow file depend on `promotion_source_account_id` | Prod-only statements by env name | One code path, so dev could switch strategy with a tfvars change | Dev holds unused grants scoped to `sis-dev-*` |
| P14 | **One rollout waiter for both strategies** on the service deployments API: `list-service-deployments`, then `describe-service-deployments`, then `describe-service-revisions` to match the target task definition. `SUCCESSFUL` passes. `ROLLBACK_*` and `STOPPED` fail with `statusReason`. The log prints `lifecycleStage`. The timeout covers the bake time | Keep `describe-services` for dev and add a second evaluator for prod | One evaluator, and the documented view of blue/green stages | A proven dev path changes. Dev needs the bootstrap re-apply first (B6) |
| P15 | **Two deploy guards.** (1) Preflight refuses while any `sis-<env>-*` alarm is in `ALARM` (Finding 3: ECS would ignore alarms for that deployment), using `cloudwatch:DescribeAlarms` on `alarm:sis-<env>-*`. (2) `scripts/ecs/render-task-def.sh` refuses a source revision whose container `environment` is not exactly `[{APP_ENV: <env>}]` | None | An alarm can never be silently ignored. A hand-made demo revision (P16) can never be promoted by accident | One read permission and one render rule |
| P16 | **Rollback demos.** Required: the user, with prod admin SSO, registers a revision with `BREAK=true` (same digest) and runs `update-service`. Green targets fail `/health`, the unhealthy-host alarm (or the circuit breaker) fails the deployment, and ECS rolls back while blue keeps serving. Then the revision is deregistered. Optional: during `BAKE_TIME` of a good promote, `set-alarm-state ALARM` shows traffic return to blue | A broken image through the pipeline (needs a broken commit on `main` or a promote input that accepts non-main tags) | No weakening of "only green `main` commits reach prod". No app change | "Broken" is a revision setting, not a different image. The P15 render rule keeps it from leaking |
| P17 | **Negative test N10** (PLAN 7.5): `app-promote.yml` dispatch input `mode: prove-isolation` runs job `isolation` with `environment: dev`. It runs `scripts/aws/assert-web-identity-denied.sh plan apply deploy` with `ACCOUNT = secrets.AWS_ACCOUNT_ID_PROD` and `ENV=prod`. Its token carries `job_workflow_ref = app-promote.yml@refs/heads/main`, which the prod deploy role trusts, so **only `sub` differs** for that role | A step in the dev deploy job (its file is not in the prod trust, so two claims would differ). A no-environment job (tests the wrong claim) | Proves exactly "a dev-environment job is refused by prod". The prod alert email fires (a demo of NFR-7) | Needs a dev approval and sends prod alert emails |
| P18 | **PR plans run for prod too** (read-only prod plan role, FR-3 parity) | Plan only inside the approved prod apply | Reviewers see prod impact before merge | ADR 0007 residual M1 now spans prod read-only metadata (R25) |
| P19 | **ECR stays in the env stack** | Move both ECR repositories to bootstrap (persistent) | No re-architecture of a proven stack | Promotion needs the dev stack up (R22). Recorded as the next improvement |
| P20 | **Organizations.** A management account with no workloads, prod as a member, and the IAM Identity Center organization instance with an `AdministratorAccess` permission set assigned to the user (CLI profile `sis-prod-admin`). Phase 7 adds no SCPs | Prod as a standalone account. A region-deny SCP now | Matches PLAN 7.1. Costs nothing | Depends on Q1 (where dev's Identity Center lives) |
| P21 | **Bake time 5 minutes, `desired_count = 1`** in prod | 10 minutes or more | One extra task for about 5 minutes per deploy | A shorter window to catch problems |
| P22 | **Two PRs** (I) | One PR. Three PRs (split B into code and live proof) | PR A is fully provable on dev with no admin step | PR B is large; the build agent may split B into B1 (bootstrap and module) and B2 (workflows) if review needs it |

### B. Environment layout (P1)

```
infra/terraform/
  bootstrap/                      per account, unchanged shape
    accounts/dev.tfvars.example   committed; <env>.tfvars gitignored (account IDs)
    accounts/prod.tfvars.example  new (PR B): adds promotion_source_account_id = "<DEV_ACCOUNT_ID>"
  modules/app-ecs/                + BLUE_GREEN path (PR B)
  envs/
    dev/                          unchanged location and state key
      main.tf variables.tf locals.tf providers.tf outputs.tf   identical in every env (P3)
      versions.tf .terraform.lock.hcl                          may differ during a staged upgrade
      backend.tf                  only the key line differs
      terraform.tfvars            committed, no account ID (FR-6)
      README.md                   identical; names the env through terraform.tfvars only
      tests/envs.tftest.hcl       generic: expected names built from var.env, so it is identical too
    prod/                         PR B, generated by make new-env
```

- `tests/dev.tftest.hcl` becomes the generic `tests/envs.tftest.hcl` in PR A: every expected name is built from
  `var.env` (`"sis-${var.env}-cluster"`), and strategy-specific asserts key on `var.deployment_strategy`.
- `.gitignore`, `scripts/tf/init.sh` (`infra/terraform/envs/${ENV}`), `scripts/tf/check.sh` (one pass per root) and Dependabot
  (`/infra/terraform/envs/*`) already fit this layout. Only `.terraform-*/` (per-account `TF_DATA_DIR` for
  bootstrap) is added to `.gitignore`.
- `terraform-iac` push paths: `infra/terraform/envs/dev/**` and `infra/terraform/modules/**`, as today. A change
  under `envs/prod/` never starts a dev apply.
- **Staged upgrade flow:** Dependabot opens one PR per root. Merge the dev one, apply, check, then merge the prod
  one. Between the two, the parity guard accepts the version difference in `versions.tf` and the lock file only.

### C. Clone script spec (`scripts/tf/new-env.sh`)

**Usage**

```
scripts/tf/new-env.sh <env> [--from <env>] [--cidr 10.N.0.0/16] [--dry-run]
make new-env ENV=<env> [FROM=dev] [CIDR=...] [DRY_RUN=1]
```

Exit codes: 0 created (or dry run shown), 1 refused, 2 usage.

**Validation (before any write)**

1. `<env>` matches P4, is not reserved, and differs from `--from`.
2. The source root `envs/<from>/` and `bootstrap/accounts/<from>.tfvars.example` exist.
3. **None** of the targets exist: `envs/<env>/`, `accounts/<env>.tfvars.example`, `accounts/<env>.tfvars`. Otherwise the script refuses and lists them (no partial overwrite, no "merge").
4. The source tfvars holds no `aws_account_id` and no 12-digit run.
5. Each rewritten key matches `^<key>[[:space:]]*=` **exactly once** in the source. Otherwise: "source format changed: update scripts/tf/new-env.sh".
6. CIDR: given, or the next free `10.N.0.0/16` (N = highest used second octet + 10, at most 250). It must be a `/16` inside `10.0.0.0/8`, and its second octet must be unused by every `envs/*/terraform.tfvars`.
7. `accounts/<env>.tfvars` is confirmed ignored with `git check-ignore -q` before it is written.

**Writes (a temp directory next to the target, then one `mv`; an `EXIT` trap removes temps)**

| File | Content |
|---|---|
| `envs/<env>/` | Copy of the **tracked** files of `envs/<from>/` only (`git ls-files`), so `.terraform/`, `*.auto.tfvars`, local state and plan files are never copied, and the lock file is. Then in `terraform.tfvars`: header replaced ("Generated by scripts/tf/new-env.sh from `<from>`; review every value"), rewritten keys `env`, `vpc_cidr`, `deployment_strategy` (if `--strategy`) and `promotion_target_env = ""` (a new env is never a promotion source). In `backend.tf`: the `key` line becomes `envs/<env>/terraform.tfstate`. Every other file and line is byte-identical |
| `bootstrap/accounts/<env>.tfvars.example` | Copy of the source example. Header "Copy to `<env>.tfvars`". Placeholder `<FROM_ACCOUNT_ID>` becomes `<ENV_ACCOUNT_ID>` (uppercase via `tr`, bash 3.2) |
| `bootstrap/accounts/<env>.tfvars` (gitignored, mode 600) | Same placeholders, for the user to fill. The script never takes or prints an account ID |

**Prints** a "Next steps (you run these)" list:

1. Account and SSO profile `sis-<env>-admin`.
2. Fill `accounts/<env>.tfvars`.
3. Bootstrap first apply on local state with `TF_DATA_DIR=.terraform-<env>`, then migrate state (commands as in the PR B checkpoint, with `<env>` filled and `<ENV_ACCOUNT_ID>` left as a placeholder).
4. GitHub environment `<env>` and the secret commands from H.
5. The exact YAML snippet of the plan caller job, plus the three choice lists to edit.
6. `make check` (the parity guard names what is missing).
7. Open a PR.

The repo slug comes from `git remote get-url origin`, with a placeholder as fallback.

**Never:** runs `terraform`, `aws`, `gh`, `git add`, `commit` or `push`; calls the network; prints a 12-digit run.

**Self-test** (`scripts/selftest/new-env.sh`, run by `scripts/ci/selftest.sh`; a temp git repo with fixture files plus copies of `lib.sh` and the script):

| T | Case | Expect |
|---|---|---|
| T1 | `qa --from dev` | `envs/qa/` plus the 2 account files. `diff -r` with `envs/dev/` shows only the rewritten keys and the backend key; the lock file is present; no `.terraform/` or `*.auto.tfvars` even when the source has them; header present; account file ignored, mode 600 |
| T2 | Run again | Exit 1, the 3 paths listed, files unchanged (hash) |
| T3 | Names `Dev`, `a`, `toolongname`, `../x`, `dev prod`, `bootstrap`, `local`, `''`, `qa\n../x` | Exit 1 or 2, nothing written |
| T4 | `--from` missing, or `--from qa` (self) | Refused |
| T5 | Auto CIDR with dev at 10.40 | 10.50.0.0/16. With a 10.50 env present: 10.60 |
| T6 | `--cidr` overlapping, `/24`, `192.168.0.0/16`, garbage | Refused |
| T7 | Source with `env` twice, or no `vpc_cidr` | "source format changed" |
| T8 | Source holding `aws_account_id` or a 12-digit run | Refused |
| T9 | `--dry-run` | Prints the plan, writes nothing (tree hash equal) |
| T10 | PATH stubs `terraform`, `aws`, `gh` that fail when called | Never called |
| T11 | Run from `/` | Works (no cwd dependence) |
| T12 | Target directory read-only mid-run | Exit 1, no target or temp file left |
| T13 | Output scan | No 12-digit run; contains the YAML snippet and `<ENV_ACCOUNT_ID>` |
| T14 | `.gitignore` regression: account file not ignored | Refused before writing |

Parity guard fixtures: a missing choice, an extra choice, a missing caller job, a mismatched `env =` line, a duplicate CIDR, a missing `.example`. Each must fail with a named message.

### D. Workflows

| File | PR A | PR B |
|---|---|---|
| `terraform-iac.yml` | `checks` unchanged. `plan-dev` calls `reusable-terraform-plan.yml` with `env: dev` and secrets `AWS_ACCOUNT_ID: secrets.AWS_ACCOUNT_ID_DEV`, `AWS_PLAN_ROLE_ARN: ...PLAN_ROLE_ARN_DEV`, `ALB_INGRESS_CIDRS: ...ALB_INGRESS_CIDRS_DEV`. `apply` takes `environment`, concurrency and `ENV` from `inputs.env \|\| 'dev'`, a dispatch choice `[dev]`, and env secrets `AWS_ACCOUNT_ID` and `ALB_INGRESS_CIDRS`. Plan and apply use `-var-file="${ENV}.tfvars"` | `plan-prod` caller. Choice `[dev, prod]`. `plan-dev` also passes `PROMOTION_TARGET_ACCOUNT_ID: secrets.AWS_ACCOUNT_ID_PROD`. `apply` passes `TF_VAR_promotion_target_account_id: secrets.PROMOTION_TARGET_ACCOUNT_ID`, masked. `monitoring.<region>.amazonaws.com:443` added to plan, apply and destroy lists |
| `reusable-terraform-plan.yml` (new) | `on: workflow_call` (input `env`; secrets `AWS_ACCOUNT_ID` required, `AWS_PLAN_ROLE_ARN` required, `ALB_INGRESS_CIDRS` optional, `PROMOTION_TARGET_ACCOUNT_ID` optional). Jobs `plan`, `plan-role-guardrails`, `comment` move here unchanged except names. Block allowlists use `secrets.AWS_ACCOUNT_ID`. The comment job still checks out `base.sha` | Same file |
| `terraform-destroy.yml` | `environment: ${{ inputs.env }}`, concurrency `terraform-envs-${{ inputs.env }}`, `ENV` from the input (validated in `confirm`), env secrets | Options `[dev, prod]` |
| `app-deploy.yml` | Dev only. `secrets.AWS_ACCOUNT_ID_DEV` becomes env secret `AWS_ACCOUNT_ID` | Waiter (P14) |
| `app-promote.yml` (new, PR B) | n/a | Dispatch inputs: `env` choice `[prod]`, `sha`, `mode` choice `[promote, prove-isolation]`. Jobs: `resolve` (audit, `contents: read`, `actions: read`, no AWS); `promote` (`environment: ${{ inputs.env }}`, block, sudo and containers disabled; hosts: `github.com`, `release-assets.githubusercontent.com`, `sts`, `api.ecr`, `${{ secrets.AWS_ACCOUNT_ID_DEV }}.dkr.ecr...`, `${{ secrets.AWS_ACCOUNT_ID }}.dkr.ecr...`, `prod-<region>-starport-layer-bucket.s3.<region>.amazonaws.com`, `ecs`, `secretsmanager`, `monitoring`); `isolation` (N10, `environment: dev`, hosts `github.com` and `sts`) |
| `oidc-smoke-test.yml` | Unchanged | N1 dispatch also checks the prod roles (`AWS_ACCOUNT_ID_PROD`) |
| `repo-guard.yml` | Parity guard step (P3) | n/a |

The `promote` steps:

1. Check config and mask both accounts.
2. Assume the prod deploy role.
3. Preflight (stack up, secret current, no alarm in `ALARM`).
4. Resolve the source digest with `crane digest <dev>/sis-dev-app:<sha>`.
5. If the prod tag `<sha>` exists, its digest must equal the source digest, else fail. If it does not exist, `crane copy <dev>@<digest> <prod>/sis-prod-app:<sha>` and re-read the digest, which must be equal.
6. Render with `--env prod`, register, update.
7. Wait (P14) and write the summary (no account ID).
8. Remove `DOCKER_CONFIG` and the temp files.

### E. Module `BLUE_GREEN` (PR B)

- **Variables** (module and root):
  - `deployment_strategy` (`ROLLING`\|`BLUE_GREEN`);
  - `bake_time_minutes` (0 to 60, default 5);
  - `promotion_target_env` (default `""`);
  - `promotion_target_account_id` (sensitive, default `""`; cross-variable validation: 12 digits if the env is set, else empty).
- **ALB:**
  - Target group `sis-<env>-tg` (name contract) plus `sis-<env>-tg-alt`.
  - `ROLLING` keeps today's listener default forward, so dev's resource shape is unchanged.
  - `BLUE_GREEN`: the listener default is `fixed-response 404`. `aws_lb_listener_rule.production` (priority 1, `path-pattern /*`, weighted forward 100/0) carries `lifecycle { ignore_changes = [action] }`, because ECS rewrites the weights.
  - No test listener rule and no lifecycle hooks (Q11).
- **Service:**
  - `deployment_configuration { strategy, bake_time_in_minutes (BLUE_GREEN only) }`.
  - `alarms { alarm_names = [3 alarms], enable = true, rollback = true }` (BLUE_GREEN only).
  - `load_balancer.advanced_configuration { alternate_target_group_arn, production_listener_rule, role_arn = "arn:<p>:iam::<acct>:role/sis-<env>-ecs-elb" }`, built from the name contract like `boundary_arn`.
  - Circuit breaker stays on. `deployment_maximum_percent = 200`, minimum 100. `ignore_changes = [task_definition]` stays.
  - If the first prod plan after a promote shows `load_balancer` drift (a target group swap), add it to `ignore_changes` (R18, step B15).
- **Alarms** (no actions; ECS polls them):
  - `sis-<env>-tg-unhealthy` and `sis-<env>-tg-alt-unhealthy`: `AWS/ApplicationELB` `UnHealthyHostCount`, Maximum, period 60, 1 of 1, `> 0`, dimensions `TargetGroup` and `LoadBalancer` (`arn_suffix`), `treat_missing_data = notBreaching`.
  - `sis-<env>-alb-5xx`: `HTTPCode_ELB_5XX_Count`, Sum, period 60, `>= 5`, notBreaching (the AWS-recommended metric).
- **ECR:** `aws_ecr_repository_policy` exists only when `promotion_target_env != ""`. Pull-only, as in P9.
- **Tests:**
  - ROLLING produces no alt target group, rule, alarms or advanced configuration.
  - BLUE_GREEN produces all of them, with the role ARN built from the contract.
  - The repo policy has exactly two actions, the root principal and the `aws:PrincipalArn` condition. Its count is 0 when unset.
  - Validation rejects an env set without an account.
  - Each env root plans its own names.

### F. Bootstrap changes (PR B)

- `variables.tf`:
  - `env` regex (P4) is already in PR A;
  - new `promotion_source_account_id` (default null, 12 digits) and `promotion_source_env` (default `"dev"`).
- `locals.tf`: `workflow_files.deploy` as in P7. `resource_names` gains `target_group_alt`, `ecs_elb_role` and `alarm_prefix = "sis-<env>-"`.
- `iam_ecs_elb.tf` (new): the role and inline policy (P12).
- `iam_apply.tf`:
  - `CloudWatchAlarms`: `PutMetricAlarm`, `DeleteAlarms`, `DescribeAlarms`, `TagResource`, `UntagResource`, `ListTagsForResource` on `arn:<p>:cloudwatch:<region>:<acct>:alarm:sis-<env>-*`.
  - `PassEcsElbRole`: `iam:PassRole` on `role/sis-<env>-ecs-elb` with `iam:PassedToService = ecs.amazonaws.com`.
  - `EcrRepositoryPolicy`: `ecr:SetRepositoryPolicy` and `ecr:DeleteRepositoryPolicy` on `ecr_repo_pattern`.
- `iam_deploy.tf`:
  - `ServiceDeploymentsRead`: `ecs:ListServiceDeployments` on the service ARN; `ecs:DescribeServiceDeployments` on the service ARN and `service-deployment/sis-<env>-cluster/sis-<env>-app/*`; `ecs:DescribeServiceRevisions` on the service ARN and `service-revision/sis-<env>-cluster/sis-<env>-app/*`.
  - `AlarmsRead`: `cloudwatch:DescribeAlarms` on `alarm:sis-<env>-*`.
  - `EcrPullFromSource` (count when the source is set): `ecr:BatchGetImage` and `ecr:GetDownloadUrlForLayer` on `arn:<p>:ecr:<region>:<source>:repository/sis-<source_env>-app`.
- `iam_guardrails.tf`: G4 resources add `role/sis-<env>-ecs-elb`.
- `outputs.tf`: `ecs_elb_role_name`, with no ARN.
- Tests: `trust.tftest.hcl` covers the deploy file per source variable. `iam.tftest.hcl` covers the new statements, the no-wildcard-action rule and the PassRole condition.

### G. Least privilege

| Role | Trust (all: `aud = sts.amazonaws.com`, `repository_id`, `repository_owner_id`, `aws:RequestedRegion`) | Phase 7 change | `*` and justification |
|---|---|---|---|
| `sis-<env>-gha-plan` | `sub = <P>:pull_request`, `StringLike ref = refs/pull/*/merge` | New in prod (same code) | Unchanged (B20) |
| `sis-<env>-gha-apply` | `sub = <P>:environment:<env>`, `ref = refs/heads/main`, `job_workflow_ref` in [`terraform-iac.yml`, `terraform-destroy.yml`] @ main | + alarms on `sis-<env>-*`, + PassRole on the infra role, + repo policy on `sis-<env>-*` | Name-prefix wildcards only. **PassRole:** the one infra role, `PassedToService = ecs.amazonaws.com`. The role can only touch this env's ALB, which the apply role can already modify itself, so no escalation |
| `sis-<env>-gha-deploy` | Same shape. `job_workflow_ref` = `app-deploy.yml` (dev) or `app-promote.yml` (prod) | + service-deployment reads, + alarm read, + (prod) source pull | `service-deployment/.../*` and `service-revision/.../*` (random IDs, one service). **No new PassRole.** If ECS demands PassRole on the infra role at `UpdateService` (not documented), it fails closed (R31) |
| `sis-<env>-ecs-elb` (new) | `ecs.amazonaws.com` | Scoped copy of the managed policy | ELB `Describe*` on `*` (no resource-level support). No confused deputy: only principals with PassRole in this account can attach it |
| Exec and task roles | Unchanged | none | none |

New secrets: `AWS_ACCOUNT_ID` (env `dev` in PR A; env `prod` in PR B), `ALB_INGRESS_CIDRS` (env, optional), `AWS_ACCOUNT_ID_PROD`, `AWS_PLAN_ROLE_ARN_PROD`, `ALB_INGRESS_CIDRS_PROD` (repo, optional), `PROMOTION_TARGET_ACCOUNT_ID` (env `dev`).

### H. Secrets and variables (nothing below reaches Terraform state except account IDs inside ARNs and the sensitive CIDRs, as today)

| Name | Level | Used by |
|---|---|---|
| `AWS_REGION` | repo variable (an environment variable of the same name would override it) | all |
| `AWS_ACCOUNT_ID_DEV`, `AWS_PLAN_ROLE_ARN_DEV`, `ALB_INGRESS_CIDRS_DEV` | repo secret | PR plan (dev), smoke test; `_DEV` account also for the `app-promote` source host |
| `AWS_ACCOUNT_ID_PROD`, `AWS_PLAN_ROLE_ARN_PROD`, `ALB_INGRESS_CIDRS_PROD` | repo secret | PR plan (prod), dev PR plan (promotion grant), N1, N10 |
| `AWS_ACCOUNT_ID`, `AWS_APPLY_ROLE_ARN`, `AWS_DEPLOY_ROLE_ARN`, `ALB_INGRESS_CIDRS` | environment secret (`dev`, `prod`) | apply, destroy, deploy, promote |
| `PROMOTION_TARGET_ACCOUNT_ID` | environment secret (`dev` only) | dev apply (repo policy) |

Never in Terraform or git: the app secret values (set by the user with `put-secret-value`), the ECR auth tokens (crane config in `$RUNNER_TEMP`), and the prod root email.

### I. PR split

- **PR A: env cloning and workflow parametrization (dev only).**
  - P1 (generic `tests/envs.tftest.hcl` in `envs/dev/`), P2 script, P3 guard, P4 names, P5 secret names, P6 (dev legs), P8 policies (minus the `app-promote` exception), YAML-loader self-tests.
  - No bootstrap re-apply. The dev plan addresses are identical to Phase 6.
- **PR B: prod.**
  - `envs/prod/` (via `make new-env ENV=prod FROM=dev`; `STRATEGY=` was removed by amendment S1), `accounts/prod.tfvars.example`.
  - Module BLUE_GREEN, bootstrap F, `app-promote.yml`, crane, waiter P14, guards P15, prod legs of every workflow, N10, N1 for prod.
  - Merged only after the prod bootstrap and secrets exist, so its own prod plan check is green.

## Alternatives considered

- **One shared root with `<env>.tfvars` per env (P1 s).** No copied `.tf` files, so drift is impossible by construction, and cloning is one new tfvars file. Rejected by the user: one lock file means a provider or Terraform bump reaches prod in the same merge as dev, and it departs from the PLAN layout. Per-env roots with the parity guard give the same drift protection and keep staged upgrades.
- **A single root with `var.env` selecting a committed locals map.** Cloning becomes an HCL edit by script, and it breaks "values only through tfvars". Rejected.
- **Environment-gated PR plans (`environment: dev-plan`)** to remove the repo-level secrets. This changes the plan role `sub` (ADR 0003), adds deployment records to every PR, and leaves branch-policy behavior for PR refs unverified. Rejected.
- **CodeDeploy blue/green.** A second deployment controller with AppSpec and its own roles. FR-15 asks for ECS built-in. Rejected.
- **`LINEAR` or `CANARY` now.** FR-15 says to document CANARY as the next step. Deferred.
- **A PAUSE hook at `POST_TEST_TRAFFIC_SHIFT` with a test header rule**, for a manual green check. Nice for a talk, but it needs `ContinueServiceDeployment` and adds a second approval surface. Deferred (Q11).
- **Region-deny SCP on prod.** Zero cost, but outside the PLAN scope, and a mistake locks the user out. Deferred (Q15).

## Consequences

### Risks

| R | Risk | Mitigation |
|---|---|---|
| R18 | Terraform drift after a blue/green deploy (rule weights; possible `load_balancer` target group swap) | `ignore_changes` on the rule action. Step B15 checks a prod plan after a promote and adds `load_balancer` to `ignore_changes` if needed |
| R19 | The first prod service create uses the placeholder, which never serves. No `COMPLETED` deployment exists, so the **first** promote cannot roll back | Demo order: good promote first, broken revision second |
| R20 | The scoped infra policy misses an action ECS adds later | Fails closed. Fallback: attach the managed policy (bootstrap) |
| R21 | The dev apply role can write any policy on `sis-dev-*` repositories | Module code is reviewed, and a test pins the document. The role is approval-gated. Residual, accepted |
| R22 | Promotion needs the dev stack (and its ECR) up | Session order in B9 to B11. P19 alternative recorded |
| R23 | An alarm in `ALARM` at deployment start disables alarm rollback | P15 preflight |
| R24 | crane is a new binary | Version and checksum pinned. Provenance file available (optional verify). Fallback: AWS CLI layer copy |
| R25 | Prod PR plan: anyone with push access reads prod metadata via the plan role before review | Read-only, G1 denies secret values, state-only S3. Residual, accepted (extends ADR 0007 M1) |
| R26 | A copied root drifts from dev (a fix lands in one env only) | The parity guard fails the PR on any difference outside the four allowed files, and names the file |
| R27 | The parity guard checks lists, not semantics | Review. The script prints the exact edits |
| R28 | BLUE_GREEN runs two tasks for the bake time of each deploy | 5-minute bake, `desired_count = 1`, destroy after each session |
| R29 | Docs differ on which mechanism rolls back blue/green | B12 records which one fired (`statusReason`) |
| R30 | N1, N10 and the demos send prod alert emails | By design |
| R31 | `UpdateService` on a BLUE_GREEN service might require PassRole on the infra role | Fails closed. Add a PassRole statement with the condition if B11 shows it |

### Other consequences

- **Cost.** Prod costs about the same per hour as dev (ALB plus one Fargate task), plus a second task during each bake time. CloudTrail's first copy is free per account. Three standard alarms fit inside the 10-alarm free tier noted in ADR 0007 Finding 6. Organizations is free. ECR storage is tens of MB. Prices were not re-checked.
- **Docs (orchestrator, D14):**
  - PLAN layout and FR-6 wording (single root);
  - README (environments, cloning, promotion, blue/green, demos, secrets table);
  - CODING_STANDARDS (env names, secret naming, reusable workflow rule, crane);
  - PROGRESS (Phase 7, closed items: YAML loader, composite action dropped, N1 Low);
  - ADR 0002 (infra role, guardrail G4);
  - ADR 0005 and 0006 (waiter, destroy input);
  - ADR 0007 (policy exceptions);
  - diagrams (prod account, promotion path, blue/green).

## PR A build notes (2026-10-27)

The build followed sections B to D with these deviations, accepted by the orchestrator under the standing
best-practice delegation:

| # | Deviation | Why | Trade-off |
|---|---|---|---|
| D1 | The parity guard compares each `README.md` outside the generated `BEGIN_TF_DOCS` block | The generated Requirements table lists provider versions, which legitimately differ during a staged upgrade | A hand-written README change still has to be made in every env |
| D2 | zizmor `self-repository` (Low) is ignored inline on each local `uses: ./...` line (round 1 replaced a global disable): zizmor 1.31.1 wants `uses: $/...`, actionlint rejects that form | Both linters are required; `./...` resolves to the caller's own commit, so nothing is weaker; the audit stays on everywhere else | One comment per caller; a self-test requires it. Remove when actionlint accepts `$/` |
| D3 | The env is validated by `scripts/names.sh env-root` (regex and `envs/<env>/` exists) as the first step after harden-runner, not by a separate job | No credential step runs before it; the dispatch choice limits the UI | A crafted API dispatch with an unknown env still makes GitHub create that empty environment (no secrets, so nothing runs) |
| D4 | `new-env.sh` always sets `env = "<env>"` in the generated bootstrap example | The bootstrap `env` variable defaults to `dev`, so a copy would bootstrap dev names in the new account | None |
| D5 | `--strategy` and the `promotion_target_env` rewrite apply only when the key exists in the source tfvars | The variables arrive in PR B | `--strategy` is refused with a message until then |
| D6 | No `-var-file` in plan or apply | Roots stay thin (P1), so `terraform.tfvars` is auto-loaded as before | None |

Check names after PR A: the plan jobs become `plan-dev / plan (read-only role)`, `plan-dev / plan role guardrails`
and `plan-dev / sticky plan comment`. The required check `guard (no AWS)` is unchanged.

## PR A verify, round 1 (2026-10-27)

No Critical or High. Fixed in one round (`fix(ci)` commit):

| Source | Finding | Decision |
|---|---|---|
| reviewer M1 | `echo "TF_DIR=$(...)"` stayed green on a bad env, so validation ran after credentials | Fixed: assign then write; a self-test runs the step with bad names; a grep bans the pattern |
| reviewer M2, security M1 | A missing env `ALB_INGRESS_CIDRS` made the apply plan `0.0.0.0/0` while the PR plan looked restricted | Fixed, fail closed: the apply refuses an empty value; open on purpose is `["0.0.0.0/0"]`. Pro: no silent widening. Con: one more required secret per env. PR plan and teardown keep unset = open, so teardown always works |
| reviewer M3 | Printed `gh api` heredoc hung when pasted | Fixed: one `printf ... \| gh api --input -` line; T13 runs `bash -n` and `zsh -n` on every printed command |
| reviewer L4 | Caller `plan-dev` had no fork/Dependabot skip | Fixed |
| reviewer L6 | T12 never reached the rollback | Fixed: T12b fails a later `mv` and checks the rollback |
| reviewer L7 | `mask-cidrs.sh` named the wrong secret | Fixed |
| reviewer L8 | Parity guard did not check a caller's secret suffix | Fixed: every mapped secret must end in `_<ENV>` |
| security L1 | `env.ENV` in block-mode endpoints was not tied to a safe source | Fixed: a literal, or `inputs.env` from a `choice` dispatch input or a `workflow_call` input |
| security L2 | A callee job without `permissions:` would be treated as an audit job | Fixed: reusable files need top-level `permissions: {}` and per-job permissions |
| security L3 | `format()` or `env[...]` could pass a secret into an audit job's endpoints | Fixed: audit endpoints allow only `vars.X` and untainted `env.X` |
| security L4 | `self-repository` was off for every file | Fixed: inline ignore per line (D2) |
| security L5 | One workflow-level concurrency slot for every env | Fixed: the group includes the env |
| reviewer L5 | Path filter misses `scripts/guard/*.py` | Accepted: those files do not run in `terraform-iac`; `repo-guard` has no filter |
| simplifier 1, 3, 6, 7 | Repeated `on:` lookups, guard runner, self-test loops, env-line check | Fixed (`workflow_yaml.read_workflow`/`workflow_on`/`dispatch_options`, `run_guard_helper`, `mutation_cases`, `_env_line_problem`) |
| simplifier 4 | Nine setup steps repeated in plan, apply and teardown | Fixed with the composite `.github/actions/terraform-setup`. **This reverses P6 point (4)**, which counted only three preamble steps. Pro: one place for the setup sequence. Con: one more file type for the pin test and zizmor (both now cover it). harden-runner stays step 1 and each job keeps its own allowlist, so least privilege and the trust pin are unchanged. `plan-role-guardrails` keeps its two inline steps (no tools, no init) |
| simplifier 2, 5 | `sys.path` inserts, `new-env.sh` bookkeeping | Kept (`-I` hardening; tested path) |

Accepted residual risk (unchanged from ADR 0007): a same-repo PR author controls the steps of the read-only
plan job; the comment job's base-SHA checkout protects `scripts/` only.

## PR A verify, round 2 (2026-10-27)

Reviewer and security reviewer: every round 1 item closed, no regression in the composite action, no Critical,
High or Medium. Open Low items, not fixed after the two-round limit:

| Source | Finding | Decision |
|---|---|---|
| reviewer | `envs/dev/README.md` still called the ALB secret optional | Fixed as docs drift |
| security N3 | `.pre-commit-config.yaml` comment said "No ignores" | Fixed as docs drift |
| security N2 | A missing environment secret falls back to a repository secret with the same name, so a repo-level `ALB_INGRESS_CIDRS` would defeat the fail-closed apply | Checkpoint A1 now lists repo secrets and expects none of the env-level names. A guard for it needs `gh` access in CI; open item |
| reviewer | No self-test pins the step order in the composite (mask and select before the role) | Open item, with PR B (which edits the composite) |
| security N1 | The audit-endpoint taint check follows `env` one level and matches `secrets` case-sensitively | Open item (defense in depth; nothing in the repo does this) |

## Amendment W: workflow display names (2026-10-30, before PR B)

The Actions tab showed slugs (`terraform-iac`, `app-deploy`) and job names carried notes (`deploy (dev, approval
required)`, `guard (no AWS)`). Production repositories show Title Case workflow names and short `verb (target)` job
names. The rules now live in `docs/reference/standards/ci-cd.md` (Naming), and a self-test enforces them.

| Decision | Choice | Why |
|---|---|---|
| W1 | Change display names only (`name:`, job `name:`); file names and job ids stay | File names are pinned in the apply, deploy and destroy role trusts (`job_workflow_ref`, ADR 0007 S2); a rename would need a bootstrap re-apply. Job ids are used by `needs:`, the parity guard and self-tests |
| W2 | Workflow names: `App CI`, `App Deploy`, `OIDC Smoke Test`, `Repo Guard`, `Terraform`, `Terraform Destroy`, `Terraform Plan (reusable)`; PR B adds `App Promote` | Domain first, so the sidebar groups by domain |
| W3 | `run-name:` on the workflows that change AWS state: `Terraform plan · PR #<n>` or `Terraform apply · <env> by <actor>`, `Deploy <ref> to dev by <actor>`, `Destroy <env> by <actor>` | The run list says what ran where, and who started it, without opening it |
| W4 | Job names drop notes: `guard`, `checks`, `confirm`, `build, test, scan`, `deploy (dev)`, `apply`, `destroy`; the reusable plan's jobs are `terraform plan`, `role guardrails`, `sticky comment` under the caller `plan (<env>)` | Permissions, environments and comments carry the notes; names stay short in check lists. `apply` and `destroy` take their env from an input, so their names stay plain: a skipped job shows its name unevaluated (seen as `apply (${{ (inputs.env \|\| 'dev') }})` on PR #30), and the `run-name` carries the env |
| W5 | The required check becomes `guard`. The user swaps it in the `main` ruleset after the PR's first run and before the merge | A required check that never reports blocks every PR |

PR B check names: `plan (dev) / terraform plan`, `plan (prod) / terraform plan`, and so on. The sticky comment
marker `terraform-iac:plan:<env>` and every concurrency group key stay as they are, except groups built from
`github.workflow`, which follow the new names (no state lock depends on them).

## Amendment S: PR B scope for the deployment path (2026-10-30)

PLAN v3 makes the goal the deployment path: PR preview, dev, promote, rollback (`docs/requirements.md`, Goal). `BLUE_GREEN` serves
a different goal (safe traffic shifting under real load) and is the largest part of PR B, so it leaves the
phase. Promote and isolation stay; rollback becomes a use of promote.

| # | Decision | Effect on this ADR |
|---|---|---|
| S1 | Prod runs `ROLLING` with the circuit breaker, like dev. No `deployment_strategy` variable | **Dropped:** P11, P12, P21, section E (module `BLUE_GREEN`, alternate target group, listener rule, alarms, bake time), the `ecs-elb` role and alarm statements of F, the alarm guard P15(1), the `STRATEGY=` input of `make new-env` (built in PR A; PR B removes it), the bake-time demo and B13's listener-rule drift check |
| S2 | **Rollback = promote an earlier green SHA** (PLAN FR-16). The prod tag `<sha>` already exists with the same digest, so P9 step 5 skips the copy and deploys that digest. Both registries keep only the last `ecr_keep_images` images, so when the prod tag exists PR B reads the digest from prod and needs no dev image; an older SHA that prod no longer holds cannot be rolled back to | No new workflow, role, trust or permission. **Replaces** P16: the demo promotes A, then B, then A again and reads `/version` each time |
| S3 | Keep the current waiter (`scripts/ecs/wait-deployment.sh` on `describe-services`) | **Dropped:** P14 and the service-deployment read statements of F. Dev needs no bootstrap re-apply for PR B |
| S4 | Keep P15(2), the render rule that refuses a revision whose `environment` is not `[{APP_ENV: <env>}]` | Unchanged; it keeps hand-made revisions out of promotion |
| S5 | **Kept as designed:** P5, P7, P9 (crane copy by digest, pull-only dev repo policy), P10 (dispatch on `main`, green-in-dev check), P13 limited to the promotion statements, P17 (N10), P18, P19, P20, P22 | PR B is now: `envs/prod`, the prod bootstrap with the promotion statements, `app-promote.yml`, crane, prod legs of every workflow, N10, N1 for prod, and the composite step-order self-test |

The checkpoint commands below still show the `BLUE_GREEN` steps as written on 2026-10-27; the PR B build rewrites
them to S1 to S5 before it is merged.

## PR B1 build notes (2026-10-30)

PR B split per P22. **B1** is everything that needs no prod account; **B2** (after Q1) adds `envs/prod`, the prod
bootstrap, the dev ECR repository policy, `app-promote.yml`, the prod workflow legs and N10.

| Item | Built |
|---|---|
| S1 | `STRATEGY=` and `--strategy` removed; `make new-env` now refuses `STRATEGY` with a message naming this amendment |
| P9 tool | crane v0.22.1 in `mise.toml`, `scripts/ci/install-tools.sh` and `scripts/ci/tools.sha256` (hash checked against the release `checksums.txt`) |
| P10 | `scripts/image/promote-resolve.sh`: 40-hex SHA, ancestor of `origin/main`, and an App Deploy run for that SHA on `main` (event `push` or `workflow_dispatch`) whose job `deploy (dev)` concluded `success`. A run whose jobs were all skipped no longer counts. A self-test pins the job name to `app-deploy.yml` |
| P9, S2 | `scripts/image/promote-copy.sh <source repo> <target repo> <sha> [temp dir]`: copy by digest with read-back. When the target tag exists, the source check is best effort (rollback works with dev down) but a readable, different source digest is refused. Prints `IMAGE_DIGEST` and `PROMOTE_COPIED` only; `DOCKER_CONFIG` is a temp dir removed on exit |
| P15(2), S4 | `render-task-def.sh` now checks the `APP_ENV` value, not only the name |
| N1 Low | harden-runner taint for audit endpoints fails closed: an env value is clean only as a literal or built from `vars.X` and clean `env.X` (multi-line expressions, `env[...]`, `toJSON(env)`, `github.*`, case-variant keys and undefined names all taint) |
| Step-order Low | A self-test requires exactly one `aws-actions/configure-aws-credentials` step in the composite, after the root select and the CIDR mask |

Verify: e2e green (`make check` three times, `pre-commit`, crane install). Two fix rounds closed security M1
(skipped-jobs run counted as green), M2 (taint gaps, including a multi-line expression) and the Lows; the
simplifier's stub and flow suggestions were applied. Accepted: an SHA deployed before #30 renamed the job to
`deploy (dev)` cannot be promoted (fails closed; prod has no such SHA).

## PR B2 build notes (2026-11-02)

Scope per amendment S and ADR 0010 (T4, T5). Q1 answered: the existing organization's management account is the
user's own and runs no workloads, so `sis-prod` is created there (P20, ADR 0010 T9).

| Item | Built |
|---|---|
| P1, P2 | `envs/prod/` from `make new-env ENV=prod` (CIDR `10.50.0.0/16`, Q3); `bootstrap/accounts/prod.tfvars.example` with `env` and `promotion_source_account_id` |
| P7 | Bootstrap `is_promoted` (`promotion_source_account_id` set): the deploy role trusts `app-promote.yml` instead of `app-deploy.yml`; new output `deploy_workflow_file` |
| P9 identity side | Prod deploy statement `EcrPullFromSource`: `ecr:BatchGetImage` and `ecr:GetDownloadUrlForLayer` on `sis-dev-app` in the source account only. Apply role gains `ecr:SetRepositoryPolicy` and `ecr:DeleteRepositoryPolicy` on `sis-<env>-*` |
| P9 resource side | Module `aws_ecr_repository_policy.promotion` when `promotion_target_env` is set (dev: `prod`): Principal the target account root, narrowed by `aws:PrincipalArn` to `sis-prod-gha-deploy`, pull only. The account comes from `TF_VAR_promotion_target_account_id` (sensitive, never committed) |
| P8 | harden-runner policy: `secrets.AWS_ACCOUNT_ID_DEV` allowed only in `app-promote.yml` job `promote` (the source registry host). Terraform policy rule 7: the one promotion principal line in a module `ecr.tf` is exempt; any other AWS principal still fails |
| P3 | Parity guard: a `plan-<env>` caller must map `PROMOTION_TARGET_ACCOUNT_ID` from `secrets.AWS_ACCOUNT_ID_<TARGET>` exactly when its tfvars sets `promotion_target_env`, and never otherwise |
| P6, P18 | `terraform-iac.yml`: `plan-prod` caller, dispatch choice `[dev, prod]`, dev plan and apply pass the promotion account. `terraform-destroy.yml`: `[dev, prod]` |
| P10, S2 | `app-promote.yml`: dispatch on `main` with `env` `[prod]` and `sha`. `resolve` (no AWS) runs `promote-resolve.sh`; `promote` (environment `prod`, block mode, containers off) runs preflight, `promote-copy.sh`, render with `--env prod`, register, update, `wait-deployment.sh`. Rollback = the same run with an earlier green SHA |
| N1, N10 (T5) | `oidc-smoke-test.yml` dispatch: N1 also against the prod roles; new job `dev-env-denied-by-prod` (environment `dev`) requires AccessDenied from the prod plan, apply and deploy roles. For apply and deploy two claims differ (`sub` and `job_workflow_ref`); for plan only `sub` |

Not built (ADR 0010 T5): the `prove-isolation` mode, the broken-release demo (B10), the drift check (B13), and
everything of section E and P11 to P16 except P15(2).

Residual (Low, accepted): the apply role can now write a repository policy on its own repositories, so a
malicious apply could share a dev image with another account. The images hold no secrets (FR-8), and every
apply is a reviewed `main` commit after an approval.

### PR B2 checkpoint results (2026-11-02)

| Step | Result |
|---|---|
| C1 | `sis-prod` created from the existing organization's management account (the user's own, no workloads; P20), in a `Prod` OU. SCPs: `FullAWSAccess` plus a root-level deny of leaving the organization and closing accounts, which does not affect the lab. `AdministratorAccess` assigned through IAM Identity Center, profile `sis-prod-admin`; root MFA set. `describe-trails` empty, so `create_trail` keeps its default. 3 AZs, Fargate vCPU quota 6 |
| C2 | `prod.tfvars` filled (gitignored) with `env = "prod"` and the promotion source account |
| C3 | Prod bootstrap on local state: 33 added; migrated to the prod state bucket; `deploy_workflow_file` = `app-promote.yml`; local state files deleted |
| C4 | Dev bootstrap: 0 to add, 1 to change (`aws_iam_role_policy.apply`), 0 to destroy |
| C5 | Environment `prod` (reviewer the user, branch policy `main`) and every secret set. The `gh api` PUT returned 403 until the PAT got Administration write. No repo secret shadows an environment secret name (N2) |
| C6 | #38 checks green: `plan (dev)` 28 to add including `aws_ecr_repository_policy`, `plan (prod)` 27 to add, `guard` green |
| C7 | #38 squash-merged as `<SHA_A>` (`42248b8`). Dev apply: 28 added. Secret value set; `app-deploy` green; dev `/version` on `42248b8` |
| C8 | `terraform-iac` dispatch with env `prod`: 27 added. Secret value set |
| C9 | `app-promote` `42248b8`: `resolve` and `promote (prod)` green, `PROMOTE_COPIED: true`; prod `/version` = `prod`, `42248b8` and the same digest as dev |
| C10 | #39 (the page says `shipped by: app-promote` on prod, read from `APP_ENV` at runtime) merged as `<SHA_B>` (`caa9bfd`); `app-deploy` green. Promote `caa9bfd`: copied by digest, "target digest equals source digest", rollout completed; prod `/` shows `shipped by: app-promote (dev digest)` and `secret_loaded: yes`. Promote `42248b8` again: "the target tag ... exists ...; nothing is copied", rollout completed, `/version` back on `42248b8` and its digest. Preflight logged N4 (deploy role `GetSecretValue`) as denied as designed |
| C11 | `oidc-smoke-test` on `main`: `refuse non-PR token (N1)` and `prod refuses a dev token (N10)` green; the prod plan, apply and deploy roles each answered "denied as designed (AccessDenied)". `prove plan role identity` skipped (it runs on `pull_request` only) |
| C12 | `terraform-destroy` env `prod` (**destroy-prod**): 27 destroyed, revisions `:2` to `:4` deregistered (Terraform removed `:1`). Env `dev` (**destroy-dev**): 28 destroyed, revisions `:17` and `:18` deregistered. Per-service checks clean in both accounts: no VPC, `LoadBalancerNotFound`, cluster `INACTIVE`, no ECR repository, no secret, no ACTIVE task definition. Bootstraps stay |

Account ID in every run log: 0.

Not observed: the job summary wording of C9 and C10 ("copied from dev by digest", "already in prod: reused"),
because the PAT cannot read job summaries; the step logs above show the same outcome. The prod alert emails of C11
and the prod SNS subscription confirmation of C3 were not reported back. Harden-runner logged a 401 and a timeout
from its own API (telemetry off, egress blocked); no step failed on it.

### PR B2 checkpoint

From the repo root. Placeholders: `<DEV_ACCOUNT_ID>`, `<PROD_ACCOUNT_ID>`, `<PR_B2>`, `<SHA_A>`, `<SHA_B>`,
`<PROD_ALB>`. Dispatches use the web UI (Actions > workflow > Run workflow).

**C1. Prod account and access.** Follow `notes/aws-organizations-prod-account-setup.md` §4 (management account:
create `sis-prod`, assign `AdministratorAccess` in IAM Identity Center), then:
```bash
aws configure sso --profile sis-prod-admin
```
```bash
AWS_PROFILE=sis-prod-admin aws sts get-caller-identity --query Account --output text
```
Expect: `<PROD_ACCOUNT_ID>`.
```bash
AWS_PROFILE=sis-prod-admin aws cloudtrail describe-trails --region ap-southeast-1 --query 'trailList[].Name' --output text
```
Expect: empty. If a trail is listed (an organization trail), set `create_trail = false` in `prod.tfvars`.

**C2. Prod inputs** (gitignored file). Copy the example, then fill `aws_account_id`, `budget_email`,
`github_owner_id`, `github_repo_id` (same as dev) and `promotion_source_account_id = "<DEV_ACCOUNT_ID>"`.
```bash
cp infra/terraform/bootstrap/accounts/prod.tfvars.example infra/terraform/bootstrap/accounts/prod.tfvars
```

**C3. Prod bootstrap** on local state first, then migrate. A separate `TF_DATA_DIR` keeps dev's `.terraform/`.
```bash
printf 'terraform {\n  backend "local" {\n    path = "prod.tfstate"\n  }\n}\n' > infra/terraform/bootstrap/backend_override.tf
```
```bash
AWS_PROFILE=sis-prod-admin TF_DATA_DIR=.terraform-prod terraform -chdir=infra/terraform/bootstrap init
```
```bash
AWS_PROFILE=sis-prod-admin TF_DATA_DIR=.terraform-prod terraform -chdir=infra/terraform/bootstrap apply -var-file=accounts/prod.tfvars
```
Expect: the same resource count as the dev bootstrap, 0 to change, 0 to destroy. Then:
```bash
rm infra/terraform/bootstrap/backend_override.tf
```
```bash
AWS_PROFILE=sis-prod-admin TF_DATA_DIR=.terraform-prod terraform -chdir=infra/terraform/bootstrap init -migrate-state -backend-config="bucket=sis-prod-tfstate-<PROD_ACCOUNT_ID>-ap-southeast-1-an"
```
```bash
AWS_PROFILE=sis-prod-admin TF_DATA_DIR=.terraform-prod terraform -chdir=infra/terraform/bootstrap output -raw deploy_workflow_file
```
Expect: `app-promote.yml`. Delete `prod.tfstate` and `prod.tfstate.backup` in the bootstrap folder, and confirm
the SNS subscription email from the prod account.

**C4. Dev bootstrap re-apply** (apply role: repository policy actions).
```bash
AWS_PROFILE=sis-dev-admin terraform -chdir=infra/terraform/bootstrap apply -var-file=accounts/dev.tfvars
```
Expect: 0 to add, 1 to change (`aws_iam_role_policy.apply`), 0 to destroy.

**C5. GitHub environment `prod` and secrets.** Reviewer = you, `main` only:
```bash
gh api -X PUT repos/trungleviet-agilityio/ship-it-safely/environments/prod -F "reviewers[][type]=User" -F "reviewers[][id]=$(gh api user --jq .id)" -F prevent_self_review=false -F "deployment_branch_policy[protected_branches]=false" -F "deployment_branch_policy[custom_branch_policies]=true"
```
```bash
gh api -X POST repos/trungleviet-agilityio/ship-it-safely/environments/prod/deployment-branch-policies -f name=main -f type=branch
```
Role ARNs from the prod bootstrap (one line each):
```bash
AWS_PROFILE=sis-prod-admin TF_DATA_DIR=.terraform-prod terraform -chdir=infra/terraform/bootstrap output -raw apply_role_arn | gh secret set AWS_APPLY_ROLE_ARN --env prod --repo trungleviet-agilityio/ship-it-safely
```
```bash
AWS_PROFILE=sis-prod-admin TF_DATA_DIR=.terraform-prod terraform -chdir=infra/terraform/bootstrap output -raw deploy_role_arn | gh secret set AWS_DEPLOY_ROLE_ARN --env prod --repo trungleviet-agilityio/ship-it-safely
```
```bash
AWS_PROFILE=sis-prod-admin TF_DATA_DIR=.terraform-prod terraform -chdir=infra/terraform/bootstrap output -raw plan_role_arn | gh secret set AWS_PLAN_ROLE_ARN_PROD --repo trungleviet-agilityio/ship-it-safely
```
These prompt; paste `<PROD_ACCOUNT_ID>` for the first three, and a JSON CIDR list (or `["0.0.0.0/0"]`) for the
last two:
```bash
gh secret set AWS_ACCOUNT_ID --env prod --repo trungleviet-agilityio/ship-it-safely
```
```bash
gh secret set AWS_ACCOUNT_ID_PROD --repo trungleviet-agilityio/ship-it-safely
```
```bash
gh secret set PROMOTION_TARGET_ACCOUNT_ID --env dev --repo trungleviet-agilityio/ship-it-safely
```
```bash
gh secret set ALB_INGRESS_CIDRS --env prod --repo trungleviet-agilityio/ship-it-safely
```
```bash
gh secret set ALB_INGRESS_CIDRS_PROD --repo trungleviet-agilityio/ship-it-safely
```
Expect: `gh secret list --env prod --repo trungleviet-agilityio/ship-it-safely` shows `AWS_ACCOUNT_ID`,
`AWS_APPLY_ROLE_ARN`, `AWS_DEPLOY_ROLE_ARN` and `ALB_INGRESS_CIDRS`.

**C6. PR checks.** Re-run the checks of `<PR_B2>`. Expect: `plan (dev)` shows the stack (or 28 to add when
torn down, including `aws_ecr_repository_policy`); `plan (prod)` shows 27 to add; `guard` green.

**C7. Merge, dev up.** Approve the push apply of dev. Then:
```bash
AWS_PROFILE=sis-dev-admin aws secretsmanager put-secret-value --region ap-southeast-1 --secret-id sis/dev/app-api-key --secret-string "$(openssl rand -hex 24)" --query Name --output text
```
Run workflow `app-deploy` and approve. Note its commit as `<SHA_A>`.

**C8. Prod up.** Run workflow `terraform-iac` with env `prod`, approve (27 to add). Then:
```bash
AWS_PROFILE=sis-prod-admin aws secretsmanager put-secret-value --region ap-southeast-1 --secret-id sis/prod/app-api-key --secret-string "$(openssl rand -hex 24)" --query Name --output text
```

**C9. Promote A.** Run workflow `app-promote` with sha `<SHA_A>`, approve `prod`. Expect: summary "copied from dev
by digest", and:
```bash
curl -s http://<PROD_ALB>/version
```
Expect: `prod`, `<SHA_A>` and the same digest as `app-deploy` showed for dev.

**C10. Promote B, then roll back to A.** Merge a one-line app change, approve `app-deploy` (`<SHA_B>`), promote
`<SHA_B>`, read `/version`. Then promote `<SHA_A>` again. Expect: the summary says "already in prod: reused", and
`/version` is back on `<SHA_A>` and its digest within minutes, with no build.

**C11. N1 and N10.** Run workflow `oidc-smoke-test` on `main`; approve `dev` for `prod refuses a dev token (N10)`.
Expect: every dev and prod role answers "denied as designed", and prod alert emails arrive.

**C12. Teardown.** Run workflow `terraform-destroy` with env `prod`, type **destroy-prod**, approve (27
destroyed). Then env `dev`, type **destroy-dev** (28). Bootstraps stay.

## Checkpoint commands (the user runs these; Claude never does, NFR-9)

Placeholders: `<DEV_ACCOUNT_ID>`, `<PROD_ACCOUNT_ID>`, `<PR_A>`, `<PR_B>`, `<SHA>`, `<PROD_ALB>`, `<BROKEN_REV>`. Each command is one line for zsh; there are no packed arguments (lessons 5, 37). Dispatches use the web UI (Actions > workflow > Run workflow), because the PAT has Actions read-only (lesson 31).

### PR A

**A1. Environment secret for dev.** The command prompts for the value; paste `<DEV_ACCOUNT_ID>`.
```bash
gh secret set AWS_ACCOUNT_ID --env dev --repo trungleviet-agilityio/ship-it-safely
gh secret list --env dev --repo trungleviet-agilityio/ship-it-safely
```
Then set `ALB_INGRESS_CIDRS` in env `dev` (required since round 1: the apply refuses an empty value). Paste the
same JSON list as the repo secret `ALB_INGRESS_CIDRS_DEV`, or `["0.0.0.0/0"]` if that one is unset:
```bash
gh secret set ALB_INGRESS_CIDRS --env dev --repo trungleviet-agilityio/ship-it-safely
```
Expect `gh secret list --env dev` to show `AWS_ACCOUNT_ID`, `ALB_INGRESS_CIDRS`, `AWS_APPLY_ROLE_ARN` and
`AWS_DEPLOY_ROLE_ARN`. Then check the repository level:
```bash
gh secret list --repo trungleviet-agilityio/ship-it-safely
```
Expect only suffixed names (`AWS_ACCOUNT_ID_DEV`, `AWS_PLAN_ROLE_ARN_DEV`, optional `ALB_INGRESS_CIDRS_DEV`).
A repo-level `AWS_ACCOUNT_ID`, `ALB_INGRESS_CIDRS`, `AWS_APPLY_ROLE_ARN` or `AWS_DEPLOY_ROLE_ARN` would be
used whenever the environment copy is missing (round 2, N2): delete it in Settings > Secrets.

**A2. Checks**
```bash
gh pr checks <PR_A> --repo trungleviet-agilityio/ship-it-safely --watch
```
Expect green: `guard (no AWS)` (parity guard, policies, self-tests), `checks (no AWS)`, `plan-dev / plan (read-only role)`, `plan-dev / plan role guardrails`, and the sticky comment `terraform-iac:plan:dev`.

**A3. Script, locally (no AWS)**
```bash
scripts/tf/new-env.sh qa --from dev --dry-run
scripts/tf/new-env.sh Dev
git status --short
```
Expect: the dry run lists `envs/qa/` with `vpc_cidr = "10.50.0.0/16"`; `Dev` is refused; no files appear.

**A4. Merge and re-prove the dev cycle on the new layout.** The merge starts the `terraform-iac` push apply, and also `app-deploy` because `lib.sh` changed. Approve **only** the apply first (lesson 43). Expect 27 to add, with the same addresses as Phase 6. Then set the secret value (one line, own terminal):
```bash
AWS_PROFILE=sis-dev-admin aws secretsmanager put-secret-value --region ap-southeast-1 --secret-id sis/dev/app-api-key --secret-string "$(openssl rand -hex 24)" --query Name --output text
AWS_PROFILE=sis-dev-admin aws s3 ls s3://sis-dev-tfstate-<DEV_ACCOUNT_ID>-ap-southeast-1-an/envs/dev/
```
Expect `terraform.tfstate` under the unchanged key. Then re-run and approve `app-deploy`; `/version` shows the `main` SHA. Then Run workflow `terraform-destroy`: env `dev`, type **destroy-dev**, approve. Expect 27 destroyed and no account ID in any log.

### PR A checkpoint results (2026-10-27)

| Step | Result |
|---|---|
| A1 | `dev` environment secrets `AWS_ACCOUNT_ID` and `ALB_INGRESS_CIDRS` (`["0.0.0.0/0"]`, no repo CIDR set) added in the web UI: the PAT has no "Environments: write". Repo secrets are only `AWS_ACCOUNT_ID_DEV` and `AWS_PLAN_ROLE_ARN_DEV`, so nothing shadows an environment name (N2) |
| A2 | #27 checks green: `guard (no AWS)`, `checks (no AWS)`, `plan-dev / plan (read-only role)` and `plan-dev / plan role guardrails` in block mode (first run of the reusable plan, no blocked host). `plan-dev / sticky plan comment` failed with exit 127 until #26 was merged (it runs `scripts/` from `main`), then posted `terraform-iac:plan:dev` with 27 to add |
| A3 | Covered by e2e: `new-env.sh qa` dry run, real run in a scratch clone (validate and test pass), refusal of reruns and bad names, parity guard results |
| A4 | The #26 merge apply (old workflow) created the stack: 27 added. The #27 merge apply (new reusable layout, composite setup, explicit CIDR list) then planned `No changes` and applied 0, which proves the layout change is drift-free. Secret value set; app-deploy green (account ID in log: 0); `/version` = `cc9a4c0` with its digest. Teardown with input `env=dev` and **destroy-dev**: 27 destroyed, revisions deregistered, account ID in log: 0 |

Not observed: a blocked host (none occurred). Dependabot's docker job failed on an ECR Public 429 again (lesson 42),
not on the config.

### PR B (superseded)

Superseded by "PR B2 checkpoint" above (amendment S, ADR 0010). Kept for the record.

**B0. Answer Q1 to Q4 first.**

**B1. Organizations and access** (management account console or CLI). Create the organization if needed, then create the prod account with a unique root email (for example a plus-address of your budget email). Then in IAM Identity Center, assign your user the `AdministratorAccess` permission set on the prod account.
```bash
aws configure sso --profile sis-prod-admin
aws sso login --profile sis-prod-admin
AWS_PROFILE=sis-prod-admin aws sts get-caller-identity --query Account --output text
```
The last command must print `<PROD_ACCOUNT_ID>`.
```bash
AWS_PROFILE=sis-prod-admin aws cloudtrail describe-trails --region ap-southeast-1 --query 'trailList[].[Name,IsMultiRegionTrail,HomeRegion]' --output text
AWS_PROFILE=sis-prod-admin aws iam list-open-id-connect-providers
```
Expect both empty. If a trail is listed (for example an organization trail), set `create_trail = false` in `prod.tfvars`. If an OIDC provider exists, report it before B3.

**B2. Fill the prod inputs** (gitignored file).
```bash
git switch <PR_B branch> && git pull
cp infra/terraform/bootstrap/accounts/prod.tfvars.example infra/terraform/bootstrap/accounts/prod.tfvars
```
Edit it: `aws_account_id = "<PROD_ACCOUNT_ID>"`, `budget_email`, `github_owner_id`, `github_repo_id` (same as dev), `promotion_source_account_id = "<DEV_ACCOUNT_ID>"`.

**B3. Prod bootstrap: first apply on local state, then migrate** (a separate `TF_DATA_DIR` keeps dev's `.terraform/` untouched).
```bash
printf 'terraform {\n  backend "local" {\n    path = "prod.tfstate"\n  }\n}\n' > infra/terraform/bootstrap/backend_override.tf
AWS_PROFILE=sis-prod-admin TF_DATA_DIR=.terraform-prod terraform -chdir=infra/terraform/bootstrap init
AWS_PROFILE=sis-prod-admin TF_DATA_DIR=.terraform-prod terraform -chdir=infra/terraform/bootstrap plan -var-file=accounts/prod.tfvars -out=prod-bootstrap.tfplan
AWS_PROFILE=sis-prod-admin TF_DATA_DIR=.terraform-prod terraform -chdir=infra/terraform/bootstrap apply prod-bootstrap.tfplan
rm infra/terraform/bootstrap/backend_override.tf
AWS_PROFILE=sis-prod-admin TF_DATA_DIR=.terraform-prod terraform -chdir=infra/terraform/bootstrap init -migrate-state -backend-config="bucket=sis-prod-tfstate-<PROD_ACCOUNT_ID>-ap-southeast-1-an"
AWS_PROFILE=sis-prod-admin TF_DATA_DIR=.terraform-prod terraform -chdir=infra/terraform/bootstrap plan -var-file=accounts/prod.tfvars
rm -f infra/terraform/bootstrap/prod.tfstate infra/terraform/bootstrap/prod.tfstate.backup infra/terraform/bootstrap/prod-bootstrap.tfplan
```
The second plan must show "No changes". Then confirm the SNS subscription email for prod.

**B4. GitHub environment `prod` and secrets**
```bash
MY_ID="$(gh api user --jq .id)"
gh api -X PUT repos/trungleviet-agilityio/ship-it-safely/environments/prod --input - <<EOF
{"reviewers":[{"type":"User","id":${MY_ID}}],"prevent_self_review":false,"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
EOF
gh api -X POST repos/trungleviet-agilityio/ship-it-safely/environments/prod/deployment-branch-policies -f name=main -f type=branch
AWS_PROFILE=sis-prod-admin TF_DATA_DIR=.terraform-prod terraform -chdir=infra/terraform/bootstrap output -raw apply_role_arn | gh secret set AWS_APPLY_ROLE_ARN --env prod --repo trungleviet-agilityio/ship-it-safely
AWS_PROFILE=sis-prod-admin TF_DATA_DIR=.terraform-prod terraform -chdir=infra/terraform/bootstrap output -raw deploy_role_arn | gh secret set AWS_DEPLOY_ROLE_ARN --env prod --repo trungleviet-agilityio/ship-it-safely
AWS_PROFILE=sis-prod-admin TF_DATA_DIR=.terraform-prod terraform -chdir=infra/terraform/bootstrap output -raw plan_role_arn | gh secret set AWS_PLAN_ROLE_ARN_PROD --repo trungleviet-agilityio/ship-it-safely
gh secret set AWS_ACCOUNT_ID --env prod --repo trungleviet-agilityio/ship-it-safely
gh secret set AWS_ACCOUNT_ID_PROD --repo trungleviet-agilityio/ship-it-safely
gh secret set PROMOTION_TARGET_ACCOUNT_ID --env dev --repo trungleviet-agilityio/ship-it-safely
gh api repos/trungleviet-agilityio/ship-it-safely/environments/prod --jq '{reviewers: [.protection_rules[].reviewers[]?.reviewer.login], branch_policy: .deployment_branch_policy}'
```
The last three `gh secret set` commands prompt: paste `<PROD_ACCOUNT_ID>` each time.

**B5. Dev bootstrap re-apply** (adds the infra role and the new statements).
```bash
AWS_PROFILE=sis-dev-admin terraform -chdir=infra/terraform/bootstrap init -backend-config="bucket=sis-dev-tfstate-<DEV_ACCOUNT_ID>-ap-southeast-1-an"
AWS_PROFILE=sis-dev-admin terraform -chdir=infra/terraform/bootstrap plan -var-file=accounts/dev.tfvars -out=bootstrap.tfplan
AWS_PROFILE=sis-dev-admin terraform -chdir=infra/terraform/bootstrap apply bootstrap.tfplan
rm infra/terraform/bootstrap/bootstrap.tfplan
```
Expect about 2 to add (`aws_iam_role.ecs_elb`, `aws_iam_role_policy.ecs_elb`), 3 to change (`aws_iam_role_policy.apply`, `aws_iam_role_policy.deploy`, `aws_iam_policy.guardrails`), and 0 to destroy. Dev trust is unchanged.

**B6. PR checks**
```bash
gh pr checks <PR_B> --repo trungleviet-agilityio/ship-it-safely --watch
```
Expect `plan-dev` (`aws_ecr_repository_policy` planned, value shown as sensitive) and `plan-prod` (full create, about 32 resources). Two sticky comments. The guard is green.

**B7. Merge, then bring dev up.** Approve the push apply (about 28 to add, including the repo policy). Then:
```bash
AWS_PROFILE=sis-dev-admin aws secretsmanager put-secret-value --region ap-southeast-1 --secret-id sis/dev/app-api-key --secret-string "$(openssl rand -hex 24)" --query Name --output text
```
Then approve `app-deploy`; it must end green (this proves the waiter on ROLLING).

**B8. Prod up.** Run workflow `terraform-iac` with env `prod`, approve (about 32 to add). Then:
```bash
AWS_PROFILE=sis-prod-admin aws secretsmanager put-secret-value --region ap-southeast-1 --secret-id sis/prod/app-api-key --secret-string "$(openssl rand -hex 24)" --query Name --output text
```

**B9. Promote.** Run workflow `app-promote`: env `prod`, mode `promote`, sha `<SHA>` (the `main` commit that app-deploy just deployed). Approve `prod`. Expect `resolve` green, the lifecycle stages through `BAKE_TIME` and `CLEAN_UP`, and `SUCCESSFUL`. Then:
```bash
AWS_PROFILE=sis-dev-admin aws ecr describe-images --region ap-southeast-1 --repository-name sis-dev-app --image-ids imageTag=<SHA> --query 'imageDetails[0].imageDigest' --output text
AWS_PROFILE=sis-prod-admin aws ecr describe-images --region ap-southeast-1 --repository-name sis-prod-app --image-ids imageTag=<SHA> --query 'imageDetails[0].imageDigest' --output text
curl -s http://<PROD_ALB>/version
```
The two digests must be identical, and `/version` shows `prod`, `<SHA>` and that digest.

**B10. Broken release demo** (FR-15). In a second terminal, run `while true; do curl -s http://<PROD_ALB>/version; echo; sleep 5; done`. Then:
```bash
AWS_PROFILE=sis-prod-admin aws ecs describe-task-definition --region ap-southeast-1 --task-definition sis-prod-app --query taskDefinition --output json > td.json
jq '{family, taskRoleArn, executionRoleArn, networkMode, requiresCompatibilities, cpu, memory, runtimePlatform, volumes, containerDefinitions: (.containerDefinitions | map(.environment += [{"name":"BREAK","value":"true"}]))}' td.json > td-broken.json
AWS_PROFILE=sis-prod-admin aws ecs register-task-definition --region ap-southeast-1 --cli-input-json file://td-broken.json --query taskDefinition.revision --output text
AWS_PROFILE=sis-prod-admin aws ecs update-service --region ap-southeast-1 --cluster sis-prod-cluster --service sis-prod-app --task-definition sis-prod-app:<BROKEN_REV> --query service.serviceName --output text
AWS_PROFILE=sis-prod-admin aws ecs list-service-deployments --region ap-southeast-1 --cluster sis-prod-cluster --service sis-prod-app --query 'serviceDeployments[0].[status,statusReason]' --output text
```
Repeat the last command until `ROLLBACK_SUCCESSFUL`, and record whether `statusReason` names the alarm or the circuit breaker (R29). The curl loop must keep showing the good SHA. Then, **mandatory**:
```bash
AWS_PROFILE=sis-prod-admin aws ecs deregister-task-definition --region ap-southeast-1 --task-definition sis-prod-app:<BROKEN_REV> --query taskDefinition.status --output text
rm td.json td-broken.json
```
Optional bake-time demo: start another promote of the same `<SHA>`; when the log shows `BAKE_TIME`, run:
```bash
AWS_PROFILE=sis-prod-admin aws cloudwatch set-alarm-state --region ap-southeast-1 --alarm-name sis-prod-alb-5xx --state-value ALARM --state-reason "bake time rollback demo"
```
Expect the run to end red with a rollback, and traffic to stay on the previous revision.

**B11. N10.** Run workflow `app-promote`: env `prod`, mode `prove-isolation`, any `<SHA>`. Approve **dev**. Expect `sub` = `...:environment:dev`, `job_workflow_ref` = `.../app-promote.yml@refs/heads/main`, and three "denied as designed" lines (plan, apply, deploy). An alert email arrives from the prod account.

**B12. N1 for prod.** Run workflow `oidc-smoke-test` (dispatch). Expect refusals from both accounts.

**B13. Drift check (R18).** Open a PR that touches only `infra/terraform/envs/README.md`. The `plan-prod` comment must say no changes. Report any change on `aws_ecs_service.app` or `aws_lb_listener_rule.production`.

**B14. Teardown.** Run workflow `terraform-destroy` with env `prod`, type **destroy-prod**, approve (about 32 destroyed, revisions deregistered). Then the same for `dev` with **destroy-dev** (about 28). Bootstraps stay (close to zero cost).

## Open questions (recommendation first)

| Q | Recommendation | Alternatives |
|---|---|---|
| Q1 | Tell us where dev's Identity Center lives. If dev is standalone with an account instance, create a **new management account** (no workloads), create prod in it, and optionally invite dev | Dev already a member: just create prod. Dev is the management account: accept it for the lab (deviates from PLAN 7.1) |
| Q2 | Prod region `ap-southeast-1` (same as dev; one STS host, one alert region, no env-level `AWS_REGION`) | Another region: an env-level `AWS_REGION` in `prod`, a regional alert in that region, and PR plan inputs |
| Q3 | Prod `vpc_cidr = 10.50.0.0/16` (script default) | Any free `/16` in `10.0.0.0/8` |
| Q4 | Release trigger: `workflow_dispatch` with `sha`, gated on a green app-deploy (P10) | Tag `v*` (trust `StringLike ref`, tag ruleset) |
| Q5 | `prod` reviewer: yourself, prevent self-review off, `main` only, no wait timer | Wait timer of a few minutes |
| Q6 | Bake time 5 minutes | 10 minutes (more safety, more cost) |
| Q7 | PR plans for prod: yes (P18) | Plan only in the approved apply |
| Q8 | Infra role: scoped inline policy (P12) | AWS managed policy |
| Q9 | Uniform bootstrap grants (P13) | Prod-only grants |
| Q10 | One waiter on the service deployments API for dev and prod (P14) | Keep `describe-services` for dev |
| Q11 | No test listener rule or PAUSE hook now | Header test rule plus a PAUSE hook for a manual green check |
| Q12 | Broken-release demo through admin CLI (P16) | A pipeline-built broken image (needs a promote input that accepts non-main images) |
| Q13 | Prod root email: a plus-address of your budget email | A separate mailbox |
| Q14 | Keep ECR in the env stack (P19) | Move ECR to bootstrap so promotion works with dev torn down |
| Q15 | No SCPs in Phase 7 | Region-deny and deny-leave-org SCPs on the prod OU |

## Build briefs

### devops-engineer, PR A (owns `infra/**`, `.github/**`, `scripts/**`, `Makefile`, `.gitignore`)

Create a branch from the phase branch (lesson 25). Read this ADR at its absolute path in `docs/adr/`.

**Files**

- `envs/dev/`: `tests/dev.tftest.hcl` becomes the generic `tests/envs.tftest.hcl` (names from `var.env`); the
  README names the env only through `terraform.tfvars` so it can stay identical (D16). Location, backend key and
  tfvars stay as they are.
- `envs` and module `variables.tf`: env regex (P4).
- `bootstrap/variables.tf`: env regex, no other change.
- `scripts/`:
  - `lib.sh`: `valid_env` rule;
  - `scripts/tf/new-env.sh` (new);
  - `scripts/guard/env_parity.py` and `scripts/guard/env-parity.sh` (new);
  - `scripts/guard/harden_runner_policy.py`, `scripts/guard/workflow_triggers.py` (P8);
  - `selftest/new-env.sh` (new);
  - `selftest/workflows.sh` (YAML loader instead of `sed` ranges);
- `Makefile`: `new-env` target.
- `.gitignore`: `.terraform-*/`.
- Workflows per D (PR A column), and `reusable-terraform-plan.yml`.

**Tests first**

- T1 to T14 and the parity fixtures.
- Policy fixtures: a `uses:` job, `secrets: inherit`, `secrets[` in an audit job, `env` from a secret in an audit job, `workflow_call` outside `reusable-*`, a reusable file with a second trigger.
- `envs.tftest.hcl` passes in `envs/dev/` and in a `make new-env ENV=qa` copy made in a temp clone.
- Parity fixtures: a changed `main.tf` in a copy fails; a changed `versions.tf` or lock file passes; a wrong `key` or `env` fails.

**Done**

- `make check` green on a fresh clone; actionlint and zizmor clean.
- `terraform test` for envs, module and bootstrap passes offline.
- No 12-digit literal anywhere.
- `scripts/tf/new-env.sh qa --dry-run` output pasted in the hand-back.
- No `apply` or `destroy` target. The script never invokes `terraform`, `aws` or `gh` (T10).

### devops-engineer, PR B

**Files**

- `make new-env ENV=prod FROM=dev`, then review `envs/prod/terraform.tfvars`. Add `promotion_target_env = "prod"` to `envs/dev/terraform.tfvars` (amendment S1: no `deployment_strategy`, no bake time).
- `bootstrap/accounts/prod.tfvars.example`.
- Module E: `alb.tf`, `ecs.tf`, `alarms.tf` (new), `ecr.tf`, variables, tests, README.
- Root variables and `main.tf` wiring.
- Bootstrap F: `iam_ecs_elb.tf` (new), `iam_apply.tf`, `iam_deploy.tf`, `iam_guardrails.tf`, `locals.tf`, `variables.tf`, `outputs.tf`, tests, README.
- `scripts/`:
  - `scripts/ecs/wait-deployment.sh` (P14, evaluator fixtures for SUCCESSFUL, IN_PROGRESS with a stage, ROLLBACK_SUCCESSFUL, ROLLBACK_FAILED, STOPPED, no matching revision);
  - `scripts/ecs/preflight.sh` (alarm guard);
  - `scripts/ecs/render-task-def.sh` (environment rule);
  - `ecr-promote.sh` (new: resolve, copy, verify, never prints an account);
  - `scripts/ci/install-tools.sh`, `scripts/ci/tools.sha256` and `mise.toml` (crane v0.22.1; check the two digests in Finding 7 against `checksums.txt`);
  - policy exception for `app-promote.yml`.
- Workflows per D (PR B column), `app-promote.yml`, `oidc-smoke-test.yml` N1.

**Tests first**

- Module: the ROLLING and BLUE_GREEN asserts, the repo policy document, the validation.
- Bootstrap: deploy `job_workflow_ref` by source variable; PassRole only on the infra role with the condition; no action wildcard in Allow statements; source pull only on the one ARN; infra role trust and scoped resources.
- Waiter, preflight, render and `ecr-promote.sh` fixtures (stubbed `aws` and `crane`: tag exists with an equal digest, an unequal digest fails, copy then verify).
- Parity guard: `app-promote` options equal envs minus dev.

**Done**

- `make check` green.
- `plan-dev` and `plan-prod` green on the PR after B5.
- The hand-back lists the expected plan counts and every new allowlist host with its source line.

### backend-dev

No change: Phase 7 touches no `app/**` file. The demo uses the existing `BREAK` variable, and promotion ships the same image.

## Sources

- https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/v6.70.0/website/docs/r/ecs_service.html.markdown
- https://github.com/hashicorp/terraform-provider-aws/releases/latest
- https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deployment-type-blue-green.html
- https://docs.aws.amazon.com/AmazonECS/latest/developerguide/blue-green-deployment-how-it-works.html
- https://docs.aws.amazon.com/AmazonECS/latest/developerguide/alb-resources-for-blue-green.html
- https://docs.aws.amazon.com/AmazonECS/latest/developerguide/blue-green-deployment-implementation.html
- https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deploy-blue-green-service.html
- https://docs.aws.amazon.com/AmazonECS/latest/developerguide/AmazonECSInfrastructureRolePolicyForLoadBalancers.html
- https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AmazonECSInfrastructureRolePolicyForLoadBalancers.html
- https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deployment-circuit-breaker.html
- https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deployment-alarm-failure.html
- https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deployment-failure-detection.html
- https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_ServiceDeployment.html
- https://servicereference.us-east-1.amazonaws.com/v1/ecs/ecs.json
- https://servicereference.us-east-1.amazonaws.com/v1/cloudwatch/cloudwatch.json
- https://docs.aws.amazon.com/AmazonECR/latest/APIReference/API_GetAuthorizationToken.html
- https://docs.aws.amazon.com/AmazonECR/latest/userguide/repository-policy-examples.html
- https://docs.aws.amazon.com/organizations/latest/userguide/orgs_manage_accounts_create.html
- https://github.com/google/go-containerregistry/releases/latest
- https://api.github.com/repos/google/go-containerregistry/releases/latest
- https://github.com/google/go-containerregistry/blob/main/cmd/crane/doc/crane_copy.md
- https://docs.github.com/en/actions/reference/security/oidc
- https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations
- https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows
- https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments
- https://docs.github.com/en/actions/reference/workflows-and-actions/variables
- https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets
- https://docs.zizmor.sh/audits/
- https://developer.hashicorp.com/terraform/cli/workspaces
- https://developer.hashicorp.com/terraform/cli/commands/test (does not list `-var-file`; secondary sources say it is supported, so B gives a fallback)
- https://dev.classmethod.jp/en/articles/ecs-blue-green-deployment/ (third party, used only for the listener-rule drift note R18)
