# ADR 0003: Phase 2 OIDC smoke test

- Status: accepted
- Date: 2026-10-23

## Context

PLAN.md Phase 2 adds the first workflow in the repo, `.github/workflows/oidc-smoke-test.yml`. It assumes the dev plan role (`sis-dev-gha-plan`) through GitHub OIDC and runs `aws sts get-caller-identity`. The phase is done when the PR run prints the plan role's assumed-role ARN. `.github/workflows/` holds only `.gitkeep` today.

Requirements covered:

| ID | What Phase 2 must deliver |
|---|---|
| Phase 2.1 | `oidc-smoke-test.yml` assumes the plan role and runs `aws sts get-caller-identity` |
| Phase 2.2 | Done when the PR run prints the plan role's assumed-role ARN |
| NFR-1 | No AWS access keys in GitHub. The role ARN comes from GitHub configuration, never from access keys |
| NFR-2 | `permissions: {}` at workflow level. `id-token: write` only on jobs that assume a role |
| NFR-3 | Every action pinned to a full commit SHA with the version in a comment. Tool versions looked up and pinned |
| NFR-4 | `step-security/harden-runner` is the first step of every job, in `audit` mode |
| NFR-6 | gitleaks pre-commit already exists. The checkpoint confirms secret scanning and push protection are on |

Constraints carried over:

- ADR 0001: D1 (public repo, so Actions logs are public), D2 (no account ID in git), D14 (orchestrator owns `README.md` and `docs/**`), D15 (Makefile front door).
- ADR 0002:
  - B12/B13: the plan role trusts only `aud = sts.amazonaws.com`, `sub = repo:trungleviet-agilityio@<owner_id>/ship-it-safely@<repo_id>:pull_request`, plus `repository_id` and `repository_owner_id`, all with `StringEquals`. `ref` is not pinned.
  - B23: repo-level `AWS_REGION`, `AWS_PLAN_ROLE_ARN_DEV`, `TF_STATE_BUCKET_DEV`, `AWS_ACCOUNT_ID_DEV`.
  - Consequences: set `mask-aws-account-id: true`; fork and Dependabot PRs cannot get an ID token.
  - Deferred Lows: L3 (a future `pull_request_target` workflow would match the plan role `sub`) and L5 (the account-ID hook scans only `infra/**`).

Findings from current docs that shape this ADR:

1. **Configuration variables are printed unmasked.** GitHub docs: "By default, variables render unmasked in your build outputs." The step log header of `configure-aws-credentials` echoes its `with:` inputs, so `role-to-assume: ${{ vars.AWS_PLAN_ROLE_ARN_DEV }}` would print the full role ARN, account ID included, in a public log. That happens before `mask-aws-account-id` can register the mask. The same applies to `env:` blocks in step headers. Secrets are redacted in those headers. (The header echo is how hosted runners render steps today. The checkpoint verifies it with a grep for the account ID.)
2. **`harden-runner` defaults to `egress-policy: block`** in its `action.yml` (v2.22.2). So `audit` must be set explicitly. In audit mode telemetry cannot be disabled (`disable-telemetry` needs `block`).
3. **`ubuntu-latest` is moving from 24.04 to 26.04** in a gradual rollout from 2026-10-19 to 2026-11-19, so today it can land on either image. Both images ship AWS CLI 2.37.13 (24.04 image 20261012.334.1, 26.04 image 20261012.163.1).
4. **Fork and Dependabot PRs.** GitHub turns write permissions into read for `pull_request` runs from forks. "Workflow runs triggered by Dependabot pull requests run as if they are from a forked repository." Secrets are not passed to either. So `id-token: write` cannot take effect, and the job must be skipped, not left to fail.
5. **`workflow_dispatch` gives a different `sub`.** A dispatched run has no `pull_request` in its `sub` (it is `...:ref:refs/heads/<branch>`). The plan role must refuse it. That makes a cheap, real negative test.
6. **zizmor's `dangerous-triggers` audit** (offline) flags `pull_request_target`, `workflow_run` and `issue_comment`. That closes L3 without a custom hook. Its `unpinned-uses` default requires hash pins on every action (NFR-3). Its `bot-conditions` audit flags `github.actor == 'dependabot[bot]'` as spoofable and recommends `github.event.pull_request.user.login`.
7. **Path-filtered workflows leave required checks "Pending"** when skipped. The smoke test must not become a required status check.

