"""Trigger allowlist for GitHub workflow files (ADR 0007 S34, ADR 0004 L1 and L-a).

The apply and deploy roles cannot tell `push` from `pull_request_target`, `issue_comment` or
`workflow_run` on main, so the repository refuses every trigger outside ALLOWED. This parses real
YAML (PyYAML, from the hash-locked CI venv), so flow lists split across lines, explicit `?` keys,
quoted keys and anchors cannot hide a trigger the way they could from a line scanner.

Usage: python -I scripts/guard/workflow_triggers.py <workflow file>...
A reusable workflow (`workflow_call`) is allowed only in a file named reusable-*.yml, and such a
file carries no other trigger (ADR 0008, P8).
Prints one violation per line on stdout, with paths relative to the working directory.
Exit codes: 0 all files pass, 1 violations, 2 usage error.
Run through scripts/guard/workflow-triggers.sh, which picks the interpreter and lists the files.
"""

import os
import sys
from typing import Any

# `python -I` leaves the script directory off sys.path; the helper module sits next to this file.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from workflow_yaml import run, workflow_on  # noqa: E402  (import after the path setup above)

ALLOWED = ("pull_request", "push", "workflow_dispatch")
REUSABLE_TRIGGER = "workflow_call"


def _is_reusable_file(shown: str) -> bool:
    name = os.path.basename(shown)
    return name.startswith("reusable-") and name.endswith((".yml", ".yaml"))


def _triggers(document: Any) -> list[str]:
    """Names under the top-level `on`, or raise ValueError saying why they cannot be read."""
    value = workflow_on(document)
    # A scalar is one trigger; a list or mapping is read by items or keys; anything else names none.
    names: list[Any] = []
    if isinstance(value, str):
        names = [value]
    elif isinstance(value, list | dict):
        names = list(value)
    if not names:
        raise ValueError("no triggers found under on:")
    if not all(isinstance(n, str) for n in names):
        raise ValueError("a trigger name is not a string")
    return names


def check(shown: str, document: Any) -> list[str]:
    """Violations of one parsed workflow, as `<file>: <message>` lines."""
    try:
        names = _triggers(document)
    except ValueError as e:
        return [f"{shown}: {e}"]
    if _is_reusable_file(shown):
        problems = [
            f"{shown}: a reusable-*.yml file must use `{REUSABLE_TRIGGER}` only, found '{n}'"
            for n in names
            if n != REUSABLE_TRIGGER
        ]
        if REUSABLE_TRIGGER not in names:
            problems.append(f"{shown}: a reusable-*.yml file must use `{REUSABLE_TRIGGER}`")
        return problems
    problems = []
    for n in names:
        if n == REUSABLE_TRIGGER:
            problems.append(
                f"{shown}: trigger '{n}' is only allowed in a file named reusable-*.yml"
            )
        elif n not in ALLOWED:
            problems.append(f"{shown}: trigger '{n}' is not allowed (allowed: {' '.join(ALLOWED)})")
    return problems


if __name__ == "__main__":
    sys.exit(run("workflow_triggers.py", check, sys.argv[1:]))
