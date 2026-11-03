---
name: review
description: Run only the sis-team verify agents (e2e, reviewer, security-reviewer, code-simplifier) on the current branch or a PR of the ship-it-safely lab. Read-only except for the commands e2e runs. Use as /sis-team:review [PR number].
argument-hint: "[PR number]"
---

# /sis-team:review

Target: PR `$ARGUMENTS` if given (`gh pr diff $ARGUMENTS --name-only`, and `gh pr checkout` only if the user
agrees), otherwise the current branch against `main` (`git diff --name-only main...HEAD`).

1. Collect the changed files and map them to phases and requirement IDs (`docs/requirements.md`).
2. Spawn in one message: `sis-team:e2e`, `sis-team:reviewer`, `sis-team:security-reviewer`,
   `sis-team:code-simplifier`, each with the changed files and requirement IDs.
3. Merge the results into one report: findings ranked Critical to Low with `file:line`, then the e2e table,
   then simplifier suggestions.
4. Do not fix anything and do not post to GitHub unless the user asks.
