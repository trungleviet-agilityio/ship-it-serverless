---
name: pr-conventions
description: Branch names, commit message format (Conventional Commits), PR title and description format, and the mandatory Pre-PR Checks (ruff, mypy, unittest, hadolint, terraform, tflint, actionlint, gitleaks) for the ship-it-safely lab. Load before committing, pushing, creating branches, or opening or reviewing PRs.
---

# PR Conventions

This is a solo lab: no ticket prefix, and Conventional Commits everywhere, including PR titles.

## Git workflow

**Default branch**: `main`. Trunk-based: short feature branch, PR into `main`, squash merge. No
`develop` or per-environment branches (FR-14).

- Never commit, push, or open a PR unless the user asks.
- Before committing: inspect `git status`, `git diff` and `git log --oneline -10`. Stage only the
  intended files. Never commit secrets, a real `.env`, `*.tfstate`, plan files, or `*.tfvars` with
  account IDs.
- Do not change git config, skip hooks (`--no-verify`), force-push, or create empty commits unless
  the user asks.
- If a hook rejects a commit, fix the cause and commit again. Do not amend the failed commit.
- Before opening a PR: review every commit in the PR (`git log main..HEAD`) and the full diff from
  the base (`git diff main...HEAD`), not just the latest commit.

### Branch names

| Work | Branch |
|---|---|
| A phase of the working plan | `phase-<n>-<slug>`, e.g. `phase-1-bootstrap-dev` |
| Anything else | `<type>/<slug>`, e.g. `chore/repo-conventions`, `fix/healthcheck-timeout` |

## Commit messages

Conventional Commits, checked by the `conventional-pre-commit` hook (`commit-msg` stage).

```
type(scope): subject
```

- **type**: required, lower-case, from the table below.
- **scope**: optional, lower-case, one short noun from the scope list. Pick the dominant area
  rather than joining two.
- **subject**: imperative ("add", not "added"), lower-case first letter, no trailing period.
- **header**: the whole first line, at most 100 characters.
- **body**: optional, after one blank line. Explain why, not what. Cite requirement IDs
  (`FR-8`, `NFR-3`) when the change implements or fixes one.
- **footer**: optional. `BREAKING CHANGE: ...` or `!` before the colon for breaking changes.
- Commits written by Claude end with the `Co-Authored-By` trailer the session gives.

### Types

| type | use for |
|---|---|
| `feat` | a new capability (app endpoint, Terraform module, workflow) |
| `fix` | a bug or security fix |
| `refactor` | behavior-preserving restructuring |
| `perf` | a change whose point is speed or cost |
| `test` | tests only (unittest, `terraform test`) |
| `docs` | `README.md`, `docs/`, `CLAUDE.md`, skills |
| `build` | `Dockerfile`, `compose.yaml`, `pyproject.toml` |
| `ci` | `.github/workflows/`, Dependabot |
| `infra` | `infra/terraform/**` |
| `chore` | repo tooling and maintenance (`.pre-commit-config.yaml`, `.tflint.hcl`, `.gitignore`, `Makefile`, `scripts/`) |
| `style` | formatting only |
| `revert` | reverting a previous commit |

### Scopes

`app`, `docker`, `bootstrap`, `app-ecs`, `envs`, `oidc`, `iam`, `ci`, `repo`, `adr`, `plugin`.
Add a new one only when none fits.

### Examples

```
feat(app): add /admin endpoint guarded by x-api-key
infra(bootstrap): add gha plan role trusted for pull_request only
ci(terraform): plan on pull request with the read-only role
fix(app-ecs): limit execution role to the one secret arn
chore(repo): pin ruff and mypy pre-commit hooks
```

Not valid:

```
Fix the healthcheck.                 # no type; capitalized; trailing period
feat: Added OIDC roles               # past tense; capitalized subject
feat(iam + ci): plan role            # two scopes
update stuff                         # no type; says nothing
```

## Pull requests

### Title

The PR title is a Conventional Commit header, same rules as above. PRs squash-merge, so the title
becomes the commit subject on `main`, and `main` history stays in one format.

```
feat(app): ship-it board with docker compose local env
infra(bootstrap): state bucket, oidc provider and gha roles
```

Exempt and not rewritten: Dependabot titles (`build(deps): ...`, `ci(deps): ...`).

### Description

Write it as a Minto pyramid: the conclusion first (what the PR does and anything the reviewer must
act on), then the key points that support it, then detail. A reviewer who stops after the first
section should know what to do. Pick headings that fit; there is no fixed template. For a phase
PR, include:

- the phase and the requirement IDs (`docs/requirements.md`) it covers,
- the verify result (which checks ran, open findings by severity),
- the commands the user still runs by hand at the checkpoint (`terraform apply`,
  `aws secretsmanager put-secret-value`, GitHub environment setup). Claude never runs them (NFR-9).

## Pre-PR checks

Run the checks for every area the PR touches and fix what fails. Do not open the PR until they
pass. Skip an area the PR does not touch.

| Area | Command |
|---|---|
| All of the below | `make check` (`make lint test tf-check`) |
| App lint | `uvx ruff check app` |
| App format | `uvx ruff format --check app` |
| App types | `uvx mypy` (strict, config in `pyproject.toml`) |
| App tests | `cd app && python3.13 -m unittest discover -s tests` |
| Dockerfile | `hadolint app/Dockerfile` |
| Terraform | `terraform fmt -check -recursive infra/terraform` |
| Terraform | `terraform init -backend=false && terraform validate` in each root and module |
| Terraform | `tflint --init && tflint --recursive` |
| Workflows | `actionlint` |
| Shell scripts | `make lint` (`shellcheck -x` on every `scripts/**/*.sh`) |
| Everything | `pre-commit run --all-files` (gitleaks, file checks, the hooks above) |

Use the tool versions pinned in `.pre-commit-config.yaml` when running them through `uvx`
(for example `uvx ruff@<version>`), so local results match the hooks.
