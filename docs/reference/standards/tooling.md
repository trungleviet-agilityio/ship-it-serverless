# Tooling standards

Tool versions, the `Makefile` and `scripts/`. Part of the [standards index](README.md); anything a linter enforces is not repeated.

## Tool versions (`mise.toml`)

- Every CLI the repo runs locally (Terraform, linters, scanners, pre-commit, uv) is pinned to an exact
  version in `mise.toml`, and `mise install` sets up a machine. Do not document `brew install` for
  them.
- CI installs the same versions as checksum-verified binaries (`scripts/ci/install-tools.sh`, sums in
  `scripts/ci/tools.sha256`), so local and CI results match (NFR-3). That includes crane, which copies images
  between registries by digest without Docker.
- Bump a version in its own `chore(repo)` commit and run `make check` before pushing.
- Python packages stay in `pyproject.toml` and run through `uv` / `uvx`, not mise.

## Makefile and shell scripts (`Makefile`, `scripts/`)

- The `Makefile` stays thin: each target is one or two lines and has a `## description` for
  `make help`. Anything longer goes in `scripts/<domain>/<name>.sh`. Never add `apply` or `destroy` targets
  (ADR 0001, D15).
- Targets must work with the GNU Make 3.81 that ships with macOS (no `.ONESHELL`, no
  `.SHELLFLAGS`).
- Scripts live in one folder per domain: `tf/`, `image/`, `lambda/`, `aws/`, `guard/` (workflow policy checks)
  and `ci/` (tool install, venv, self-test runner). Names drop the domain prefix (`scripts/tf/init.sh`).
  `scripts/lib.sh` holds shared functions; `scripts/names.sh <image|app|env-root|gha-role|role>` prints
  derived names; a one-line wrapper around a `lib.sh` function belongs in `names.sh`, not in a new file.
- Every name starts with the project prefix from `project.env` (`PROJECT_PREFIX` in `lib.sh`). Never write
  the prefix literally in a script or workflow; derive it (`names.sh`, `gha_role_name`, `state_bucket`). The
  few copies that cannot read the file are owned by `scripts/project.sh` (ADR 0011).
- Scripts start with `#!/usr/bin/env bash` and `source "$(dirname "$0")/../lib.sh"`, which sets
  `set -Eeuo pipefail`, `ROOT`, `log`/`ok`/`warn`/`die` and `require_cmd`. Messages go to stderr.
- Write for bash 3.2: no `mapfile`, no associative arrays, and never expand an empty array under
  `set -u`; check `${#arr[@]}` first.
- Use `terraform -chdir=<dir>` or a subshell instead of `cd` and back.
- When looping over many directories, collect failures, finish the loop, then print a summary and
  exit non-zero.
- `shellcheck -x` passes on every `scripts/**/*.sh` (run by `make lint`).
- Libraries (`scripts/lib.sh`, `scripts/selftest/common.sh`) are sourced and mode 100644; every other
  script is 100755 (a self-test checks both).
- When a check needs a real parser, write a small Python helper in `scripts/` (stdlib plus packages
  from the hash-locked `scripts/ci/requirements.txt`), run it with `python -I`, and keep the `.sh`
  file as the entry point (ADR 0007 S34). `make venv` creates `.venv-ci`.
- Terraform policy (`scripts/tf/policy.sh`): no `provisioner` and no `data "external"` in any
  quoting (rule 9), no `*.tf.json` (rule 10), and module sources under `envs/` and `modules/` are
  local paths only (rule 11), and providers are `hashicorp/*` only (rule 12). After `init`,
  `scripts/tf/resolved-sources.sh` checks what Terraform actually resolved (module sources in
  `modules.json`, providers in the lock file), so the text rules are fast feedback and the resolved
  check fails closed.
- Editors follow [`.editorconfig`](../../../.editorconfig).
