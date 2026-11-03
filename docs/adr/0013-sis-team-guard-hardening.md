# ADR 0013: sis-team guard blocks GitHub writes, pushes to main and secret file reads

- Status: accepted
- Date: 2026-11-03
- Amends: ADR 0001 D8 (guardrail layers 2 and 3)

## Context

The guard hook (`plugins/sis-team/scripts/guard.py`) and the deny rules in `.claude/settings.json` blocked
Terraform state changes, Secrets Manager values, IAM writes and `gh secret set`. A review of super-board, an
autonomous board runner for Claude Code (github.com/EricTechPro/super-board, MIT), showed gaps that its own
suggested allowlist would open, and that are open here too:

- The `gh` CLI in the Claude shell signs in as the owner. `gh api -X POST .../actions/runs/<id>/pending_deployments`
  approves a gated environment deployment as the owner, which runs `terraform-iac` apply or `app-deploy` with the
  OIDC roles. `gh api` can also write secrets, variables, environments and rulesets, so the `gh secret set` deny
  rule was easy to get around.
- `gh pr merge`, `gh workflow run` and `git push origin main` start the same deployments. The `main` ruleset and
  the environment reviewers stop most of this on GitHub's side, but they are the last layer, not the only one.
- Read rules covered `app/.env` and `*.tfstate` only. Plan files, account tfvars, backend configs, `.terraform/`
  data dirs and `~/.aws/` were readable.

## Decision

| # | Decision |
|---|---|
| G1 | The guard blocks `gh pr merge`, `gh workflow run\|enable\|disable`, `gh run rerun\|cancel`, `gh secret\|variable set\|delete`, `gh repo edit\|delete\|archive\|rename`, `gh auth login\|refresh\|token`, `gh project delete\|close\|field-delete`. The owner merges, dispatches and approves |
| G2 | `gh api` is read-only for Claude: a call is blocked when its method is not `GET`, when it sends fields (`-f`, `-F`, `--input`) without `-X GET`, or when it is a GraphQL `mutation` |
| G3 | `git push` is blocked when it would update `main` or `master` (explicit refspec, `HEAD` or a bare push while on `main`) or rewrite history (`--force`, `-f`, `+refspec`, `--mirror`, `--all`, `--delete`). `--force-with-lease` to a feature branch stays allowed for rebases |
| G4 | Secret files are blocked for `Read`, `Grep` and inside Bash commands: `.env` (not `.env.example`), `*.tfstate*`, plan files, `*.tfvars.json`, `*.auto.tfvars`, `bootstrap/accounts/*.tfvars`, `*.tfbackend`, `.terraform/` and `.terraform-<env>/` data dirs, `~/.aws/`, `~/.ssh/`, `*.pem`, SSH keys. The committed `envs/*/terraform.tfvars` and every `*.example` stay readable. The list follows `.gitignore` |
| G5 | `.claude/settings.json` gets matching deny rules (layer 2); the hook stays the layer that catches other spellings (layer 3) |
| G6 | `plugins/sis-team/scripts/test_guard.py` tests every blocked and allowed form. It runs in `make lint` and in the `guard` job of `repo-guard.yml`, which the `main` ruleset requires |
| G7 | The hook keeps running under the system `python3` (3.9 on macOS), standard library only |

Not adopted from super-board: its unattended build loop, auto-merge gate, model router and installer. They
conflict with the checkpoint rule (NFR-9) and the version pinning rule (NFR-3). The full review is in the
maintainer's notes.

## Consequences

- A blocked call prints the reason; Claude prints the command for the owner instead, as for `terraform apply`.
- Claude can still read GitHub (`gh pr view`, `gh run view --log`, `gh api` GETs), push feature branches and open
  PRs.
- Copying `app/.env.example` to `app/.env` goes through `make up`, not a Claude Bash call.
- The same change lands in ship-it-safely as a narrow exception to ADR 0010 T8 (guard and deny rules only).
