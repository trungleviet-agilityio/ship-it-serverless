#!/usr/bin/env python3
"""Print the sis-team agent roster as a Markdown table, read from the plugin files.

Phase comes from the "<Phase>-phase" prefix of each agent's description; "Spawned by" lists the skills
whose SKILL.md names `sis-team:<agent>`. Stdlib only, so it runs with any python3.
Usage: team_table.py [plugin_dir]   (default: the plugin this script lives in)
"""

import re
import sys
from pathlib import Path

PHASE_ORDER = {"Plan": 0, "Build": 1, "Verify": 2}
WRITE_TOOLS = {"Edit", "Write", "NotebookEdit"}


def frontmatter(path: Path) -> dict[str, str]:
    match = re.match(r"^---\n(.*?)\n---\n", path.read_text(), re.DOTALL)
    if not match:
        return {}
    fields: dict[str, str] = {}
    for line in match.group(1).splitlines():
        key, sep, value = line.partition(":")
        if sep and not line.startswith(" "):
            fields[key.strip()] = value.strip().strip('"')
    return fields


def access(fields: dict[str, str]) -> str:
    tools = {t.strip() for t in fields.get("tools", "").split(",") if t.strip()}
    if not tools:
        level = "All tools"
    elif tools & WRITE_TOOLS:
        level = "Full"
    elif "Bash" in tools:
        level = "Bash, no edits"
    else:
        level = "Read-only"
    if tools & {"WebFetch", "WebSearch"}:
        level += " + web"
    if fields.get("isolation") == "worktree":
        level += ", own worktree"
    return level


def main() -> int:
    plugin = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[3]
    skills = {p.parent.name: p.read_text() for p in sorted((plugin / "skills").glob("*/SKILL.md"))}
    rows = []
    for path in sorted((plugin / "agents").glob("*.md")):
        fields = frontmatter(path)
        name = fields.get("name", path.stem)
        description = fields.get("description", "")
        phase_match = re.match(r"(\w+)-phase", description)
        phase = phase_match.group(1).capitalize() if phase_match else "?"
        # Keep the sentences that say what the agent does: drop the "<Phase>-phase ... lab" lead-in, the
        # "Read-only" note (the Access column shows it) and "Use from/as ..." routing hints.
        sentences = re.split(r"(?<=\.)\s+(?=[A-Z])", description)[1:]
        kept = [s for s in sentences if not s.startswith(("Read-only", "Use from", "Use as"))]
        does = " ".join(kept).rstrip(".")
        mention = re.compile(rf"sis-team:{re.escape(name)}\b")
        spawned = [f"`/sis-team:{s}`" for s, text in skills.items() if mention.search(text)]
        rows.append((PHASE_ORDER.get(phase, 9), name, phase, fields.get("model", "inherit"),
                     access(fields), " and ".join(spawned) or "-", does))

    print("| Agent | Phase | Model | Access | Spawned by | What it does |")
    print("|---|---|---|---|---|---|")
    for _, name, phase, model, acc, spawned, does in sorted(rows):
        print(f"| `sis-team:{name}` | {phase} | {model} | {acc} | {spawned} | {does} |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
