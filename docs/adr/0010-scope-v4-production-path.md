# ADR 0010: Scope v4, trim the remaining work to the production path

- Status: accepted
- Date: 2026-11-02
- Supersedes: the Phase 8 part of PLAN v3 (`docs/requirements.md`, Goal); amends ADR 0008 amendment S

## Context

- Phases 0 to 6 are done and proven live. Phase 7 PR A (env cloning) is done; PR B1 (#33, offline promote
  tooling) is open; PR B2 (prod) waits on the prod account (ADR 0008 Q1).
- Phase 8 (PR previews, ADR 0009 on #34, PR A on #35) is about 1,400 lines in review and needs a third role,
  a third GitHub environment and a `workflow_run` split (ADR 0009 amendment H).
- Goal now: one app reaches **production** through the pipeline, by digest, with rollback. The lab then becomes
  the template for the next app (English for Devs).

## Options

| Option | Reaches prod | Extra work | Notes |
|---|---|---|---|
| A. Finish v3 as planned (prod, then previews) | Yes | Phase 8 PR A, PR B, checkpoint | Previews are a review aid, not part of the release path |
| **B. Prod path only; defer previews** | Yes | None beyond Phase 7 | Demo steps 3 to 5 still prove "one digest, promote, roll back" |
| C. Single account, prod as a second env in dev | Yes | Less IAM | Loses the account boundary, the main isolation lesson (ADR 0008 N10) |

## Decision

| # | Decision |
|---|---|
| T1 | **Option B.** Done = requirements demo steps 3, 4 and 5 pass on live AWS, each checked by `/version` (SHA and digest) |
| T2 | Phase 8 is **deferred**, not deleted. Merge #34 with ADR 0009 status `deferred (ADR 0010)`; close #35 unmerged and keep its branch. FR-17 moves to Out of scope |
| T3 | Merge #33 (PR B1) as built |
| T4 | PR B2 keeps: `envs/prod` from `make new-env`, `accounts/prod.tfvars.example`, prod bootstrap with the promotion statements and the pull-only dev ECR repo policy, `app-promote.yml` (promote; rollback = promote an earlier green SHA), the `prod` leg of plan, apply and destroy, N1 for prod |
| T5 | PR B2 drops: the `prove-isolation` mode of `app-promote.yml` (N10 becomes one dispatched job in `oidc-smoke-test.yml`), the broken-release demo (B10, optional at the checkpoint), the drift check (B13), and the leftover `BLUE_GREEN` checkpoint steps |
| T6 | B2 code is offline and is built **before** the prod account exists; only the checkpoint needs it |
| T7 | Prod stack is up only for the checkpoint, then torn down (`destroy-prod`, `destroy-dev`). Bootstraps stay |
| T8 | `sis-team` is frozen after Phase 7 closes: no new agents or skills in this repo. Reuse happens by fork in the next app (`2026-11-01-sis-team-fit-review.md` in English for Devs) |
| T9 | ADR 0008 Q1 answered (user, 2026-11-02): the existing organization's management account is the user's own and runs no workloads. `sis-prod` is created there as designed (P20) |

## Consequences

- No PR preview URL; reviewers rely on `app-ci` (build, test, scan) before merge.
- Remaining user steps: create `sis-prod` in the organization (T9), then the ADR 0008 PR B checkpoint (B1 to B9, B11, B12, B14).
- ADR 0009 keeps its number and design for a later phase.
- Repo docs to update in B2: `docs/requirements.md` (Goal demo, Scope, FR-17), `README.md` phase table.

## Sources

- ADR 0008 amendment S and PR B checkpoint: `docs/adr/0008-phase-7-prod-account-and-env-cloning.md`
- https://docs.aws.amazon.com/organizations/latest/userguide/orgs_best-practices_mgmt-acct.html

## Change log

| Date | Change |
|---|---|
| 2026-11-02 | Proposed |
| 2026-11-02 | T9: Q1 answered |
| 2026-11-02 | Accepted (user) |
