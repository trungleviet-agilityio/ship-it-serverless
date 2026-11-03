---
name: run
description: Build and verify one phase of the ship-it-safely lab with the sis-team agents - build agents in parallel worktrees, merge, update docs, then verify agents in parallel, then stop at the checkpoint. Use as /sis-team:run <phase>.
argument-hint: <phase number>
---

# /sis-team:run

Phase: `$ARGUMENTS` (ask for it if empty).

## 0. Preconditions

- The working tree is clean and on `main` (or a feature branch cut from it). Build agents branch their
  worktrees from the default branch, so anything uncommitted is invisible to them: if `git status` is not
  clean, stop and ask the user to commit first.
- `docs/adr/` has an `accepted` ADR for this phase. If not, tell the user to run `/sis-team:plan <phase>`
  (Phase 0 may skip this: it follows the working plan directly).
- Create a feature branch `phase-<n>-<slug>` for the merged result.

## 1. Build (parallel)

Decide which build agents the phase needs from the paths it touches:

| Paths | Agent |
|---|---|
| `app/**` | `sis-team:backend-dev` |
| `infra/**`, `.github/**`, `.tflint.hcl`, `.pre-commit-config.yaml`, `Makefile`, `scripts/**` | `sis-team:devops-engineer` |

Spawn the needed agents in one message so they run in parallel. Give each: the phase, its requirement IDs,
its build brief from the ADR, and the path ownership above. Each works in its own worktree.

## 2. Merge

Merge each agent's worktree branch into the feature branch. Ownership is disjoint, so conflicts mean an agent
left its lane: stop and show the user. Remove the worktrees afterwards.

## 3. Docs (you, not an agent)

You own the repo `README.md` and `docs/**` (ADR 0001 D14); build agents never edit them. READMEs inside
`infra/**` are `devops-engineer`'s (D16): check they exist and match the code, and send gaps back to it. After the merge, update the
docs this phase changed, from the ADR and the merged diff:

- `README.md`: setup steps, commands, variables, ports and outputs that the phase added or changed, plus any
  section the working plan asks for in this phase (for example the trust conditions, cost and teardown notes).
- `docs/**` other than `docs/adr/`: runbooks or notes the phase calls for.
- Write only what the code does now. Every command must match a real script, target or workflow; no account
  IDs or emails (D2).

Commit the docs separately (`docs(<scope>): ...`) so verify sees them in the diff.

## 4. Verify (parallel)

Spawn in one message: `sis-team:e2e`, `sis-team:reviewer`, `sis-team:security-reviewer`,
`sis-team:code-simplifier`. Give each the phase, requirement IDs and the list of changed files
(`git diff --name-only main...HEAD`).

## 5. Fix loop (at most 2 rounds)

- Critical/High security findings, reviewer bugs and new e2e failures go back to the owning build agent as a
  focused brief, then re-run only the verify agents that reported them. Docs drift findings you fix yourself.
- Medium/Low findings and simplifier suggestions are listed for the user, not auto-fixed.
- After 2 rounds, stop and report what is still open.

## 6. Checkpoint (always stop here)

Commit on the feature branch (Conventional Commit, per phase). Then report:

1. What was built (files, one line each).
2. A verify table: agent, result, open findings.
3. The exact commands the user runs by hand for this phase's checkpoint in the working plan (kept outside the repo; its path is in `CLAUDE.local.md`), such as
   `terraform apply`, `aws secretsmanager put-secret-value`, GitHub environment setup, `git push` and PR.
   Never run them yourself.

Do not push or open a PR unless the user asks.
