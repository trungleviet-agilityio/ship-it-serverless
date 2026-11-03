#!/usr/bin/env bash
# Trigger allowlist for every workflow file (ADR 0004 L1, ADR 0007 S34): the rules are in scripts/guard/workflow_triggers.py.
#
# Usage: scripts/guard/workflow-triggers.sh [workflow file ...]   (default: every .github/workflows/*.yml and *.yaml)
# Env:   CI_PYTHON  interpreter with PyYAML (default: .venv-ci/bin/python from `make venv`, else python3)

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

run_workflow_helper workflow_triggers.py "workflow trigger" "$@"
ok "workflow triggers are within the allowlist: pull_request push workflow_dispatch (workflow_call only in reusable-*.yml)"
