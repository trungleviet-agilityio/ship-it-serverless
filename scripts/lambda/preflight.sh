#!/usr/bin/env bash
# Before a deploy, fail early and clearly (ADR 0012 L3, L7; ADR 0006 G14). Needs the AWS CLI with deploy credentials.
# 1. The function must exist. Terraform creates it from an image that is already in ECR (ADR 0012 L3), so the very
#    first run of an environment pushes before the function exists: then this prints a notice and exits 3, and the
#    workflow pushes the image and stops green. Any other answer than "not found" is a failure.
# 2. The function must be State Active with LastUpdateStatus Successful: an update in progress or a failed one would
#    make UpdateFunctionCode fail half way.
# 3. The app secret must have a current value (an AWSCURRENT version). DescribeSecret returns metadata only; version
#    IDs are never printed.
# 4. N4: the deploy role must be denied the secret value. The call asks for the secret name only, so even a broken
#    deny could not return the value; the answer must be AccessDeniedException.
# Names derive from ENV (default dev). Error text is printed with 12-digit runs replaced.
#
# Usage: ENV=dev scripts/lambda/preflight.sh
# Exit codes: 0 ready, 1 not ready or a failure, 3 the function does not exist yet (first run of the environment).

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 0 ] || die "usage: ENV=dev scripts/lambda/preflight.sh"
require_cmd aws "the AWS CLI is preinstalled on GitHub runners"
require_cmd jq "apt-get install jq"
app_names

run_capture aws lambda get-function-configuration --function-name "$FUNCTION" --query '[State, LastUpdateStatus]' --output text
if [ "$RUN_RC" -ne 0 ]; then
  case "$RUN_ERR" in
    *ResourceNotFoundException*)
      warn "function not created yet: run terraform-iac apply for ${ENV} after this push"
      exit 3
      ;;
    *AccessDeniedException*) die "deploy role cannot read the function ${FUNCTION}: re-apply bootstrap (ADR 0012 L9): $RUN_ERR" ;;
    *) die "get-function-configuration failed (exit code $RUN_RC): $RUN_ERR" ;;
  esac
fi
state="" update=""
IFS=$'\t' read -r state update <<<"$RUN_OUT"
case "$state" in
  Active) ;;
  Pending) die "function ${FUNCTION} is Pending (an update or a reactivation is running): Re-run failed jobs in a minute" ;;
  Inactive) die "function ${FUNCTION} is Inactive (idle for weeks, ADR 0012 Finding 3): one request through the API starts the reactivation (it is rejected while Pending), then Re-run failed jobs" ;;
  *) die "function ${FUNCTION} is in state '$(printf '%s' "$state" | redact_ids)', expected Active" ;;
esac
case "$update" in
  Successful) ;;
  InProgress) die "an update of ${FUNCTION} is in progress: Re-run failed jobs when it ends" ;;
  *) die "the last update of ${FUNCTION} is '$(printf '%s' "$update" | redact_ids)', expected Successful (read the function in the console)" ;;
esac
ok "function ${FUNCTION} is Active and its last update succeeded"

not_up="the ${ENV} stack is not complete. Re-create it (terraform-iac, Run workflow), set the secret value, then run the deploy again."
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
