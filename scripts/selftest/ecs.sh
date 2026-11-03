#!/usr/bin/env bash
# Self-tests of the CI helper scripts: the rollout evaluation and wait loop, the preflight, the service status helper and the revision cleanup.
# Run by scripts/ci/selftest.sh; also runnable alone. A bad fixture must fail with its message.

# shellcheck source=scripts/selftest/common.sh
source "$(dirname "$0")/common.sh"

# --- ecs/wait-deployment.sh --evaluate
td_new="arn:aws:ecs:ap-southeast-1:${acct}:task-definition/sis-dev-app:8"
td_old="arn:aws:ecs:ap-southeast-1:${acct}:task-definition/sis-dev-app:7"
# svc <status> <deployments json> [events json]
svc() { printf '{"services":[{"status":"%s","deployments":%s,"events":%s}],"failures":[]}' "$1" "$2" "${3:-[]}"; }
# eval_json <describe-services json>: run --evaluate on it.
# Always called inside $( ): the ERR trap is cleared there so exit code 10 (continue) is not reported as a crash.
eval_json() {
  trap - ERR
  printf '%s' "$1" | "$ROOT/scripts/ecs/wait-deployment.sh" --evaluate "$td_new"
}
dep() { printf '{"status":"%s","rolloutState":"%s","taskDefinition":"%s","rolloutStateReason":"%s"}' "$1" "$2" "$3" "${4:-}"; }

out="$(eval_json "$(svc ACTIVE "[$(dep PRIMARY COMPLETED "$td_new")]")" 2>/dev/null)" || die "selftest: completed rollout should succeed"
[ "$out" = "SUCCESS" ] || die "selftest: expected SUCCESS, got $out"
rc=0
out="$(eval_json "$(svc ACTIVE "[$(dep PRIMARY IN_PROGRESS "$td_new"),$(dep ACTIVE COMPLETED "$td_old")]")" 2>/dev/null)" || rc=$?
{ [ "$rc" -eq 10 ] && [ "$out" = "CONTINUE" ]; } || die "selftest: in-progress rollout should continue (exit 10), got $rc $out"
ok "evaluate: success and continue"

failed="[$(dep ACTIVE FAILED "$td_new" "tasks failed to start in ${acct}"),$(dep PRIMARY COMPLETED "$td_old")]"
events="[{\"message\":\"service sis-dev-app (task ${acct}) failed\"}]"
expect_fail "evaluate a failed rollout" "rollout failed" eval_json "$(svc ACTIVE "$failed" "$events")"
out="$(eval_json "$(svc ACTIVE "$failed" "$events")" 2>&1 || true)"
case "$out" in
  *"tasks failed to start in <redacted>"*"task <redacted>"*) ;;
  *) die "selftest: reason and events must be printed with 12-digit runs redacted: $out" ;;
esac
case "$out" in *"$acct"*) die "selftest: the failed rollout output holds a 12-digit run" ;; esac
ok "evaluate: failure prints the reason and redacts digits"

expect_fail "evaluate a rolled-back rollout" "rolled back by the circuit breaker" \
  eval_json "$(svc ACTIVE "[$(dep PRIMARY COMPLETED "$td_old")]")"
expect_fail "evaluate an empty services list" "stack is not up" eval_json '{"services":[],"failures":[]}'
expect_fail "evaluate a MISSING failure" "stack is not up" eval_json '{"services":[],"failures":[{"reason":"MISSING"}]}'
expect_fail "evaluate an inactive service" "stack is not up" eval_json "$(svc DRAINING "[$(dep PRIMARY COMPLETED "$td_new")]")"

# --- ecs/wait-deployment.sh polling loop
progress="$(svc ACTIVE "[$(dep PRIMARY IN_PROGRESS "$td_new")]")"
completed="$(svc ACTIVE "[$(dep PRIMARY COMPLETED "$td_new")]")"
wait_script() { stubbed env ECS_WAIT_POLL=0 "$ROOT/scripts/ecs/wait-deployment.sh" c s "$td_new" "$@"; }
stub_reset
stub aws-ecs-describe-services out "$progress" 0
stub aws-ecs-describe-services out "$completed"
wait_script 30 >/dev/null 2>&1 || die "selftest: the wait loop should succeed after one poll"
stub_reset
stub aws-ecs-describe-services out "$progress"
expect_fail "wait that never completes" "timeout after 0s" wait_script 0
throttle="An error occurred (ThrottlingException) when calling the DescribeServices operation for ${acct}"
stub_reset
for n in 0 1; do
  stub aws-ecs-describe-services rc 255 "$n"
  stub aws-ecs-describe-services err "$throttle" "$n"
