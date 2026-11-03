#!/usr/bin/env python3
"""PreToolUse guard: block commands that change AWS state or touch secret values.

Layer 3 of the guardrails (see docs/adr/0001-lab-decisions.md, D8). Permission deny rules match the
command text as written, so `terraform -chdir=envs/dev apply` or `bash -c '...'` slip past them.
This hook scans the whole command string instead. Exit code 2 blocks the call and shows stderr to Claude.
"""
import json
import re
import sys

BLOCKED = [
    (r"\bterraform\b[^\n;&|]*\s(apply|destroy|import|force-unlock)\b", "terraform apply/destroy/import"),
    (r"\bterraform\b[^\n;&|]*\sstate\s+(rm|mv|push|replace-provider)\b", "terraform state mutation"),
    (r"\baws\b[^\n;&|]*\ssecretsmanager\s+(put-secret-value|get-secret-value|create-secret|update-secret)\b",
     "Secrets Manager value access"),
    (r"\baws\b[^\n;&|]*\siam\s+(create-access-key|create-user|attach-\w+-policy|put-\w+-policy)\b",
     "IAM write"),
    (r"\baws\b[^\n;&|]*\ssts\s+assume-role\b", "manual role assumption"),
    (r"\bgh\s+secret\s+set\b", "GitHub secret write"),
]


def main() -> int:
    try:
        event = json.load(sys.stdin)
    except json.JSONDecodeError:
        return 0
    command = event.get("tool_input", {}).get("command", "")
    for pattern, label in BLOCKED:
        if re.search(pattern, command):
            print(
                f"sis-team guard blocked this command ({label}). NFR-9: Claude prepares it, the user runs it "
                "at the checkpoint. Print the exact command for the user instead.",
                file=sys.stderr,
            )
            return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
