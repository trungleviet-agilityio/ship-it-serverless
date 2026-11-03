# ship-it-safely

Lab: ship a small containerized app to AWS ECS Fargate through GitHub Actions + Terraform, with OIDC, least
privilege and supply-chain hardening. `docs/requirements.md` is the requirements source (goal, scope, `FR-*`,
`NFR-*`); `docs/adr/` holds locked decisions (read `0001-lab-decisions.md` first). The phase plan and the
progress tracker are the maintainer's working notes, kept outside the repo; their paths are in `CLAUDE.local.md`.

## Rules

- Work one phase of the working plan at a time and stop at every **Checkpoint** with the exact commands for the
  user. After a checkpoint, update the progress note (outside the repo), never a file in the repo.
- Never add `PLAN.md`, `PROGRESS.md` or another copy of the working notes to the repo (`.gitignore` refuses them).
- Never run `terraform apply`, `terraform destroy`, `terraform import`, `terraform state rm|mv|push`,
  `aws secretsmanager put-secret-value|get-secret-value`, or `aws iam create-access-key`. Prepare the command;
  the user runs it (NFR-9). Guardrails: `.claude/settings.json` deny rules and the `sis-team` guard hook.
- This shell has no AWS credentials on purpose. Do not ask for them or export a profile.
- Never commit secrets, a real `.env`, `*.tfstate`, `*.tfvars` holding account IDs, or plan files.
- Look up current versions and commit SHAs for actions and tools; never guess them (NFR-3).
- Follow `docs/reference/standards/` (one file per domain: application, Terraform, CI/CD, tooling; index in its `README.md`).
- Run checks through `make` (`make help`): `make check` runs everything a PR must pass. No `apply` or `destroy`
  targets, ever.
- Load the `pr-conventions` skill before committing, branching or opening a PR. It holds the commit and PR title
  format (Conventional Commits, `infra` type for Terraform) and the Pre-PR Checks: ruff, mypy, unittest,
  hadolint, `terraform fmt`/`validate`, `tflint`, `actionlint`, `pre-commit run --all-files`.
- Other project skills: `checkpoint-commands` (before printing any command the user runs), `pin-versions`
  (before adding or bumping an action, tool, hook, base image or provider), `ci-triage` (when a run fails).
- Commit per phase, e.g. `infra(app-ecs): fargate service with secrets manager injection`.
- Trunk-based: short feature branch, PR into `main`, squash merge. No `develop` branch.

## Agent team

The `sis-team` plugin (`plugins/sis-team/`) provides `/sis-team:plan <phase>`, `/sis-team:run <phase>`,
`/sis-team:close <phase> [checkpoint]` (records checkpoint results and opens the docs PR) and `/sis-team:review`, plus `/sis-team:team` (roster table) and `/sis-team:diagram <topic>` (diagrams in
`docs/diagrams/`). Build agents work in their own worktree and own disjoint paths:

| Agent | Owns |
|---|---|
| `backend-dev` | `app/**` |
| `devops-engineer` | `infra/**`, `.github/**`, repo tooling (`.tflint.hcl`, `.pre-commit-config.yaml`, `Makefile`, `scripts/**`) |

The orchestrating session (the one running `/sis-team:run`) owns the repo `README.md` and `docs/**`: it writes
ADRs from the architect's text and updates the docs after the merge. Build agents never edit them (ADR 0001, D14).
READMEs inside `infra/**` (one per Terraform root and module) belong to `devops-engineer` (D16).

Verify agents (`e2e`, `reviewer`, `security-reviewer`, `code-simplifier`) never edit files; `reviewer` also checks docs drift.