## Decision

### Workflow shape

| # | Decision | Why / source |
|---|---|---|
| C1 | One file, `.github/workflows/oidc-smoke-test.yml`, `name: oidc-smoke-test`. Delete `.github/workflows/.gitkeep`. | PLAN §6 layout |
| C2 | **Triggers:** `pull_request` with `branches: [main]` and `paths: [.github/workflows/oidc-smoke-test.yml]`, plus `workflow_dispatch` (no inputs), which runs only the negative job (C12). **Never `pull_request_target`.** Not `infra/**`: bootstrap trust changes are applied by hand after merge, so a PR run would test the old trust. From Phase 3, `terraform-iac.yml` exercises the plan role on every infra PR anyway. | Workflow syntax (paths); secure-use guidance against `pull_request_target` |
| C3 | **Skip fork and Dependabot PRs at job level:** `if: github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository && github.event.pull_request.user.login != 'dependabot[bot]'`. The run shows the job as skipped, not failed. A deleted fork has a null `head.repo`, which also skips. Spoofing this check gains nothing, because a fork or Dependabot run has no ID token or secrets either way. | Finding 4; GitHub Dependabot-automation docs use `github.event.pull_request.user.login`; zizmor `bot-conditions` |
| C4 | **Permissions:** workflow `permissions: {}`. Each job sets only `id-token: write`, with a comment explaining why. **No `contents: read`**, because no job checks out the repo (nothing in the job needs repo files). No `environment:` on any job, so the PR `sub` stays `:pull_request`. | NFR-2; GitHub OIDC reference ("Without `id-token: write`, the OIDC JWT ID token cannot be requested"); PLAN §5 note |
| C5 | **Runner and limits:** `runs-on: ubuntu-24.04` (pinned label, not `ubuntu-latest`). `timeout-minutes: 5` per job. `concurrency: { group: ${{ github.workflow }}-${{ github.ref }}, cancel-in-progress: true }`. The workflow changes no AWS state, so concurrency is only there to drop stale runs. Revisit `ubuntu-26.04` in Phase 6 together with harden-runner `block` mode. | Finding 3; CODING_STANDARDS (timeout on every job) |
| C6 | **Step 1 of every job:** `step-security/harden-runner@dc2769abcc0fcfbadfc1df54081c1608579ef6b2 # v2.22.2` with `egress-policy: audit` set explicitly. Expected egress: `sts.ap-southeast-1.amazonaws.com`, `token.actions.githubusercontent.com` (and the pipelines host behind `ACTIONS_ID_TOKEN_REQUEST_URL`), and StepSecurity's own endpoints. Phase 6 turns this into a `block` allowlist. | NFR-4; Finding 2; release v2.22.2 (2026-10-19) |
| C7 | **Step 2, "Check configuration":** reads `ROLE_ARN` from `secrets.AWS_PLAN_ROLE_ARN_DEV` (see C10) and `REGION` from `vars.AWS_REGION`, through `env:`. It fails with a `::error::` if either is empty, or if `ROLE_ARN` does not match `^arn:aws:iam::[0-9]{12}:role/sis-dev-gha-plan$`. It prints nothing but the pass/fail message. A missing value then fails with a clear message, not a vague STS error. | Requirement: "fail clearly if the variables are missing" |
| C8 | **Step 3:** `aws-actions/configure-aws-credentials@e1253824e5c10ff9df46874f81ed3ec929e19cfd # v6.3.0` (node24) with: `role-to-assume: ${{ secrets.AWS_PLAN_ROLE_ARN_DEV }}`, `aws-region: ${{ vars.AWS_REGION }}`, `role-session-name: gha-oidc-smoke-${{ github.run_id }}-${{ github.run_attempt }}` (well under STS's 64 characters; `[\w+=,.@-]` only), `mask-aws-account-id: true`, `retry-max-attempts: 3` (the default 12 with backoff would burn the 5-minute timeout on a trust error). `audience` is left at its default `sts.amazonaws.com` (B11). `role-duration-seconds` is left at its 3600 default (NFR-7). No `output-credentials`. | action.yml at the pinned SHA; STS `RoleSessionName` constraints |
| C9 | **Step 4, "Prove identity":** `aws --version`. Call `aws sts get-caller-identity --output json` once into a shell variable. Extract `Account` with `jq` and immediately `echo "::add-mask::$account"` (defense in depth if the action's mask ever regresses). Then: assert the ARN matches `^arn:aws:sts::[0-9]{12}:assumed-role/sis-dev-gha-plan/gha-oidc-smoke-`; assert the ARN's account equals the account inside `ROLE_ARN`; print the full ARN (shows as `arn:aws:sts::***:assumed-role/sis-dev-gha-plan/gha-oidc-smoke-<run>-<attempt>`). Write only the account-free part `assumed-role/sis-dev-gha-plan/<session>` to `$GITHUB_STEP_SUMMARY`, built with `${arn#*:assumed-role/}`. Never print the raw JSON before masking. No `${{ }}` expressions in `run:`; everything goes through `env:`. | Phase 2.2 done criterion; CODING_STANDARDS (no interpolation in `run:`); GitHub "Masking a value in a log" |
| C10 | **Where the role ARN lives (decision needs the user, Q1).** Recommended: store `AWS_PLAN_ROLE_ARN_DEV` as a **repository secret**, not a variable. `AWS_REGION` stays a variable. A secret is redacted in the step header (Finding 1), so the account ID never appears in the public log. The action and `::add-mask::` mask it in later output. This keeps the intent of NFR-1 (no AWS keys in GitHub; the ARN is not a credential). It deviates from NFR-1's literal "variables, not secrets" and from ADR 0002 B23, which this ADR amends for this one name. The same question will come back in Phase 3 for `AWS_APPLY_ROLE_ARN`, `AWS_DEPLOY_ROLE_ARN`, `AWS_ACCOUNT_ID(_DEV)` and `TF_STATE_BUCKET(_DEV)` (the bucket name holds the account ID, B8). **Fallback if the user declines:** swap `secrets.` for `vars.` in two places. The account ID then appears once per run in the configure step header, accepted as "not a secret" per AWS. | GitHub variables concept page; secrets docs; D2; ADR 0002 consequence on masking |
| C11 | **AWS CLI:** use the runner's preinstalled CLI (2.37.13 on both Ubuntu images today) and print `aws --version` in the log. Do not install a pinned CLI in Phase 2: one read-only `sts` call does not justify a download plus signature check. The runner image is versioned and its readme records the CLI version. Revisit in Phase 6 (NFR-3 checksum rule) only if a later workflow depends on CLI behavior. | runner-images Ubuntu2404 and Ubuntu2604 readmes |

### Negative test

| # | Decision | Why / source |
|---|---|---|
| C12 | **N1 (in Phase 2): the plan role refuses a non-PR token.** Second job `plan-role-denied-outside-pr`, `if: github.event_name == 'workflow_dispatch'`, same runner, timeout, permissions (`id-token: write`), harden-runner and C7 check. Its configure step has `id: assume`, `continue-on-error: true`, `disable-retry: true`, `mask-aws-account-id: true`, and session name `gha-oidc-negative-<run_id>-<attempt>`. A final step reads `steps.assume.outcome` through `env:`. It **fails the job if the outcome is `success`** ("plan role was assumed outside pull_request: trust too broad"). Otherwise it passes and prints the expected `sub` form (`repo:...:ref:<GITHUB_REF>`). No AWS calls follow. The C7 check runs first, so a missing secret cannot fake a pass. The user confirms the reason in the log (`Not authorized to perform sts:AssumeRoleWithWebIdentity`) and in CloudTrail (`errorCode AccessDenied`). `workflow_dispatch` only works once the file is on the default branch, so N1 runs after merge. **Amended in the Phase 2 fix rounds:** the configure action step was replaced by one shell step, because any failure (network, token fetch, wrong ARN) used to count as a refusal. The step masks the account from the secret, fetches the OIDC token itself, checks that its `sub` ends with `:ref:$GITHUB_REF`, calls `aws sts assume-role-with-web-identity --no-sign-request`, and passes only on an explicit `AccessDenied`. A success fails with "trust too broad", and any other error fails with the masked stderr. The call's exit code is captured with `|| rc=$?`, since the runner shell is `bash -eo pipefail`. STS returns the same AccessDenied for a well-formed but wrong ARN (other account, missing role). The user accepted this (2026-10-26) because the PR job asserts that the caller account equals the account inside `AWS_PLAN_ROLE_ARN_DEV` and that the caller is `sis-dev-gha-plan`; an N1 AccessDenied from the same, unchanged secret therefore comes from the dev plan role's trust. CloudTrail stays an optional cross-check. | Finding 5; events-that-trigger-workflows (`workflow_dispatch`); IAM CloudTrail page (unauthenticated `AssumeRoleWithWebIdentity` calls are logged) |
| C13 | **Not in Phase 2:** (a) a job with `environment: dev` on a PR branch. The `dev` environment's `main`-only branch policy and required reviewer stop it before any token is minted, so it tests GitHub, not the trust, and needs an approval. (b) Plan role `GetSecretValue` denied and plan role cannot create resources: PLAN Phase 3.4. (c) Cross-account denial: Phase 7.5. (d) A real fork PR: needs a second account. C3 is checked by reading the job condition. | Keep the phase small |

### Repo tooling (security Lows L3, L5)

| # | Decision | Why / source |
|---|---|---|
| C14 | **Add zizmor as a pre-commit hook:** `repo: https://github.com/zizmorcore/zizmor-pre-commit`, `rev: c92afdf2c6ca336aaa8f39e2bd8d48f62dbd8e1f # frozen: v1.31.1`, `id: zizmor`, default `regular` persona, no ignores. It closes **L3** through `dangerous-triggers`, and also checks `template-injection`, `excessive-permissions`, `unpinned-uses` (hash pins required everywhere) and `artipacked`. It runs offline unless a GitHub token is in the environment, and `make lint` runs it through `pre-commit run --all-files`, so no Makefile change. No separate `pull_request_target` grep hook: zizmor covers it, and an inline `# zizmor: ignore[...]` would be visible in review. zizmor is managed by pre-commit, not `mise.toml`. | zizmor docs (integrations, usage, audits); tag list for zizmor-pre-commit |
| C15 | **Widen the account-ID hook (closes L5)** to workflow files, with alphanumeric boundaries so a 40-character hex SHA pin cannot trip it. A digit run inside a SHA is bounded by letters. With the current digit-only boundaries, roughly 1 SHA in 70 would contain an isolated 12-digit run. New `entry`: `(?<![0-9A-Za-z])(?!123456789012)[0-9]{12}(?![0-9A-Za-z])`. New `files`: `^(infra/.*\.(tf\|hcl\|tfvars\.example)\|\.github/.*\.ya?ml)$` (unescaped `\|` in the real regex). Keep `exclude: \.terraform\.lock\.hcl$`. Rename the hook to "no bare 12-digit AWS account ID in infra or workflows". | L5; arithmetic on hex SHAs |
| C16 | **actionlint stays local** (`make lint` already runs it once a workflow exists; mise pins 1.7.12, still the latest release). No CI lint workflow in Phase 2. A "repo checks" workflow needs pinned, checksum-verified tool installs (NFR-3). That belongs in Phase 3 (FR-9 already runs fmt, validate and tflint in CI) or Phase 6. | D15; actionlint releases |
| C17 | **Dependabot for `github-actions` is deferred to Phase 6** (NFR-5). When it lands: set a `cooldown` (zizmor `dependabot-cooldown`) and remember that Dependabot PRs touching this file are skipped by C3. | PLAN Phase 6.3 |
| C18 | **The smoke test is not a required status check.** It is path-filtered, so it would block unrelated PRs in "Pending". | Finding 7 |

### Least privilege summary

| Item | Value | Wildcards |
|---|---|---|
| Role assumed | `sis-dev-gha-plan` only (no apply or deploy ARN appears in this workflow) | none added |
| Trust conditions | unchanged from B13: `aud`, `sub` `:pull_request`, `repository_id`, `repository_owner_id`, all `StringEquals` | none |
| Calls made | `sts:GetCallerIdentity` (needs no IAM permission) | none |
| GitHub token scopes | `id-token: write` per job; everything else `none` | none |
| IAM changes | none (no Terraform change in Phase 2) | none |

## Alternatives considered

- **`ubuntu-latest`.** It is mid-migration to 26.04 until 2026-11-19, so runs are not reproducible. Rejected for a pinned label.
- **Keep the ARN in a variable and pre-mask it.** Any step that reads a variable shows it in its own `env:` or script header before the mask exists. No ordering trick avoids the first exposure. Hence C10.
- **Print only the role or session part of the ARN.** Kept for the job summary, but the full masked ARN is still logged because Phase 2.2 asks for "the assumed-role ARN". Masking the account keeps it safe.
- **Install a pinned AWS CLI, or drop the CLI and use the action's `aws-account-id` output.** Installing is overkill for one call (C11). The output-only route fails Phase 2.1, which names `aws sts get-caller-identity`.
- **`allowed-account-ids` on the action.** Needs the account ID as one more input (one more secret, or a leak). The ARN pattern and same-account assertion in C9 give the same protection.
- **Run the smoke test on `infra/**` PRs too.** It would test the pre-apply trust and duplicate Phase 3's plan job. Rejected.
- **Negative test as a job on the PR with `environment: dev`.** Blocked by GitHub's branch policy and reviewer gate before STS is called, and needs approval (C13a).
- **A custom pygrep hook banning `pull_request_target`.** Smaller, but covers one issue. zizmor covers it and more for one pinned hook.
- **zizmor via `zizmorcore/zizmor-action` in CI with SARIF upload.** Needs `security-events: write` and a CI lint workflow. Deferred with C16.
- **Dependabot now.** Phase 6 owns it, and it adds PR noise before the pipelines exist.

## Consequences

- The PR that adds the workflow runs it: `pull_request` uses the workflow from the PR merge ref, and secrets reach same-repo branches. So the PR opened for this phase is itself the proof run.
- If Q1 is accepted, ADR 0002 B23 is amended: `AWS_PLAN_ROLE_ARN_DEV` becomes a repo secret. Phase 3 must decide the same for the other account-bearing values (role ARNs, account ID, state bucket). Environment-level secrets work for the `dev` jobs.
- harden-runner in `audit` sends run telemetry (network and process events) to StepSecurity, and the insights link is visible for a public repo. It contains endpoints, not the account ID. Accepted under NFR-4.
- Fork and Dependabot PRs that touch the workflow show a skipped job, not a red one.
- L3 and L5 from ADR 0002's security review were first only mitigated locally by C14 and C15 (pre-commit
  can be skipped). The user's decisions on 2026-10-26 close them on the server and in the repo:
  - **M1 / L3:** the plan role trust now also requires `StringLike ref = refs/pull/*/merge` (ADR 0002 B13
    amendment), so AWS refuses a `pull_request_target` run even though its `sub` matches. IAM has no
    `event_name` key, so that variant was dropped.
  - **M2 / L5:** the `no-aws-account-id` hook scans every text file (lock file excluded), allowing only
    `123456789012` and the PLAN.md placeholders, and `.gitignore` adds `*.tfbackend`
    (`!*.tfbackend.example`). Committed `envs/<env>/terraform.tfvars` stay allowed (FR-6) and are scanned.
  - **Low (N1 and a wrong ARN):** accepted, see C12.
- After Phase 3, this workflow becomes a rarely triggered diagnostic. Keep it: it re-proves OIDC in isolation when trust breaks, and N1 stays a one-command regression test for the plan role's `sub` pin.
- **Docs follow-up for the orchestrator (D14):**
  - README: add a Phase 2 section (what the smoke test proves, how to run N1, how to read CloudTrail), and note that the ARN is a secret if Q1 is accepted.
  - CODING_STANDARDS, GitHub Actions section, add:
    - pin `runs-on` to a versioned label;
    - set harden-runner `egress-policy` explicitly (its default is `block`);
    - no checkout and no `contents: read` unless the job needs repo files;
    - the fork/Dependabot skip condition using `github.event.pull_request.user.login`;
    - zizmor must pass;
    - (if Q1 is accepted) account-bearing values go in secrets, region and names in variables.
  - Mark ADR 0002 B23 "amended by ADR 0003 C10" if Q1 is accepted.
  - PLAN.md NFR-1 wording, if the orchestrator treats PLAN.md as a doc it owns.

## Open questions (resolved)

Answered by the user on 2026-10-23:

- **Q1.** Yes: `AWS_PLAN_ROLE_ARN_DEV` is a repository **secret**, not a variable. This amends ADR 0002 B23
  for this one name; `AWS_REGION` stays a variable.
- **Q2.** Keep the smoke test after Phase 3 as a diagnostic.

## Checkpoint steps (the user runs these; Claude never does, NFR-9)

Placeholders: `<DEV_ACCOUNT_ID>` from `CLAUDE.local.md`, `<PR>` the PR number. Prerequisite: the Phase 1 checkpoint (ADR 0002 steps 0 to 3) is finished, and `terraform output oidc_sub_prefix` matched GitHub's `sub_claim_prefix`.

**1. Set the role ARN and check repo security settings**

```bash
REPO=trungleviet-agilityio/ship-it-safely
export AWS_PROFILE=sis-dev-admin
cd infra/terraform/bootstrap

# Q1 = yes: secret from stdin (nothing in shell history). Remove the variable if it was already created.
terraform output -raw plan_role_arn | gh secret set AWS_PLAN_ROLE_ARN_DEV --repo "$REPO"
gh variable delete AWS_PLAN_ROLE_ARN_DEV --repo "$REPO" 2>/dev/null || true
# Q1 = no instead: gh variable set AWS_PLAN_ROLE_ARN_DEV --repo "$REPO" --body "$(terraform output -raw plan_role_arn)"

gh variable list --repo "$REPO"      # AWS_REGION = ap-southeast-1
gh secret list --repo "$REPO"        # AWS_PLAN_ROLE_ARN_DEV present (Q1 = yes)

# NFR-6: both must be "enabled"
gh api "repos/${REPO}" --jq '.security_and_analysis | {secret_scanning: .secret_scanning.status, push_protection: .secret_scanning_push_protection.status}'
```

**2. Read the PR run (the orchestrator pushes the branch and opens the PR; you read it)**

```bash
gh pr checks <PR> --repo "$REPO" --watch
RUN_ID="$(gh run list --repo "$REPO" --workflow oidc-smoke-test.yml --branch phase-2-oidc-smoke-test --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run view "$RUN_ID" --repo "$REPO" --log | grep 'assumed-role/sis-dev-gha-plan/'   # expect arn:aws:sts::***:assumed-role/sis-dev-gha-plan/gha-oidc-smoke-...
gh run view "$RUN_ID" --repo "$REPO" --log | grep -c '<DEV_ACCOUNT_ID>'              # expect 0
gh run view "$RUN_ID" --repo "$REPO" --log | grep 'aws-cli/'                          # CLI version for the record
```

Also open the job summary (account-free role/session line) and the harden-runner insights link, and note the egress endpoints for Phase 6.

**3. Cross-check in CloudTrail (admin, read-only; events can take a few minutes)**

```bash
aws cloudtrail lookup-events --region ap-southeast-1 \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --max-results 5 --output json \
  | jq -r '.Events[].CloudTrailEvent | fromjson
           | [.eventTime, (.errorCode // "OK"), .userIdentity.userName, .requestParameters.roleSessionName] | @tsv'
# expect: OK  repo:trungleviet-agilityio@<owner_id>/ship-it-safely@<repo_id>:pull_request  gha-oidc-smoke-...
```

**4. Merge, then run negative test N1 from `main`**

```bash
gh pr merge <PR> --repo "$REPO" --squash          # you merge; Claude never does
gh workflow run oidc-smoke-test.yml --repo "$REPO" --ref main
sleep 15
RUN_ID="$(gh run list --repo "$REPO" --workflow oidc-smoke-test.yml --event workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId')"
gh run watch "$RUN_ID" --repo "$REPO" --exit-status   # expect success (= denied as designed)
gh run view "$RUN_ID" --repo "$REPO" --log | grep 'Refused as designed (AccessDenied'   # printed only after a real denied call
# Re-run step 3: newest event shows errorCode AccessDenied and a sub ending in :ref:refs/heads/main
```

If step 2 fails at the assume step (for example AccessDenied in the configure-aws-credentials log), compare the token `sub` in CloudTrail (step 3) with `terraform output oidc_sub_prefix`. Fix the bootstrap, not the workflow.

## Sources

- GitHub OIDC reference: https://docs.github.com/en/actions/reference/security/oidc
- Workflow syntax (permissions, `permissions: {}`, fork and Dependabot permissions, paths, pending checks, concurrency): https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax
- Events that trigger workflows (`workflow_dispatch` on default branch): https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows
- Variables render unmasked: https://docs.github.com/en/actions/concepts/workflows-and-actions/variables
- Variables reference (precedence): https://docs.github.com/en/actions/reference/workflows-and-actions/variables
- Using secrets (forks, Dependabot, `::add-mask::`): https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets
- Secure use reference (redaction, `pull_request_target`): https://docs.github.com/en/actions/reference/security/secure-use
- Dependabot on Actions (read-only token, `github.actor` example): https://docs.github.com/en/code-security/dependabot/troubleshooting-dependabot/troubleshooting-dependabot-on-github-actions
- Automating Dependabot (`github.event.pull_request.user.login`): https://docs.github.com/en/code-security/dependabot/working-with-dependabot/automating-dependabot-with-github-actions
- REST get a repository (`security_and_analysis`): https://docs.github.com/en/rest/repos/repos#get-a-repository
- configure-aws-credentials v6.3.0 release: https://github.com/aws-actions/configure-aws-credentials/releases/tag/v6.3.0
- configure-aws-credentials action.yml at the pinned SHA: https://raw.githubusercontent.com/aws-actions/configure-aws-credentials/e1253824e5c10ff9df46874f81ed3ec929e19cfd/action.yml
- configure-aws-credentials README: https://raw.githubusercontent.com/aws-actions/configure-aws-credentials/main/README.md
- harden-runner v2.22.2 release: https://github.com/step-security/harden-runner/releases/tag/v2.22.2
- harden-runner action.yml at the pinned SHA (default `block`): https://raw.githubusercontent.com/step-security/harden-runner/dc2769abcc0fcfbadfc1df54081c1608579ef6b2/action.yml
- Runner images (labels): https://github.com/actions/runner-images
- Ubuntu 24.04 image readme (AWS CLI 2.37.13): https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md
- Ubuntu 26.04 image readme (AWS CLI 2.37.13): https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2604-Readme.md
- `ubuntu-latest` migration changelog: https://github.blog/changelog/2026-09-17-ubuntu-26-generally-available-and-latest-migration
- STS AssumeRoleWithWebIdentity (RoleSessionName, errors): https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRoleWithWebIdentity.html
- IAM and STS in CloudTrail (unauthenticated web identity calls logged, regional logging): https://docs.aws.amazon.com/IAM/latest/UserGuide/cloudtrail-integration.html
- zizmor usage (offline/online, exit codes): https://docs.zizmor.sh/usage/
- zizmor integrations (pre-commit repo and hook id): https://docs.zizmor.sh/integrations/
- zizmor audits (`dangerous-triggers`, `unpinned-uses`, `bot-conditions`): https://docs.zizmor.sh/audits/
- zizmor releases: https://github.com/zizmorcore/zizmor/releases
- zizmor-pre-commit tags (v1.31.1 = c92afdf2c6ca336aaa8f39e2bd8d48f62dbd8e1f): https://github.com/zizmorcore/zizmor-pre-commit/tags
- actionlint releases (1.7.12 latest): https://github.com/rhysd/actionlint/releases

## Build briefs

### devops-engineer (owns `.github/**`, `infra/**`, `.pre-commit-config.yaml`, `Makefile`, `scripts/**`)

**Goal:** implement C1 to C12, C14 and C15. Do not edit `README.md`, `docs/**`, `PLAN.md` or anything under `app/**`. No Terraform changes this phase. Write C10 for the recommended option (`secrets.AWS_PLAN_ROLE_ARN_DEV`). If the orchestrator relays Q1 = no, use `vars.AWS_PLAN_ROLE_ARN_DEV` in the same two places.

**Files**

- Create `.github/workflows/oidc-smoke-test.yml`; delete `.github/workflows/.gitkeep`.
- Edit `.pre-commit-config.yaml`:
  - add the zizmor hook (C14), placed after the local hooks, with the `# frozen: v1.31.1` comment style already used in the file;
  - change `no-aws-account-id` `entry`, `files` and `name` (C15).
- No change to `Makefile`, `mise.toml` or `scripts/**` (`make lint` already runs pre-commit and actionlint).

**Shape of the workflow (the SHAs are the load-bearing part):**

```yaml
name: oidc-smoke-test
on:
  pull_request:
    branches: [main]
    paths: [.github/workflows/oidc-smoke-test.yml]
  workflow_dispatch:
permissions: {}
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
jobs:
  assume-plan-role:            # C3 if:, C4 permissions, C5 runner/timeout
    steps:                     # C6 harden-runner, C7 check, C8 configure, C9 prove
  plan-role-denied-outside-pr: # C12, if: github.event_name == 'workflow_dispatch'
```

- `step-security/harden-runner@dc2769abcc0fcfbadfc1df54081c1608579ef6b2 # v2.22.2`
- `aws-actions/configure-aws-credentials@e1253824e5c10ff9df46874f81ed3ec929e19cfd # v6.3.0`

**Verify before use (NFR-3):** confirm each SHA is the tag's commit. For an annotated tag, use the peeled `^{}` line:

```bash
git ls-remote https://github.com/step-security/harden-runner 'refs/tags/v2.22.2*'
git ls-remote https://github.com/aws-actions/configure-aws-credentials 'refs/tags/v6.3.0*'
git ls-remote https://github.com/zizmorcore/zizmor-pre-commit 'refs/tags/v1.31.1*'
```

If any differs from this ADR, stop and report. Do not substitute.

**Tests first (red, then green)**

1. Write a throwaway bad workflow in the scratchpad, outside the repo, with `pull_request_target`, a tag-pinned `uses:`, workflow-level `id-token: write`, and `${{ github.event.pull_request.title }}` in `run:`. Confirm `zizmor --offline <file>` (via `uvx zizmor@1.31.1`) and `actionlint <file>` both fail on it.
2. Account-ID hook:
   - Stage a scratch copy at `.github/workflows/zz-test.yml` (never committed) containing an IAM ARN with any real-looking 12-digit account ID, built at test time. Confirm `pre-commit run no-aws-account-id --files .github/workflows/zz-test.yml` fails.
   - Replace the content with a `uses: x/y@a1234567890123b...` style 40-hex line holding a 12-digit run. Confirm it passes.
   - Confirm `123456789012` passes.
   - Delete the file.
3. Then write the real workflow until checks pass.

**Checks that define done**

- `actionlint` (with shellcheck on PATH via mise) is clean on `.github/workflows/oidc-smoke-test.yml`.
- `pre-commit run zizmor --all-files` reports no findings, with no `# zizmor: ignore` comments.
- `make check` is green: lint (including pre-commit, hadolint, shellcheck, actionlint), test, tf-check.
- Grep checks on the workflow:
  - no `pull_request_target`, no `environment:`, no `actions/checkout`, no `contents:` permission;
  - top-level `permissions: {}`; each job has `timeout-minutes` and only `id-token: write`;
  - every `uses:` is `owner/repo@<40 hex> # vX.Y.Z`;
  - no `${{` inside any `run:` block;
  - `egress-policy: audit` present in both jobs;
  - `mask-aws-account-id: true` in both configure steps;
  - `runs-on: ubuntu-24.04`.
- `git status` shows no `*.tfvars`, state, plan files or scratch workflow.
- Commit: `ci(workflows): oidc smoke test for the dev plan role`, then a second commit or the same PR for hooks: `chore(repo): zizmor hook and account-id guard for workflows` (follow the `pr-conventions` skill).
- Hand back the checkpoint steps from this ADR unchanged. Never run `terraform` against AWS, `gh secret set`, `gh variable set`, `gh workflow run` or a merge.

### backend-dev

Not needed in Phase 2.
