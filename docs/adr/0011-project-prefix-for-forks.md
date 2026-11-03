# ADR 0011: One project prefix in project.env, so the lab forks as a template

- Status: accepted
- Date: 2026-11-02
- Amends: ADR 0001 D3 (prefix `sis`); ADR 0010 T8 (reuse by fork)

## Context

ADR 0010 T8 makes this repo the template for the next app: reuse happens by fork. Every AWS name is
`<prefix>-<env>-<thing>` (ADR 0002), but the prefix `sis` was written out in about ten places: `scripts/lib.sh`
(app names, role ARN, image name), `scripts/tf/init.sh` (state bucket), the role name passed to
`aws/check-config.sh` in five workflow steps, the dev repository in `app-promote.yml`, the role check in
`oidc-smoke-test.yml`, the harden-runner allowlists, Terraform defaults and tfvars, and `app/compose.yaml`. A fork
that misses one copy fails at the first credentialed step (a role name or bucket host that does not exist) or,
worse, checks a role against the wrong name.

## Decision

| # | Decision |
|---|---|
| R1 | `project.env` at the repo root holds `PREFIX=<prefix>`, the one value a fork changes. Same rule as Terraform: `^[a-z][a-z0-9]{1,9}$` |
| R2 | Scripts read it once, in `lib.sh` (`PROJECT_PREFIX`). Names derive from helpers: `app_names`, `gha_role_name`, `state_bucket`, `image_name`. `PROJECT_PREFIX` in the environment wins only so the self-tests can pin their fixture prefix |
| R3 | Workflows never spell a role or repository name: `aws/check-config.sh` takes the role kind (`plan`, `apply`, `deploy`) and derives the name from `ENV`; `names.sh gha-role` and `names.sh app` serve inline steps |
| R4 | Copies that cannot run a script stay literal: the bootstrap `prefix` default, `envs/*/terraform.tfvars`, the state bucket host in harden-runner allowlists (read before checkout, and the policy allows no new expression there, ADR 0007 S45), and the compose image. `scripts/project.sh check` (in `make lint`) fails when one differs; `make set-prefix PREFIX=<new>` rewrites them all |
| R5 | Tests do not depend on the committed prefix: bootstrap tests pin `prefix = "sis"` as a fixture, env root tests assert through `var.prefix`, shell self-tests export `PROJECT_PREFIX=sis` |
| R6 | The prefix is set once, in a fresh fork, before the first bootstrap. Changing it on a live project names new resources; nothing in AWS is renamed |

## Consequences

- Forking for a new product: `make set-prefix PREFIX=<new>`, replace `app/` (keep the contract: one port, a health
  path, `/version` with SHA and digest), then bootstrap each account as in the README.
- Docs, ADRs and diagrams keep `sis` as history; they are not copies.
- The `sis-team` plugin keeps its name (frozen by ADR 0010 T8); a fork renames it if it wants to.
