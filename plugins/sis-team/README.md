# sis-team

Claude Code agent team for the ship-it-safely lab. A solution architect settles each phase's design in an
ADR; two build agents (`backend-dev`, `devops-engineer`) work in their own git worktrees with TDD; four verify
agents (`e2e`, `reviewer`, `security-reviewer`, `code-simplifier`) check the result in parallel and never edit
files. A `PreToolUse` guard hook blocks `terraform apply`/`destroy`, state mutation, Secrets Manager value
access and IAM writes, so a human always runs those at the checkpoint. It also blocks PR merges, workflow
dispatch, `gh api` writes, pushes to `main` and reads of secret files (`scripts/test_guard.py`, ADR 0013).

Commands: `/sis-team:plan <phase>`, `/sis-team:run <phase>`, `/sis-team:close <phase> [checkpoint]`,
`/sis-team:review [PR]`, `/sis-team:team` (agent
roster table from the agent files) and `/sis-team:diagram <topic>` (draw.io AWS diagrams, checked and exported
to PNG).
Setup and the agent table: see the repository `README.md`.
