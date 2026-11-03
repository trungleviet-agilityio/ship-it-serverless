#!/usr/bin/env bash
# Before a deploy, fail early and clearly (ADR 0005, F16, Q2; ADR 0006, G14). Needs the AWS CLI with deploy credentials.
# 1. The ECS service must be ACTIVE: a green run must always mean "deployed", so a missing stack fails.
# 2. The app secret must have a current value (an AWSCURRENT version). A secret that was just re-created has none,
#    and the rollout would end in a circuit-breaker rollback. DescribeSecret returns metadata only; version IDs are
#    never printed.
# 3. N4: the deploy role must be denied the secret value (explicit deny, FR-3). The call asks for the secret name
#    only, so even a broken deny could not return the value. Because it is an explicit deny, the answer is
#    AccessDeniedException whether or not the secret exists; anything else is a failure.
# Names derive from ENV (default dev). Error text is printed with 12-digit runs replaced.
#
# Usage: ENV=dev scripts/ecs/preflight.sh

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 0 ] || die "usage: ENV=dev scripts/ecs/preflight.sh"
require_cmd aws "the AWS CLI is preinstalled on GitHub runners"
require_cmd jq "apt-get install jq"
app_names

not_up="the ${ENV} stack is not up. Re-create it (terraform-iac, Run workflow), set the secret value, then run app-deploy (Run workflow)."
ecs_service_status "$CLUSTER" "$SERVICE"
[ "$SERVICE_STATUS" = "ACTIVE" ] || die "$not_up"
ok "service is ACTIVE"

run_capture aws secretsmanager describe-secret --secret-id "$SECRET_ID" --query VersionIdsToStages --output json
if [ "$RUN_RC" -ne 0 ]; then
  case "$RUN_ERR" in
    *AccessDeniedException*) die "deploy role cannot describe the secret: re-apply bootstrap (ADR 0006, G14)" ;;
    *ResourceNotFoundException*) die "$not_up" ;;
    *) die "describe-secret failed (exit code $RUN_RC): $RUN_ERR" ;;
  esac
fi
# VersionIdsToStages maps a version ID to its stage names, and is null for a secret that never had a value.
printf '%s' "$RUN_OUT" | jq -e '[(. // {})[]] | flatten | index("AWSCURRENT") != null' >/dev/null \
  || die "secret ${SECRET_ID} has no current value: set it with put-secret-value in your own terminal, then Re-run failed jobs"
ok "secret has a current value"

assert_denied "N4 (deploy role, GetSecretValue)" AccessDeniedException \
  aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --query Name --output text
