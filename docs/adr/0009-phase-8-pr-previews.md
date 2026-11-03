# ADR 0009: Phase 8 PR preview environments on the dev ALB

- Status: deferred (ADR 0010, 2026-11-02). Accepted 2026-10-30 with Q1 to Q11 at the recommended answers; PR A (#35) closed unmerged, branch `phase-8-pr-a` kept
- Amended 2026-10-30 (user): Amendment H. Credentialed preview jobs run `main`'s code through `workflow_run`
  (Q4 flipped) after the PR A security review found H1. Sections A (V6, V13 to V18), E, F, I, J, K, M, Risks,
  the PR B brief and the PR B checkpoint are rewritten to match.
- Date: 2026-10-30

## Context

### Goal

FR-17: a pull request from this repository that touches `app/**` gets the image it built running in the dev account. Its own URL is posted as a sticky PR comment, and `/version` shows the PR head SHA. Closing the PR removes what the preview created. The build stays credential-free. The preview job uses the GitHub environment `preview` (required reviewer) and a preview role that can only touch resources tagged `Env=preview`. Fork and Dependabot PRs get no preview.

Fixed by the user and not reopened here:
- The dev ALB is reused, over HTTP, with no domain.
- There is no third-party hosting or tunnel.
- Previews work only while the dev stack is up.
- Display names follow ADR 0008 amendment W: workflow `App Preview` in `app-preview.yml`, short lower-case job names with no expressions.

### Requirements

| ID | What Phase 8 must deliver | State found (branch `docs/working-notes-out-of-repo`, clean) |
|---|---|---|
| FR-17 | Preview per same-repo PR, URL in a sticky comment, `/version` = head SHA, removed on close | Not started. The dev ALB has one listener (port 80) whose default action forwards to `sis-dev-tg`. There are no rules |
| FR-5, FR-11 | Deploy by digest, least privilege, credential-free build | `app-deploy.yml`: `build-scan` (no token) hands an image artifact with sha256 to `deploy` (env `dev`, block mode, Docker exception) |
| FR-8 | The pipeline never reads secret values | The dev exec role may `GetSecretValue` on `sis/dev/app-api-key`. Previews must never get this role |
| FR-12 | Teardown must always work | `terraform-destroy.yml` plans a destroy of `module.app_ecs.` only, then deregisters the `sis-dev-app` family |
| NFR-1 | Account-bearing values are environment secrets | Env `dev`: `AWS_ACCOUNT_ID`, `AWS_DEPLOY_ROLE_ARN`, ... (ADR 0008 P5) |
| NFR-2, NFR-4 | Explicit permissions. harden-runner first; block mode on credentialed jobs | `harden_runner_policy.py` enforces this. `NEEDS_CONTAINERS = (("app-deploy.yml","deploy"),)` |
| NFR-3 | Pins | No new tool or action in this ADR |
| NFR-7 | Session cap; alert on an unexpected OIDC subject | `expected_subs` is built from `local.trust`, so new trusts extend the alert pattern automatically |
| NFR-8 | Tags | CLI-created resources carry `Project`, `Env=preview`, `ManagedBy=app-preview` (precedent: `ManagedBy=app-deploy` on task definitions) |
| NFR-9 | The user runs apply, destroy and secrets | Unchanged. The bootstrap re-apply is a checkpoint step |

### Findings from official docs

1. **ALB quotas.** 50 listeners per ALB. 100 rules per ALB (default rules excluded). 100 target groups per ALB (not adjustable). 3,000 target groups per region. 5 condition values and 5 match evaluations per rule.
2. **ALB rule transforms.**
   - `url-rewrite` rewrites "the path or the query string" with a regex and a replacement. Capture groups (`$1`) are allowed.
   - Only "one host header rewrite transform and one URL rewrite transform per rule". "You can't add a transform to a default rule."
   - "If there is no pattern match, the original request is sent to the target"; "if there is a pattern match but the transform fails, we return an HTTP 500 error."
   - `aws elbv2 create-rule` has `--transforms` (CLI 2.39.2 docs). Rule priority runs from 1 to 50000, and "a listener can't have multiple rules with the same priority". A path pattern is case-sensitive, at most 128 characters, and compared to the path only.
3. **ELB authorization** (service reference JSON):
   - `CreateRule` is authorized on the **listener** resource with `aws:RequestTag`, `aws:ResourceTag` and `aws:TagKeys`. `DeleteRule` and `ModifyRule` are authorized on `listener-rule` with `aws:ResourceTag`.
   - `CreateTargetGroup` is authorized on `targetgroup` with `aws:RequestTag`. `DeleteTargetGroup` and `ModifyTargetGroup` are authorized with `aws:ResourceTag`.
   - `AddTags` carries `elasticloadbalancing:CreateAction`.
   - Describe actions have no resource-level support.
   - Listener ARNs are `listener/app/<lb-name>/<lb-id>/<listener-id>`, so the dev listener and any other listener on the same ALB share the name part. **Only a tag can tell them apart.**
   - ELB tag-on-create: callers "must also have explicit permissions to use the elasticloadbalancing:AddTags action". `CreateAction` scopes it to creation.
4. **ECS authorization** (service reference JSON):
   - `CreateService` on `service` takes `aws:RequestTag` and `ecs:task-definition`. `UpdateService` takes `ecs:task-definition`. `DeleteService` and `DescribeServices` take `aws:ResourceTag` and `ecs:cluster`.
   - `ListServices` has no resource and takes condition `ecs:cluster`.
   - `RegisterTaskDefinition` on `task-definition` takes `aws:RequestTag`, `ecs:task-cpu` and `ecs:task-memory`.
   - **`DeregisterTaskDefinition` has no resource and no condition.**
   - `TagResource` carries `ecs:CreateAction`.
5. **ECS lifecycle.**
   - DeleteCluster: "You can't delete a cluster that contains services" (`ClusterContainsServicesException`), and also not one with active tasks.
   - DeleteService: with `force` "you can delete a service even if it wasn't scaled down to zero tasks". A deleted service moves to `DRAINING` and "is no longer visible in ... ListServices", then to `INACTIVE`.
   - "If you attempt to create a new service with the same name as an existing service in either ACTIVE or DRAINING status, you receive an error."
6. **Execution role.** The AWS trust example is `ecs-tasks.amazonaws.com` with no condition. Fargate uses the execution role for ECR pulls, awslogs and `secrets`.
7. **GitHub `pull_request` event.**
   - The default types are `opened`, `synchronize` and `reopened`. `GITHUB_REF` is `refs/pull/N/merge`.
   - **For a closed PR: "If a pull request was closed but not merged, it will be `refs/pull/PULL_REQUEST_NUMBER/merge`. If a pull request was closed as a result of being merged, it will be the fully qualified ref of the branch it was merged into"** (`refs/heads/main`).
   - "Workflows will not run on `pull_request` activity if the pull request has a merge conflict."
   - Fork PRs: "secrets are not passed" and the token is read-only. "Workflows triggered by Dependabot pull requests are treated as though they are from a forked repository."
8. **`workflow_run`** runs the default-branch file and "is able to access secrets and write tokens, even if the previous workflow was not". "Running untrusted code on the `workflow_run` trigger may lead to security vulnerabilities." zizmor's `dangerous-triggers` audit flags it, and adds that "a `workflow_run` always runs in the context of the target repository".
9. **Environments.**
   - Up to six required reviewers. Self-review prevention is optional.
   - "A job cannot access environment secrets until one of the required reviewers approves it."
   - Branch rules match `GITHUB_REF`, and "adding another branch rule for `refs/pull/*/merge` would also allow workflows triggered by `pull_request` events" to deploy. "Wildcard characters will not match `/`."
   - On GitHub Free, environment secrets exist only on public repos.
10. **OIDC.**
    - `sub` is `repo:O/R:environment:<name>` when the job references an environment.
    - IAM supports `actor`, `actor_id`, `job_workflow_ref`, `repository`, `repository_id`, `repository_owner_id`, `workflow`, `ref`, `environment` and `enterprise_id`. There is **no `event_name`** (lesson 11).
    - `job_workflow_ref` is documented only "for jobs using a reusable workflow". ADR 0007 A0 proved the claim on `main` for top-level files. Its value for a `pull_request` run is not documented (R35).
11. **Concurrency.** "At most one job or workflow run can be pending". A newer pending run cancels the older pending one. The docs say nothing about jobs that wait for an environment approval.
12. **Cost.**
    - Public IPv4: 0.005 USD per hour.
    - Fargate Linux x86, us-east-1: 0.000011244 USD per vCPU-second and 0.000001235 USD per GB-second. The page does not list ap-southeast-1.
13. **Provider v6.70.0 `aws_lb_listener`** supports a `fixed-response` default action and `tags`; "tags with matching keys will overwrite those defined at the provider-level".

### Repo facts that shape the design

- `scripts/ecs/render-task-def.sh` copies the latest **dev** revision and requires the `APP_API_KEY` secret, the dev exec role and the dev task role. Previews need their own renderer.
- The dev exec role can read the dev secret. A preview able to pass that role could register a task definition with `secrets` pointing at the dev secret, and its own container would receive the value. The preview role must never pass any dev role.
- The dev ECR lifecycle keeps the last 10 images of **any** tag. Preview pushes there would evict `main` images that promote and rollback rely on (ADR 0008 S2).
- The apply role can already delete `sis-dev-*` target groups, rules and any service in `sis-dev-cluster`. It cannot list services.
- Trust policies have one statement per role (`oidc.tf`). `workflow_files` is the pinned-file contract, and `selftest/workflows.sh` checks that each listed file exists.
- The trigger allowlist is `pull_request`, `push`, `workflow_dispatch`, plus `workflow_call` only in `reusable-*.yml`.
- Comment jobs check out `base.sha` scripts only. A PR that introduces the script a comment job calls fails its own comment with exit 127 (lesson 44).

## Decision

### A. Decisions

| # | Decision | Alternatives | Pro | Con |
|---|---|---|---|---|
| V1 | **Routing: a dedicated preview listener** on the dev ALB, port `8000`, created by Terraform, tagged `Env=preview`, default action `fixed-response 404`. **One rule per PR** on that listener: priority `<n>` (the PR number), condition `path-pattern /pr-<n>/*`, action forward to the PR target group, transform `url-rewrite ^/pr-<n>/(.*)$` to `/$1`. URL: `http://<dev ALB DNS>:8000/pr-<n>/` | (a) Path rules on the dev port 80 listener. (b) One listener per PR on a port range. (c) Host-header rules (needs DNS). (d) Path rules plus a `BASE_PATH` in the app | The preview role never touches the dev listener: `CreateRule` is tag-scoped to the preview listener (Finding 3), and the dev ALB ARN cannot express that. No app change. One SG ingress port. Priority = PR number is unique and idempotent. Up to 100 rules per ALB (Finding 1) is far above the cap | A non-standard port; some networks block 8000. Depends on ALB transforms, a newer feature (R36). `/pr-<n>` without the slash gets the listener's 404. (a) would let an approved PR shadow dev traffic with a priority 1 `/*` rule. (b) needs `CreateListener` on the dev ALB (Env=dev, so not tag-scopable) and an SG port range. (c) has no domain. (d) is an app change for an infra concern |
| V2 | **Per-PR resources are created by tested AWS CLI scripts** (`scripts/preview/*.sh`), idempotent by deterministic names and tags. Terraform owns only the shared preview infrastructure in `modules/app-ecs` behind `preview_enabled`: the listener, the SG rules, the preview task SG, the ECR repo `sis-dev-preview` and the log group `/ecs/sis-dev-preview` | (t1) Terraform with a per-PR state key. (t2) `for_each` over open PRs in `envs/dev` | Fast, no state access for a PR-controlled job, offline self-tests with PATH stubs (existing pattern). The dev stack plan shows no drift: listener rules are separate resources and are not managed by `aws_lb_listener` | Imperative code to maintain (about 300 lines plus tests). (t1) needs state write for the preview role, provider downloads and orphaned state keys. (t2) needs the apply role and an approval on every PR |
| V3 | **Four garbage-collection layers:** (1) `closed` runs `down.sh <n>`; (2) every approved deploy sweeps previews of PRs that are no longer open before its cap check; (3) a `workflow_dispatch` sweep on `main`; (4) the dev teardown sweeps everything first (V4) | Only (1) | Covers a merge-conflict close (Finding 7, R38), a failed cleanup, an approval given after close (R39) and a dev teardown | More moving parts; each one is tested |
| V4 | **`terraform-destroy` runs `scripts/preview/sweep.sh --all --no-images` with the apply role before the destroy plan**, waits for the deleted services to be `INACTIVE`, and afterwards deregisters the `sis-<env>-preview` family as well as `sis-<env>-app`. The apply role gains only `ecs:ListServices` (condition `ecs:cluster`) | Let Terraform fail and clean up by hand. A separate job with the cleanup role | Teardown never meets `ClusterContainsServicesException` or ENIs in the SGs (Finding 5). It fails closed: a sweep error stops the job before any delete. Prod is a no-op | One more apply-role action. The sweep runs before the destroy plan is reviewed by the guard; previews are disposable (accepted) |
| V5 | **Preview role `sis-dev-gha-preview`**, trusted only from env `preview` on PR refs (E). It creates, updates and deletes only `Env=preview` resources with `sis-dev-preview-*` names | Reuse the deploy role. One role for deploy and cleanup | Smallest set of rights for PR code that runs after a human approval | A new role and environment |
| V6 | **Separate cleanup role `sis-dev-gha-preview-cleanup` in env `preview-cleanup` with no reviewer**, used by `main`'s code in `app-preview-deploy.yml` (jobs `cleanup`, `sweep`). Delete and describe only | One role trusting both subs; cleanup behind approval | Cleanup never waits for a human; least privilege per job; N16 differs from the preview trust in `sub` only | One more role and environment |
| V7 | **A fence policy `sis-dev-gha-preview-fence`** (managed, attached to both preview roles) with explicit denies (F.4), plus the shared guardrails G1 to G6 | Rely on implicit deny | Survives a future Allow edit. Gives N11 to N15 an explicit reason | One more policy and its tests |
| V8 | **Preview execution role `sis-dev-preview-exec`, created by bootstrap**, with the ECS boundary. It may pull from `sis-dev-preview` and write logs to `/ecs/sis-dev-preview` only, with an explicit deny on Secrets Manager and SSM. **No task role.** The preview role may pass only this role | Pass the dev exec role. Create it in the module | The dev secret is out of reach even with a hostile task definition. The role exists without the dev stack, and the apply role cannot edit it (G4 extended) | A bootstrap re-apply |
| V9 | **No app secret in previews**: no `secrets` in the task definition, so `secret_loaded: no` and `/admin` always returns 401 | A preview secret shell. Reuse the dev secret | A preview runs PR code, so any value given to it is readable by the PR author, and a preview secret would be public in effect. Reusing dev's is ruled out (FR-8) | `/admin` cannot be demoed on a preview |
| V10 | **Cap of 3 concurrent previews** (`PREVIEW_MAX=3` in `lib.sh`). The preflight counts `ACTIVE` `sis-dev-preview-*` services after the sweep. At the cap, the deploy job fails before creating anything, and the comment says so and lists the open preview PRs | 2 or 5. A hard cap in IAM | About 0.06 USD per hour at the cap. Clear failure | The PR-controlled script enforces the cap, so it is soft against a hostile approved PR (R34). IAM cannot count |
| V11 | **Images go to a separate repo `sis-dev-preview`** (IMMUTABLE, scan on push, `force_delete`, keep the last 20), with tag `pr-<n>-<sha>` and a task definition by digest. `down.sh` deletes the PR's tags | The dev repo with a `pr-` tag prefix | A PR image can never be promoted (promote reads `sis-dev-app`), and preview pushes never evict `main` images | One more repository |
| V12 | **The build runs in a credential-free job** that checks out `pull_request.head.sha`, builds, tests, smoke-tests and scans with `scripts/image/verify.sh`, and uploads `preview-image` (1 day) plus its sha256. `GIT_SHA` = head SHA | Build the merge commit | `/version` names the exact commit whose content is running | Rebuilds what `App CI` also built (runner minutes only) |
| V13 | **Triggers:** `app-preview.yml` on `pull_request` (`main`, types `[opened, synchronize, reopened, closed]`, path filters), credential-free. `app-preview-deploy.yml` on `workflow_run` (`workflows: [App Preview]`, `types: [completed]`) plus `workflow_dispatch` (sweep). Amendment H | `pull_request` credentialed jobs (H1) | Credentialed code is always reviewed `main` code | Trigger exception and zizmor inline ignore (HD9) |
| V14 | **Concurrency `app-preview-pr-${{ needs.resolve.outputs.pr }}`, `cancel-in-progress: false`**, shared by `deploy` and `cleanup` in `app-preview-deploy.yml` (Finding 17). App Preview builds use `app-preview-build-<n>` with cancel true | Global group | One writer per PR; a cleanup always runs after or instead of a pending deploy | Approval and concurrency interplay undocumented (R39) |
| V15 | **Sticky comment from `main`'s code** (`comment` job in `app-preview-deploy.yml`, pull-requests: write, no AWS), using `scripts/gh/sticky-comment.sh` | Comment from App Preview | No PR code with a write token | None |
| V16 | **Fork and Dependabot refusal is authoritative in `resolve`** (HD3, from the API and immutable IDs). App Preview jobs also carry the usual `if` to save runner minutes | `if` only | Cannot be bypassed by a PR | One API call |
| V17 | **harden-runner:** block mode, telemetry off and `disable-sudo-and-containers: true` on `deploy`, `cleanup` and `sweep`; audit on `resolve`, `list-open` and `comment`, and on App Preview jobs. crane push (HD10) | Docker exception | No container runtime in credentialed jobs | Fallback recorded if crane fails |
| V18 | **Environment branch rules:** `preview` and `preview-cleanup` allow **`main` only** (Finding 20). Prevent self-review off | PR refs | GitHub refuses either environment on any other ref, before IAM | Set by hand in the web UI |
| V19 | **The preview roles never deregister task definitions.** Revisions of family `sis-dev-preview` stay `ACTIVE` (no cost) until the dev teardown deregisters them with the apply role | Grant `ecs:DeregisterTaskDefinition` on `*` | `DeregisterTaskDefinition` has no resource scope (Finding 4), so granting it would let an unreviewed cleanup token deregister dev revisions | After a close, one revision per deploy remains until teardown (R41) |
| V20 | **Negative tests N11 to N17** (section K) | Fewer | Proves the fence live on every deploy, without alert emails (only `AssumeRoleWithWebIdentity` refusals send alerts) | More calls per deploy |
| V21 | **Two PRs:** A = shared preview infrastructure in the module, plus `sticky-comment.sh`. B = bootstrap, workflow, scripts, teardown sweep and tests | One PR | A is small, needs no bootstrap re-apply and is provable on dev | B is large: the trust names the file it adds (`workflow_files`), so they ship together |

### B. URL and routing (V1)

| Item | Value |
|---|---|
| Listener | `aws_lb_listener.preview`, port `var.preview_listener_port` (8000), HTTP, tags `{ Name = "sis-dev-preview", Env = "preview" }`. Default action `fixed-response`, 404, `text/plain`, "No preview at this path" |
| Ingress | `aws_vpc_security_group_ingress_rule.alb_preview`, indexed over `alb_ingress_cidrs` like port 80 (same masking rules, ADR 0007 S35) |
| Rule | Priority `<n>` (refused above 50000). Condition `path-pattern ["/pr-<n>/*"]`. Forward to `sis-dev-preview-<n>`. Transform `[{"Type":"url-rewrite","UrlRewriteConfig":{"Rewrites":[{"Regex":"^/pr-<n>/(.*)$","Replace":"/$1"}]}}]`. Tags `Project`, `Env=preview`, `ManagedBy=app-preview`, `PreviewPr=<n>` |
| Target group | `sis-dev-preview-<n>`, ip, HTTP 8080, VPC of the ALB. Health check `/health`, 200, interval 15, healthy 2, unhealthy 3. `deregistration_delay.timeout_seconds = 5`. Same tags |
| Health check | Goes straight to the targets, so no rewrite is involved |

### C. Resources and lifecycle

| Resource | Name | Owner | Created by | Removed by |
|---|---|---|---|---|
| Preview listener, SG ingress on 8000, preview task SG `sis-dev-preview-task` (ingress 8080 from the ALB SG, egress 443), ALB SG egress to it, ECR `sis-dev-preview` and lifecycle, log group `/ecs/sis-dev-preview` (1 day) | as named | Terraform (module, `preview_enabled`) | dev apply | dev destroy |
| Exec role `sis-dev-preview-exec` | as named | bootstrap | admin | never (bootstrap) |
| Image `pr-<n>-<sha>` | in `sis-dev-preview` | preview role | `deploy` | `down.sh` (tag prefix `pr-<n>-`), lifecycle, repo `force_delete` |
| Task definition revision | `sis-dev-preview:<rev>`, tags incl. `PreviewPr`, `GitSha` | preview role | `deploy` | teardown deregistration (V19) |
| Target group, rule, service `sis-dev-preview-<n>` | as named | preview role | `up.sh` | `down.sh`, `sweep.sh` |

`up.sh <n> <td-arn>`, idempotent:
1. Find the ALB `sis-dev-alb` (VPC, subnets, DNS) and the listener on 8000. Check that the listener carries `Env=preview`.
2. Find or create the target group, then set its attributes.
3. Find the rule by priority `<n>`. If one exists, its `PreviewPr` tag must be `<n>`; otherwise refuse.
4. Service state:
   - `ACTIVE`: `update-service`.
   - `DRAINING`: wait for `INACTIVE`, then create.
   - `MISSING` or `INACTIVE`: `create-service` with launch type FARGATE, desired 1, the preview SG, the ALB subnets, public IP, circuit breaker with rollback, grace 30 s and tags.
5. Print `PREVIEW_URL=http://<dns>:8000/pr-<n>/`.

`down.sh <n> [--no-images]`, idempotent (missing is fine): delete the rule, then `delete-service --force`, then wait for `INACTIVE`, then delete the target group, then delete images with the tag prefix.

`sweep.sh --keep "<numbers>" | --all [--no-images]`:
- Collect PR numbers from `ListServices` names, from `DescribeServices` on the target group names (catches `DRAINING`), and from `Env=preview` rules on the preview listener.
- Act only on names matching `^sis-<env>-preview-[1-9][0-9]{0,4}$`.
- Run `down.sh` for each number not kept.

### D. Teardown interaction (V4)

`terraform-destroy.yml` job `destroy`, after the setup step:
1. **Remove previews:** `scripts/preview/sweep.sh --all --no-images`. This uses the apply role, which already has `DeleteService`, `DeleteRule`, `DeleteTargetGroup` and `Describe*` on `sis-dev-*`, plus the new `ListServices`.
2. The destroy plan, guard and apply run as today. Terraform deletes the listener, SGs, repo (with images) and log group.
3. `deregister-revisions.sh` takes the families `sis-<env>-app` and `sis-<env>-preview`. The preview family is deregistered only when no `sis-<env>-preview-*` service is `ACTIVE` or `DRAINING`.

If dev is destroyed while PRs are open, the previews are gone. After dev is re-created, push a commit or re-run the PR's `deploy` job.

### E. Roles and trust

All trusts keep `aud = sts.amazonaws.com`, `repository_id`, `repository_owner_id` and `aws:RequestedRegion` (StringEquals). The preview roles use the same single-statement shape as apply and deploy, so `oidc.tf` needs no legs.

| Role | `sub` (StringEquals) | `ref` (StringEquals) | `job_workflow_ref` (StringEquals) |
|---|---|---|---|
| `sis-dev-gha-preview` | `<P>:environment:preview` | `refs/heads/main` | `O/R/.github/workflows/app-preview-deploy.yml@refs/heads/main` |
| `sis-dev-gha-preview-cleanup` | `<P>:environment:preview-cleanup` | `refs/heads/main` | same |

- No PR-controlled code can obtain either token (Amendment H).
- `app-preview.yml` is credential-free and must not be listed in `workflow_files`. A self-test enforces both.

Bootstrap changes (PR B):
- `variables.tf`: `preview_enabled` (bool, default false). `accounts/dev.tfvars.example` sets it to true.
- `locals.tf`:
  - `workflow_files.preview = ["app-preview-deploy.yml"]` (when enabled), feeding `job_workflow_refs` as for deploy;
  - `trust` gains `preview` and `preview_cleanup` entries in the existing shape (`ref_test = "StringEquals"`);
  - `resource_names` and `role_names` additions as before.
- `iam_preview.tf` (new): the two roles (3600 s), their inline policies, the fence, and the exec role with the boundary.
- `iam_apply.tf`: `EcsListServicesInCluster`.
- `iam_guardrails.tf`: attachments for both roles; G4 adds `role/sis-dev-preview-exec`.
- `outputs.tf`: `preview_role_arn`, `preview_cleanup_role_arn`.
- `monitoring.tf`: no edit (`expected_subs` follows `local.trust`).

### F. Least privilege

Region and account are omitted below. `<C>` = `sis-dev-cluster`, `<A>` = `sis-dev-alb`.

**F.1 `sis-dev-gha-preview`**

| Sid | Actions | Resource | Conditions | `*` justification |
|---|---|---|---|---|
| EcrAuth | `ecr:GetAuthorizationToken` | `*` | none | No resource-level support |
| EcrPushPreviewRepo | BatchCheckLayerAvailability, InitiateLayerUpload, UploadLayerPart, CompleteLayerUpload, PutImage, BatchGetImage, DescribeImages, ListImages, BatchDeleteImage | `repository/sis-dev-preview` | none | |
| RegisterPreviewTaskDef | `ecs:RegisterTaskDefinition` | `task-definition/sis-dev-preview:*` | `aws:RequestTag/Env = preview`, `aws:RequestTag/Project = ship-it-safely`, `ecs:task-cpu <= 256`, `ecs:task-memory <= 512` | |
| EcsTagOnCreate | `ecs:TagResource` | `task-definition/sis-dev-preview:*`, `service/<C>/sis-dev-preview-*` | `ecs:CreateAction` in [RegisterTaskDefinition, CreateService] | |
| CreatePreviewService | `ecs:CreateService` | `service/<C>/sis-dev-preview-*` | RequestTag Env and Project; ArnLike `ecs:task-definition = task-definition/sis-dev-preview:*` | |
| UpdatePreviewService | `ecs:UpdateService` | same | ArnLike `ecs:task-definition` as above | |
| ReadPreviewServices | `ecs:DescribeServices` | same | none | |
| DeletePreviewService | `ecs:DeleteService` | same | `aws:ResourceTag/Env = preview` | |
| ListServicesInCluster | `ecs:ListServices` | `*` | ArnEquals `ecs:cluster = cluster/<C>` | No resource (Finding 4); condition-scoped |
| ElbRead | `elasticloadbalancing:Describe*` | `*` | none | No resource-level support |
| CreatePreviewTargetGroup | `CreateTargetGroup` | `targetgroup/sis-dev-preview-*/*` | RequestTag Env and Project | |
| ManagePreviewTargetGroup | `ModifyTargetGroup`, `ModifyTargetGroupAttributes`, `DeleteTargetGroup` | same | `aws:ResourceTag/Env = preview` | |
| CreateRuleOnPreviewListener | `CreateRule` | `listener/app/<A>/*/*` | `aws:ResourceTag/Env = preview` (the listener), RequestTag Env and Project | ID wildcards only; the tag selects the listener |
| ManagePreviewRule | `ModifyRule`, `DeleteRule` | `listener-rule/app/<A>/*/*/*` | `aws:ResourceTag/Env = preview` | as above |
| ElbTagOnCreate | `AddTags` | `targetgroup/sis-dev-preview-*/*`, `listener-rule/app/<A>/*/*/*` | `elasticloadbalancing:CreateAction` in [CreateTargetGroup, CreateRule]; `aws:RequestTag/Env = preview` | |
| Ec2FindPreviewSg | `ec2:DescribeSecurityGroups` | `*` | none | No resource-level support (subset of the approved `ec2:Describe*`) |
| PassPreviewExecRole | `iam:PassRole` | `role/sis-dev-preview-exec` | `iam:PassedToService = ecs-tasks.amazonaws.com` | |

**`iam:PassRole` (highest risk)** reaches one role. That role cannot read any secret or SSM parameter, cannot pull from `sis-dev-app` and writes only to the preview log group. No task role is passed. **Tag escalation is closed:** `AddTags` and `ecs:TagResource` work only on create.

**Known IAM limit (H1):** ECS has no condition key for `loadBalancers[].targetGroupArn` or `networkConfiguration.securityGroups`, and target registration runs as the ECS service-linked role. So a holder of this role could attach a preview service to `sis-dev-tg` or any security group. After Amendment H only `main`'s reviewed code holds the role. `up.sh` refuses any target group but `sis-dev-preview-<n>` and any SG but `sis-dev-preview-task`, and a self-test pins this. The fence and tag scoping stay as defense in depth (R47).

**F.2 `sis-dev-gha-preview-cleanup`**
- `ElbRead`, `ListServicesInCluster`, `ReadPreviewServices`, `DeletePreviewService`, `ManagePreviewRule` (DeleteRule only), `ManagePreviewTargetGroup` (DeleteTargetGroup only).
- `ecr:ListImages` and `ecr:BatchDeleteImage` on `repository/sis-dev-preview`.
- Nothing else: no create, update, register, tag or PassRole.

**F.3 `sis-dev-preview-exec`** (boundary `sis-dev-ecs-boundary`; trust `ecs-tasks.amazonaws.com`, as AWS documents and as the dev exec role has)
- Allow `ecr:GetAuthorizationToken` on `*` (no resource-level support).
- Allow ECR pull (`BatchCheckLayerAvailability`, `GetDownloadUrlForLayer`, `BatchGetImage`) on `repository/sis-dev-preview`.
- Allow `logs:CreateLogStream` and `logs:PutLogEvents` on `log-group:/ecs/sis-dev-preview:*`.
- Deny `secretsmanager:*`, `ssm:*` and `kms:Decrypt` on `*`.

**F.4 Fence `sis-dev-gha-preview-fence`** (Deny; action wildcards only here)

| Sid | Deny | Resource | Condition |
|---|---|---|---|
| FenceDevService | `ecs:*` | `service/<C>/sis-dev-app`, `task-definition/sis-dev-app:*` | none |
| FenceDevRepo | `ecr:*` | `repository/sis-dev-app` | none |
| FenceSecrets | `secretsmanager:*` | `*` | none (no metadata either) |
| FenceIamWrites | `iam:Create*`, `Put*`, `Update*`, `Delete*`, `Attach*`, `Detach*`, `Add*`, `Remove*`, `Tag*`, `Untag*`, `*PermissionsBoundary`, `*PolicyVersion`, `Set*`, `Upload*` | `*` | none |
| FenceNonPreviewElb | `CreateListener`, `ModifyListener`, `DeleteListener`, `CreateRule`, `ModifyRule`, `DeleteRule`, `SetRulePriorities`, `ModifyTargetGroup`, `ModifyTargetGroupAttributes`, `DeleteTargetGroup`, `RegisterTargets`, `DeregisterTargets`, `DeleteLoadBalancer`, `ModifyLoadBalancerAttributes`, `SetSecurityGroups`, `SetSubnets`, `RemoveTags` | `*` | `StringNotEquals aws:ResourceTag/Env = preview` (a missing tag also denies). Create-only actions are not listed, because they have no resource tag yet |

**F.5 Apply role delta:** `EcsListServicesInCluster` (`ecs:ListServices`, `*`, ArnEquals `ecs:cluster`). Nothing else.

**Standards amendments** (orchestrator): add `ecs:ListServices` (with `ecs:cluster`) to the approved `*` list. The trust rule now allows StringLike `ref` and `job_workflow_ref` on the preview legs, wildcard on the PR number only.

### G. App secret (V9)

None. The preview task definition has no `secrets`, and the preview exec role denies Secrets Manager. The dev secret and its ARN never appear in the preview path. Nothing is added to Terraform state.

### H. Cap and cost (V10)

| Item | Value |
|---|---|
| Per preview | 0.25 vCPU, 0.5 GB, 1 task, one public IPv4. At us-east-1 rates about 0.0124 USD per hour Fargate plus 0.005 USD IPv4, so about 0.02 USD per hour. ap-southeast-1 is somewhat higher (not on the page, not checked) |
| Cap | 3, so about 0.06 USD per hour at the cap. The ALB, rules and target groups add nothing measurable |
| Timeouts | build 15 min, deploy 30 min (rollout wait 1200 s), cleanup 10, sweep 15, comment 5. All are under the 60-minute session |
| At the cap | The deploy fails before any create, and the comment lists the open previews. Close one, then "Re-run failed jobs" |
| Backstops | Teardown after each session (V4); the 20 USD budget alert at 80% |

### I. Image (V11, V12, HD2, HD4, HD10)

1. **App Preview `build-scan`** (credential-free):
   - checks out `pull_request.head.sha`;
   - runs `scripts/image/verify.sh` (build, unit tests, smoke, scan) with `GIT_SHA` = head SHA;
   - exports `image.tar` (`scripts/image/export.sh`);
   - uploads `preview-image` (1 day).
2. **App Preview `record`** (credential-free, no checkout, `permissions: {}`) uploads `preview-meta`: `{"pr": <n>, "head_sha": "<40 hex>"}`. It runs for every type, including `closed`. Values reach the step through `env:`.
3. **App Preview Deploy `resolve`** (credential-free):
   - downloads both artifacts from `run-id: github.event.workflow_run.id` into `$RUNNER_TEMP/untrusted`;
   - applies HD3; for a deploy, runs `inspect-image.sh` (HD4);
   - uploads `checked-image` (1 day) and outputs `image-sha256`.
4. **`deploy`** downloads `checked-image` from its own run and verifies the sha256 against the `resolve` output. It pushes with `scripts/image/ecr-push-tar.sh sis-dev-preview pr-<n>-<sha> <tar>` (crane, temp `DOCKER_CONFIG`). If the tag exists, the stored image is reused. The digest and media type come from `ecr describe-images`.
5. Render, register and `up.sh` as before. The task definition references the digest.

### J. Workflows

**`.github/workflows/app-preview.yml`** ("App Preview", credential-free)
- `on.pull_request`: `branches: [main]`, `types: [opened, synchronize, reopened, closed]`. Paths: `app/**`, `.github/workflows/app-preview.yml`, `scripts/image/*.sh`, `scripts/lib.sh`, `scripts/names.sh`, `scripts/ci/install-tools.sh`, `scripts/ci/tools.sha256`, `mise.toml`.
- `permissions: {}`. No `environment`, no `id-token`, no `secrets.` anywhere (self-test).

| Job id | `name:` | `if` | Permissions | harden-runner |
|---|---|---|---|---|
| `build-scan` | `build, scan` | action != closed, same repo, not Dependabot | contents: read | audit |
| `record` | `record` | same repo, not Dependabot | none | audit |

Concurrency `app-preview-build-${{ github.event.pull_request.number }}`, cancel true. A cancelled run makes `resolve` skip (conclusion not success).

**`.github/workflows/app-preview-deploy.yml`** ("App Preview Deploy", the only file in the preview trusts)
- `run-name`: `Sweep previews by <actor>` on dispatch, else `Preview for App Preview run <workflow_run.id>`.
- `permissions: {}`. `env: ENV: dev`.
- `on`: `workflow_run` (`workflows: [App Preview]`, `types: [completed]`, `# zizmor: ignore[dangerous-triggers]` with the reason "credentialed code is main's; triggering-run artifacts are data, validated in a credential-free job"), and `workflow_dispatch`.

| Job id | `name:` | `if` | Env | Permissions | harden-runner |
|---|---|---|---|---|---|
| `resolve` | `resolve` | `github.event_name == 'workflow_run'` | none | contents: read, actions: read, pull-requests: read | audit |
| `deploy` | `deploy (preview)` | `needs.resolve.outputs.mode == 'deploy'` | `preview` | contents: read, id-token: write | block, telemetry off, sudo and containers off |
| `cleanup` | `cleanup (preview)` | `needs.resolve.outputs.mode == 'cleanup'` | `preview-cleanup` | contents: read, id-token: write | block, sudo and containers off |
| `comment` | `sticky comment` | `always() && needs.resolve.outputs.pr != ''` and deploy or cleanup did not skip | none | contents: read, pull-requests: write | audit |
| `list-open` | `list open PRs` | `workflow_dispatch` on `main` | none | pull-requests: read | audit |
| `sweep` | `sweep (preview)` | needs `list-open`, `github.ref == 'refs/heads/main'` | `preview-cleanup` | contents: read, id-token: write | block, sudo and containers off |

- Every checkout uses the default ref (`main`'s `GITHUB_SHA`) with `persist-credentials: false`. Event values reach scripts only through `env:`.
- **`resolve` steps:**
  1. Download `preview-meta`, and `preview-image` when present (`run-id`, `github-token: github.token`).
  2. `scripts/preview/resolve.sh`, which writes outputs `mode`, `pr`, `head_sha`, `keep` (open PR numbers), `reason`.
  3. For a deploy: `inspect-image.sh`, upload `checked-image`, output `image-sha256`.
  4. Remove the untrusted directory.
- **`deploy` steps:**
  1. Install crane (checksum verified).
  2. Download `checked-image` and verify the sha256.
  3. `check-config.sh sis-dev-gha-preview`.
  4. Assume the role (session `gha-preview-<run_id>-<attempt>`, masked account).
  5. N11 to N15.
  6. `sweep.sh --keep "$KEEP"`.
  7. Preflight (listener, cap).
  8. Push with crane, render, register, `up.sh`, `wait-deployment.sh`.
  9. Outputs `url` and `digest`; summary through `assert-no-account-id.sh`; remove temp files.
- **`cleanup` steps:** `down.sh "$PR"`, then summary.
- **`sweep` steps:** `sweep.sh --keep "$KEEP"`, then N16 (`assert-web-identity-denied.sh preview`).
- **`comment` steps:** `sticky-comment.sh` with marker `<!-- app-preview:pr -->`, posting the URL, head SHA, digest, result and run link, or "Preview removed", or the skip reason when the cap is reached or dev is down.
- **Concurrency:** `deploy` and `cleanup` use `app-preview-pr-${{ needs.resolve.outputs.pr }}`, cancel false. `sweep` uses `app-preview-sweep`.
- **Allowlists** (only `vars.AWS_REGION`, `secrets.AWS_ACCOUNT_ID`, `env.ENV`):
  - `deploy`: `github.com`, `release-assets.githubusercontent.com` (crane), `sts.<r>`, `api.ecr.<r>`, `<acct>.dkr.ecr.<r>`, `prod-<r>-starport-layer-bucket.s3.<r>`, `ecs.<r>`, `elasticloadbalancing.<r>`, `ec2.<r>`, `secretsmanager.<r>` (N12), `iam.amazonaws.com` (N15). All on port 443.
  - `cleanup` and `sweep`: `github.com`, `sts`, `ecs`, `elasticloadbalancing`, `api.ecr`.
  - No credentialed job calls `api.github.com`; `resolve` and `list-open` do that without credentials.
- **Policy and self-tests (HD9):**
  - the trigger exception;
  - `untrusted_inputs.py` with fixtures (a checkout `ref: ${{ github.event.workflow_run.head_sha }}`, `run-id` in `deploy`, `bash $RUNNER_TEMP/untrusted/x`, `actions/cache`, an event expression in `run:`; each must fail);
  - `app-preview.yml` credential-free;
  - `workflow_files` lists `app-preview-deploy.yml` and not `app-preview.yml`;
  - `deploy` and `cleanup` share the group;
  - no job holds both `id-token: write` and `pull-requests: write`.

### K. Negative tests

| N | Where | Call | Pass when |
|---|---|---|---|
| N1 (ext) | `oidc-smoke-test` dispatch | `assert-web-identity-denied.sh plan apply deploy preview preview-cleanup` | AccessDenied from all five |
| N8 (ext) | `oidc-smoke-test` PR | PR token against `apply deploy preview preview-cleanup` | AccessDenied |
| N11 | `deploy` (preview role) | `ecs update-service --cluster sis-dev-cluster --service sis-dev-app --task-definition sis-dev-preview:999999` | AccessDenied (fence) |
| N12 | `deploy` | `get-secret-value` and `describe-secret` on `sis/dev/app-api-key` | AccessDeniedException |
| N13 | `deploy` | `ecr describe-images --repository-name sis-dev-app` | AccessDenied |
| N14 | `deploy` | `elbv2 create-rule` on the dev port 80 listener (priority 50000, `/n14-never-routed`, tag `Env=preview`) | AccessDenied; an unexpected success is deleted, then the test fails |
| N15 | `deploy` | `iam tag-role --role-name sis-dev-preview-exec --tags Key=N15,Value=probe` | AccessDenied |
| N16 | `sweep` (env `preview-cleanup` token, same file, same ref) | `assert-web-identity-denied.sh preview` | AccessDenied; only `sub` differs. One alert email |
| N17 | App Preview `if`, `resolve` HD3, live fork or Dependabot PR | refusal by API identity | No deploy run, no approval request; the `resolve` summary says "fork" or "dependabot" |
| N18 | `untrusted_inputs.py` fixtures | static | Each fixture fails |
| N19 | `up.sh` self-test | target group `sis-dev-tg` or SG `sis-dev-task` | Refused before any call |

### L. Secrets and state

| Name | Level | Used by |
|---|---|---|
| `AWS_ACCOUNT_ID`, `AWS_PREVIEW_ROLE_ARN` | env `preview` | `deploy` |
| `AWS_ACCOUNT_ID`, `AWS_PREVIEW_CLEANUP_ROLE_ARN` | env `preview-cleanup` | `cleanup`, `sweep` |

- No repo-level secret with these names (ADR 0008 N2).
- Kept out of Terraform state: every per-PR resource (CLI-managed), any app secret value (none exists), ECR tokens (temp `DOCKER_CONFIG`).
- In state as today: role ARNs and account IDs inside ARNs.

### M. PR split (V21)

- **PR A (built):** unchanged (HD12).
- **PR B, `infra(bootstrap): preview roles and app preview workflows`:**
  - bootstrap E and F;
  - `app-preview.yml` and `app-preview-deploy.yml`;
  - `scripts/preview/` (`resolve.sh`, `inspect-image.sh`, `render-task-def.sh`, `preflight.sh`, `up.sh`, `down.sh`, `sweep.sh`, `assert-isolation.sh`);
  - `scripts/image/ecr-push-tar.sh`;
  - the trigger exception and `untrusted_inputs.py`;
  - the `terraform-destroy` sweep and the family loop;
  - the N1/N8 extension;
  - the plan comment switched to `sticky-comment.sh`.
- PR B **cannot preview itself**: `workflow_run` runs only the default-branch file (Finding 14). The live proof starts after merge.

## Alternatives considered

- **`pull_request` credentialed jobs with an approval and the fence** (the original V13). Rejected by Amendment H: approved PR code holds the role, and ECS cannot restrict target groups or security groups by IAM (H1), so PR code could serve dev's traffic. `workflow_run` was chosen instead. Its known hazards (artifact poisoning, event-ref checkout, cache poisoning) are handled by HD2 to HD4 and the HD9 guard.
- **Path rules on the dev port 80 listener.** Simplest URL, but the role would need `CreateRule` on the dev listener (Env=dev). A hostile approved PR could add a priority 1 `/*` rule and hijack dev. Rejected.
- **A listener per PR port.** No rewrite needed. But `CreateListener` is authorized on the dev ALB, which cannot be tag-scoped, and an SG port range opens more surface. Rejected.
- **Terraform per-PR state.** Declarative, but state write for PR code, slow init and orphaned keys. Rejected.
- **Cleanup behind approval.** One role fewer, but an unapproved close leaves a billed task. Kept as Q2.
- **Reusing the dev exec role or the dev secret.** It would let PR code read the dev secret. Rejected (FR-8).

## Consequences

### Risks

| R | Risk | Mitigation |
|---|---|---|
| R32 | Closed by Amendment H: PR code never holds the preview role | n/a |
| R33 | Closed: the cleanup token is held only by `main`'s code | n/a |
| R34 | The cap is enforced by `main`'s script, not IAM | Review of `main`; budget alert; teardown sweep |
| R35 | The `workflow_run` token claims (`ref`, `job_workflow_ref`) must equal the main pin | Fails closed; checkpoint B5 reads the claims from the N16 log |
| R36 | ALB URL rewrite unavailable or misbehaving | Smoke at B7; fallback `BASE_PATH` in the app |
| R37 | Closed: merged-close refs no longer reach a trust (credentialed runs are always on `main`) | n/a |
| R38 | A PR closed with a merge conflict starts no App Preview run | Deploy-time sweep, dispatch sweep, teardown |
| R39 | Approval and concurrency interplay undocumented | Shared per-PR group; cleanup decided by API state; sweeps |
| R40 | The preview URL is public | Ingress CIDRs cover port 8000; no secret in previews |
| R41 | Preview revisions stay `ACTIVE` until teardown | No cost; teardown deregisters |
| R42 | Closed if crane pushes the tarball (HD10) | Fallback: Docker exception, recorded |
| R43 | Lifecycle may expire a long-lived preview's image | Push again |
| R44 | Closed for previews (comment from `main`); unchanged for the plan comment | n/a |
| R45 | A sweep bug run by the apply role could delete the dev service | Strict name regex; self-test |
| R46 | One approval per push | Intended |
| R47 | **Malicious or buggy merged code on `main`** holds the preview role and could attach to `sis-dev-tg` or any SG (H1 class; IAM cannot express it) | PR review of `app-preview-deploy.yml` and `scripts/preview/**`; `up.sh` refusal (N19); fence; G1 to G6; `Env=preview` tags |
| R48 | Untrusted image content runs in dev behind a public URL | `preview` approval; no secret, no task role; preview SG; cap; teardown |
| R49 | Artifact poisoning, or a parser bug in `inspect-image.sh` | Credential-free `resolve`; size and name bounds; JSON read to stdout only; digest check on download; the HD9 guard |
| R50 | Deploy-workflow changes take effect only after merge; a broken `main` file blocks previews until a fix merges | Self-tests and a dispatch sweep before demos |
| R51 | The approval prompt is on the App Preview Deploy run, not on the PR checks | The comment links the run; the reviewer is notified by GitHub |
| R52 | `workflows: [App Preview]` matches by name; another workflow could take that name | `resolve` requires `workflow_run.path == .github/workflows/app-preview.yml` |
| R53 | `workflow_run` chains are limited to three levels | One level used |

### Other consequences

- **Cost:** see H. Dev gains a free listener, an SG and a repo with tens of MB.
- **Alerts:** N16 and the extended N1/N8 send alert emails by design. N11 to N15 do not (not STS refusals).
- **Docs** (orchestrator, D14):
  - requirements FR-17 status;
  - README (preview flow, URL form, approvals, teardown);
  - `ci-cd.md` (app-preview exception, cleanup environment, comment script);
  - `terraform.md` (approved `*` list, StringLike legs);
  - ADR 0002 name contract (`sis-dev-preview-*`);
  - ADR 0007 exception lists;
  - a diagram of the preview path.

## Amendment H: credentialed preview jobs run main's code (2026-10-30)

### Why

The PR A security review found a High (H1). In the `pull_request` design, approved PR code holds the preview role and can call `ecs create-service` with `loadBalancers[].targetGroupArn = sis-dev-tg`. PR code then serves dev's port 80 traffic. It can also pass any security group.

ECS has no condition key for target groups or security groups. The `CreateService` keys are `aws:RequestTag`, `aws:TagKeys`, `ecs:auto-assign-public-ip`, `ecs:capacity-provider`, `ecs:enable-*`, `ecs:namespace`, `ecs:propagate-tags`, `ecs:subnet`, `ecs:task-cpu`, `ecs:task-definition` and `ecs:task-memory` (Finding 4). Target registration is done by the ECS service-linked role, so the fence's `RegisterTargets` deny never applies.

IAM cannot close H1. Only the code that holds the role can, so that code must be reviewed code. The user chose the alternative this ADR first rejected: **deploy from `main` with `workflow_run`** (Q4).

### Findings from official docs (added)

14. `workflow_run`:
    - "This event will only trigger a workflow run if the workflow file exists on the default branch."
    - `GITHUB_SHA` is the "last commit on default branch" and `GITHUB_REF` is the "default branch".
    - The run "is able to access secrets and write tokens, even if the previous workflow was not".
    - "Running untrusted code on the `workflow_run` trigger may lead to security vulnerabilities."
    - "You can't use `workflow_run` to chain together more than three levels of workflows."
    - Types are `completed`, `requested` and `in_progress`.
15. The REST "Get a workflow run" schema has `head_sha`, `head_branch`, `event`, `conclusion`, `pull_requests` (array or null), `head_repository`, `path` and `run_attempt`. The docs do not say when `pull_requests` is empty (for example for forks). **This design does not rely on it.**
16. `actions/download-artifact`:
    - `run-id` is "the id of the workflow run where the desired download artifact was uploaded from".
    - `github-token` "is required when downloading artifacts from a different repository or from a different workflow run", and needs "actions:read".
    - A single artifact "will always be extracted directly to the specified path".
    - `digest-mismatch` defaults to `error`.
17. Context availability: `jobs.<job_id>.concurrency` and `jobs.<job_id>.environment` accept `github, needs, strategy, matrix, inputs, vars`. A per-PR group can therefore use an output of an earlier job.
18. `crane push PATH IMAGE`: "If the PATH is a directory, it will be read as an OCI image layout. Otherwise, PATH is assumed to be a docker-style tarball." No Docker daemon is needed.
19. zizmor `dangerous-triggers` flags `workflow_run`. Its remediation suggests `workflow_call`, which cannot run a privileged follow-up of an untrusted PR. It warns that "a `workflow_run` always runs in the context of the target repository".
20. Environment branch rules are "matched against the `GITHUB_REF` of the workflow run". A `workflow_run` job therefore matches the rule `main`.

### Decisions

| # | Decision | Alternatives | Pro | Con |
|---|---|---|---|---|
| HD1 | **Two workflows.** `app-preview.yml` ("App Preview", `pull_request`) is **credential-free**: build, test, smoke, scan, then upload `preview-image` and `preview-meta`. `app-preview-deploy.yml` ("App Preview Deploy", `workflow_run` on `["App Preview"]` `[completed]`, plus `workflow_dispatch` sweep) holds every credential and runs only `main`'s code | Keep `pull_request` with the fence (H1 stays open) | No PR-controlled step ever holds AWS credentials or a write token. H1 becomes reachable only by merged code | A trigger-policy exception and an inline zizmor ignore. Workflow changes take effect only after merge |
| HD2 | **Everything from the triggering run is data.** Only the credential-free `resolve` job downloads it (into `$RUNNER_TEMP/untrusted`). It never checks out an event ref and never executes a file from the artifact. It validates, then re-uploads `checked-image` to its own run with a sha256 output. Credentialed jobs download only same-run artifacts | Download in the credentialed job | Untrusted parsing has no credentials. Credentialed egress allowlists stay as proven (same-run download, as app-deploy) | One extra artifact hop (about 30 s) |
| HD3 | **Deploy or cleanup is decided by the GitHub API, not the event.** Resolve reads `pr` from `preview-meta` (untrusted, `^[1-9][0-9]{0,4}$`) and calls `GET /repos/{repo}/pulls/{pr}`. It refuses unless `head.repo.id == github.repository_id`, `user.login != 'dependabot[bot]'`, `workflow_run.event == 'pull_request'`, `workflow_run.path == '.github/workflows/app-preview.yml'` and `workflow_run.head_repository.full_name == github.repository`. Then: `state == open` with `head.sha == workflow_run.head_sha` and `conclusion == success` means **deploy**; `state == closed` means **cleanup** (any conclusion); anything else means **skip**, with the reason in the summary | Trust `pull_requests[]` or the meta `action` | A forged number can at most clean up a PR that is really closed (harmless), or deploy the image that matches that PR's current head. A superseded run skips | One API call |
| HD4 | **Image bounds** (`scripts/preview/inspect-image.sh`, run in `resolve`, never executes content). The artifact is one file `image.tar` of at most 512 MB. `tar -tf` member names must not be absolute and must not contain `..`. `manifest.json` (read with `tar -xOf`, nothing written) lists exactly one image whose config has `Labels["org.opencontainers.image.revision"] == head_sha` (the Dockerfile sets it from `GIT_SHA`). At most 32 layers | Trust the artifact | Bounded parser input, bound to the reviewed head SHA | The label is attacker-chosen, so it binds identity, not intent (the image is untrusted code by definition) |
| HD5 | **Trusts pinned to `main`:** both preview roles use `job_workflow_ref = O/R/.github/workflows/app-preview-deploy.yml@refs/heads/main` and `ref = refs/heads/main`, both StringEquals. No StringLike and no legs | Keep the PR legs | The same shape as apply and deploy (ADR 0007 S2). No trust standard amendment | A rename of the file needs a bootstrap re-apply |
| HD6 | **Keep the separate cleanup role and `preview-cleanup` environment** (recommended) | One role trusting two subs; or cleanup inside `preview` | `preview` keeps a reviewer while cleanup must not wait for one. Least privilege per job. N16 becomes a refusal where only `sub` differs | One extra role and environment (already designed) |
| HD7 | **Keep the `preview` approval.** It now gates cost and running untrusted image code in dev behind a public URL, not credentialed code | Drop it | A human decides what PR code runs in the account | One click per push. The prompt appears on the App Preview Deploy run, not on the PR checks (R51) |
| HD8 | **The sticky comment is posted by `main`'s code**: job `comment` in `app-preview-deploy.yml` (contents: read, pull-requests: write; no id-token; no artifact), calling `scripts/gh/sticky-comment.sh` from the default checkout | Comment from App Preview | No PR code with a write token (closes R44 for previews) | None |
| HD9 | **Policy.** Trigger allowlist: `workflow_run` only in `app-preview-deploy.yml`, with exactly `workflows: [App Preview]` and `types: [completed]`. New guard `scripts/guard/untrusted_inputs.py`: in that file, no `actions/checkout` with `ref` or `repository`; `run-id` on `actions/download-artifact` only in `resolve`, with a path under `runner.temp`; no `${{ github.event.* }}` in `run:`; no `actions/cache` or `cache:` input; any path under the untrusted directory appears only as an argument to `inspect-image.sh` or `upload-artifact`. `app-preview.yml` may hold no `id-token`, `environment`, `secrets.` or write permission. One inline `# zizmor: ignore[dangerous-triggers]` on the `workflow_run:` key, with the reason in a comment | No guard | The rules that make `workflow_run` safe are enforced in repo-guard | One more helper with fixtures; a third allowed inline ignore in `ci-cd.md` |
| HD10 | **Push with crane** (pinned by ADR 0008 PR B1) from the checked tarball. Every credentialed job keeps `disable-sudo-and-containers: true`. No `NEEDS_CONTAINERS` entry for previews | Docker load and push | Closes R42 | Depends on the B1 pin being on `main`. If crane rejects the `docker save` format, fall back to the `NEEDS_CONTAINERS` exception (recorded at the checkpoint) |
| HD11 | **Defense in depth stays:** the fence, tag and name scoping, the preview exec role, and no secret. `up.sh` refuses any target group other than `sis-dev-preview-<n>` and any security group other than `sis-dev-preview-task` (self-tested) | Drop the fence | Limits a buggy or hostile **merged** change | IAM still cannot express H1 (R47) |
| HD12 | **PR A needs no change.** The listener, SGs, repo, log group and `sticky-comment.sh` are reused as built, provided `sticky-comment.sh` takes the PR number and body from env or arguments and does not read `GITHUB_EVENT_PATH`. If it does read the event, add a `PR_NUMBER` env override in PR B | n/a | n/a | n/a |

### Risks closed and remaining

- **Closed:**
  - R32 (PR code holds the preview role);
  - R33 (PR code holds the cleanup token);
  - R42 (Docker in a credentialed job, if HD10 holds);
  - R44 for previews (write token with PR-steered steps);
  - H1 as exploitable **by PR code**;
  - R35 changes from "undocumented PR claim" to the documented main pin, verified at checkpoint step B5.
- **Remaining:** R47 to R53 below, plus R34, R36 to R41, R43, R45 and R46.

## Checkpoint commands (the user runs these; NFR-9)

Run from the repo root. Each block is one command per line for zsh, with no packed arguments (lesson 37). Dispatches and approvals use the web UI (the PAT has Actions read-only, lesson 31).

### PR A

**A1. Checks.** With the PR A branch checked out:
```bash
gh pr checks --watch
```
Expect green `guard`, `checks` and `plan (dev) / terraform plan`. The sticky plan comment lists the new `module.app_ecs` preview addresses (about 9) and no change to existing ones.

**A2. Merge, then bring dev up.** Approve the push apply. Then:
```bash
AWS_PROFILE=sis-dev-admin aws secretsmanager put-secret-value --region ap-southeast-1 --secret-id sis/dev/app-api-key --secret-string "$(openssl rand -hex 24)" --query Name --output text
```
Approve App Deploy if it starts. Then:
```bash
ALB_DNS="$(AWS_PROFILE=sis-dev-admin aws elbv2 describe-load-balancers --region ap-southeast-1 --names sis-dev-alb --query 'LoadBalancers[0].DNSName' --output text)"
curl -s -o /dev/null -w '%{http_code}\n' "http://${ALB_DNS}:8000/pr-1/"
curl -s "http://${ALB_DNS}/version"
```
Expect `404` from the preview listener, and the dev `/version` unchanged. Keep dev up for PR B, or destroy it (Run workflow Terraform Destroy, env `dev`, type **destroy-dev**).

### PR B

PR B cannot preview itself (Finding 14). Prove the code offline, apply the bootstrap, merge, then prove it live.

**B1. Checks.** With the PR B branch checked out:
```bash
gh pr checks --watch
```
Expect green `guard`, `checks`, the plan and OIDC Smoke Test (N8 lists preview and preview-cleanup as denied). App Preview runs `build, scan` and `record`. No App Preview Deploy run appears yet (the file is not on `main`).

**B2. Enable previews in the gitignored dev inputs.**
```bash
printf 'preview_enabled = true\n' >> infra/terraform/bootstrap/accounts/dev.tfvars
```

**B3. Dev bootstrap re-apply from the PR B branch.**
```bash
AWS_PROFILE=sis-dev-admin terraform -chdir=infra/terraform/bootstrap init -backend-config="bucket=sis-dev-tfstate-$(AWS_PROFILE=sis-dev-admin aws sts get-caller-identity --query Account --output text)-ap-southeast-1-an"
AWS_PROFILE=sis-dev-admin terraform -chdir=infra/terraform/bootstrap plan -var-file=accounts/dev.tfvars -out=bootstrap.tfplan
AWS_PROFILE=sis-dev-admin terraform -chdir=infra/terraform/bootstrap apply bootstrap.tfplan
rm infra/terraform/bootstrap/bootstrap.tfplan
```
Expect about 11 to add (3 roles, 3 inline policies, the fence, 4 attachments), 3 to change (`aws_iam_role_policy.apply`, `aws_iam_policy.guardrails`, `aws_cloudwatch_event_rule.oidc_unexpected`) and 0 to destroy. The plan, apply and deploy trusts are unchanged.

**B4. GitHub environments (web UI, Settings > Environments).**
- `preview`: Required reviewers = you; Prevent self-review **off**; Deployment branches and tags = Selected, branch rule **main**.
- `preview-cleanup`: no reviewers; Selected, branch rule **main**.

Then the secrets. If a line is refused (PAT without Environments write), add the same secret in the web UI.
```bash
AWS_PROFILE=sis-dev-admin terraform -chdir=infra/terraform/bootstrap output -raw preview_role_arn | gh secret set AWS_PREVIEW_ROLE_ARN --env preview --repo trungleviet-agilityio/ship-it-safely
AWS_PROFILE=sis-dev-admin terraform -chdir=infra/terraform/bootstrap output -raw preview_cleanup_role_arn | gh secret set AWS_PREVIEW_CLEANUP_ROLE_ARN --env preview-cleanup --repo trungleviet-agilityio/ship-it-safely
AWS_PROFILE=sis-dev-admin aws sts get-caller-identity --query Account --output text | gh secret set AWS_ACCOUNT_ID --env preview --repo trungleviet-agilityio/ship-it-safely
AWS_PROFILE=sis-dev-admin aws sts get-caller-identity --query Account --output text | gh secret set AWS_ACCOUNT_ID --env preview-cleanup --repo trungleviet-agilityio/ship-it-safely
gh secret list --env preview --repo trungleviet-agilityio/ship-it-safely
gh secret list --env preview-cleanup --repo trungleviet-agilityio/ship-it-safely
gh secret list --repo trungleviet-agilityio/ship-it-safely
```
The repo-level list must not contain `AWS_PREVIEW_ROLE_ARN`, `AWS_PREVIEW_CLEANUP_ROLE_ARN` or `AWS_ACCOUNT_ID`.

**B5. Merge PR B (squash). Then prove the trust.**
- The merge close starts App Preview `record`, then App Preview Deploy: `resolve` says "closed", and `cleanup (preview)` runs without approval and finds nothing (green). App Deploy also starts (`scripts/lib.sh` changed): approve it.
- Then Run workflow **App Preview Deploy** on `main`. Expect in the `sweep (preview)` log:
  - `Token sub` ending in `:environment:preview-cleanup`;
  - `Token job_workflow_ref: trungleviet-agilityio/ship-it-safely/.github/workflows/app-preview-deploy.yml@refs/heads/main`;
  - "the preview role denied as designed" (N16);
  - one alert email.

  If the assume step fails instead, stop and report the claims (R35).

**B6. Dev up.** If dev is down: Run workflow Terraform (env `dev`), approve, then:
```bash
AWS_PROFILE=sis-dev-admin aws secretsmanager put-secret-value --region ap-southeast-1 --secret-id sis/dev/app-api-key --secret-string "$(openssl rand -hex 24)" --query Name --output text
```
Then Run workflow App Deploy and approve.

**B7. Two demo PRs.**
```bash
git switch -c demo/preview-a origin/main
printf '# preview demo a\n' >> app/src/board.py
git commit -am "chore(app): preview demo a"
git push -u origin demo/preview-a
gh pr create --repo trungleviet-agilityio/ship-it-safely --fill
git switch -c demo/preview-b origin/main
printf '# preview demo b\n' >> app/src/board.py
git commit -am "chore(app): preview demo b"
git push -u origin demo/preview-b
gh pr create --repo trungleviet-agilityio/ship-it-safely --fill
```
For each PR, App Preview goes green and then an App Preview Deploy run waits for the `preview` approval (Actions tab). Approve both. Expect:
- the deploy logs show "denied as designed" for N11 to N15 and a crane push;
- two bot comments with different `/pr-` URLs.

Then, on each demo branch:
```bash
ALB_DNS="$(AWS_PROFILE=sis-dev-admin aws elbv2 describe-load-balancers --region ap-southeast-1 --names sis-dev-alb --query 'LoadBalancers[0].DNSName' --output text)"
git switch demo/preview-a
curl -s "http://${ALB_DNS}:8000/pr-$(gh pr view --json number --jq .number)/version"
gh pr view --json headRefOid --jq .headRefOid
curl -s "http://${ALB_DNS}/version"
```
`git_sha` must equal the head SHA, and `env` must be `preview`. The dev `/version` is unchanged. Repeat with `git switch demo/preview-b`.

**B8. Close both without merging.**
```bash
gh pr close demo/preview-a --repo trungleviet-agilityio/ship-it-safely --delete-branch
gh pr close demo/preview-b --repo trungleviet-agilityio/ship-it-safely --delete-branch
AWS_PROFILE=sis-dev-admin aws ecs list-services --region ap-southeast-1 --cluster sis-dev-cluster --query 'serviceArns[]' --output text | tr '\t' '\n' | sed 's|.*/||'
AWS_PROFILE=sis-dev-admin aws elbv2 describe-target-groups --region ap-southeast-1 --query 'TargetGroups[].TargetGroupName' --output text
AWS_PROFILE=sis-dev-admin aws ecr list-images --region ap-southeast-1 --repository-name sis-dev-preview --query 'imageIds[].imageTag' --output text
```
Run the last three after both cleanup runs are green. Expect:
- only `sis-dev-app` and `sis-dev-tg`;
- no `pr-` tags of the closed PRs;
- comments say "Preview removed";
- the URLs return 404.

**B9. Fork and Dependabot (N17).** With a second GitHub account, fork and open a PR touching `app/`. Otherwise use the next Dependabot Docker PR. Expect App Preview jobs skipped. If an App Preview Deploy run appears, `resolve` ends with mode `skip` and reason "fork" or "dependabot", and there is no approval request.

**B10. N1 and N8.** Run workflow OIDC Smoke Test. Expect refusals from plan, apply, deploy, preview and preview-cleanup.

**B11. Teardown with a preview open.** Open a third demo PR as in B7 and approve its preview. Then Run workflow Terraform Destroy: env `dev`, type **destroy-dev**, approve. Expect:
- "Remove previews" reports one removed;
- the destroy deletes all dev resources (about 36);
- revisions are deregistered for both families.

Then close the demo PR; its cleanup finds nothing and ends green.

## Open questions (recommendation first)

| Q | Recommendation | Alternatives |
|---|---|---|
| Q1 | Dedicated preview listener on port 8000 with path rules and URL rewrite (V1) | Port 8080 or 81; a port per PR; path rules on port 80 |
| Q2 | No-approval cleanup with the delete-only role (V6) | Cleanup behind the `preview` approval (one role fewer) |
| Q3 | Cap 3 | 2 (cheaper) or 5 |
| Q4 | **Answered (Amendment H): `workflow_run` deploy from `main`**; credential-free App Preview build | n/a |
| Q5 | Leave preview revisions `ACTIVE` until teardown (V19) | `ecs:DeregisterTaskDefinition` on `*` for the approved role only |
| Q6 | Separate repo `sis-dev-preview` (V11) | Dev repo with a `pr-` tag prefix and a second lifecycle rule |
| Q7 | Fork proof through a Dependabot Docker PR if there is no second account | A second GitHub account |
| Q8 | No `actor_id` pin on the preview trusts (the approval is the gate) | Pin `actor_id` to your user (blocks collaborators' PRs; a close by someone else would not clean up) |
| Q9 | Build the head SHA (V12) | Build the merge commit like App CI |
| Q10 | Fail the deploy (red) with a clear comment when dev is down (ADR 0005 F16: green means deployed) | End green with a notice |
| Q11 | Previews for draft PRs too (the approval still gates them) | Skip drafts (`draft == false`; then add the `ready_for_review` type) |

## Build briefs

### devops-engineer, PR A (owns `infra/**`, `.github/**`, `scripts/**`, `Makefile`, repo tooling)

Branch from `main` (lesson 25). Read this ADR at its absolute path under `docs/adr/`.

**Files**
- `infra/terraform/modules/app-ecs/preview.tf` (new):
  - `aws_lb_listener.preview` (fixed-response 404, tags with `Env = "preview"`);
  - `aws_vpc_security_group_ingress_rule.alb_preview` (indexed over CIDRs, port `preview_listener_port`);
  - `aws_security_group.preview_task` and its rules (ingress container port from the ALB SG, egress 443), plus `aws_vpc_security_group_egress_rule.alb_to_preview_task`;
  - `aws_ecr_repository.preview` (IMMUTABLE, scan on push, AES256, `force_delete`, `Env = "preview"`) and its lifecycle (keep `preview_ecr_keep_images`, default 20);
  - `aws_cloudwatch_log_group.preview` (1 day, `Env = "preview"`).
  - Everything uses `count = var.preview_enabled ? 1 : 0`.
- Module `variables.tf`: `preview_enabled` (default false), `preview_listener_port` (default 8000, 1024 to 65535, not 80, not the container port), `preview_ecr_keep_images`.
- Module `locals.tf`: names from the contract.
- Module `outputs.tf`: `preview_listener_port`, `preview_repository_name` (no ARN).
- README.
- `envs/dev`: the variable and `preview_enabled = true` in `terraform.tfvars`; README.
- `scripts/gh/sticky-comment.sh` (marker, bot-only update, `assert-no-account-id.sh` on the body, env-only inputs) and its case in `scripts/selftest/`.

**Tests first**
- `app_ecs.tftest.hcl`:
  - disabled means zero preview resources;
  - enabled means listener port, `Env=preview` tag, default 404, no forward;
  - one ingress per CIDR on the preview port, no CIDR in descriptions;
  - preview SG rules exact;
  - ECR immutable, scan and force delete;
  - log retention 1;
  - names equal the contract.
- Sticky comment: create, update, refuse to update a non-bot comment, refuse a 12-digit run.

**Done**
- `make check` green; actionlint and zizmor clean.
- `terraform test` passes offline.
- The plan shows additions only under `module.app_ecs` (preview addresses).
- No 12-digit literal anywhere.

### devops-engineer, PR B

Branch from `main` after PR A. Confirm that crane (ADR 0008 PR B1) is pinned on `main` in `scripts/ci/tools.sha256` and `mise.toml`. If it is not, stop and report.

**Files**
- Bootstrap: `variables.tf`, `locals.tf` (`workflow_files.preview = ["app-preview-deploy.yml"]`, the two trust entries in the existing shape), `iam_preview.tf`, `iam_apply.tf`, `iam_guardrails.tf`, `outputs.tf`, `accounts/dev.tfvars.example`, README. Tests in `trust.tftest.hcl`, `iam.tftest.hcl` and `monitoring.tftest.hcl`.
- `scripts/lib.sh`:
  - `preview_names`, `PREVIEW_MAX=3`;
  - `web_identity_call` accepts `preview` and `preview-cleanup`;
  - `PREVIEW_IMAGE_MAX_BYTES=536870912`, `PREVIEW_IMAGE_MAX_LAYERS=32`.
- `scripts/preview/`: `resolve.sh` (offline-testable with a stubbed `gh`), `inspect-image.sh`, `render-task-def.sh`, `preflight.sh`, `up.sh` (refuses a foreign target group or SG), `down.sh`, `sweep.sh`, `assert-isolation.sh`.
- `scripts/image/ecr-push-tar.sh` (crane, temp `DOCKER_CONFIG`, digest from ECR).
- `scripts/ecs/deregister-revisions.sh` (both families).
- `scripts/guard/workflow_triggers.py` (`workflow_run` exception: exact file, `workflows`, `types`).
- `scripts/guard/untrusted_inputs.py` and its `.sh` entry in repo-guard and `make lint`.
- Self-tests: `scripts/selftest/preview.sh`, plus `workflows.sh`.
- Workflows: `app-preview.yml`, `app-preview-deploy.yml`, `terraform-destroy.yml` (Remove previews), `oidc-smoke-test.yml` (N1, N8), `reusable-terraform-plan.yml` (comment via `sticky-comment.sh`).
- If `sticky-comment.sh` reads `GITHUB_EVENT_PATH`, add a `PR_NUMBER` env override (HD12).

**Tests first**
- Bootstrap:
  - plan, apply and deploy trust JSON unchanged;
  - preview and cleanup trusts are single statements with StringEquals `sub`, `ref = refs/heads/main` and `job_workflow_ref = .../app-preview-deploy.yml@refs/heads/main`;
  - no StringLike outside the plan role;
  - PassRole only on the exec role with `PassedToService`;
  - Allow `*` only on the approved list;
  - `AddTags` and `TagResource` only with `CreateAction`;
  - fence as in F.4;
  - exec role with boundary and secret deny;
  - `expected_subs` has both new subs;
  - `ListServices` scoped by `ecs:cluster`;
  - no preview resources when disabled.
- `resolve.sh`:
  - open with a matching SHA and success means deploy;
  - open with an older SHA means skip;
  - open with a failed or cancelled conclusion means skip;
  - closed means cleanup;
  - fork (head repo ID differs), Dependabot author, wrong `workflow_run.path`, wrong event, a non-numeric or out-of-range PR, or missing meta means skip with a reason.
- `inspect-image.sh` fixtures: an oversize file, an absolute path, `..`, two images, a label mismatch, too many layers, not a tar. Each is refused without writing files.
- `up.sh`, `down.sh`, `sweep.sh` and preflight as before, plus N19.
- `untrusted_inputs.py` fixtures (N18). Trigger exception fixtures: `workflow_run` in another file, another `workflows` name, or `types: [requested]` each fail.
- crane push stub test.

**Done**
- `make check` green; zizmor clean with exactly one `dangerous-triggers` inline ignore; actionlint clean.
- `terraform test` passes.
- No 12-digit literal. No runnable `<...>`.
- The hand-back lists the bootstrap plan counts and every allowlist host with its line.

### backend-dev

No change: the ALB URL rewrite removes the need for a base path, and the preview shows `APP_ENV=preview` and `secret_loaded: no` with the current code. Only if R36 triggers: add an optional `BASE_PATH` prefix strip in `app/src/board.py` with tests.

## Sources

- https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-limits.html
- https://docs.aws.amazon.com/elasticloadbalancing/latest/application/rule-transforms.html
- https://docs.aws.amazon.com/cli/latest/reference/elbv2/create-rule.html
- https://servicereference.us-east-1.amazonaws.com/v1/elasticloadbalancing/elasticloadbalancing.json
- https://docs.aws.amazon.com/elasticloadbalancing/latest/userguide/tagging-resources-during-creation.html (read through the search result summary)
- https://servicereference.us-east-1.amazonaws.com/v1/ecs/ecs.json
- https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_DeleteService.html
- https://docs.aws.amazon.com/AmazonECS/latest/APIReference/API_DeleteCluster.html
- https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_execution_IAM_role.html
- https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_iam-condition-keys.html
- https://aws.amazon.com/vpc/pricing/
- https://aws.amazon.com/fargate/pricing/
- https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/v6.70.0/website/docs/r/lb_listener.html.markdown
- https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows
- https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments
- https://docs.github.com/en/actions/reference/security/oidc
- https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency
- https://docs.zizmor.sh/audits/
- https://docs.github.com/en/rest/actions/workflow-runs#get-a-workflow-run
- https://raw.githubusercontent.com/actions/download-artifact/main/README.md
- https://docs.github.com/en/actions/reference/workflows-and-actions/contexts
- https://github.com/google/go-containerregistry/blob/main/cmd/crane/doc/crane_push.md
- https://docs.github.com/en/webhooks/webhook-events-and-payloads (workflow_run action values only)
