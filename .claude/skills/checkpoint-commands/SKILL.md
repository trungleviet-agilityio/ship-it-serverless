---
name: checkpoint-commands
description: How to write the commands the user runs by hand at a ship-it-safely checkpoint (terraform apply and destroy, secret values, SSO, GitHub settings, workflow dispatches, teardown checks). Load before printing any command for the user to run, in chat, an ADR checkpoint section or a PR description.
---

# Checkpoint commands

Claude never runs `terraform apply|destroy|import|state`, `aws secretsmanager put-secret-value|get-secret-value`
or `aws iam create-access-key` (NFR-9). It prints them, the user runs them. Each rule below comes from a real
failure in the lessons log; follow all of them.

## Shape of one command

- One command per fenced `bash` block, then a line `Expect: ...` with the exact output or count to compare.
- **Self-contained:** each command works in a fresh zsh. Put the profile and region inline
  (`AWS_PROFILE=sis-dev-admin AWS_REGION=ap-southeast-1 aws ...`). Never rely on an earlier `export`, `cd` or
  shell variable.
- Paths are relative to the repo root and use `terraform -chdir=...`. Say "from the repo root" once.
- Never pack several arguments into one shell variable (zsh does not word-split). Use env vars or write them out.
- Keep lines short enough not to wrap in a terminal; split a long pipeline into two commands.
- When the account ID is allowed in commands (CLAUDE.local.md), print the real value, never `<DEV_ACCOUNT_ID>`.
  In committed files (ADR, README, PR body), always use the placeholder.

## Secrets

- Generate and store a secret value in **one** line, in the user's own terminal, and print only the name:
  `--secret-string "$(openssl rand -hex 24)" --query Name --output text`. Never generate in one command and use
  it in another.
- `gh secret set NAME --env <env>` prompts for the value; never put the value on the command line.

## Order and waits

- Start with `aws sso login --profile <profile>` when the step needs the admin profile.
- The stack order is always: `terraform-iac` apply, then the secret value, then approve `app-deploy`.
  When a merge starts both workflows, say to approve **only** the apply first.
- Before merging an infra PR during a teardown window, say that the merge starts an apply to reject.
- Long waits (`aws ecs wait`, `--watch`) go in the user's own terminal, not a `!` command.
- When a shared trust or IAM local changes, update the expected plan counts in `Expect:`.

## GitHub

- Workflow dispatch and re-run: the web UI (Actions > workflow > Run workflow / Re-run failed jobs). The PAT has
  Actions read-only, so `gh run rerun` and `gh workflow run` fail.
- A typed confirmation goes in **bold** with the exact text, e.g. type **destroy-dev**.
- Check token scopes with a read call before a settings step; offer the web UI as a fallback.
- After creating a ruleset, read back `conditions.ref_name.include`.

## Teardown checks

Prove deletion per service, never with the Resource Groups Tagging API (it lags and keeps INACTIVE task
definitions). Give one command each for: `ec2 describe-vpcs` (by `tag:Project`), `elbv2 describe-load-balancers`
(expect `LoadBalancerNotFound`), `ecs describe-clusters`, `ecr describe-repositories`,
`secretsmanager list-secrets`, and `ecs list-task-definitions --status ACTIVE` (expect empty).

## Writing them

The plugin guard hook scans the whole Bash command line, so never echo or heredoc these commands through Bash.
Write them with the Write or Edit tool, or into a `--body-file`. Do not put the trigger words in a PR title.
