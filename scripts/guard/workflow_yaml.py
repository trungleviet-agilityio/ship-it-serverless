"""Shared reader, trigger accessors and entry point for the workflow checks (workflow_triggers,
harden_runner_policy, env_parity) and the self-test facts (selftest/workflow_facts.py).

Not run directly. PyYAML comes from the hash-locked CI venv (scripts/ci/venv.sh).
"""

import os
import sys
from collections.abc import Callable
from pathlib import Path
from typing import Any

import yaml


class UniqueKeyLoader(yaml.SafeLoader):
    """SafeLoader that refuses a mapping holding the same key twice.

    GitHub keeps one of the two values and PyYAML the last, so a duplicate could hide a trigger.
    """

    def construct_mapping(self, node: yaml.MappingNode, deep: bool = False) -> dict[Any, Any]:
        self.flatten_mapping(node)  # expand `<<` merge keys first: the pair count is then real
        mapping = super().construct_mapping(node, deep=deep)
        if len(mapping) != len(node.value):
            raise yaml.constructor.ConstructorError(
                None, None, "duplicate key in a mapping", node.start_mark
            )
        return mapping


def load_workflow(text: str) -> Any:
    """Parse one workflow file, refusing duplicate mapping keys. Raises yaml.YAMLError."""
    loader = UniqueKeyLoader(text)
    try:
        return loader.get_single_data()
    finally:
        loader.dispose()


def read_workflow(path: Path) -> Any:
    """Read and parse one workflow file. Raises ValueError, never a YAML or OS error."""
    try:
        return load_workflow(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as e:
        raise ValueError(f"invalid YAML: {getattr(e, 'problem', None) or 'parse error'}") from e
    except OSError as e:
        raise ValueError(f"cannot read workflow: {e.strerror or e}") from e


def workflow_on(document: Any) -> Any:
    """The value under the top-level `on` (None when absent). Raises ValueError for a bad document.

    YAML 1.1 (PyYAML) reads an unquoted `on` as True; GitHub reads it as the string "on".
    """
    if not isinstance(document, dict):
        raise ValueError("the workflow is not a YAML mapping")
    keys = [k for k in document if k == "on" or k is True]
    if len(keys) > 1:
        raise ValueError("both `on` and its YAML 1.1 form `true` are present")
    return document[keys[0]] if keys else None


def trigger_input(document: Any, trigger: str, name: str) -> dict[str, Any] | None:
    """The definition of input `name` under `on.<trigger>.inputs`, or None when there is none."""
    on = workflow_on(document)
    section = on.get(trigger) if isinstance(on, dict) else None
    inputs = section.get("inputs") if isinstance(section, dict) else None
    found = inputs.get(name) if isinstance(inputs, dict) else None
    return found if isinstance(found, dict) else None


def dispatch_options(document: Any, name: str) -> list[str]:
    """The options of the dispatch choice input `name`. Raises ValueError if it has none."""
    found = trigger_input(document, "workflow_dispatch", name)
    options = found.get("options") if found else None
    if not isinstance(options, list):
        raise ValueError(f"no workflow_dispatch input {name} with options")
    return [str(o) for o in options]


def run(prog: str, check: Callable[[str, Any], list[str]], argv: list[str]) -> int:
    """Run `check(shown path, parsed document)` over each file and print its violations.

    Exit codes: 0 all files pass, 1 violations, 2 usage error.
    """
    if not argv:
        print(f"usage: {prog} <workflow file>...", file=sys.stderr)
        return 2
    problems: list[str] = []
    for name in argv:
        path = Path(name)
        shown = os.path.relpath(path)
        if not path.is_file():
            problems.append(f"{shown}: workflow not found")
            continue
        try:
            document = read_workflow(path)
        except ValueError as e:
            problems.append(f"{shown}: {e}")
            continue
        problems.extend(check(shown, document))
    for line in problems:
        print(line)
    return 1 if problems else 0
