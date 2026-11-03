#!/usr/bin/env bash
# Offline self-test of the CI helper scripts (ADR 0004, L1; ADR 0005, F22; ADR 0006, G16). The single entry point:
# it runs every area file under scripts/selftest/, each a plain bash script that sources selftest/common.sh.
#   terraform   plan summary, destroy plan guard, tf/init, plan role guardrails
#   workflows   trigger allowlist, path filters, job isolation, the destroy workflow structure
#   render      task definition render
#   ecs         rollout evaluation and wait, preflight, service status, revision cleanup, role name
#   image       build mirror policy, ECR push, image archive
#   promote     promotion resolve check and the crane copy by digest (stub gh and crane)
#   tooling     account ID guard, lib.sh helpers, tool installer, config check, usage contracts
#   new-env     environment clone script (tf/new-env.sh) and the env parity guard
# A bad fixture must fail with its message; the real workflows must pass. Areas are independent, so one can be run
# alone: scripts/selftest/ecs.sh.
#
# Usage: scripts/ci/selftest.sh

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 0 ] || die "usage: scripts/ci/selftest.sh"

for area in terraform workflows render ecs image promote tooling new-env; do
  log "self-tests: ${area}"
  "$ROOT/scripts/selftest/${area}.sh" || die "self-tests failed in scripts/selftest/${area}.sh"
done
ok "ci helper self-tests pass"
