---
name: plan
description: Settle the design of one phase of the ship-it-safely lab before any code is written. Spawns the solution-architect, saves its ADR to docs/adr/, and stops for the user's approval. Use as /sis-team:plan <phase>.
argument-hint: <phase number>
---

# /sis-team:plan

Phase: `$ARGUMENTS` (ask for it if empty).

1. Read the phase in the working plan (kept outside the repo; its path is in `CLAUDE.local.md`), `docs/requirements.md` and `docs/adr/*.md`. If the phase depends on an input
   still marked `TODO` in the working plan, ask the user for it now. Without a working plan, ask the user for
   the phase scope.
2. Spawn `sis-team:solution-architect` with: the phase number, its requirement IDs, the list of existing ADRs,
   and the answers from step 1.
3. Save the returned ADR as `docs/adr/NNNN-phase-<n>-<slug>.md` (next free number, status `proposed`). Keep
   the build briefs in the same file under `## Build briefs`.
4. Show the user a short summary: the decisions, open questions, and what they will run by hand at the
   checkpoint. Ask them to approve (status becomes `accepted`) or change it.
5. Stop. Do not start building in this skill.
