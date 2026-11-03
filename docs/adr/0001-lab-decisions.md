# ADR 0001: Lab decisions locked before Phase 0

- Status: accepted
- Date: 2026-10-22

## Context

`PLAN.md` (v2) leaves inputs open, and the agent team proposal (`sis-team`) was written before checking the
Claude Code plugin docs. This ADR locks both so every agent works from the same decisions.

## Decisions

| # | Decision | Why |
|---|---|---|
| D1 | Repo `trungleviet-agilityio/ship-it-safely`, **public** | On a free GitHub plan, environment required reviewers and secret scanning push protection are only free on public repos. FR-9, FR-12 and NFR-6 depend on them |
| D2 | No AWS account IDs in git. Bootstrap reads the account from `aws sts get-caller-identity` and checks it against `allowed_account_ids` passed as `TF_VAR_aws_account_id`; CI gets it from a GitHub environment variable | Account IDs are not secrets, but a public repo should not hand them out |
| D3 | Region `ap-southeast-1`, prefix `sis`, budget 20 USD/month | Closest region; matches the plan examples |
| D4 | App in Python 3.13 with the standard library only | Zero third-party dependencies: the supply-chain story stays about the pipeline, not the app |
| D5 | Tonight's target is Phase 0 to 3 (local app, bootstrap, OIDC smoke test, infra pipeline). Phase 4 if time allows | About 3 hours of work; Phase 1 and 3 need the AWS account |
| D6 | Agent team is a Claude Code plugin `sis-team` inside this repo (`plugins/sis-team/`), registered through a repo-local marketplace (`.claude-plugin/marketplace.json`) | Versioned with the lab, installable by teammates with one command, no separate repo yet |
| D7 | Plugin entry points are **skills** (`skills/plan`, `skills/run`, `skills/review`), not `commands/` | Plugin docs say to prefer `skills/` for new plugins; they are still invoked as `/sis-team:plan` etc. |
| D8 | Guardrails live in three layers: (1) no admin AWS credentials in the shell that runs Claude Code, (2) deny rules in `.claude/settings.json`, (3) a `PreToolUse` hook in the plugin (`scripts/guard.py`) | A plugin `settings.json` only applies `agent` and `subagentStatusLine`, so it cannot carry permission rules. Deny rules match command text and miss forms like `terraform -chdir=x apply`; the hook catches those with a regex. Layer 1 is the real boundary |
| D9 | Build agents (`backend-dev`, `devops-engineer`) use `isolation: worktree` and own disjoint paths: `app/**` vs `infra/**` and `.github/**` | Worktrees branch from the default branch, not from the session HEAD, so each phase must be committed to `main` before `/sis-team:run` |
| D10 | Verify agents never get `Write` or `Edit`. `reviewer`, `security-reviewer`, `code-simplifier` get `Read, Grep, Glob` only; `e2e` also gets `Bash` to run checks | A reviewer that can edit can "fix it to pass". `e2e` runs commands but cannot change files |
| D11 | `solution-architect` is read-only plus web; it returns the ADR text and the orchestrating session writes it to `docs/adr/` | Keeps the read-only rule absolute; no path-scoped write permission needed |
| D12 | `e2e` checks Terraform offline with `terraform init -backend=false`, `validate` and `terraform test` with `mock_provider`, not `terraform plan` | Agents have no AWS credentials (D8), so a real plan only runs in CI with the plan role |
| D13 | Model split: `security-reviewer` and `solution-architect` on opus; the rest on sonnet | The expensive model goes to trust policies and design, where a miss costs the most |
| D14 | The orchestrating session owns `README.md` and `docs/**`. `/sis-team:run` has a Docs step after the merge and before verify; `reviewer` checks docs drift against the code | The README spans app and infra, so either build agent editing it would break disjoint ownership (D9) and conflict at merge. The orchestrator already holds the ADR and the merged diff, so a separate writer agent would only re-read them |
| D15 | A thin `Makefile` is the single entry point for local checks (`help`, `up`, `down`, `test`, `lint`, `tf-check`, `check`); logic longer than a couple of lines goes in `scripts/*.sh` sharing `scripts/lib.sh`. No `apply`/`destroy` targets. `devops-engineer` owns both | `make help` makes the commands discoverable, and CI calls the same targets, so local and CI results match. Make is poor at arguments and loops, so it stays thin. Leaving out apply keeps D8 intact: a convenience target would bypass the checkpoint |
| D16 | Every Terraform root and module has a `README.md`: hand-written purpose, usage and run steps, plus inputs, outputs and resources tables that `terraform-docs` (`.terraform-docs.yml`, `terraform_docs` pre-commit hook) writes between `BEGIN_TF_DOCS` / `END_TF_DOCS` markers. `make tf-check` fails on a missing README or marker. READMEs inside `infra/**` belong to `devops-engineer`; the repo `README.md` and `docs/**` stay with the orchestrator (D14), and the repo README only links to them. Roots stay thin; modules never declare `provider` or `backend` | A README next to the code is where a reader looks first, and it changes in the same commit as the code. Generated tables cannot drift from `variables.tf` / `outputs.tf`; the prose explains what the tables cannot. Splitting ownership by path keeps D9's disjoint lanes |

## Consequences

- Every phase ends with a commit on `main` (or a merged PR) before the next `/sis-team:run`.
- `terraform apply`, `destroy` and `aws secretsmanager put-secret-value` are always run by the user at checkpoints.
- `README.md` and `docs/**` change in their own `docs(...)` commit inside each phase branch.
- Open inputs: dev account ID and budget email, asked for at Phase 1.
