# Engineering standards

Current-state conventions for this lab, one file per domain. Anything a linter already enforces is not
repeated. `make check` and the Pre-PR Checks in `.claude/skills/pr-conventions/SKILL.md` verify them.

[`docs/requirements.md`](../../requirements.md) holds the requirements, `docs/adr/` the locked decisions. When a standard and an ADR disagree, the ADR
wins; update the standard in the same PR.

| File | Covers | Paths |
|---|---|---|
| [`application.md`](application.md) | Python, the Dockerfile, the Fargate runtime | `app/` |
| [`terraform.md`](terraform.md) | Layout, READMEs, naming, IAM, secrets and state, tests | `infra/terraform/` |
| [`ci-cd.md`](ci-cd.md) | Naming, supply chain, runner hardening, credentials, environments, reuse | `.github/` |
| [`tooling.md`](tooling.md) | Tool versions, the `Makefile`, shell and Python helper scripts | `mise.toml`, `Makefile`, `scripts/` |

Commit and PR format live in the `pr-conventions` skill, not here.

## Rules for every domain

- No secrets and no account IDs in committed files, logs or names (ADR 0001, D2). Account IDs live in
  gitignored files and in the commands printed for the user.
- Pin every external dependency to an exact version or digest and look it up, never guess it (NFR-3).
- A rule that can be checked is checked by a script with a self-test, not left to review.
- A comment records a contract, an invariant or a reason the code cannot show.
