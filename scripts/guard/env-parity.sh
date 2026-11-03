#!/usr/bin/env bash
# Environment parity guard (ADR 0008, P3): the per-environment Terraform roots stay copies of envs/dev, and every
# environment is in every workflow list. The rules are in scripts/guard/env_parity.py.
#
# Usage: scripts/guard/env-parity.sh [repo root]   (default: this repository)
# Env:   CI_PYTHON  interpreter with PyYAML (default: .venv-ci/bin/python from `make venv`, else python3)

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -le 1 ] || die "usage: scripts/guard/env-parity.sh [repo root]"
run_guard_helper env_parity.py "environment parity" "${1:-$ROOT}"
ok "environment roots match envs/dev and every workflow lists every environment"
