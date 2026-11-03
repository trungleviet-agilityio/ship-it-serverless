#!/usr/bin/env bash
# Deregister every ACTIVE task definition revision of the app family after the stack is destroyed (ADR 0006, G12;
# closes ADR 0005, F23). Terraform deregisters only the revisions it created, so the ones app-deploy registered
# would stay ACTIVE. INACTIVE revisions cost nothing. Needs the AWS CLI with apply credentials (no new permission:
# DescribeTaskDefinition and DeregisterTaskDefinition are already allowed).
# 1. It runs only when the service is gone (MISSING or INACTIVE), so it never pulls a revision from a live service.
# 2. DescribeTaskDefinition with a family returns the latest ACTIVE revision, and ClientException means none is
#    left. Each revision is deregistered once. If the same revision comes back right after it was deregistered
#    (eventual consistency), the describe is retried once after DEREGISTER_RETRY_SLEEP seconds (default 5); a second
#    repeat fails.
# MAX_REVISIONS (default 200) caps the loop. Prints DEREGISTERED=<count> on stdout, also when the script fails
# (an EXIT trap), so the job summary shows how far it got. Names derive from ENV.
#
# Usage: ENV=dev scripts/ecs/deregister-revisions.sh >> "$GITHUB_OUTPUT"

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 0 ] || die "usage: ENV=dev scripts/ecs/deregister-revisions.sh"
require_cmd aws "the AWS CLI is preinstalled on GitHub runners"
app_names
max_revisions="${MAX_REVISIONS:-200}"
retry_sleep="${DEREGISTER_RETRY_SLEEP:-5}"

count=0
trap 'printf "DEREGISTERED=%s\n" "$count"' EXIT

ecs_service_status "$CLUSTER" "$SERVICE"
case "$SERVICE_STATUS" in
  MISSING | INACTIVE) ;;
  *) die "service ${SERVICE} still exists (${SERVICE_STATUS}); not deregistering" ;;
esac

# latest_revision: set REVISION to the newest ACTIVE revision of the family, or "" when none is left.
latest_revision() {
  run_capture aws ecs describe-task-definition --task-definition "$FAMILY" --query taskDefinition.revision --output text
  REVISION=""
  if [ "$RUN_RC" -ne 0 ]; then
    case "$RUN_ERR" in
      *ClientException*) return 0 ;; # no ACTIVE revision is left
      *) die "describe-task-definition failed (exit code $RUN_RC): $RUN_ERR" ;;
    esac
  fi
  printf '%s' "$RUN_OUT" | grep -Eq '^[0-9]+$' || die "describe-task-definition returned '${RUN_OUT}', not a revision number"
  REVISION="$RUN_OUT"
}

last=""
while :; do
  latest_revision
  if [ -n "$REVISION" ] && [ "$REVISION" = "$last" ]; then
    warn "revision ${REVISION} returned after it was deregistered; retrying in ${retry_sleep}s"
    sleep "$retry_sleep"
    latest_revision
    [ "$REVISION" != "$last" ] || die "revision ${REVISION} returned again (eventual consistency); re-run the job"
  fi
  [ -n "$REVISION" ] || break
  [ "$count" -lt "$max_revisions" ] || die "more than ${max_revisions} active revisions; run the job again"
  run_capture aws ecs deregister-task-definition --task-definition "${FAMILY}:${REVISION}" --query taskDefinition.status --output text
  [ "$RUN_RC" -eq 0 ] || die "deregister-task-definition failed (exit code $RUN_RC): $RUN_ERR"
  [ "$RUN_OUT" = "INACTIVE" ] || die "revision ${REVISION} is ${RUN_OUT} after deregistering, expected INACTIVE"
  log "deregistered ${FAMILY}:${REVISION}"
  last="$REVISION"
  count=$((count + 1))
done
