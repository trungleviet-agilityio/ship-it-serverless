#!/usr/bin/env python3
"""PreToolUse guard: block commands that change AWS or GitHub state, and reads of secret files.

Layer 3 of the guardrails (see docs/adr/0001-lab-decisions.md, D8). Permission deny rules match the
command text as written, so `terraform -chdir=envs/dev apply` or `bash -c '...'` slip past them.
This hook scans the whole command string instead. Exit code 2 blocks the call and shows stderr to
Claude.

The GitHub rules (merges, workflow dispatch, `gh api` writes, pushes to main) and the secret file
rules were added by docs/adr/0013-sis-team-guard-hardening.md: the `gh` token in this shell is the
owner's, so a `gh api` write could approve a pending environment deployment, which runs terraform
apply. Ideas for the push and secret file rules come from super-board
(github.com/EricTechPro/super-board, MIT).
"""

# The hook runs under the system python3 (3.9 on macOS), so annotations must not be evaluated.
from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys

BLOCKED = [
    (
        r"\bterraform\b[^\n;&|]*\s(apply|destroy|import|force-unlock)\b",
        "terraform apply/destroy/import",
    ),
    (
        r"\bterraform\b[^\n;&|]*\sstate\s+(rm|mv|push|replace-provider)\b",
        "terraform state mutation",
    ),
    (
        r"\baws\b[^\n;&|]*\ssecretsmanager\s+(put-secret-value|get-secret-value|create-secret|update-secret)\b",
        "Secrets Manager value access",
    ),
    (
        r"\baws\b[^\n;&|]*\siam\s+(create-access-key|create-user|attach-\w+-policy|put-\w+-policy)\b",
        "IAM write",
    ),
    (r"\baws\b[^\n;&|]*\ssts\s+assume-role\b", "manual role assumption"),
    (r"\bgh\s+(secret|variable)\s+(set|delete|remove)\b", "GitHub secret or variable write"),
    (r"\bgh\s+pr\s+merge\b", "PR merge (the owner merges)"),
    (r"\bgh\s+workflow\s+(run|enable|disable)\b", "workflow dispatch or toggle"),
    (r"\bgh\s+run\s+(rerun|cancel)\b", "workflow run rerun or cancel"),
    (r"\bgh\s+repo\s+(edit|delete|archive|unarchive|rename)\b", "repository settings change"),
    (r"\bgh\s+auth\s+(login|logout|refresh|token|setup-git)\b", "gh sign-in, scopes or token"),
    (r"\bgh\s+project\s+(delete|close|field-delete)\b", "GitHub Project deletion"),
]

PROTECTED_BRANCHES = {"main", "master"}

# Files that .gitignore keeps out of git because they can hold secrets, account IDs or state.
# The committed infra/terraform/envs/*/terraform.tfvars and every *.example file stay readable.
SECRET_FILE_PATTERNS = [
    r"(^|/)\.env(\.(?!example$)[^/]+)?$",
    r"\.tfstate(\.[^/]*)?$",
    r"(^|/)(\w[\w.-]*\.)?tfplan(\.json)?$",
    r"\.tfvars\.json$",
    r"\.auto\.tfvars$",
    r"(^|/)bootstrap/accounts/[^/]+\.tfvars$",
    r"\.tfbackend$",
    r"(^|/)\.terraform(-[^/]+)?/",
    r"(^|/)\.aws/",
    r"(^|/)\.ssh/",
    r"\.pem$",
    r"(^|/)id_(rsa|ecdsa|ed25519)(\.pub)?$",
]


def block(label: str, hint: str = "Print the exact command for the user instead.") -> int:
    print(
        f"sis-team guard blocked this call ({label}). NFR-9: Claude prepares it, "
        f"the user runs it at the checkpoint. {hint}",
        file=sys.stderr,
    )
    return 2


def segments(command: str) -> list[str]:
    """Split a shell line into simple commands.

    Rough on purpose: a split inside quotes only makes a match likelier.
    """
    return [s.strip() for s in re.split(r"&&|\|\||[;|\n]|\$\(|`", command) if s.strip()]


def words(segment: str) -> list[str]:
    try:
        return shlex.split(segment)
    except ValueError:
        return segment.split()


FIELD_FLAGS = ("-f", "-F", "--field", "--raw-field", "--input")
# gh api flags that take a value, so the value is not mistaken for the endpoint.
VALUE_FLAGS = (
    "-H",
    "--header",
    "-q",
    "--jq",
    "-t",
    "--template",
    "-p",
    "--preview",
    "--hostname",
    "--cache",
)


