#!/usr/bin/env bash
# The result block of the terraform-destroy job summary (ADR 0007 S12, S37). The heading says what happened, so a
# red run cannot be read as a success: Destroyed, Destroy failed, Nothing to destroy, Destroy did not finish.
# Prints Markdown on stdout; the workflow pipes it through assert-no-account-id.sh into the step summary.
#
# Usage: scripts/tf/destroy-report.sh
# Env:   ENV            environment name (heading suffix)
#        DELETES        deletes in the checked plan; empty when the plan check did not finish
#        APPLY_OUTCOME  outcome of the apply step (success, failure, skipped, cancelled)
#        DEREGISTERED   task definition revisions deregistered; empty when the cleanup did not start
#        ROLE           name of the assumed role

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 0 ] || die "usage: scripts/tf/destroy-report.sh (reads ENV, DELETES, APPLY_OUTCOME, DEREGISTERED, ROLE)"
env_name="${ENV:?ENV is not set}"
deletes="${DELETES:-}"
outcome="${APPLY_OUTCOME:-}"

if [ -z "$deletes" ]; then
  heading="Destroy did not finish"
  detail="Resources: not known (the plan check did not finish or refused the plan)"
elif [ "$deletes" = "0" ]; then
  heading="Nothing to destroy"
  detail="Nothing to destroy."
elif [ "$outcome" = "success" ]; then
  heading="Destroyed"
  detail="Resources: ${deletes} deleted"
else
  heading="Destroy failed"
  detail="Resources: ${deletes} planned; the apply did not succeed (${outcome:-no outcome})"
fi

echo "### ${heading} (${env_name})"
echo "$detail"
echo "Task definition revisions deregistered: ${DEREGISTERED:-not known (the cleanup did not start)}"
echo "Role: \`${ROLE:-not assumed}\`"
