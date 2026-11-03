"""Tests of the sis-team PreToolUse guard (guard.py).

Every blocked form, and the reads and pushes it must allow.

Run: python3 -m unittest discover -s plugins/sis-team/scripts -p 'test_*.py'
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from collections.abc import Mapping

GUARD = os.path.join(os.path.dirname(os.path.abspath(__file__)), "guard.py")


def run(event: Mapping[str, object]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(  # noqa: S603  # runs guard.py with a fixed argv
        [sys.executable, "-I", GUARD],
        input=json.dumps(event),
        capture_output=True,
        text=True,
        check=False,
    )


def bash(command: str, cwd: str = "") -> int:
    return run({"tool_name": "Bash", "tool_input": {"command": command}, "cwd": cwd}).returncode


def read(path: str) -> int:
    return run({"tool_name": "Read", "tool_input": {"file_path": path}}).returncode


class BlockedCommands(unittest.TestCase):
    def test_blocks(self) -> None:
        for command in [
            # AWS and Terraform (the original rules)
            "terraform -chdir=infra/terraform/envs/dev apply -auto-approve",
            "terraform state rm aws_s3_bucket.x",
            "aws secretsmanager get-secret-value --secret-id x",
            "aws sts assume-role --role-arn x --role-session-name y",
            # GitHub writes
            "gh secret set TOKEN",
            "gh variable set AWS_REGION --body ap-southeast-1",
            "gh pr merge 12 --squash",
            "gh workflow run terraform-iac.yml -f env=dev",
            "gh run rerun 123",
            "gh repo edit --visibility private",
            "gh auth token",
            "gh auth refresh -s project",
            "gh project delete 3 --owner me",
            # gh api writes, including the deployment approval path
            "gh api -X POST repos/o/r/actions/runs/1/pending_deployments -f state=approved",
            "gh api --method=PUT repos/o/r/actions/secrets/X --input body.json",
            "gh api repos/o/r/environments/dev -XDELETE",
            "gh api repos/o/r/rulesets/1 -f enforcement=disabled",
            "gh api graphql -f query='mutation { deleteProjectV2(input: {}) { clientMutationId }}'",
            "bash -c 'gh api -X PATCH repos/o/r -f private=true'",
            "echo ok && gh api -X POST repos/o/r/dispatches -f event_type=x",
            # pushes that change main or rewrite history
            "git push origin main",
            "git push origin HEAD:main",
            "git push origin feat/x:refs/heads/main",
            "git push --force origin feat/x",
            "git push -f origin feat/x",
            "git push origin +feat/x",
            "git push --mirror origin",
            "git push origin --delete feat/x",
            "git -C ../other push origin main",
            # secret files read through the shell
            "cat app/.env",
            "cat infra/terraform/envs/dev/terraform.tfstate",
            "cat infra/terraform/bootstrap/accounts/dev.tfvars",
            "less infra/terraform/envs/dev/.terraform/terraform.tfstate",
            "cat ~/.aws/credentials",
            "cat ~/.ssh/id_ed25519",
        ]:
            with self.subTest(command=command):
                self.assertEqual(bash(command), 2)

    def test_blocks_push_of_current_main(self) -> None:
        with tempfile.TemporaryDirectory() as repo:
            subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True)  # noqa: S603,S607
            self.assertEqual(bash("git push", cwd=repo), 2)
            self.assertEqual(bash("git push origin", cwd=repo), 2)
            git = ["git", "-C", repo, "checkout", "-q", "-b", "feat/x"]
            subprocess.run(git, check=True)  # noqa: S603,S607
            self.assertEqual(bash("git push -u origin HEAD", cwd=repo), 0)


class AllowedCommands(unittest.TestCase):
    def test_allows(self) -> None:
        for command in [
            "terraform -chdir=infra/terraform/envs/dev validate",
            "terraform init -backend=false",
            "gh pr view 12 --json state",
            "gh pr create --draft --title x --body-file b.md",
            "gh pr checks 12",
            "gh run view 123 --log",
            "gh api repos/o/r/pulls --paginate --jq '.[] | .number'",
            "gh api -X GET search/issues -f q=repo:o/r",
            "gh api -H 'Accept: application/vnd.github+json' repos/o/r/environments",
            "gh api graphql -f query='query { viewer { login } }'",
            "git push -u origin feat/x",
            "git push --force-with-lease origin feat/x",
            "cat app/.env.example",
            "cat infra/terraform/envs/dev/terraform.tfvars",
            "cat infra/terraform/bootstrap/accounts/dev.tfvars.example",
            "cat infra/terraform/envs/dev/.terraform.lock.hcl",
            "scripts/aws/check-config.sh",
            "cat project.env",
        ]:
            with self.subTest(command=command):
                self.assertEqual(bash(command), 0)


class FileTools(unittest.TestCase):
    def test_reads(self) -> None:
        self.assertEqual(read("/repo/app/.env"), 2)
        self.assertEqual(read("/repo/infra/terraform/envs/dev/terraform.tfstate.backup"), 2)
        self.assertEqual(read("/repo/infra/terraform/envs/dev/.terraform-prod/environment"), 2)
        self.assertEqual(read("/repo/infra/terraform/envs/dev/backend.tfbackend"), 2)
        self.assertEqual(read("/repo/app/.env.example"), 0)
        self.assertEqual(read("/repo/infra/terraform/envs/prod/terraform.tfvars"), 0)
        self.assertEqual(read("/repo/infra/terraform/envs/dev/backend.tfbackend.example"), 0)

    def test_grep_glob(self) -> None:
        grep = {"tool_name": "Grep", "tool_input": {"pattern": "account", "glob": "*.tfstate"}}
        self.assertEqual(run(grep).returncode, 2)
        grep = {"tool_name": "Grep", "tool_input": {"pattern": "tfstate", "path": "infra"}}
        self.assertEqual(run(grep).returncode, 0)

    def test_bad_input_is_ignored(self) -> None:
        done = subprocess.run(  # noqa: S603  # runs guard.py with a fixed argv
            [sys.executable, GUARD], input="not json", text=True, check=False
        )
        self.assertEqual(done.returncode, 0)


if __name__ == "__main__":
    unittest.main()