def gh_api_write(segment: str) -> bool:
    """True when a `gh api` call is not a plain read.

    A read is a GET with no request fields, or a GraphQL query that is not a mutation.
    """
    m = re.search(r"\bgh\s+api\b(.*)", segment, re.S)
    if not m:
        return False
    args = words(m.group(1))
    method = None
    has_fields = False
    endpoint = None
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("-X", "--method") and i + 1 < len(args):
            method = args[i + 1]
            i += 1
        elif a.startswith("--method="):
            method = a.split("=", 1)[1]
        elif a.startswith("-X") and len(a) > 2:
            method = a[2:]
        elif a in FIELD_FLAGS or re.match(r"^(-[fF].|--(raw-)?field=|--input=)", a):
            has_fields = True
            if a in FIELD_FLAGS:
                i += 1
        elif a in VALUE_FLAGS:
            i += 1
        elif not a.startswith("-") and endpoint is None:
            endpoint = a
        i += 1
    if endpoint == "graphql":
        return re.search(r"\bmutation\b", segment) is not None
    effective = (method or ("POST" if has_fields else "GET")).upper()
    return effective != "GET"


def current_branch(cwd: str) -> str:
    try:
        out = subprocess.run(  # noqa: S603  # fixed argv, no shell
            ["git", "-C", cwd or ".", "symbolic-ref", "--short", "-q", "HEAD"],  # noqa: S607
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return out.stdout.strip()


def git_push_problem(segment: str, cwd: str) -> str | None:
    """Return why a `git push` is blocked.

    Blocked: force or mirror pushes, deletes, and any push that updates main.
    """
    m = re.search(r"\bgit\b((?:\s+-[Cc]\s+\S+)*)\s+push\b(.*)", segment, re.S)
    if not m:
        return None
    pre = words(m.group(1))
    if "-C" in pre:
        cwd = os.path.join(cwd or ".", pre[pre.index("-C") + 1])
    args = words(m.group(2))
    flags = [a for a in args if a.startswith("-")]
    for f in flags:
        if f in ("-f", "--force", "--mirror", "--all", "--delete", "-d", "--prune") or (
            re.match(r"^-[a-zA-Z]*[fd]", f) and not f.startswith("--")
        ):
            return f"git push {f}"
    rest = [a for a in args if not a.startswith("-")]
    refspecs = rest[1:]
    if not refspecs:
        refspecs = ["HEAD"]
    for spec in refspecs:
        if spec.startswith("+"):
            return "force push (+refspec)"
        src, _, dst = spec.partition(":")
        target = dst if dst else src
        if target == "HEAD":
            target = current_branch(cwd)
        target = target.removeprefix("refs/heads/")
        if target in PROTECTED_BRANCHES:
            return f"push to {target}"
    return None


def secret_path(path: str) -> bool:
    p = path.replace("\\", "/")
    return any(re.search(pat, p) for pat in SECRET_FILE_PATTERNS)


def check_bash(command: str, cwd: str) -> int:
    for pattern, label in BLOCKED:
        if re.search(pattern, command):
            return block(label)
    for seg in segments(command):
        if gh_api_write(seg):
            return block(
                "gh api write",
                "Only GET reads are allowed through gh api. Print the call for the user.",
            )
        problem = git_push_problem(seg, cwd)
        if problem:
            return block(
                problem,
                "Push a feature branch and open a PR; main changes only through a merged PR.",
            )
        for w in words(seg):
            if secret_path(w):
                return block(
                    f"secret file {w}", "Name the file and ask the user; never print its content."
                )
    return 0


def check_file_tool(tool_input: dict[str, object]) -> int:
    for key in ("file_path", "path", "glob", "pattern"):
        value = tool_input.get(key)
        if isinstance(value, str) and key != "pattern" and secret_path(value):
            return block(
                f"secret file {value}", "Name the file and ask the user; never read its content."
            )
    return 0


def main() -> int:
    try:
        event = json.load(sys.stdin)
    except json.JSONDecodeError:
        return 0
    tool = event.get("tool_name", "Bash")
    tool_input = event.get("tool_input", {}) or {}
    if tool == "Bash":
        return check_bash(str(tool_input.get("command", "")), str(event.get("cwd", "")))
    return check_file_tool(tool_input)


if __name__ == "__main__":
    sys.exit(main())