done
stub aws-ecs-describe-services out "$completed"
out="$(wait_script 30 2>&1)" || die "selftest: two describe-services failures in a row must be tolerated: $out"
case "$out" in *"ThrottlingException"*"<redacted>"*) ;; *) die "selftest: the redacted failure text was not printed: $out" ;; esac
stub_reset
stub aws-ecs-describe-services rc 255
stub aws-ecs-describe-services err "An error occurred (AccessDeniedException) for ${acct}"
out="$(wait_script 30 2>&1 || true)"
case "$out" in
  *"failed 3 times in a row"*"AccessDeniedException"*) ;;
  *) die "selftest: three describe-services failures must stop the wait with the error: $out" ;;
esac
case "$out" in *"stack is not up"* | *"$acct"*) die "selftest: the failure must not blame the stack or print digits: $out" ;; esac
ok "wait loop polls, tolerates two failures, stops on three, and times out"

# --- ecs/preflight.sh
secret_denied="An error occurred (AccessDeniedException) when calling the GetSecretValue operation for ${acct}"
version_id="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
stages_current="{\"${version_id}\":[\"AWSCURRENT\"],\"ffffffff-bbbb-cccc-dddd-eeeeeeeeeeee\":[\"AWSPREVIOUS\"]}"
preflight() { stubbed env ENV="${PREFLIGHT_ENV:-dev}" "$ROOT/scripts/ecs/preflight.sh"; }
preflight_ready() {
  stub_reset
  stub aws-ecs-describe-services out ACTIVE
  stub aws-secretsmanager-describe-secret out "$stages_current"
  stub aws-secretsmanager-get-secret-value rc 254
  stub aws-secretsmanager-get-secret-value err "$secret_denied"
}
preflight_ready
preflight >/dev/null 2>&1 || die "selftest: the preflight of a healthy stack failed"
calls_have "--cluster sis-dev-cluster --services sis-dev-app" || die "selftest: the preflight did not derive the dev names"
calls_have "--secret-id sis/dev/app-api-key" || die "selftest: the preflight did not derive the dev secret"
PREFLIGHT_ENV=prod preflight >/dev/null 2>&1 || die "selftest: the prod preflight failed"
calls_have "--cluster sis-prod-cluster" || die "selftest: the preflight did not derive the prod names"
ok "preflight passes for an active stack and a denied secret"
preflight_ready
stub aws-ecs-describe-services rc 254
stub aws-ecs-describe-services err "An error occurred (ClusterNotFoundException) when calling DescribeServices"
expect_fail "preflight without a cluster" "the dev stack is not up" preflight
preflight_ready
stub aws-ecs-describe-services rc 254
stub aws-ecs-describe-services err "An error occurred (ThrottlingException) for ${acct}"
expect_fail "preflight with throttling" "describe-services failed (exit code 254): An error occurred (ThrottlingException) for <redacted>" preflight
for status in INACTIVE None; do
  preflight_ready
  stub aws-ecs-describe-services out "$status"
  expect_fail "preflight with service status $status" "the dev stack is not up" preflight
done
preflight_ready
stub aws-secretsmanager-get-secret-value rc 0
stub aws-secretsmanager-get-secret-value out "sis/dev/app-api-key"
expect_fail "preflight when the deploy role can read the secret" "N4 (deploy role, GetSecretValue) failed: the call succeeded" preflight
preflight_ready
stub aws-secretsmanager-get-secret-value err "An error occurred (ResourceNotFoundException)"
expect_fail "preflight with another N4 error" "N4 (deploy role, GetSecretValue) failed for a reason other than AccessDeniedException" preflight

# The secret must have an AWSCURRENT version (ADR 0006, G14); the answer is metadata and is never echoed.
preflight_ready
out="$(preflight 2>&1)" || die "selftest: the preflight of a secret with a current value failed: $out"
case "$out" in *"$version_id"*) die "selftest: the preflight printed a secret version ID" ;; esac
calls_have "describe-secret --secret-id sis/dev/app-api-key" || die "selftest: the preflight did not describe the secret"
for stages in null '{}' '{"v1":["AWSPENDING"]}' '{"v1":["AWSPREVIOUS"],"v2":["AWSPENDING"]}'; do
  preflight_ready
  stub aws-secretsmanager-describe-secret out "$stages"
  expect_fail "preflight with secret stages $stages" "secret sis/dev/app-api-key has no current value" preflight
done
preflight_ready
stub aws-secretsmanager-describe-secret out ""
expect_fail "preflight with an empty describe-secret answer" "has no current value" preflight
preflight_ready
stub aws-secretsmanager-describe-secret rc 254
stub aws-secretsmanager-describe-secret err "An error occurred (AccessDeniedException) when calling DescribeSecret for ${acct}"
out="$(preflight 2>&1 || true)"
case "$out" in
  *"re-apply bootstrap"*) ;;
  *) die "selftest: describe-secret AccessDenied must ask for a bootstrap re-apply: $out" ;;
