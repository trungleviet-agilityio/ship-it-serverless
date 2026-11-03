# ADR 0007: Phase 6 supply-chain hardening

- Status: accepted
- Date: 2026-10-27 (accepted the same day under the user's delegation; see the decision log)

> **As built (2026-10-27):** the bootstrap local and output are `workflow_files` (no `workflow_names` is left).
> G6 is four Deny statements (`G6DenyAuditTrail`, `G6DenyAlertRule`, `G6DenyAlertTopic`, `G6DenyTrailBucket`),
> because one statement with mixed resources would apply every action to every resource. `build-image.sh` takes
> `PYTHON_IMAGE_MIRRORS` as a list whose word `dockerfile` means the `FROM` line as written (default
> `dockerfile docker.io/library/python`). The orchestrator verified A11 locally: the build-context fallback works
> with the default docker driver. Where the text below differs, the code and the verify table win.

## Context

PLAN.md Phase 6 covers NFR-3 to NFR-7 and the items carried forward in PROGRESS.md. Several items were built early, and this ADR checks them against the repo. It then decides what is left: the carried items, the gaps from the conventions doc (G2 to G5), and the NFR-7 stretch.

Phase 5 closed on 2026-10-26: its bootstrap re-apply (`DescribeSecret`) and the N5 to N7 tests passed, and `envs/dev` is destroyed. So the Phase 6 bootstrap re-apply carries only Phase 6 changes.

### Requirements

| ID | What Phase 6 must deliver | State found in the repo (branch `phase-6-supply-chain`, clean, at `25a0e4d`) |
|---|---|---|
| NFR-3 | Every action pinned to a SHA with the version in a comment. Tools pinned by version and checksum-verified | **Done.** All 31 `uses:` lines are 40-hex SHAs with a `# vX.Y.Z` comment. These pins are the latest releases as of today: harden-runner v2.22.2 (2026-10-19), checkout v7.0.1, configure-aws-credentials v6.3.0, upload-artifact v7.0.2, download-artifact v8.0.2. `install-ci-tools.sh` checks terraform 1.17.0, tflint 0.65.0, trivy 0.76.1 and hadolint 2.15.1 against `ci-tools.sha256`. Pre-commit revs are frozen SHAs. `ci-requirements.txt` is hash-locked |
| NFR-4 | harden-runner is the first step of every job. Start in `audit`; consider `block` with an allowlist after reviewing an egress log | Audit in every job. Block is not done |
| NFR-5 | Lock files with `linux_amd64` and dev-machine hashes. Dependabot for actions, Docker and Terraform | Lock files exist in `bootstrap`, `envs/dev` and `modules/app-ecs`. There is **no `.github/dependabot.yml`** |
| NFR-6 | gitleaks pre-commit plus GitHub push protection | gitleaks v8.30.1 runs in pre-commit and in `repo-guard`. The push-protection setting is checked at the checkpoint (step A9) |
| NFR-7 | `max_session_duration = 3600` (done, tested in `trust.tftest.hcl`). Stretch: CloudTrail plus an alert on `AssumeRoleWithWebIdentity` with an unexpected `sub` | No trail is managed in code |

### Findings from official docs and the repo

1. **IAM supports `token.actions.githubusercontent.com:job_workflow_ref`** with string operators. AWS describes it as "the reference path to the reusable workflow for jobs using a reusable workflow ... to make sure only approved workflows can assume roles". The documented GitHub keys are `actor`, `actor_id`, `job_workflow_ref`, `repository`, `repository_id`, `repository_owner_id`, `workflow`, `ref`, `environment` and `enterprise_id`. **`workflow_ref` is not on the list.**
2. **GitHub documents `job_workflow_ref` only "for jobs using a reusable workflow".** The docs do not say whether the claim is present, or what it holds, for a job in a plain workflow. The example payload shows `octo-org/octo-automation/.github/workflows/oidc.yml@refs/heads/main`. So this ADR does not assume the claim's value: checkpoint step A0 reads it from a real token before the trust changes. A `StringEquals` on a missing key fails closed (AccessDenied); it can never open access.
3. **harden-runner v2.22.2** inputs:
   - `egress-policy` defaults to `block`;
   - `allowed-endpoints` is an "only these endpoints" list;
   - `disable-telemetry` "can only be set to true when egress-policy is block";
   - `disable-sudo-and-containers` is available.

   The StepSecurity docs show `allowed-endpoints` as a folded block of `host:port` lines and accept wildcards such as `*.data.mcr.microsoft.com:443`. Block mode filters at DNS and at layers 3 and 4. The community tier is free for public repos on GitHub-hosted runners. No page I opened says whether insights pages of public repos are public (ADR 0005 Q1 stays a live check).
4. **Dependabot.**
   - `package-ecosystem` values: `github-actions`, `docker`, `docker-compose`, `terraform`, `pip`, `pre-commit`, `uv`.
   - `directories` accepts globs. For actions use `/`, and Dependabot scans `/.github/workflows`.
   - `groups` support `patterns`, `exclude-patterns`, `update-types` and `applies-to`.
   - `cooldown`: `default-days` works for every ecosystem; the semver-specific days do not apply to Docker, GitHub Actions, pre-commit or Terraform. The default cooldown is 3 days and never applies to security updates.
   - `commit-message.prefix` plus `include: scope` gives `prefix(deps): ...`.
   - `schedule.interval` includes `monthly`. The default open-PR limit is 5.
   - Terraform support is listed as ">= 0.13, <= 1.15.x" (the repo pins 1.17.0).
   - The official pages I opened do not say whether a SHA-pinned action keeps its `# vX` comment after an update (verified on the first PR, step A10).
5. **The Dependabot Docker parser does not resolve `ARG`** (dependabot-core `docker/file_parser.rb`: the `FROM_LINE` regex reads literal text and does no `${VAR}` substitution). `app/Dockerfile` uses `FROM ${PYTHON_IMAGE}:3.13-slim@sha256:...`, so **Dependabot would never update the base image as the file stands.** `docker buildx build --build-context name=docker-image://...` "overrides a stage called name when used as FROM ... AS name". That keeps the registry fallback (ADR PR #16) without an `ARG` in `FROM`.
6. **CloudTrail and alerting costs.**
   - Event history is free. "You can deliver one copy of your ongoing management events to your Amazon S3 bucket for free". Additional copies cost 2.00 USD per 100,000 events.
   - Sending events to CloudWatch Logs adds ingestion (0.50 USD/GB in the page examples). A custom metric costs 0.30 USD/month and an alarm 0.10 USD/month. The free tier includes 10 metrics, 10 alarms and 5 GB of logs.
   - EventBridge: "AWS management events are ingested by the event bus for free". CloudTrail-sourced detail types need "a CloudTrail trail with logging".
   - `AssumeRoleWithWebIdentity` is logged with `readOnly: true`, so a rule must use state `ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS`. Provider v6.70.0 `aws_cloudwatch_event_rule.state` accepts that value.
   - The web identity event has `userIdentity.type = WebIdentityUser` and `userName = <sub>`.
   - CloudTrail logs non-authenticated `AssumeRoleWithWebIdentity` calls, including refusals. Global-endpoint STS calls are logged in us-east-1; regional calls are logged in their own region.
   - EventBridge patterns support `anything-but` lists, `exists` and `$or`.
7. **STS `DurationSeconds`**: "If you specify a value higher than this setting, the operation fails." The minimum is 900 and the default is 3600.
8. **Code owners.** "Pull request authors cannot approve their own pull requests", and with "require review from code owners" any PR touching owned paths "must be approved by that code owner". On a single-maintainer repo, turning that rule on blocks every merge unless the owner bypasses it.
9. **Docker Compose** default file: "`compose.yaml` (preferred) or `compose.yml`". **Google shell guide:** "Libraries must have a `.sh` extension and should not be executable."
10. **Repo facts that shape the design.**
    - `scripts/lib.sh` and `scripts/selftest/common.sh` are only ever sourced. `ci-selftest.sh` runs the six named areas and never `common.sh`.
    - `ci-requirements.txt` already hash-locks `pyyaml==6.0.3`, a pre-commit dependency.
    - `oidc-smoke-test.yml` N1 already decodes the token payload and prints only `sub`.
    - `security_groups.tf` keys ALB rules by CIDR (`for_each = toset(...)`) and writes the CIDR into `description`.
    - `tf-policy.sh` rule 9 matches only quoted labels in `*.tf`.
    - The destroy summary heading is always `### Destroyed`.
    - The `confirm` job comment says the phrase "is never echoed", but GitHub prints the step `env:` block in the log.

## Decision

Phase 6 ships in **two PRs**. PR A holds everything except block mode. PR B switches the credentialed jobs to `block`, using the egress list the user collects at checkpoint A. Block mode cannot be designed before that log exists (PLAN Phase 6.2).

### A. Decision table (carried items, conventions gaps, NFRs)

| # | Item | Decision | Pro | Con |
|---|---|---|---|---|
| S1 | NFR-3 pins and checksums | **Verified done; add a guard.** New `ci-selftest` check: every `uses:` matches `@[0-9a-f]{40} # v[0-9]`, and each action has one SHA across all workflows | A drifted or tag-only pin fails offline, not only in zizmor | A few lines of selftest |
| S2 | Item 1: `job_workflow_ref` instead of `workflow` (ADR 0005 L2, R2) | **Build in PR A, gated by step A0.** Apply and deploy trust replace the `workflow` condition with `StringEquals job_workflow_ref`. Values: `<owner>/<repo>/.github/workflows/<file>@refs/heads/main`. Files: `terraform-iac.yml` and `terraform-destroy.yml` (apply), `app-deploy.yml` (deploy). The plan role stays unpinned. **No reusable workflow** | Pins the file path, not a `name:` any merged file can copy, which closes R2. Fails closed if the claim is absent or different | Bootstrap re-apply. A rename of a workflow file needs a re-apply. If A0 shows no claim, keep the `name` pin and record that (fallback, no apply) |
| S3 | Item 2: harden-runner insights exposure (ADR 0005 Q1) | **Check at checkpoint A (step A6)**, then PR B sets `disable-telemetry: true` on every credentialed job | Stops new account-bearing hostnames from leaving the runner | Insights from past runs stay wherever they are. Account IDs are not secrets (D2), so this is accepted |
| S4 | NFR-4 block mode | **PR B**: `egress-policy: block`, `disable-telemetry: true` and an explicit `allowed-endpoints` on every job with `id-token: write`. These are the `terraform-iac` plan, plan-role-guardrails and apply jobs, the `terraform-destroy` destroy job, the `app-deploy` deploy job and both `oidc-smoke-test` jobs. Jobs without credentials stay `audit` | Exfiltration from the jobs that hold AWS credentials needs an allowed host. The allowlist is reviewed in git | An allowlist to maintain. A missed host fails the job, possibly mid-apply (R16). Telemetry off means no insights for those jobs |
| S5 | NFR-5 Dependabot | **Build in PR A** (`.github/dependabot.yml`, B below) for `github-actions`, `docker`, `terraform` and `pre-commit`. **Not** `pip` or `docker-compose` | Weekly-to-monthly pin bumps come from a bot that looks up SHAs, which is better than hand edits | PRs that touch workflows trigger approval-gated runs on merge (R11). Terraform Dependabot PRs get no plan (no secrets, R15) |
| S6 | Lock files multi-platform | **Verified present.** Step A10 checks that the first Terraform Dependabot PR keeps both platforms' `h1:` hashes | `init -lockfile=readonly` in CI already fails on a missing `linux_amd64` hash | A missing darwin hash only shows locally |
| S7 | NFR-6 gitleaks and push protection | **Verified in repo; the user confirms the setting (step A9)** | No code change | n/a |
| S8 | NFR-7 stretch: trail plus alert | **Build in PR A, in bootstrap**, with **EventBridge plus SNS email, not a CloudWatch Logs metric filter** (C below) | About 0 USD a month: free first trail copy, free management event ingestion, no log ingestion, no IAM role for CloudTrail. One email per suspicious event, with the event detail | Deviates from the NFR-7 wording "metric filter/alarm" (PLAN note). Regional only (global-endpoint STS calls land in us-east-1). Depends on there being no other trail (Q2) |
| S9 | Item 3: YAML-parser trigger allowlist (ADR 0004 L-a) | **Build in PR A.** `scripts/workflow_triggers.py` uses PyYAML from the hash-locked venv. `check-workflow-triggers.sh` stays the entry point and calls it | Real YAML semantics: flow lists split across lines, explicit `?` keys, anchors and quoted keys. It refuses duplicate keys and a file with both `on` and YAML 1.1 `true` | Adds a Python helper and a local venv (`make venv`). PyYAML and GitHub's parser can still differ (R13) |
| S10 | Item 4: ALB ingress from a secret (ADR 0004 L4, ADR 0006 Q5) | **Build in PR A, off by default.** Repo secret `ALB_INGRESS_CIDRS_DEV` (JSON list); unset means `0.0.0.0/0`. Rules are created with `count` and are indexed, not keyed by CIDR; descriptions hold no CIDR; variables are `sensitive`. Each element is masked | Narrows plain-HTTP `/admin` exposure (R6) without committing an IP | The user maintains the secret when their IP changes. A wrong value locks the user out of the ALB, but no CI job uses the ALB |
| S11 | Item 5: `tf-policy.sh` rule 9 bypasses | **Build in PR A.** Rule 9 matches quoted or unquoted labels. **Rule 10:** no `*.tf.json` under `infra/terraform`. **Rule 11:** module `source` under `envs/` and `modules/` must start with `./` or `../` | Closes the three named gaps with tests | The policy remains a review aid: a PR can edit it too |
| S12 | Item 6: destroy heading | **Build in PR A.** Move the result block to `scripts/tf-destroy-report.sh` (selftested). Headings: `Destroyed`, `Destroy failed`, `Nothing to destroy`, `Destroy did not finish` | A skimmer cannot misread a red run | One more small script |
| S13 | Item 7: false comment in `terraform-destroy.yml` | **Fix in PR A.** "The script never echoes the phrase. GitHub prints the step `env:` block, so it shows there; it is not a secret." | The comment matches what really happens | None |
| S14 | Item 8: `ecs:DeleteTaskDefinitions` at teardown | **Drop** | No new apply-role permission. `INACTIVE` revisions cost nothing (ADR 0006 Finding 3) | Revisions stay listed as `INACTIVE` indefinitely |
| S15 | Item 9: negative tests (PR token refused; session cap) | **Build in PR A**, in `oidc-smoke-test.yml` (D below): N8 (a PR token is refused by apply and deploy) and N9 (a 3601 s request on the plan role fails; a 900 s session reports its expiry) | Repeatable proof in CI. No stored keys, no long sleep | Each run raises expected AccessDenied and duration-error alert emails (by design, a demo of S8) |
| S16 | Item 10: `guard (no AWS)` required | **User setting at checkpoint A (step A8)** | Blocks merging with a red guard | Without a second maintainer, a ruleset bypass stays possible for the owner |
| S17 | G2 `.editorconfig` | **Build in PR A**: LF, final newline, UTF-8, trim trailing whitespace (except Markdown), 2 spaces for YAML, HCL, JSON and shell, 4 for Python, tabs for `Makefile` | Editors match the linters | Advisory only. No new checker tool (`end-of-file-fixer` already enforces part of it) |
| S18 | G3 `CODEOWNERS` | **Build** `.github/CODEOWNERS` with `* @trungleviet-agilityio`. **Do not turn on "Require review from Code Owners"** while there is one maintainer (Finding 8, Q6) | Ownership is documented and reviews are requested automatically | No enforcement until a second maintainer exists |
| S19 | G4 libraries not executable | **Build**: `chmod -x scripts/lib.sh scripts/selftest/common.sh` (`git update-index --chmod=-x`). A selftest checks that these two are mode 100644 and every other `scripts/*.sh` and `scripts/selftest/*.sh` is 100755 | Follows the guide; no one can run a library by mistake | A mode-only diff touches the path filters of `app-ci`, `app-deploy` and `terraform-iac`, so merging starts those runs |
| S20 | G5 `compose.yaml` | **Build**: rename `app/docker-compose.yml` to `app/compose.yaml` (backend-dev) and update the `Makefile` `up` and `down` targets (devops). The orchestrator updates the plugin agent docs and the `pr-conventions` skill | Matches the Docker docs | Churn in five files across three owners |
| S21 | Dependabot Docker readability (Finding 5) | **Build**: the Dockerfile gets one literal `FROM public.ecr.aws/docker/library/python:3.13-slim@sha256:<d> AS base`, and `test` and `runtime` use `FROM base`. `build-image.sh` builds as is first. A fallback mirror attempt adds `--build-context base=docker-image://<mirror>:3.13-slim@sha256:<d>`, with tag and digest read from that `FROM` line | Dependabot can bump the base. One digest in one place. The mirror fallback is kept | Using `--build-context` with the default `docker` driver is not confirmed in the docs. Step A11 proves it locally |

### B. Dependabot (`.github/dependabot.yml`)

| Ecosystem | `directories` | Group | Commit prefix | Notes |
|---|---|---|---|---|
| `github-actions` | `["/"]` | `actions`, `patterns: ["*"]` | `ci` | Every workflow in one PR |
| `docker` | `["/app"]` | `base-image`, `patterns: ["*"]` | `build` | Needs S21 |
| `terraform` | `["/infra/terraform/bootstrap", "/infra/terraform/envs/*", "/infra/terraform/modules/*"]` | `terraform`, `patterns: ["*"]` | `infra` | The globs pick up `envs/prod` in Phase 7 |
| `pre-commit` | `["/"]` | `hooks`, `patterns: ["*"]` | `chore` | Keep only if the first PR preserves `# frozen: vX` (Q4) |

All four use `schedule.interval: monthly`, `cooldown.default-days: 7`, `commit-message.include: scope` and the default label. Not covered, so a monthly manual check (recorded in PROGRESS): the `mise.toml` tool versions plus `ci-tools.sha256`, and `ci-requirements.txt` (`pip` left out, Q5).

**Terraform Dependabot PRs get no plan** (the plan job skips Dependabot). Rule: before merging one, the maintainer re-opens it from their own branch so the plan role runs. Commands are in the checkpoint.

### C. NFR-7: trail, rule and alert (bootstrap, admin-applied)

| # | Resource | Settings |
|---|---|---|
| S22 | `aws_s3_bucket.trail` | `sis-dev-cloudtrail-<acct>-<region>-an`, `bucket_namespace = "account-regional"` (B8 pattern), `force_destroy = true` (Q9). Public access block, `BucketOwnerEnforced`, SSE-S3, lifecycle that expires objects after 30 days. TLS-only deny (the same document shape as `state_tls`) |
| S23 | Trail bucket policy | AWS standard policy: `cloudtrail.amazonaws.com` may call `s3:GetBucketAcl` on the bucket and `s3:PutObject` on `AWSLogs/<acct>/*`, with `s3:x-amz-acl = bucket-owner-full-control`. Both statements carry `aws:SourceArn = arn:aws:cloudtrail:<region>:<acct>:trail/sis-dev-trail` |
| S24 | `aws_cloudtrail.this` | `sis-dev-trail`, `is_multi_region_trail = true`, `include_global_service_events = true`, `enable_log_file_validation = true`, management events only (the default selector). No CloudWatch Logs, no KMS, no data events. **Only if Q2 finds no existing trail** |
| S25 | `aws_sns_topic.security_alerts` | `sis-dev-security-alerts`, no KMS (the AWS-managed SNS key cannot be used by EventBridge, and a CMK costs 1 USD/month). Email subscription to `var.budget_email` (Q10). The user confirms it |
| S26 | Topic policy | `events.amazonaws.com` may call `sns:Publish` on this topic, with `aws:SourceArn = <rule ARN>` |
| S27 | `aws_cloudwatch_event_rule.oidc_unexpected` | `sis-dev-oidc-unexpected`, default bus, `state = "ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS"` (Finding 6). Pattern below. The target is the topic |
| S28 | Guardrails statement `G6DenyAuditTampering` | Deny `cloudtrail:*` on `*`; `events:*` on the rule ARN; `sns:*` on the topic ARN; `s3:*` on the trail bucket and its objects. No CI role needs any of these. This is defense in depth against a future Allow |

Event pattern. The subs come from `distinct([for t in local.trust : t.sub])`; they hold owner and repo IDs, never the account:

```json
{
  "source": ["aws.sts"],
  "detail-type": ["AWS API Call via CloudTrail"],
  "detail": {
    "eventName": ["AssumeRoleWithWebIdentity"],
    "$or": [
      { "errorCode": [{ "exists": true }] },
      { "userIdentity": { "userName": [{ "anything-but": ["<sub_prefix>:pull_request", "<sub_prefix>:environment:dev"] }] } }
    ]
  }
}
```

A refused attempt (wrong `sub`, `ref` or `job_workflow_ref`; a too-long duration) alerts through `errorCode`. A successful assumption with any other subject (a trust mistake) alerts through `anything-but`. Step A5 confirms the `userName` field on a real event.

**Cost (ap-southeast-1).**

| Item | Cost |
|---|---|
| Trail | 0 (first copy) |
| S3 storage | A few MB a month with 30-day expiry, under 0.01 USD. This is an estimate; the S3 price page was not opened |
| EventBridge | 0 (management event ingestion is free; a few matches a month) |
| SNS email | A handful a month. Estimate; the SNS price page was not opened |

Total: about 0 USD a month, well inside the 20 USD budget. A second trail would instead cost 2 USD per 100,000 events, which is why Q2 is checked first.

### D. Scripts, workflows, Terraform (PR A)

| # | Change |
|---|---|
| S29 | **Trust (`locals.tf`, `oidc.tf`).**<br>- `workflow_names` becomes `workflow_files = { apply = ["terraform-iac.yml", "terraform-destroy.yml"], deploy = ["app-deploy.yml"] }`.<br>- `job_workflow_refs = { for k, fs in local.workflow_files : k => [for f in fs : "${var.github_owner}/${var.github_repo}/.github/workflows/${f}@refs/heads/main"] }`.<br>- `trust.apply.workflows` and `trust.deploy.workflows` become the refs; the plan stays `null`.<br>- The dynamic condition becomes `StringEquals` on `${local.oidc_host}:job_workflow_ref`. `ref = refs/heads/main` stays (cheap, already tested).<br>- `trust.tftest.hcl`: the `workflow_names_pinned` run becomes a `job_workflow_ref_pinned` run with exact values. Plan has no `job_workflow_ref` and no `workflow` condition. `only_documented_condition_keys` allows `aud, sub, repository_id, repository_owner_id, ref, job_workflow_ref`. There are no wildcards in `job_workflow_ref` values |
| S30 | **Shared OIDC helpers in `lib.sh`:** `oidc_token <audience>` (curl with `ACTIONS_ID_TOKEN_REQUEST_*`, masks the token) and `jwt_claim <token> <claim>` (base64url decode with `jq`). They are used by S31 and S32 and print nothing themselves |
| S31 | **`scripts/assert-web-identity-denied.sh <role>...`** (role names `plan`, `apply`, `deploy`). It builds `arn:aws:iam::${ACCOUNT}:role/sis-${ENV}-gha-<role>` and masks `ACCOUNT`. It prints `sub` and `job_workflow_ref`, then for each role runs an unsigned `assume-role-with-web-identity` and requires `AccessDenied` / "Not authorized". Success or any other error fails. It replaces the inline N1 step |
| S32 | **`scripts/assert-session-cap.sh <role>`** (N9). It sends `--duration-seconds 3601` and requires a failure whose text names `DurationSeconds` or `MaxSessionDuration`. It sends `--duration-seconds 900 --query Credentials.Expiration --output text` and prints "session expires in about 15 minutes (<expiration>)". Credentials never reach stdout |
| S33 | **`oidc-smoke-test.yml`.**<br>- PR job `assume-plan-role` keeps its steps and adds N8 (`assert-web-identity-denied.sh apply deploy`) and N9 (`assert-session-cap.sh plan`).<br>- Dispatch job N1 becomes `assert-web-identity-denied.sh plan apply deploy`. A non-PR, non-environment token must be refused by all three.<br>- Each job gets `ACCOUNT: secrets.AWS_ACCOUNT_ID_DEV`, `ENV: dev` and `REGION: vars.AWS_REGION` in `env:` and a checkout (`persist-credentials: false`), with `contents: read` added.<br>- `paths` gains the two scripts and `scripts/lib.sh` |
| S34 | **`scripts/workflow_triggers.py`** (stdlib plus PyYAML, run with `python -I`).<br>- A `SafeLoader` subclass refuses duplicate mapping keys.<br>- It reads the top-level `on`, or YAML 1.1 `True`, and fails if both are present or neither is.<br>- It accepts str, list or mapping; any other node fails.<br>- It checks each trigger against `pull_request push workflow_dispatch`.<br>- Messages match the current script.<br>**`check-workflow-triggers.sh`** keeps its usage. It picks `CI_PYTHON`, else `$ROOT/.venv-ci/bin/python`, else `python3`; fails with "pyyaml missing: run make venv (hash locked)" if `import yaml` fails; then execs the Python file.<br>**`scripts/ci-venv.sh <dir>`** creates or reuses a venv and installs `--require-hashes -r scripts/ci-requirements.txt`. It is used by `repo-guard` (replacing the inline 3 lines) and by `make venv` (`.venv-ci`, gitignored).<br>Ruff covers `scripts/*.py` (`files: ^(app/\|scripts/.*\.py$)`). Mypy stays app-only (no PyYAML stubs) |
| S35 | **ALB CIDRs (S10).**<br>- `modules/app-ecs`: `alb_ingress_cidrs` gets `sensitive = true`. `alb_http` uses `count = nonsensitive(length(var.alb_ingress_cidrs))`, `cidr_ipv4 = var.alb_ingress_cidrs[count.index]` and `description = "HTTP from allowed CIDR ${count.index}"`. The validation stays.<br>- `envs/dev`: new `alb_ingress_cidrs_json` (string, `sensitive`, default `""`). `locals { alb_ingress_cidrs = var.alb_ingress_cidrs_json == "" ? ["0.0.0.0/0"] : jsondecode(var.alb_ingress_cidrs_json) }`, with a validation that the value is a JSON list of IPv4 CIDRs. The old `alb_ingress_cidrs` root variable is removed.<br>- `terraform-iac.yml` plan and apply: the plan step env gets `TF_VAR_alb_ingress_cidrs_json: ${{ secrets.ALB_INGRESS_CIDRS_DEV }}`.<br>- A step before it runs `scripts/mask-cidrs.sh` (reads `CIDRS`; empty prints the notice "ALB ingress: default 0.0.0.0/0"; otherwise `::add-mask::` per element; prints nothing else; fails on non-JSON).<br>- `terraform-destroy` needs no change (a destroy plan deletes what is in state) |
| S36 | **`tf-policy.sh`.**<br>- Rule 9: `^[[:space:]]*provisioner([[:space:]]\|")` and `^[[:space:]]*data[[:space:]]+"?external"?[[:space:]{]`.<br>- Rule 10: `find "$root" -name '*.tf.json'` is a violation.<br>- Rule 11: an awk pass over `module` blocks under `envs/` and `modules/` flags any `source =` not starting with `"./` or `"../`. `required_providers` `source` lines are not inside a `module` block, so they are not matched.<br>Self-test fixtures in `tf-policy-selftest.sh` for each form |
| S37 | **`scripts/tf-destroy-report.sh`** (S12). Reads `ENV`, `DELETES`, `APPLY_OUTCOME`, `DEREGISTERED` and `ROLE`, and prints the Markdown block. The workflow pipes it through `assert-no-account-id.sh`. Fix the comment (S13) |
| S38 | **Workflow comments** that call the trust a `name:` pin (`terraform-iac`, `app-deploy`, `terraform-destroy`, `repo-guard`) now say "the file path is in the trust (`workflow_files`)". `selftest/workflows.sh`: the name-parity check becomes a file-parity check. Every entry of bootstrap `workflow_files` exists under `.github/workflows/`, and `repo-guard.yml` and `oidc-smoke-test.yml` are not listed |

### E. harden-runner block (PR B, after checkpoint A)

| # | Decision |
|---|---|
| S39 | For each job in S4:<br>- `egress-policy: block`, `disable-telemetry: true`, and `allowed-endpoints: >` with one `host:port` per line, taken from the step A6 egress list for that job.<br>- **Account-bearing hosts are written as expressions, never wildcards and never literals:** `sis-dev-tfstate-${{ secrets.AWS_ACCOUNT_ID_DEV }}-${{ vars.AWS_REGION }}-an.s3.${{ vars.AWS_REGION }}.amazonaws.com:443` and `${{ secrets.AWS_ACCOUNT_ID_DEV }}.dkr.ecr.${{ vars.AWS_REGION }}.amazonaws.com:443`.<br>- If zizmor flags secrets in `with:`, stop and report. The fallback is a region-scoped wildcard, recorded as R12 |
| S40 | Selftest for PR B:<br>- every job with `id-token: write` has `egress-policy: block` and `disable-telemetry: true`;<br>- every endpoint has `:port`;<br>- no entry is `*`, `*:443`, `*.amazonaws.com:443`, `*.githubusercontent.com:443` or `*.github.com:443`;<br>- jobs without credentials still name `audit` explicitly |
| S41 | Expected endpoint families, to be confirmed from the log, not copied blindly:<br>- `github.com`, `api.github.com`, release asset hosts (checkout, tflint download);<br>- `releases.hashicorp.com`, `registry.terraform.io` (Terraform, providers);<br>- `sts.<region>.amazonaws.com`;<br>- the regional service endpoints the job calls (`ec2`, `ecs`, `elasticloadbalancing`, `logs`, `secretsmanager`, `api.ecr`) and `iam.amazonaws.com`;<br>- the ECR layer bucket host for pushes;<br>- the state bucket host (S39).<br>Runner-required endpoints are allowed implicitly in the community tier (v2.21.1 notes) |

### F. PR B decisions after checkpoint A (2026-10-27, same delegation)

The A6 list covers the plan, plan-role-guardrails and smoke-test jobs. These decisions fill what S39 to S41 left
open. harden-runner stays at v2.22.2, the latest release (checked 2026-10-27).

| # | Decision | Pro | Con |
|---|---|---|---|
| S42 | **Seven jobs go to `block`:** terraform-iac `plan`, `plan-role-guardrails`, `apply`; terraform-destroy `destroy`; app-deploy `deploy`; both oidc-smoke-test jobs (every job with `id-token: write`). All other jobs keep `audit`, written out | Blocking where AWS credentials live; insights stay on credential-free jobs, where they are useful and hold no account host | Seven allowlists to keep current |
| S43 | **Hosts for jobs A6 did not capture** (apply, destroy, deploy) come from the code, not a guess: the plan job's list plus the regional endpoint of every AWS service in `envs/dev` and `modules/app-ecs` (`ec2`, `elasticloadbalancing`, `ecs`, `api.ecr`, `logs`, `secretsmanager`) and `iam.amazonaws.com`; deploy from its scripts and actions (artifact download, ECR registry and layer host, `ecs`, `secretsmanager`). The build agent confirms each against AWS and StepSecurity docs | Every host traces to a resource or script line | A missed host fails a job (R16); checkpoint B is the proof |
| S44 | **`CHECKPOINT_DISABLE=1`** in the workflow `env:` of terraform-iac and terraform-destroy. `checkpoint-api.hashicorp.com` leaves the allowlists | One host fewer; no version-check call to HashiCorp | No upgrade notice in CI logs (Dependabot covers that) |
| S45 | **The S40 rules are a repo-guard check, not only a self-test** (as built after verify round 1: also `disable-sudo-and-containers` with the one `deploy` exception, no `*` and only three expression contexts in credentialed endpoints, no `if:`/`continue-on-error:` on the step, no `container:`/`services:` on credentialed jobs, no `secrets.` in other jobs' endpoints; both helpers share `run()` in `workflow_yaml.py`): a Python helper on the hash-locked PyYAML venv (like `workflow_triggers.py`) reads every workflow and fails when a credentialed job is not `block` with telemetry off, an endpoint has no `:port`, an entry is a broad wildcard (S40 list), a literal 12-digit number appears, or a non-credentialed job does not say `audit`. Self-tests cover each rule | A new credentialed job cannot ship in audit by accident; YAML read the way GitHub reads it | One more helper and its fixtures |
| S46 | **Dependabot python ignore:** in the `docker` entry, `ignore` `dependency-name: "*python*"` (matched to the name Dependabot reports, checked by the agent) with `update-types: ["version-update:semver-minor", "version-update:semver-major"]`. Digest and patch updates of 3.13 still arrive. The user closes #22 after merge | Security rebuilds stay automatic; a runtime change stays a planned change | Moving to a new Python is manual |
| S47 | **Rollout:** PR B's own checks prove the plan and smoke-test lists in block mode before merge. Apply, deploy and destroy are proven at checkpoint B on an empty stack. Rollback for one job is a short PR that adds the host the log names (amended after verify: the S45 check refuses `audit` on a credentialed job, so that is not a fallback) | The risky lists are tested where a failure costs nothing | A blocked host mid-apply leaves a partial dev stack; `terraform-destroy` cleans it |

Build hand-back questions, decided by the orchestrator:

| Question | Decision | Pro | Con |
|---|---|---|---|
| `plan` gets the apply service endpoints, not only the A6 list (A6 ran on a destroyed stack, so refresh called nothing) | **Keep** | A PR plan against a live stack refreshes every resource and would fail otherwise | Seven hosts A6 did not observe |
| Artifact download (`deploy`) and the OIDC token endpoint are not listed (runner endpoints are implicit in the community tier) | **Keep, prove it**: the PR's smoke-test job proves the token endpoint; checkpoint B proves the download | No guessed blob-storage host | Only a third-party write-up says results storage is implicit; if deploy blocks, add the host the log names |
| ECR layer host `prod-<region>-starport-layer-bucket.s3.<region>.amazonaws.com` on `deploy` | **Keep**; checkpoint B shows whether push uses it | AWS documents the bucket; a fixed AWS-owned bucket, not a wildcard | Possibly one unused host |
| `api.github.com` only on the jobs where A6 saw it | **Keep** | Lists follow evidence | Unknown caller; a blocked call shows in the log |
| The YAML loader moved to `scripts/workflow_yaml.py`, shared by the trigger and harden-runner helpers through `run_workflow_helper` | **Keep** | One loader and one wrapper path (no duplication) | Small refactor of a PR A file |

PR B verify findings (round 1), decided by the orchestrator:

| Finding | Decision | Pro | Con |
|---|---|---|---|
| Security H1: code in a credentialed job can undo block mode with passwordless sudo or Docker | **Fix**: `disable-sudo-and-containers: true` on six jobs, required by the policy check; `deploy` is the one named exception (it needs `docker load` and `push`) | Block mode holds against third-party code on the jobs that never need root | `deploy` stays exposed (docker group means root): **residual risk, accepted** for the lab |
| Security M1: a PR author with push access can change the plan job's policy, and it runs with the plan role before review | **Accept, recorded as a residual risk** | Gating the plan behind an environment changes the plan `sub` and slows every PR | Anyone with push access reads the account through the plan role for one session (read-only, `GetSecretValue` denied by the guardrails policy) |
| Security M2: exact AWS hosts do not stop uploads to another account | **Correct the claim** (Alternatives, region-wide wildcards); keep exact hosts | The ADR says what block mode really buys | None |
| Security M3: `api.github.com` has no known caller | **Remove** from `plan`, `apply`, `destroy`; this PR's plan run proves it | One upload API fewer on three credentialed jobs | If blocked, re-add it with the caller named |
| Security M4, reviewer L2: wildcard denylist too short; expressions unchecked | **Fix**: no `*` at all in a credentialed job's endpoints; only `vars.AWS_REGION`, `secrets.AWS_ACCOUNT_ID_DEV`, `env.ENV` expressions | A green check means no wildcard and no variable-widened list | A future wildcard needs a policy change in review |
| Security L1, L2, L4: `if:`/`continue-on-error` on the harden-runner step; `container:`/`services:` on a credentialed job; `secrets.` in a non-credentialed job's endpoints | **Fix** in the policy check, with fixtures | Closes the shapes that look compliant but are not | A few more rules |
| Reviewer M1, security L3: artifact download and runner endpoints are implicit | **Prove at checkpoint B** and record the implicit names from the `deploy` log | No guessed blob host | Deploy may block once |
| Reviewer M2: harden-runner's job summary may list account-bearing hosts | **Check at checkpoint B** on the PR plan run's summary | Evidence first | Account IDs are not secrets (D2) |
| Reviewer L1, L3: "switch to audit" rollback fails the required guard | **Fixed** in README and S47: the rollback is a PR that adds the host | Docs match the check | None |
| Simplifier 1 to 5, 7 | **Fix now** (one `run()` entry point, one self-test dispatcher, no duplicate test, short wrappers, simpler duplicate-key loader, short Dependabot comment) | No duplication | None |
| Simplifier 6: share the plan and apply host lists with a YAML anchor | **Keep separate** | Different roles; a future divergence shows in the diff | 15 repeated lines |

Round 2 (security re-check): H1, M3, M4, L1, L2 closed; none of the six hardened jobs needs sudo or Docker; a
bad `vars.AWS_REGION` value fails `check-aws-config.sh` before any role is assumed.

| Finding | Decision | Pro | Con |
|---|---|---|---|
| N1 (Low): an audit job can still carry a secret in `allowed-endpoints` through `secrets['X']`, `toJSON(secrets)` or an `env.X` set from a secret | **Accept, PROGRESS open item** (refuse any expression mentioning `secrets` in audit jobs, and `env` values built from secrets, when the policy is next touched) | Needs a workflow editor and a missed review; account IDs are not secrets (D2) | An account host could reach an insights page by that route |

### Least privilege summary

| Item | Value | Wildcards |
|---|---|---|
| Plan role | Trust and policy unchanged | existing B20 only |
| Apply role | Trust: `aud`, `sub = <P>:environment:dev`, `repository_id`, `repository_owner_id`, `ref = refs/heads/main`, **`job_workflow_ref` in [`.../terraform-iac.yml@refs/heads/main`, `.../terraform-destroy.yml@refs/heads/main`]** (replaces `workflow`). Policy unchanged | none added |
| Deploy role | Same trust shape with `job_workflow_ref = .../app-deploy.yml@refs/heads/main`. Policy unchanged (Phase 5 G14 `DescribeSecret` stays) | none added |
| Guardrails | + `G6DenyAuditTampering` (Deny only) | `cloudtrail:*`, `events:*`, `sns:*`, `s3:*`, all in a Deny, which widens protection |
| `iam:PassRole` | Unchanged; no new role is passed. CloudTrail gets no role (no CloudWatch Logs delivery) | none |
| Service principals | `cloudtrail.amazonaws.com` (bucket; `aws:SourceArn` = trail), `events.amazonaws.com` (topic; `aws:SourceArn` = rule) | none |
| GitHub tokens | `oidc-smoke-test` jobs gain `contents: read` (checkout of the scripts) | none |
| New secrets | `ALB_INGRESS_CIDRS_DEV` (optional, repo) | n/a |

### File layout (PR A)

```
.editorconfig                              new (S17)
.gitignore                                 + .venv-ci/
.github/CODEOWNERS                         new (S18)
.github/dependabot.yml                     new (S5, B)
.github/workflows/oidc-smoke-test.yml      S33
.github/workflows/repo-guard.yml           ci-venv.sh, comment (S34, S38)
.github/workflows/terraform-iac.yml        CIDR secret, comments (S35, S38)
.github/workflows/terraform-destroy.yml    report script, comment (S12, S13)
.github/workflows/app-deploy.yml           comment (S38)
.pre-commit-config.yaml                    ruff files pattern (S34)
Makefile                                   venv target, compose.yaml (S20, S34)
scripts/lib.sh                             chmod -x, oidc_token, jwt_claim (S19, S30)
scripts/selftest/common.sh                 chmod -x (S19)
scripts/{assert-web-identity-denied,assert-session-cap,ci-venv,mask-cidrs,tf-destroy-report}.sh   new
scripts/workflow_triggers.py               new (S34)
scripts/{check-workflow-triggers,tf-policy,tf-policy-selftest,build-image}.sh   edited
scripts/selftest/{workflows,tooling,terraform,image}.sh   new cases
infra/terraform/bootstrap/{locals,oidc,iam_guardrails}.tf, monitoring.tf (new), variables.tf, outputs.tf (topic name only), README.md
infra/terraform/bootstrap/tests/{trust,iam}.tftest.hcl, tests/monitoring.tftest.hcl (new)
infra/terraform/modules/app-ecs/{security_groups,variables}.tf, tests/app_ecs.tftest.hcl, README.md
infra/terraform/envs/dev/{variables,main,locals}.tf, README.md
app/Dockerfile, app/compose.yaml (renamed), app/.dockerignore     backend-dev (S20, S21)
```

## Alternatives considered

- **Reusable workflows so `job_workflow_ref` is guaranteed** (ADR 0005 L2 wording). This adds a caller and a callee per pipeline, and secrets and `environment` handling across the call. Rejected unless step A0 shows the claim is missing for plain workflows.
- **Keep the `workflow` pin and add `job_workflow_ref`.** Two pins on the same fact means two places to update on a rename. Rejected.
- **A CloudWatch Logs metric filter plus an alarm** (NFR-7 literal). It needs trail delivery to CloudWatch Logs, an IAM role that CloudTrail assumes (a `PassRole` by the admin), a log group, ingestion fees, a metric and an alarm. Rejected for EventBridge (S8). It stays the fallback if the user wants an alarm history graph for the talk.
- **No trail; read event history by hand.** Free, but there is no alert. Rejected for the stretch.
- **Block mode on every job in PR A with a guessed allowlist.** It breaks jobs mid-apply on the first missed host. Rejected (PLAN Phase 6.2 says review a log first).
- **Region-wide wildcards (`*.s3.<region>.amazonaws.com`) for account hosts.** They allow exfiltration to any bucket in the region. Rejected for exact hosts built from secrets (S39). Kept only as the fallback. Amended after the PR B security review: block mode filters at DNS and at layers 3 and 4, not by SNI or `Host`, and regional S3 and AWS API front ends are shared, so an exact host does not stop code that brings its own AWS keys from writing to another account. The exact host still stops DNS-level exfiltration and keeps the list honest; the session credentials are the real prize, guarded by least privilege and `disable-sudo-and-containers`.
- **StepSecurity policy store.** Needs an API key or `id-token: write` for a third party. Rejected.
- **A stricter line parser instead of PyYAML.** No new dependency, but the hand grammar stays the weak point. Rejected: PyYAML is already in the hash-locked venv.
- **A `language: python` pre-commit hook with `additional_dependencies: [pyyaml==6.0.3]`.** That installs by version, not by hash. Rejected for `ci-venv.sh`.
- **Renovate** (it can bump `mise.toml` and the checksum file). It needs a GitHub App with write access. Rejected; manual monthly check.
- **Dependabot `pip` for `ci-requirements.txt`.** The file is `uv pip compile` output with hashes, and Dependabot support for that header is unverified. It holds one top-level package that is also pinned in `mise.toml`. Rejected (Q5).
- **An environment-gated negative job (`environment: dev`) in `oidc-smoke-test`** to prove another file cannot use the apply role. It adds an approval to a smoke workflow and exposes `dev` environment secrets to it. Rejected; N8 and the file-pinned trust cover the risk.
- **Sleeping 16 minutes to show credentials expire.** It wastes runner time. Rejected for N9 (cap refused, expiry printed).
- **Turning on code owner review now.** It blocks every merge on a single-maintainer repo (Finding 8). Deferred.
- **A selftest that keeps the `terraform.tfvars` placeholder digest equal to the Dockerfile digest.** It would make every Docker Dependabot PR fail until a human edits it, and the placeholder never serves (ADR 0005 F2). Rejected.

## Consequences

- **Bootstrap re-apply (one, after Phase 5's).** Expect about 12 to add (trail bucket and its 5 configuration resources, trail, topic, topic policy, subscription, rule, target) and 3 to change (`aws_iam_role.apply`, `aws_iam_role.deploy`, `aws_iam_policy.guardrails`). The user confirms the SNS subscription email.
- **R2 closed** once A7 proves the file-pinned trust live.
- **R6 reduced** when the user sets `ALB_INGRESS_CIDRS_DEV`.
- **R8 (ADR 0005 Q1)** is checked at A6 and closed for credentialed jobs by PR B.
- **New risks.**
  - **R11:** a grouped Dependabot actions PR touches every workflow. Merging it starts the `terraform-iac` push apply and `app-deploy`, both approval-gated. If the stack is down, **reject** the pending apply, because approving it re-creates the stack (lessons log 14).
  - **R12:** if S39's expressions are refused, the wildcard fallback leaves an in-region exfiltration path.
  - **R13:** PyYAML and GitHub's YAML parser may disagree on exotic input. Duplicate-key refusal and the double `on`/`true` check narrow this.
  - **R14:** a wrong `job_workflow_ref` value fails closed (AccessDenied). Rollback is a re-apply of the previous commit.
  - **R15:** Terraform Dependabot PRs skip the plan. Re-open them from a maintainer branch before merging.
  - **R16:** in PR B, a host missing from the allowlist fails a job, possibly mid-apply. The plan job runs first on the PR, and the first apply runs on an empty stack.
- **Alert noise by design.** Every N1, N8 and N9 run sends about 3 to 5 alert emails.
- **The mode change on `lib.sh` and the `oidc-smoke-test` and `terraform-iac` changes start `terraform-iac` (push apply) and `app-deploy` on merge.** The checkpoint uses them.
- **Docs to update (orchestrator, D14):**
  - **README:** trust table row `workflow` becomes `job_workflow_ref` (file path at `main`). Add sections: Dependabot handling (re-open Terraform PRs; reject a pending apply after a Dependabot merge when the stack is down); security alerts (trail, rule, email; what triggers it); optional ALB CIDR secret; `make venv`; `compose.yaml`.
  - **CODING_STANDARDS:**
    - the trust pins `job_workflow_ref`, and `workflow_files` is the contract;
    - harden-runner: `block` plus `disable-telemetry` on credentialed jobs, exact hosts, account hosts only through secret expressions (after PR B);
    - tf-policy rules 9 to 11;
    - Python helpers allowed in `scripts/` when they need a parser, run from the hash-locked venv with `-I`;
    - libraries are not executable;
    - `.editorconfig`;
    - base image in one literal `FROM ... AS base`;
    - the Compose file is `app/compose.yaml`.
  - **PLAN.md:** NFR-7 note (EventBridge rule instead of metric filter/alarm, ADR 0007 S8); Phase 6 steps.
  - **PROGRESS.md:** Phase 6 row; close L2, Q1, L-a, L4, the rule 9 gaps, the destroy heading, `guard` required, negative tests and the NFR-7 stretch. Add the open items "monthly manual check of `mise.toml` tools and `ci-requirements.txt`" and "code owner review when a second maintainer joins".
  - **ADRs:** ADR 0002 (trust: `job_workflow_ref`; guardrail G6; bootstrap monitoring), ADR 0004 (L4, L-a resolved), ADR 0005 (L2, Q1 resolved), ADR 0006 (deferred rule 9 and heading items resolved; S14 drops `DeleteTaskDefinitions`).
  - **`docs/diagrams/bootstrap.drawio`:** trail, bucket, rule and topic.
  - **`plugins/sis-team/agents/e2e.md`, `backend-dev.md`, `.claude/skills/pr-conventions/SKILL.md`:** `compose.yaml`.

## Open questions (recommendation first)

| Q | Recommendation | Alternatives |
|---|---|---|
| Q1 | Do PR B whatever step A6 shows; record the A6 result | Skip PR B if insights are private (keeps audit, loses exfiltration blocking) |
| Q2 | Before applying, check `describe-trails`. If no trail exists, build S24. If one exists, set `create_trail = false` (one variable, default `true`) and keep the rule | Always create (risks paying for a second copy) |
| Q3 | Leave `ALB_INGRESS_CIDRS_DEV` unset by default; set it to your `/32` when not demoing | Always set it (phone demos and changing IPs then fail) |
| Q4 | Keep the `pre-commit` ecosystem if the first PR keeps `# frozen: vX` comments; otherwise drop it and run `pre-commit autoupdate --freeze` monthly | Leave it out now |
| Q5 | No `pip` ecosystem | Add it and test the uv-compiled file |
| Q6 | CODEOWNERS file yes, code owner review rule no | Turn it on with an owner bypass (gives no real protection) |
| Q7 | Confirm `@trungleviet-agilityio` is a user or team with write access (the git user is `trungle-agilityio`) | Use the other handle |
| Q8 | `monthly` with a 7-day cooldown | `weekly` (more PRs, faster fixes; security updates are immediate either way) |
| Q9 | Trail bucket `force_destroy = true` (simpler end-of-lab teardown) | `false`, consistent with the state bucket, plus a manual emptying step |
| Q10 | Alerts go to `var.budget_email` | A separate `security_alert_email` variable |

## Decision log (open questions resolved)

The user delegated these choices ("decide open questions by best practice and record pros and cons"). The
orchestrator accepted every recommendation on 2026-10-27, with the changes noted. The pro and con of each are the
decision record.

| Q | Decision | Pro | Con |
|---|---|---|---|
| Q1 | Build PR B (block mode on credentialed jobs) whatever A6 shows; record the A6 result | Blocks exfiltration from the only jobs that hold AWS credentials, independent of who can read insights | One more PR and an allowlist to maintain |
| Q2 | Check `describe-trails` first (A1); create the trail only if none exists (`create_trail`, default `true`) | Never pays for a second copy of management events | One extra variable and a conditional resource |
| Q3 | Leave `ALB_INGRESS_CIDRS_DEV` unset by default | Demos from a phone or a changing IP keep working | `/admin` stays reachable from anywhere on plain HTTP until the user sets it |
| Q4 | Keep the `pre-commit` ecosystem only if the first PR keeps `# frozen: vX` comments (A10) | Hooks are bumped by the bot like everything else | If comments are lost, it is removed again and hooks fall back to a monthly `pre-commit autoupdate --freeze` |
| Q5 | No `pip` ecosystem | The uv-compiled, hash-locked file is not put at risk by an unverified updater | `ci-requirements.txt` needs the monthly manual check |
| Q6 | `CODEOWNERS` file yes, "require review from code owners" no | Documents ownership and requests reviews without blocking a one-maintainer repo | No enforcement until a second maintainer joins (PROGRESS open item) |
| Q7 | **Resolved by lookup:** the token's login and the repo owner are both `trungleviet-agilityio` (a user), so `* @trungleviet-agilityio` is correct. `trungle-agilityio` is only the local git author name | No guess in the file | None |
| Q8 | `monthly` schedule with a 7-day cooldown | Few PRs, and new releases get a week to be pulled if bad; security updates skip the cooldown | Non-security fixes arrive up to about five weeks late |
| Q9 | Trail bucket `force_destroy = true` with 30-day expiry | End-of-lab teardown is one step | Inconsistent with the state bucket; an admin destroy deletes the audit log copies (event history keeps 90 days anyway) |
| Q10 | Alerts go to `var.budget_email` | No new input; one inbox for cost and security | Cannot route security mail elsewhere without a later variable |
| Q11 (added) | Keep the `terraform` Dependabot ecosystem although its docs list Terraform up to 1.15.x and the repo pins 1.17.0; drop it if A10 shows parse errors (R17) | Provider and lock-file bumps come from the bot | Support for the pinned version is unverified until the first run |

**R17 (added):** Dependabot may not parse a configuration that needs Terraform 1.17.0. Signal: an error on Insights >
Dependency graph > Dependabot for the terraform entry. Fallback: remove that entry and bump providers by hand monthly.

## Verify findings (decided by the orchestrator on 2026-10-27, same delegation)

No Critical or High finding. Round 1 builds everything marked **Fix**; the rest is recorded here.

| Finding | Decision | Pro | Con |
|---|---|---|---|
| Security M1: the alert only sees STS calls in ap-southeast-1; a caller can use another region or the global endpoint | **Fix**: every trust adds `StringEquals aws:RequestedRegion = <region>` (AWS: the key "is always included in the request context"; a global-endpoint call carries us-east-1 and is refused). Refused probes in other regions stay unalerted: accepted, they grant nothing | Zero cost; an unexpected success can only happen where the rule watches | A region move needs a bootstrap re-apply; a client on the global STS endpoint now fails (fails closed, seen at A4 and A7) |
| Reviewer M1: rule 9 anchored at line start, so a one-line `{ provisioner ... }` passes | **Fix**: unanchored match plus one-line fixtures | The rule covers what CODING_STANDARDS claims | A few more fixtures |
| Security L1: rule 11 counts braces inside strings and comments; providers are unrestricted | **Fix**: strip strings and comment tails before counting; new rule 12 allows only `hashicorp/*` providers | Closes a remote-code path in the plan job | A non-hashicorp provider later needs a policy change |
| Security L2: the destroy job does not mask the ALB CIDRs | **Fix**: the same `mask-cidrs.sh` step before the destroy plan | An AWS error text cannot print the maintainer's `/32` | None worth noting |
| Security L3: the pin self-test reads only `*.yml` | **Fix** (glob or refuse `.yaml`) | No workflow escapes the SHA-pin guard | None |
| Security L4: anyone can trigger refusal emails | **Accept** | No extra moving parts in a lab | A flood could hide one real alert; the trail still has every event |
| Reviewer L3: `app-ci` has its own inline hash-locked install | **Fix**: use `ci-venv.sh` | One owner of the install | None |
| Reviewer L4: the build-context fallback is proven only on the maintainer's Docker | **Accept**; the e2e run and A11 prove it locally, and a 429 in CI is the live test | No extra workflow | A failure would first show under rate limiting |
| Reviewer L5, L7, L8: destroy detail wording, module IPv4 regex, `job_workflow_ref` case sensitivity | **Fix** (wording, regex, README note) | Accurate messages; early validation | None |
| Reviewer L6: N1 has no positive control | **Accept**; the PR job's real plan-role assumption is the control, and `check-aws-config.sh` checks the inputs | No approval-gated job in a smoke workflow | A wrong ARN in the dispatch job would still read as "refused" |
| Reviewer M2, L1, L2: diagram, PLAN Phase 6 steps, README make and phases rows | **Fix (orchestrator docs)**; PROGRESS at the checkpoint | Docs match the code | None |
| e2e: `make check` fails on a fresh clone until `make venv` | **Fix**: `lint` depends on a `.venv-ci/bin/python` file target | A new clone works with one command | The first `make check` takes longer |
| e2e: the local Compose run was blocked for the agent by the permission system | **User checks it** (`make up`, the four endpoints, `make down`) at checkpoint A | No workaround of a permission block | One more manual step |
| Simplifier 1, 2, 3, 4, 6, 7, 9 (reuse `assert_denied`, drop name-built topic and rule locals, table-driven policy fixtures, one trigger-test helper, one base-line regex, `require_env`, trims) and rule order | **Fix now** (senior clean-code standard) | One definition per idea; fewer lines to maintain | A broader diff in a fix round |
| Simplifier 5: workflow self-tests on a YAML loader instead of `sed` ranges | **Defer to Phase 7**, before more workflows arrive | This PR stays reviewable | The brittle ranges stay one more phase |
| Simplifier 8, 10: rule 7 scope, `create_trail`, a shared `env_trust` local | **Keep** | ADR 0004 per-module intent and Q2 stay as decided | A few repeated lines |
| Re-check R1 (reviewer, Medium): `aws:RequestedRegion` could lock every role out if the key did not resolve on this unauthenticated call | **Keep and prove at the checkpoint**: A4 (the PR plan job assumes the plan role after A2) is the go or no-go; rollback is reverting the condition and re-applying bootstrap | Closes the M1 detection gap at no cost; it fails closed, never open | A wrong guess costs one admin re-apply |
| Re-check R2, R5, R3, R4 and security L1 residual: awk `-v` mangled patterns, rule 9 without a space, the venv target touched the interpreter, the mask never reached the log, and string/heredoc/comment tricks against rules 11 and 12 | **Fix (round 2)**: patterns through `ENVIRON`, fixtures for each form, a `.venv-ci/.installed` stamp, a mask in each caller, and `tf-resolved-sources.sh` after `init` (checks what Terraform resolved, not the text) | Fails closed whatever the HCL looks like | One more script in `tf-check` |
| Security residual M1: refused probes in other regions still send no alert | **Accept**, recorded in PROGRESS | They grant nothing | Probing outside the region stays silent |

## Checkpoint A commands (the user runs these; Claude never does, NFR-9)

Placeholders: `<DEV_ACCOUNT_ID>` (the orchestrator fills it from `CLAUDE.local.md`) and `<PR_A>`. Commands are one per line for zsh; never pack several arguments into one shell variable (lessons log 37).

**A0. Read the `job_workflow_ref` claim before changing the trust.** Web UI: Actions > oidc-smoke-test > Run workflow > branch `phase-6-supply-chain`. Expect in the N1 log:

- `Token job_workflow_ref: trungleviet-agilityio/ship-it-safely/.github/workflows/oidc-smoke-test.yml@refs/heads/phase-6-supply-chain`;
- three refusals (plan, apply, deploy).

If the claim is empty or shaped differently, **stop**: do not apply bootstrap, and report it (S2 fallback).

**A1. Existing trails (Q2)**

```bash
aws sso login --profile sis-dev-admin
AWS_PROFILE=sis-dev-admin aws cloudtrail describe-trails --query 'trailList[].[Name,IsMultiRegionTrail,HomeRegion]' --output text
# expect empty; if a trail is listed, report it before step A2
```

**A2. Bootstrap re-apply from the PR branch**

```bash
git switch phase-6-supply-chain && git pull
AWS_PROFILE=sis-dev-admin terraform -chdir=infra/terraform/bootstrap init -backend-config="bucket=sis-dev-tfstate-<DEV_ACCOUNT_ID>-ap-southeast-1-an"
AWS_PROFILE=sis-dev-admin terraform -chdir=infra/terraform/bootstrap plan -var-file=accounts/dev.tfvars -out=bootstrap.tfplan
# expect: about 12 to add, 4 to change (aws_iam_role.plan, aws_iam_role.apply, aws_iam_role.deploy for the trust; aws_iam_policy.guardrails for G6), 0 to destroy
AWS_PROFILE=sis-dev-admin terraform -chdir=infra/terraform/bootstrap apply bootstrap.tfplan
rm infra/terraform/bootstrap/bootstrap.tfplan
AWS_PROFILE=sis-dev-admin aws iam get-role --role-name sis-dev-gha-apply --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition.StringEquals' --output json | sed -E 's/[0-9]{12}/<acct>/g'
# expect job_workflow_ref with terraform-iac.yml and terraform-destroy.yml at refs/heads/main, and no workflow key
```

**A3. Confirm the alert subscription.** Open the email "AWS Notification - Subscription Confirmation" and click Confirm. Then:

```bash
AWS_PROFILE=sis-dev-admin aws sns list-subscriptions-by-topic --region ap-southeast-1 --topic-arn arn:aws:sns:ap-southeast-1:<DEV_ACCOUNT_ID>:sis-dev-security-alerts --query 'Subscriptions[].SubscriptionArn' --output text | grep -vc PendingConfirmation
# expect 1
```

**A4. PR checks**

```bash
gh pr checks <PR_A> --repo trungleviet-agilityio/ship-it-safely --watch
# repo-guard guard, terraform-iac checks/plan/comment, oidc-smoke-test (N8, N9) green; plan comment shows alb_http[0], no CIDR
```

**A4 is the go or no-go for the region pin (verify R1).** If the plan job fails with AccessDenied after A2, revert the `aws:RequestedRegion` condition in `oidc.tf` on the branch and re-apply bootstrap, then report it.

**A5. Alerts fire on the negative tests.** Web UI: re-run the `oidc-smoke-test` PR job (after A2). Expect 3 to 5 emails within about 15 minutes. Then confirm the field the rule matches:

```bash
AWS_PROFILE=sis-dev-admin aws cloudtrail lookup-events --region ap-southeast-1 --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity --max-results 6 --query 'Events[].CloudTrailEvent' --output text | jq -r '[.userIdentity.type, .userIdentity.userName, (.errorCode // "ok")] | @tsv'
# expect WebIdentityUser, the sub in userName, AccessDenied rows for apply/deploy, a duration error row, ok rows for the plan role
```

**A6. Q1 and the egress list for PR B.** For the latest runs of terraform-iac `plan`, `plan-role-guardrails` and `apply`, terraform-destroy `destroy`, app-deploy `deploy`, and both oidc-smoke-test jobs:

1. Open each job's harden-runner insights link in a logged-out browser.
2. Search for `<DEV_ACCOUNT_ID>` and report found or not found (Q1).
3. Copy the Network Events destinations per job, replacing the account ID with `<acct>`, and paste them to the orchestrator.

**A7. Merge and prove the file-pinned trust live.** Web UI: Squash and merge, then:

1. Approve the `terraform-iac` push apply. It re-creates the stack and proves the apply trust.
2. Set the secret: `V="$(openssl rand -hex 24)"; AWS_PROFILE=sis-dev-admin aws secretsmanager put-secret-value --region ap-southeast-1 --secret-id sis/dev/app-api-key --secret-string "$V" --query VersionId --output text; unset V`.
3. Run `app-deploy` and approve it. This proves the deploy trust.
4. Check: `ALB="$(AWS_PROFILE=sis-dev-admin aws elbv2 describe-load-balancers --region ap-southeast-1 --names sis-dev-alb --query 'LoadBalancers[0].DNSName' --output text)"; curl -fsS "http://${ALB}/version"; echo`.
5. Optional (S10): Settings > Secrets and variables > Actions > New repository secret `ALB_INGRESS_CIDRS_DEV` = `["<your IP>/32"]` (`curl -s https://checkip.amazonaws.com`). Run `terraform-iac` with Run workflow and approve. `curl` works from your laptop and times out from a phone on mobile data.
6. Run `terraform-destroy` (`destroy-dev`) and approve. This proves the destroy trust. Expect the heading `### Destroyed (dev)`.

**A8. Required status check (S16, user setting).** Settings > Rules > Rulesets > the `main` ruleset > Require status checks to pass > Add checks > `guard (no AWS)` (source GitHub Actions) > Save. Do **not** enable "Require review from Code Owners" (Q6).

**A9. Push protection (NFR-6)**

```bash
gh api repos/trungleviet-agilityio/ship-it-safely --jq '.security_and_analysis | {secret_scanning: .secret_scanning.status, push_protection: .secret_scanning_push_protection.status}'
# expect both "enabled"; if the token cannot read it, check Settings > Advanced Security in the web UI
```

**A10. Dependabot.** Web UI: Insights > Dependency graph > Dependabot shows the four ecosystems checked without errors. On the first PRs:

- an actions PR keeps `# vX.Y.Z` comments;
- a docker PR changes the one `FROM ... AS base` digest;
- a pre-commit PR keeps `# frozen:` comments (Q4);
- a terraform PR keeps both platforms. Check with `git fetch origin <branch> && git show origin/<branch>:infra/terraform/envs/dev/.terraform.lock.hcl | grep -c 'h1:'`, which must equal the count on `main`.

To plan a Terraform Dependabot PR: `gh pr checkout <N> && git switch -c deps/terraform-<date> && git push -u origin HEAD`, then open a PR from that branch, read its plan comment, merge it, and close the Dependabot PR.

**A11. Base-image fallback (S21), locally**

```bash
PYTHON_IMAGE_MIRRORS="docker.io/library/python" BUILD_RETRY_DELAYS=0 make image
# expect "built ... (base from docker.io/library/python)"
```

**A12. Local Compose (FR-1, blocked for the e2e agent):** `make up`, then open `/`, `/health`, `/version` and `/admin` (expect 401 without the key) on http://localhost:8080, then `make down`.

## Checkpoint A results (2026-10-27)

| Step | Result |
|---|---|
| A0 | The token carries `job_workflow_ref` = `<repo>/.github/workflows/oidc-smoke-test.yml@refs/pull/21/merge`, the form the trust pins |
| A1 | No trail in the account, so `create_trail = true` (the first trail is free) |
| A2 | Bootstrap plan and apply: 12 added, 4 changed (three role trusts and the guardrails policy) |
| A3 | SNS subscription confirmed (1 subscription) |
| A4 | Go: the PR plan job assumed `sis-dev-gha-plan` after A2, so `aws:RequestedRegion` resolves on `AssumeRoleWithWebIdentity`. N8 `AccessDenied` on apply and deploy; N9 refused 3601 s and printed the 900 s expiry |
| A5 | `lookup-events` shows `WebIdentityUser` with the `sub` in `userName`. The alert email for the refused apply assume arrived (raw event JSON, sent to the private budget inbox) |
| A6 | Insights need any GitHub login; the plan job lists the state bucket host, which holds the account ID. Egress per job is below |
| A7 | Merged at 07:18. Apply 27 (session `gha-apply-<run>`), secret set, deploy from the `FROM` line (no fallback), `/version` = `main` SHA by digest, destroy 27 with revision 10 deregistered and no account ID in the log |
| A8 | `guard (no AWS)` is a required check (ruleset API: `required_status_checks`, GitHub Actions source) |
| A9 | Secret scanning and push protection enabled |
| A10 | Four update jobs ran without failure; one PR, #22, moves the single `FROM ... AS base` line to Python 3.15 (CI green). Actions, Terraform and pre-commit had nothing newer |
| A11 | Verified locally before the PR (Docker Hub fallback by `--build-context`) |
| A12 | `make up`: `/`, `/health`, `/version` 200, `/admin` 401 without the key; `make down` |

Egress seen at A6 (audit mode), the input for the PR B allowlists. `<acct>` marks a host that holds the account
ID; PR B writes those from a secret expression, never as text:

| Job | Hosts |
|---|---|
| repo-guard | `github.com`, `pypi.org`, `files.pythonhosted.org`, `proxy.golang.org`, `storage.googleapis.com` |
| terraform-iac `plan` | `github.com`, `api.github.com`, `releases.hashicorp.com`, `release-assets.githubusercontent.com`, `checkpoint-api.hashicorp.com`, `registry.terraform.io`, `sts.ap-southeast-1.amazonaws.com`, the state bucket host (`<acct>`) |
| terraform-iac `plan-role-guardrails` | `github.com`, STS, Secrets Manager and EC2 endpoints in `ap-southeast-1` |
| oidc-smoke-test | `github.com`, STS in `ap-southeast-1` |
| Image checks | `tuf-repo-cdn.sigstore.dev` (signature verification) |

Not captured: the apply, deploy and destroy jobs. PR B starts them from the plan list plus the services each one
calls, and checkpoint B reads the blocked hosts from the logs.

Decisions taken at the checkpoint (same delegation as the decision log):

| Finding | Decision | Pro | Con |
|---|---|---|---|
| #22 jumps the runtime from Python 3.13 to 3.15 | **Do not merge.** PR B adds a Dependabot `ignore` on `version-update:semver-minor` and `semver-major` for the python image, so only digest and patch updates arrive; close #22 | Security rebuilds stay automatic; a runtime change stays a planned change across `mise.toml`, `pyproject.toml` and the image | Moving to a new Python is manual |
| Insights hold the account ID behind any GitHub login (Q1) | **Turn telemetry off** (`disable-telemetry: true`) on the jobs that hold AWS credentials in PR B; keep audit insights on credential-free jobs | No account-bearing host leaves through a third party | No insights page for those jobs; blocked hosts are read from the job log |
| The alert email is raw JSON | **Optional in PR B**: an EventBridge input transformer that sends one line (event, role, `sub`, error) | Readable at a glance | One more bootstrap apply; the raw event is still in CloudTrail |
| No Dependabot PR for actions, Terraform or pre-commit | **Accept**; the user checks the Dependabot tab for ecosystem errors before PR B merges | Pins were already current | Q4 and R17 stay unproven until the first real update |

## Checkpoint B results (2026-10-27)

| Step | Result |
|---|---|
| 1 | PR #24: `plan`, `plan-role-guardrails` and `assume-plan-role` green in block mode. Nothing needed `api.github.com`; the OIDC token endpoint is implicit |
| 2 | harden-runner wrote no job summary with telemetry off (`Error fetching job summary: TypeError: fetch failed` in the post step), so no account-bearing host reaches a summary (reviewer M2 closed) |
| 3 | After the merge: apply 27 added in block mode. The first deploy started with the apply and stopped at Preflight ("the dev stack is not up", N4 as designed). After the secret value, the re-run deployed: artifact download (implicit, reviewer M1 closed), ECR push to the account registry, rollout green; `/version` = `87cd3c0` by digest `sha256:7ace86d1...`. Destroy 27 and revision 12 deregistered. No blocked host and no account ID in any log |
| 4 | No host was blocked, so no allowlist change |
| 5 | Dependabot logged "Ignored versions: semver-minor, semver-major" for `docker/library/python` and closed #22. That run failed on an ECR Public 429 (anonymous quota), not on the config |

Not observed: which of the `deploy` hosts the ECR layer upload used (no blocked host, telemetry off). The list
stays as built; a later block names any missing one.

## Checkpoint B (after PR B)

1. `gh pr checks <PR_B> --repo trungleviet-agilityio/ship-it-safely --watch`. The `plan`, `plan-role-guardrails` and both oidc-smoke-test jobs are green in block mode. This proves the token endpoint is implicit and that nothing needs `api.github.com`.
2. On the PR's `plan` run, open the Job summary and search for `tfstate-` and `.dkr.ecr.` (reviewer M2): report whether harden-runner's summary shows an account-bearing host.
3. Merge. Then approve the apply, set the secret, deploy and destroy as in A7 steps 1 to 6. All green. On the `deploy` log, copy the harden-runner lines that name implicit or blocked hosts (artifact download, ECR layer upload; security L3).
4. A blocked host fails a job with the host in the log: report it, and the fix is a short PR that adds it.
5. Close Dependabot #22 (the ignore now keeps Python on 3.13); the next monthly run must not reopen it.

## Sources

- IAM condition keys, GitHub OIDC claims (`job_workflow_ref`, immutable IDs): https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_iam-condition-keys.html
- GitHub OIDC reference (claims, `job_workflow_ref` for reusable workflows): https://docs.github.com/en/actions/reference/security/oidc
- GitHub OIDC concepts (example payload): https://docs.github.com/en/actions/concepts/security/openid-connect
- harden-runner inputs at the current release: https://raw.githubusercontent.com/step-security/harden-runner/main/action.yml
- harden-runner releases: https://api.github.com/repos/step-security/harden-runner/releases?per_page=5
- harden-runner README (tiers): https://github.com/step-security/harden-runner
- StepSecurity workflow runs (allowed-endpoints format, wildcards, disable-telemetry): https://docs.stepsecurity.io/github-actions/harden-runner/workflow-runs
- StepSecurity restricting endpoints: https://docs.stepsecurity.io/start-here/guides/how-to-restrict-network-connections-to-explicitly-allowed-endpoints
- Dependabot options reference: https://docs.github.com/en/code-security/reference/supply-chain-security/dependabot-options-reference
- Dependabot for actions: https://docs.github.com/en/code-security/how-tos/secure-your-supply-chain/secure-your-dependencies/keeping-your-actions-up-to-date-with-dependabot
- dependabot-core Docker parser: https://raw.githubusercontent.com/dependabot/dependabot-core/main/docker/lib/dependabot/docker/file_parser.rb
- docker buildx build `--build-context`: https://docs.docker.com/reference/cli/docker/buildx/build/
- Compose file name: https://docs.docker.com/compose/intro/compose-application-model/
- CloudTrail pricing: https://aws.amazon.com/cloudtrail/pricing/
- CloudWatch pricing: https://aws.amazon.com/cloudwatch/pricing/
- EventBridge pricing: https://aws.amazon.com/eventbridge/pricing/
- EventBridge CloudTrail events (trail required): https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-service-event-cloudtrail.html
- EventBridge read-only management events: https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-service-event-cloudtrail-management.html
- EventBridge pattern operators: https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-create-pattern-operators.html
- EventBridge SNS target permissions: https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-use-resource-based.html
- IAM and STS in CloudTrail (`readOnly`, web identity `userIdentity`, regional logging): https://docs.aws.amazon.com/IAM/latest/UserGuide/cloudtrail-integration.html
- CloudTrail S3 bucket policy: https://docs.aws.amazon.com/awscloudtrail/latest/userguide/create-s3-bucket-policy-for-cloudtrail.html
- STS AssumeRoleWithWebIdentity (`DurationSeconds`): https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRoleWithWebIdentity.html
- Provider v6.70.0 `aws_cloudwatch_event_rule`: https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/v6.70.0/website/docs/r/cloudwatch_event_rule.html.markdown
- Rulesets (code owners, status checks, bypass): https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets
- Authors cannot approve their own PRs: https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/reviewing-changes-in-pull-requests/approving-a-pull-request-with-required-reviews
- Google shell style guide (libraries): https://google.github.io/styleguide/shellguide.html
- Terraform CLI config (`disable_checkpoint`): https://developer.hashicorp.com/terraform/cli/config/config-file
- Latest releases (current pins confirmed):
  - https://api.github.com/repos/actions/checkout/releases/latest (v7.0.1)
  - https://api.github.com/repos/aws-actions/configure-aws-credentials/releases/latest (v6.3.0)
  - https://api.github.com/repos/actions/upload-artifact/releases/latest (v7.0.2)
  - https://api.github.com/repos/actions/download-artifact/releases/latest (v8.0.2)
- Seen in search results only (not opened, not relied on): https://dev.classmethod.jp/articles/aws-sts-oidc-github-google-circleci-oci/ and https://blog.stepsecurity.io/stepsecurity-harden-runner-now-supports-wildcard-domains-in-block-mode-d3148c42715f

## Build briefs

### devops-engineer (owns `infra/**`, `.github/**`, `.tflint.hcl`, `.pre-commit-config.yaml`, `Makefile`, `scripts/**`, `.editorconfig`, `.gitignore`)

**Goal:** PR A is S1, S2, S5, S8 to S13, S15, S17 to S19, the Makefile part of S20, the `build-image.sh` part of S21, and S29 to S38. PR B is S39 to S41, and only after the orchestrator passes on the A6 egress list.

**Rules:**
- Do not edit `README.md`, `docs/**`, `PLAN.md`, `CLAUDE.md`, `plugins/**`, `.claude/**` or `app/**`.
- Never run `terraform apply`, `destroy`, `import` or `state`, `gh secret`, `gh variable`, `gh workflow run`, or a merge.
- Write workflow and script files with Write or Edit, not Bash heredocs (lessons log 23).
- Branch with `git switch -c <new> phase-6-supply-chain` (lessons log 25).

**Verify pins and versions before use (NFR-3).** No new actions in PR A or PR B. If anything below differs, stop and report.

```bash
git ls-remote https://github.com/step-security/harden-runner 'refs/tags/v2.22.2*'           # dc2769abcc0fcfbadfc1df54081c1608579ef6b2
git ls-remote https://github.com/actions/checkout 'refs/tags/v7.0.1*'                      # 3d3c42e5aac5ba805825da76410c181273ba90b1
git ls-remote https://github.com/aws-actions/configure-aws-credentials 'refs/tags/v6.3.0*' # e1253824e5c10ff9df46874f81ed3ec929e19cfd
grep -n '^pyyaml==6.0.3' scripts/ci-requirements.txt
```

**Tests first (red, then green)**

1. **`trust.tftest.hcl`.**
   - apply `job_workflow_ref` is exactly `["trungleviet-agilityio/ship-it-safely/.github/workflows/terraform-iac.yml@refs/heads/main", "trungleviet-agilityio/ship-it-safely/.github/workflows/terraform-destroy.yml@refs/heads/main"]` (as a set); deploy is exactly the `app-deploy.yml` one;
   - no role has a `workflow` condition; plan has no `job_workflow_ref`;
   - `only_documented_condition_keys` allows exactly `aud, sub, repository_id, repository_owner_id, ref, job_workflow_ref`;
   - no `*` in `job_workflow_ref` values;
   - `local.workflow_files` equals the contract map.
2. **New `monitoring.tftest.hcl`** (mock provider, values from mock data):
   - the trail is multi-region, includes global events, has log file validation, no `cloud_watch_logs_*` and no `kms_key_id`;
   - the bucket has public access block, `BucketOwnerEnforced`, SSE-S3 and 30-day expiry;
   - the bucket policy actions are exactly `s3:GetBucketAcl` and `s3:PutObject`, the principal is `cloudtrail.amazonaws.com`, and both statements carry `aws:SourceArn` equal to the trail ARN;
   - the `PutObject` resource ends with `AWSLogs/<the mock account ID>/*` (use the mock data value, never a literal 12-digit number: the account-ID hook refuses it), with `s3:x-amz-acl`;
   - the rule `state == "ENABLED_WITH_ALL_CLOUDTRAIL_MANAGEMENT_EVENTS"`; `jsondecode(event_pattern)` has `eventName == ["AssumeRoleWithWebIdentity"]`, an `$or` with `errorCode exists` and an `anything-but` equal to the distinct trust subs;
   - the topic policy allows only `sns:Publish` for `events.amazonaws.com` with `aws:SourceArn` equal to the rule ARN;
   - the subscription is `email` to `var.budget_email`;
   - `create_trail = false` creates no trail and no trail bucket, and still creates the rule (Q2).
3. **`iam.tftest.hcl`.** `G6DenyAuditTampering` is a Deny and covers exactly the S28 actions and resources. The no-broad-allow and B20 tests still pass: the new wildcards are Deny only.
4. **`app_ecs.tftest.hcl`.**
   - Two CIDRs give `alb_http[0]` and `alb_http[1]` with those `cidr_ipv4` values;
   - no description contains a CIDR;
   - an invalid CIDR fails validation.
   - In `envs/dev`: `alb_ingress_cidrs_json = ""` gives `["0.0.0.0/0"]`; `"[\"198.51.100.7/32\"]"` decodes; `"not json"` and `"[\"::/0\"]"` fail validation.
5. **`tf-policy-selftest.sh`** fixtures. Each must fail with its rule ID:
   - `provisioner local-exec {`, `provisioner "local-exec" {`, `data external x {`, `data "external" "x" {`;
   - a `main.tf.json`;
   - `module "x" { source = "git::https://example.com/m.git" }` and `source = "terraform-aws-modules/vpc/aws"`.
   These must pass: `module "x" { source = "../../modules/app-ecs" }` and a `required_providers` `source = "hashicorp/aws"`.
6. **`workflow_triggers.py`** via `check-workflow-triggers.sh` (selftest `workflows.sh`; copy the `.py` into the temp repo next to `lib.sh`). These must fail: a multi-line flow list containing `pull_request_target`; `? pull_request_target` as an explicit key; an anchor or alias that expands to `workflow_run`; quoted `"on":` with `issue_comment`; a file with both `on:` and `true:`; duplicate `on:` keys; a file with no `on`; a non-mapping document. All real workflows pass. A missing `yaml` module fails with "run make venv".
7. **`assert-web-identity-denied.sh` and `assert-session-cap.sh`**, with stub `curl` and `aws`:
   - AccessDenied for every role passes;
   - success on any role fails "trust too broad";
   - a network error fails "not a role refusal";
   - output never contains the stub account or the token;
   - a 3601 refusal with "DurationSeconds" passes; a 3601 success fails;
   - the 900-second expiry line is printed without credentials.
   `jwt_claim` decodes padded and unpadded payloads.
8. **`mask-cidrs.sh`:** empty input prints only the notice; a two-element list prints exactly two `::add-mask::` lines; non-JSON fails.
9. **`tf-destroy-report.sh`:** one case per heading (deleted, apply failed, nothing, did not finish), plus `DEREGISTERED` unset giving "not known".
10. **`build-image.sh`** (stub `docker`):
    - the first attempt has no `--build-context`;
    - after a refusal, the mirror attempt passes `--build-context base=docker-image://docker.io/library/python:3.13-slim@sha256:<digest from Dockerfile>`;
    - a Dockerfile without exactly one `FROM ... AS base` with a 64-hex digest fails.
11. **Mode guard** (`tooling.sh`): `git ls-files -s` gives 100644 for `scripts/lib.sh` and `scripts/selftest/common.sh` and 100755 for every other `scripts/*.sh` and `scripts/selftest/*.sh`.
12. **Pin guard** (`workflows.sh`, S1), plus a mutation test with an `@v4` copy. **File parity** (S38), plus a mutation test with an unknown file name in a copy of `locals.tf`.
13. **Scratchpad check:** run zizmor (`pre-commit run zizmor --all-files`) and actionlint on `.github/dependabot.yml` and the edited workflows. Report any `dependabot-cooldown` or similar finding; do not add ignores.

**Files:** as in "File layout (PR A)", excluding `app/**`.

- `Makefile`:
  - `venv: ## Hash-locked CI venv (.venv-ci) for pre-commit and the YAML trigger check` as one line calling `scripts/ci-venv.sh .venv-ci`;
  - `up` and `down` use `app/compose.yaml`;
  - no other targets.
- `repo-guard` uses `scripts/ci-venv.sh "$RUNNER_TEMP/venv"` and adds that venv's `bin` to `GITHUB_PATH`.
- Add `scripts/mask-cidrs.sh` to the `terraform-iac` PR `paths`, and the new oidc scripts to `oidc-smoke-test` `paths` (the `check_paths` selftest enforces this).

**PR B files:** the four workflows' credentialed jobs (S39), and the selftest S40. Endpoints come only from the orchestrator's A6 list.

**Checks that define done**

- `make venv && make check` is green. `pre-commit run --all-files` passes, with zizmor clean and no ignores. `scripts/check-workflow-triggers.sh` passes.
- `terraform fmt -check -recursive infra/terraform`, `make tf-check` and `tflint --recursive` are clean. `terraform test` passes in `bootstrap`, `modules/app-ecs` and `envs/dev`.
- `git ls-files -s scripts/lib.sh scripts/selftest/common.sh` shows 100644.
- `grep -rn 'workflow_names\|:workflow"' infra/terraform/bootstrap` finds nothing.
- `grep -rn 'docker-compose' Makefile .github scripts` finds nothing.
- No account ID anywhere. `git status` shows no state files, plan files, tfvars, `.venv-ci` or scratch files.
- Commits (load `pr-conventions` first):
  - `infra(bootstrap): pin apply and deploy trust to the workflow file path`
  - `infra(bootstrap): cloudtrail trail and an alert on unexpected github oidc assumptions`
  - `infra(app-ecs): alb ingress from an optional secret, rules indexed not keyed by cidr`
  - `ci(workflows): negative oidc tests for apply, deploy and the session cap`
  - `ci(repo): dependabot, codeowners and editorconfig`
  - `fix(scripts): yaml parser trigger allowlist and stricter terraform policy`
  - `fix(scripts): destroy report states the real outcome`
  - `chore(scripts): libraries are not executable`
  - `build(scripts): base image fallback through a named build context`
  - PR B: `ci(workflows): harden-runner block mode with exact allowlists on credentialed jobs`
- Hand back the checkpoint A commands unchanged.

### backend-dev (owns `app/**`)

**Goal:** S20 and S21, both in PR A, merged together with the devops changes so that `make image` and CI keep working.

**Files**

- `app/Dockerfile`:
  - Remove `ARG PYTHON_IMAGE`.
  - Line 1 comment: "Base pinned by index digest in one literal FROM so Dependabot can bump it; scripts/build-image.sh can swap the registry with a named build context (ADR 0007 S21)."
  - `FROM public.ecr.aws/docker/library/python:3.13-slim@sha256:d98cc29d3266e535dd9da1099688d9cb3ca4753813571e071763d17725460962 AS base`, then `FROM base AS test` and `FROM base AS runtime`.
  - Everything else unchanged. No `# syntax=` line unless the build fails without one (CODING_STANDARDS); if it does, report it rather than adding one.
- `git mv app/docker-compose.yml app/compose.yaml`; no content change.
- `app/.dockerignore`: change line 8 from `docker-compose.yml` to `compose.yaml`.

**Tests first:** none new in Python. The checks are behavioural: `make test` passes; `make image`, then `make smoke`, passes, and so does the A11 fallback command.

**Checks that define done**

- `make test`, `hadolint app/Dockerfile` and `pre-commit run --all-files` are green.
- `grep -c '^FROM' app/Dockerfile` is 3, and exactly one `FROM` has `@sha256:`.
- `docker compose -f app/compose.yaml config` parses.
- Commit: `build(app): one literal base image stage and compose.yaml`.

### Orchestrator docs list (D14, after the merge)

See "Docs to update" in Consequences. The plugin and skill files that mention `docker-compose.yml` are the orchestrator's (they are outside both build lanes).
