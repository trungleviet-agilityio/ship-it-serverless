#!/usr/bin/env python3
"""Check .drawio files before export: structure, icon names and lab rules. Stdlib only.

Usage: check_drawio.py <file.drawio> [...]
Exit 1 and one line per problem when anything fails.
"""

import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ICONS_MD = Path(__file__).resolve().parents[1] / "references" / "icons.md"
KNOWN = set(re.findall(r"mxgraph\.aws4\.\w+", ICONS_MD.read_text()))
ACCOUNT_ID = re.compile(r"(?<![0-9])(?!123456789012)[0-9]{12}(?![0-9])")
EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.]+")


def style_dict(style: str) -> dict[str, str]:
    pairs = (part.partition("=") for part in style.split(";") if part)
    return {key: value for key, _, value in pairs}


def check(path: Path) -> list[str]:
    text = path.read_text()
    problems = []
    if "<!--" in text:
        problems.append("XML comments break draw.io parsing; remove them")
    for pattern, what in ((ACCOUNT_ID, "a 12-digit account ID"), (EMAIL, "an email address")):
        if pattern.search(text):
            problems.append(f"contains {what} (ADR 0001, D2)")
    try:
        root = ET.fromstring(text)
    except ET.ParseError as e:
        return problems + [f"not well-formed XML: {e}"]

    for diagram in root.iter("diagram"):
        page = diagram.get("name", "?")
        cells = list(diagram.iter("mxCell"))
        ids = [c.get("id") for c in cells]
        dupes = {i for i in ids if ids.count(i) > 1}
        if dupes:
            problems.append(f"[{page}] duplicate cell ids: {sorted(dupes)}")
        if "0" not in ids or "1" not in ids:
            problems.append(f"[{page}] missing root cells id=0 and id=1")
        known_ids = set(ids)
        containers = set()
        for cell in cells:
            style = style_dict(cell.get("style") or "")
            if style.get("shape") == "mxgraph.aws4.group":
                containers.add(cell.get("id"))
                if style.get("container") != "1":
                    problems.append(f"[{page}] group {cell.get('id')} needs container=1")
            for key in ("shape", "resIcon", "grIcon"):
                name = style.get(key, "")
                if name.startswith("mxgraph.aws4.") and name != "mxgraph.aws4.resourceIcon" \
                        and name != "mxgraph.aws4.group" and name not in KNOWN:
                    problems.append(f"[{page}] {cell.get('id')}: {name} is not in references/icons.md")
            if cell.get("edge") == "1":
                for end in ("source", "target"):
                    if cell.get(end) not in known_ids:
                        problems.append(f"[{page}] edge {cell.get('id')} has no valid {end}")
                geometry = cell.find("mxGeometry")
                if geometry is None or geometry.get("relative") != "1":
                    problems.append(f"[{page}] edge {cell.get('id')} needs <mxGeometry relative=\"1\">")
        for cell in cells:
            parent = cell.get("parent")
            if parent not in (None, "0", "1") and parent not in containers and cell.get("edge") != "1":
                problems.append(f"[{page}] {cell.get('id')} has parent {parent}, which is not a group")
    return problems


def main() -> int:
    failed = False
    for arg in sys.argv[1:]:
        for problem in check(Path(arg)):
            print(f"{arg}: {problem}")
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
