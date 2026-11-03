# ship-it-serverless

Lab: ship a small web app to AWS Lambda as a **Lambda Web Function** through GitHub Actions + Terraform, with
OIDC, least privilege and supply-chain hardening. The same container image runs in compose, CI and Lambda (Lambda
Web Adapter); an API Gateway HTTP API calls alias `live`; releases publish a version by digest, then move the alias
(all at once or canary); rollback moves it back. Dev and prod accounts, promote by digest. Prefix `sls`
(`project.env`).

Sources of truth: `docs/requirements.md` (`FR-*`, `NFR-*`), `docs/adr/` (start with `0001` and `0012`),
`docs/tradeoffs.md`, `docs/reference/standards/`. The phase plan and progress note live outside the repo; their
paths are in `CLAUDE.local.md`.

## Rules

- One phase at a time. Stop at every **Checkpoint** with the exact commands for the user; afterwards update the
  progress note outside the repo. Never add `PLAN.md`, `PROGRESS.md` or a copy of the working notes.
- Never run `terraform apply|destroy|import`, `terraform state rm|mv|push`,
  `aws secretsmanager put-secret-value|get-secret-value` or `aws iam create-access-key`. Prepare the command; the
  user runs it (NFR-9).
- Never merge a PR, run or rerun a workflow, approve a deployment, write through `gh api`, or push to `main`.
  Push a feature branch and open a PR; the owner merges and approves (ADR 0013).
- This shell has no AWS credentials on purpose. Do not ask for them or export a profile.
- Never commit secrets, a real `.env`, `*.tfstate`, `*.tfvars` holding account IDs, or plan files.
- Look up versions, SHAs and digests; never guess them (NFR-3).
- `make check` is what a PR must pass, `make verify` builds and scans the image. No `apply` or `destroy` targets.
- Trunk-based: short feature branch, PR into `main`, squash merge. Conventional Commits, `infra` type for Terraform.
- Every decision records its options with pros and cons (ADR plus `docs/tradeoffs.md`). An accepted risk is
  written as accepted, never as "cannot happen".

The hard limits are enforced by `.claude/settings.json` deny rules and the `sis-team` guard hook, not by this file.
Path rules in `.claude/rules/` load with the files they cover.

## Skills

| Load | When |
|---|---|
| `pr-conventions` | Before a branch, commit, push or PR (format and the Pre-PR Checks) |
| `checkpoint-commands` | Before printing any command the user runs |
| `pin-versions` | Before adding or bumping an action, tool, hook, base image or provider |
| `ci-triage` | When a run fails, a check is red or AWS says AccessDenied |

## Agent team

`/sis-team:plan <phase>` (ADR first), `/sis-team:run <phase>` (build, merge, verify, stop at the checkpoint),
`/sis-team:close <phase> [checkpoint]`, `/sis-team:review [PR]`, `/sis-team:team`, `/sis-team:diagram <topic>`.

| Owner | Paths |
|---|---|
| `backend-dev` | `app/**` |
| `devops-engineer` | `infra/**`, `.github/**`, `Makefile`, `scripts/**`, `.tflint.hcl`, `.pre-commit-config.yaml`, READMEs inside `infra/**` |
| Orchestrating session | `README.md`, `docs/**`, `CLAUDE.md`, `.claude/**`, `plugins/**` |

Verify agents (`e2e`, `reviewer`, `security-reviewer`, `code-simplifier`) never edit files.
