---
name: close
description: Close a phase (or one checkpoint of it) of the ship-it-safely lab after the user has run the checkpoint - record the results in the ADR, update the progress note (outside the repo) and the lessons log, and open the docs PR. Use as /sis-team:close <phase> [checkpoint letter].
argument-hint: <phase number> [checkpoint letter]
---

# /sis-team:close

Phase: `$ARGUMENTS` (ask if empty). Run this only after the user reports the checkpoint results; never record a
step as passed that the user or a run log has not shown.

## 1. Collect evidence

- The checkpoint steps are in the phase ADR (`docs/adr/NNNN-phase-<n>-*.md`, section "Checkpoint ...").
- For each step, take the result from what the user reported, or read it yourself:
  `gh run view <id> --repo trungleviet-agilityio/ship-it-safely --log` (counts such as "27 added",
  "27 destroyed"), `gh pr checks <pr>`, `gh pr view <pr> --json state,mergeCommit`.
- Note what was **not** observed and why. A failure that was expected (a guard refusing by design) is a pass
  with a note.

## 2. Write the docs (orchestrator owns `docs/**`, `README.md` and the progress note)

Branch `docs/phase-<n>-checkpoint-<x>` from `origin/main` (fetch first), not from the phase branch.

1. **ADR:** insert `## Checkpoint <X> results (<YYYY-MM-DD>)` right above the checkpoint section: a table
   `| Step | Result |` with one row per step, then "Not observed: ..." if any.
2. **Progress note** (outside the repo; its path is in `CLAUDE.local.md`; never commit it):
   - the phase row: status (✅ when the last checkpoint passed, 🟡 otherwise), PRs, and a one-line result;
   - plan alignment text: what is now in place, and what is still to do;
   - open items: close the ones this checkpoint settled (say how), add new ones with source and target
     (verify findings accepted as residual risk, deferred work);
   - live state: whether the stack is up or destroyed, with the date.
3. **Lessons log** (memory `lessons-learned-log`): one entry per new error seen during the checkpoint.

Edit with one small Python script in the scratchpad that asserts each old string occurs exactly once before
replacing it, so a doc that changed under you fails loudly instead of being patched in the wrong place.

## 3. Check and open the PR

- `pre-commit run --files <changed files>` (gitleaks, account ID hook, end of file).
- No account IDs, ARNs with IDs or emails; no em-dashes or en-dashes.
- Commit `docs(progress): close phase <n> with checkpoint <x> results` (skill `pr-conventions`), push, and open
  the PR with a `--body-file`: what the PR does, the results, the changes, and any PR that is now redundant.
- Never merge it. Report the PR link, the open items added, and what the next phase or checkpoint needs from
  the user.
