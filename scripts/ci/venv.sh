#!/usr/bin/env bash
# Create (or reuse) a virtual environment with the hash-locked CI Python tools: pre-commit and PyYAML
# (scripts/ci/requirements.txt, installed with --require-hashes). repo-guard and `make venv` both use it.
#
# Usage: scripts/ci/venv.sh <venv dir>
# Env:   PYTHON  interpreter that creates the venv (default: python3)

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 1 ] || die "usage: scripts/ci/venv.sh <venv dir>"
venv="$1"
py="${PYTHON:-python3}"
require_cmd "$py" "install Python 3 (mise or your package manager)"

[ -x "$venv/bin/python" ] || "$py" -m venv "$venv"
"$venv/bin/pip" install --quiet --require-hashes -r "$ROOT/scripts/ci/requirements.txt"
ok "hash-locked CI tools installed in $venv"
