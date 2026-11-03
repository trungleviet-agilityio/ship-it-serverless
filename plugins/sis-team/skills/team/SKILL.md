---
name: team
description: Show the sis-team agent roster for the ship-it-safely lab as a table (agent, phase, model, access, which skill spawns it, what it does), read from the plugin's agent and skill files. Read-only. Use as /sis-team:team.
---

# /sis-team:team

Run the script and show its output to the user as-is, a Markdown table:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/team/scripts/team_table.py"
```

- The table comes from the files, so it is current: frontmatter of `agents/*.md` (model, tools, isolation,
  description) and the `sis-team:<agent>` mentions in `skills/*/SKILL.md`.
- After the table, add one line per skill: `/sis-team:plan` (design, ADR), `/sis-team:run` (build, docs,
  verify, checkpoint), `/sis-team:review` (verify agents only), `/sis-team:diagram` (architecture diagrams),
  `/sis-team:team` (this table).
- If the script fails or a row shows `?`, say which agent file is missing a field. Do not edit any file.
