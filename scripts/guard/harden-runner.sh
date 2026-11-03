#!/usr/bin/env bash
# harden-runner policy for every workflow job (ADR 0007 S45): the rules are in scripts/guard/harden_runner_policy.py.
#
# Usage: scripts/guard/harden-runner.sh [workflow file ...]   (default: every .github/workflows/*.yml and *.yaml)
# Env:   CI_PYTHON  interpreter with PyYAML (default: .venv-ci/bin/python from `make venv`, else python3)

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

run_workflow_helper harden_runner_policy.py "harden-runner policy" "$@"
ok "harden-runner policy holds"