esac
case "$out" in *"$acct"*) die "selftest: the describe-secret failure printed a 12-digit run" ;; esac
preflight_ready
stub aws-secretsmanager-describe-secret rc 254
stub aws-secretsmanager-describe-secret err "An error occurred (ResourceNotFoundException) when calling DescribeSecret"
expect_fail "preflight with no secret" "the dev stack is not up" preflight
preflight_ready
stub aws-secretsmanager-describe-secret rc 254
stub aws-secretsmanager-describe-secret err "An error occurred (ThrottlingException) for ${acct}"
expect_fail "preflight with describe-secret throttling" "describe-secret failed (exit code 254): An error occurred (ThrottlingException) for <redacted>" preflight
ok "preflight requires a current secret value and handles describe-secret errors"

# --- ecs_service_status (lib.sh): sets SERVICE_STATUS instead of printing, so callers need no `|| exit 1`
# shellcheck disable=SC2016  # the inner script is meant to expand in the child shell
service_status() { stubbed bash -c 'source "$1/scripts/lib.sh"; ecs_service_status sis-dev-cluster sis-dev-app; printf "%s" "$SERVICE_STATUS"' _ "$ROOT"; }
for status in ACTIVE DRAINING INACTIVE; do
  stub_reset
  stub aws-ecs-describe-services out "$status"
  [ "$(service_status 2>/dev/null)" = "$status" ] || die "selftest: ecs_service_status must keep $status"
done
for answer in None MISSING ""; do
  stub_reset
  stub aws-ecs-describe-services out "$answer"
  [ "$(service_status 2>/dev/null)" = "MISSING" ] || die "selftest: ecs_service_status must map '$answer' to MISSING"
done
stub_reset
stub aws-ecs-describe-services rc 254
stub aws-ecs-describe-services err "An error occurred (ClusterNotFoundException) when calling DescribeServices"
[ "$(service_status 2>/dev/null)" = "MISSING" ] || die "selftest: ecs_service_status must map ClusterNotFoundException to MISSING"
stub_reset
stub aws-ecs-describe-services rc 254
stub aws-ecs-describe-services err "An error occurred (ThrottlingException) for ${acct}"
expect_fail "ecs_service_status with throttling" "describe-services failed (exit code 254): An error occurred (ThrottlingException) for <redacted>" service_status
# An unknown status must fail closed: it never reads as "the service is gone".
for answer in STOPPED active "ACTIVE INACTIVE"; do
  stub_reset
  stub aws-ecs-describe-services out "$answer"
  expect_fail "ecs_service_status with the unknown status '$answer'" "describe-services returned an unexpected status: $answer" service_status
done
ok "ecs_service_status maps every answer to one of four states and refuses the rest"
# The preflight and the revision cleanup stop on an unknown status instead of reading it as missing.
preflight_ready
stub aws-ecs-describe-services out STOPPED
expect_fail "preflight with an unknown service status" "unexpected status" preflight
# --- ecs/deregister-revisions.sh
# dereg [env [max revisions]]
dereg() { stubbed env ENV="${1:-dev}" MAX_REVISIONS="${2:-200}" DEREGISTER_RETRY_SLEEP=0 "$ROOT/scripts/ecs/deregister-revisions.sh"; }
client_exception="An error occurred (ClientException) when calling the DescribeTaskDefinition operation: Unable to describe task definition."
# dereg_ready <revision>...: the service is gone, the family returns the revisions in order, then ClientException.
dereg_ready() {
  local n=0 r
  stub_reset
  stub aws-ecs-describe-services out None
  for r in "$@"; do
    stub aws-ecs-describe-task-definition out "$r" "$n"
    n=$((n + 1))
  done
  stub aws-ecs-describe-task-definition rc 254 "$n"
  stub aws-ecs-describe-task-definition err "$client_exception" "$n"
  stub aws-ecs-deregister-task-definition out INACTIVE
}
dereg_ready 9 8 7
out="$(dereg 2>/dev/null)" || die "selftest: ecs/deregister-revisions failed on three revisions"
[ "$out" = "DEREGISTERED=3" ] || die "selftest: ecs/deregister-revisions printed: $out"
[ "$(grep -c 'deregister-task-definition' "$sd/calls")" = 3 ] || die "selftest: expected three deregistrations"
[ "$(grep 'deregister-task-definition' "$sd/calls" | sed 's/.*--task-definition //; s/ .*//' | tr '\n' ' ')" = "sis-dev-app:9 sis-dev-app:8 sis-dev-app:7 " ] \
  || die "selftest: revisions were not deregistered newest first"
