# CI/CD standards

GitHub Actions workflows (`.github/workflows/`) and local actions (`.github/actions/`). Part of the
[standards index](README.md); anything a linter enforces is not repeated.

## Naming

What people see in the Actions tab is the `name:`, not the file. File names are IDs: the apply, deploy and
destroy role trusts pin them (`job_workflow_ref`, bootstrap `workflow_files`), so renaming a file needs a
bootstrap re-apply (ADR 0007 S2). Change display names instead.

| Item | Rule | Example |
|---|---|---|
| File | kebab-case, `<domain>-<action>.yml`; reusable files `reusable-*.yml` | `app-deploy.yml`, `reusable-terraform-plan.yml` |
| Workflow `name:` | Title Case, domain first, so the sidebar groups by domain | `App Deploy`, `Terraform Destroy` |
| `run-name:` | On workflows that change AWS state: what, where, who | `Deploy main to dev by <actor>` |
| Job id | kebab-case, stable: callers, `needs:` and self-tests use it | `build-scan`, `plan-dev` |
| Job `name:` | lower-case `verb (target)`, short; a literal env in parentheses, never an expression | `deploy (dev)`, `plan (prod)`, `apply` |
| Step `name:` | Sentence case, imperative | `Assume the deploy role` |

- No notes in job names ("no AWS", "approval required"): the job's `permissions:`, `environment:` and a
  comment say that. A self-test in `scripts/selftest/workflows.sh` enforces the workflow and job name rules,
  including no expression in a job name.
- A required status check matches a job name (`guard`; a reusable job shows as `<caller name> / <job name>`).
  Renaming such a job is also a change to the `main` ruleset, made in the same window as the merge.
- A job name never holds an expression: GitHub shows a skipped job's name unevaluated
  (`apply (${{ inputs.env }})`), and apply runs are skipped on every pull request. A job whose env comes from an
  input has a plain name (`apply`, `destroy`); the `run-name:` carries the env.
- `run-name:` may use `inputs`, `github.ref_name`, `github.actor` and PR numbers. It is display text, never
  run by a shell.

## Supply chain

- Every third-party action is pinned to a full commit SHA with the version in a comment (NFR-3).
  Tool binaries are pinned by version and checksum-verified.
- Prefer the runner's AWS CLI over third-party actions for steps that hold credentials; install scanners as
  checksum-verified binaries, never through their actions.
- Never use `pull_request_target`. zizmor (pre-commit) must pass with no global disables. Two inline ignores are
  allowed, each on the one line it covers: `# zizmor: ignore[self-repository]` on a local `uses: ./...` line
  (actionlint rejects the `$/` form zizmor asks for; a self-test requires the comment), and
  `# zizmor: ignore[github-env]` on the composite step that writes the validated `TF_DIR`.
- Images are single-platform `linux/amd64`, built once, pushed once by an immutable git-SHA tag, and deployed by
  digest. Never print the registry host, image URI or any ARN with the account ID.

## Runner hardening

- `step-security/harden-runner` is the first step of every job (NFR-4). Set `egress-policy`
  explicitly. A job with `id-token: write` uses `block`, `disable-telemetry: true`,
  `disable-sudo-and-containers: true` (only app-deploy `deploy` is exempt: it runs Docker) and
  `allowed-endpoints` with one exact `host:port` per line: no `*`, and no expression other than
  `vars.AWS_REGION`, `secrets.AWS_ACCOUNT_ID` and `env.ENV` (only app-promote `promote` may also use
  `secrets.AWS_ACCOUNT_ID_DEV`, for the source registry host). Jobs without credentials never name a secret
  in their endpoints, in any letter case, and an `env` value they reach is clean only as a literal or built from
  `vars.X` and other clean `env.X` (anything else, including multi-line expressions, taints it). Such a job has
  no `container:` or `services:`, and its harden-runner step has no `if:` or `continue-on-error:`. Every other job
  uses `audit`. `scripts/guard/harden-runner.sh` enforces all of this.
- Pin `runs-on` to a versioned label (`ubuntu-24.04`), not `ubuntu-latest`.
- Set `timeout-minutes` on every job. Jobs that hold AWS credentials stay below the 60-minute role session
  (NFR-7), so a stuck job fails while it can still release a lock.

## Permissions and credentials

- `permissions:` at workflow level is `{}` or read-only; each job grants what it needs.
  `id-token: write` only on jobs that assume a role (NFR-2).
- No `actions/checkout` and no `contents: read` unless the job needs repo files.
- Never store AWS access keys (NFR-1). Values that contain the account ID (role ARNs) are GitHub
  **secrets**, because variables print unmasked in public logs; names and the region are
  **variables** (ADR 0003 C10). Set `mask-aws-account-id: true` on `configure-aws-credentials`.
- Jobs that need an OIDC token skip fork and Dependabot PRs, which get none:
  `github.event.pull_request.head.repo.full_name == github.repository` and
  `github.event.pull_request.user.login != 'dependabot[bot]'` (not `github.actor`, which zizmor
  flags as spoofable).
- Steps that run third-party or build code (build, tests, scanners) never share a job with `id-token: write`,
  an `environment:` or secrets: GitHub permissions are per job, not per step. Hand results to the credentialed
  job as an artifact whose checksum is verified before use (ADR 0005, H1 decision).
- Never interpolate `${{ github.event.* }}` or other user-controlled values directly in `run:`.
  Pass them through `env:` and quote them in the shell.

## Environments

- PR plan jobs do not set `environment:` (the OIDC `sub` must be `pull_request`); apply, deploy
  and destroy jobs do.
- Environment jobs read secrets with env-agnostic names (`AWS_ACCOUNT_ID`) and take the env from
  `inputs.env`, validated by `scripts/names.sh env-root` before any credential step. PR plan jobs have no
  environment, so they read repo secrets suffixed with the env (`AWS_ACCOUNT_ID_DEV`). The one cross-env mapping is
  `PROMOTION_TARGET_ACCOUNT_ID` from `AWS_ACCOUNT_ID_<TARGET>` in the caller of an env that sets
  `promotion_target_env` (the parity guard checks it).

## Structure and reuse

- Reusable workflows are named `reusable-*.yml`, have `on: workflow_call` and nothing else, and are the only
  files with that trigger. Callers pass each secret by name, never `secrets: inherit`. A job that assumes a
  role on `main` (apply, deploy, destroy) stays in a top-level file, because the role trust pins that file
  (`job_workflow_ref`).
- The composite assumes the role in exactly one `aws-actions/configure-aws-credentials` step, after the root
  select and the CIDR mask (a self-test pins the order).
- Steps repeated by several Terraform jobs live in the local composite action
  `.github/actions/terraform-setup` (root, tools, config check, CIDR mask, role, init). harden-runner and
  checkout stay job steps, and each job keeps its own `allowed-endpoints`.
- Workflow steps stay short: logic longer than a few lines lives in `scripts/` with a usage line and a
  case in `scripts/selftest/<area>.sh` (run by `scripts/ci/selftest.sh`), so it can run and be tested outside CI.

## Terraform and state

- Workflows that run Terraform set `CHECKPOINT_DISABLE: "1"`.
- One concurrency group per Terraform state (`terraform-envs-<env>`), shared by every job that writes that
  state; never cancel in progress. Do not use `queue:` until actionlint accepts it. Set `concurrency` on every
  workflow that changes AWS state.
- **Destructive workflows** run on `workflow_dispatch` only. A typed confirmation is checked in a job with
  no credentials before the approval is requested; the credentialed job plans the destroy, refuses any action
  other than delete, and applies that same saved plan in the same job (ADR 0006).