dereg_ready
[ "$(dereg 2>/dev/null)" = "DEREGISTERED=0" ] || die "selftest: no revisions must print DEREGISTERED=0"
! calls_have "deregister-task-definition" || die "selftest: nothing to deregister, but a call was made"
dereg_ready 3
stub aws-ecs-describe-services rc 254
stub aws-ecs-describe-services err "An error occurred (ClusterNotFoundException) when calling DescribeServices"
[ "$(dereg 2>/dev/null)" = "DEREGISTERED=1" ] || die "selftest: a missing cluster means the service is gone"
dereg_ready 3
stub aws-ecs-describe-services out INACTIVE
[ "$(dereg 2>/dev/null)" = "DEREGISTERED=1" ] || die "selftest: an INACTIVE service means the service is gone"
dereg_ready 3
[ "$(dereg prod 2>/dev/null)" = "DEREGISTERED=1" ] || die "selftest: the prod revision cleanup failed"
calls_have "sis-prod-app:3" || die "selftest: ENV=prod must derive sis-prod-app"
ok "ecs/deregister-revisions cleans every active revision once the service is gone"
for status in ACTIVE DRAINING; do
  dereg_ready 9
  stub aws-ecs-describe-services out "$status"
  expect_fail "revision cleanup with a $status service" "still exists" dereg
  ! calls_have "deregister-task-definition" || die "selftest: a $status service must keep its revisions"
done
# Eventual consistency: the revision that was just deregistered may come back once. The describe is retried once.
dereg_ready 9 9
[ "$(dereg 2>/dev/null)" = "DEREGISTERED=1" ] || die "selftest: a revision that returns once must be retried, not deregistered twice"
[ "$(grep -c 'deregister-task-definition' "$sd/calls")" = 1 ] || die "selftest: the retried revision was deregistered again"
[ "$(cat "$sd/aws-ecs-describe-task-definition.n")" = 3 ] || die "selftest: the repeated revision must be described exactly once more"
dereg_ready 9 9 9
expect_fail "revision cleanup with a revision that keeps returning" "revision 9 returned again" dereg
# DEREGISTERED is printed on failure too, so a summary shows how far the cleanup got.
dereg_ready 9 9 9
out="$(dereg 2>/dev/null || true)"
[ "$out" = "DEREGISTERED=1" ] || die "selftest: a failed cleanup must still print the count so far, got: $out"
dereg_ready 9 8 7
expect_fail "revision cleanup over the cap" "more than 2 active revisions" dereg dev 2
dereg_ready 9 8 7
[ "$(dereg dev 2 2>/dev/null || true)" = "DEREGISTERED=2" ] || die "selftest: the count at the cap must be printed"
dereg_ready 9
stub aws-ecs-describe-services out ACTIVE
[ "$(dereg 2>/dev/null || true)" = "DEREGISTERED=0" ] || die "selftest: a refused cleanup must print DEREGISTERED=0"
dereg_ready 9
stub aws-ecs-describe-task-definition rc 254 0
stub aws-ecs-describe-task-definition err "An error occurred (AccessDeniedException) for ${acct}" 0
out="$(dereg 2>&1 || true)"
case "$out" in
  *"describe-task-definition failed (exit code 254): An error occurred (AccessDeniedException) for <redacted>"*) ;;
  *) die "selftest: a describe error must fail with redacted text: $out" ;;
esac
dereg_ready 9
stub aws-ecs-deregister-task-definition rc 254
stub aws-ecs-deregister-task-definition err "An error occurred (AccessDeniedException) for ${acct}"
expect_fail "revision cleanup when deregister fails" "deregister-task-definition failed (exit code 254)" dereg
dereg_ready 9
stub aws-ecs-deregister-task-definition out ACTIVE
expect_fail "revision cleanup when the revision stays ACTIVE" "expected INACTIVE" dereg
dereg_ready not-a-number
expect_fail "revision cleanup with a non-numeric revision" "not a revision number" dereg

# --- names.sh role: the role name only, never the session name (it carries the run ID)
role_name() { stubbed "$ROOT/scripts/names.sh" role; }
stub_reset
stub aws-sts-get-caller-identity out "arn:aws:sts::${acct}:assumed-role/sis-dev-gha-apply/gha-apply-12345-1"
[ "$(role_name 2>/dev/null)" = "sis-dev-gha-apply" ] || die "selftest: names role must print the role name only"
stub_reset
stub aws-sts-get-caller-identity out "arn:aws:iam::${acct}:user/someone"
expect_fail "names role for an IAM user" "not an assumed role" role_name
stub_reset
stub aws-sts-get-caller-identity rc 254
stub aws-sts-get-caller-identity err "An error occurred (ExpiredToken) for ${acct}"
expect_fail "names role without credentials" "not an assumed role" role_name
ok "names role prints the role name and fails closed"
