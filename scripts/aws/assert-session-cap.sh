#!/usr/bin/env bash
# Session cap test (PLAN N9, ADR 0007 S32): a role with max_session_duration 3600 refuses a longer session, and a
# short session reports when it ends. Both calls use the job's own token against the named role, so run it where
# that role trusts the token (the plan role on a pull request). Credentials never reach stdout or the log: the
# successful call keeps only the expiration time.
#
# Usage: scripts/aws/assert-session-cap.sh <plan|apply|deploy>
# Env:   ACCOUNT  AWS account ID (masked)   REGION  AWS region   ENV  environment name (default dev)
#        ACTIONS_ID_TOKEN_REQUEST_URL and _TOKEN (set by GitHub when the job has id-token: write)

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 1 ] || die "usage: scripts/aws/assert-session-cap.sh <plan|apply|deploy>"
role="$1"

mask "${ACCOUNT:?ACCOUNT is not set}"
token="$(oidc_token)"

# One second over the cap must be refused for the duration, not for the trust. The message names both the requested
# DurationSeconds and the role's MaxSessionDuration.
assert_denied "a 3601 second session on the ${role} role" DurationSeconds \
  web_identity_call "$role" "$token" --duration-seconds 3601 --query Credentials.Expiration --output text

# The shortest session STS allows (900 seconds): the answer is the expiration time only.
run_capture web_identity_call "$role" "$token" --duration-seconds 900 --query Credentials.Expiration --output text
[ "$RUN_RC" -eq 0 ] || die "a 900 second session was refused on the ${role} role (exit code ${RUN_RC}): ${RUN_ERR}"
printf 'session expires in about 15 minutes (%s)\n' "$RUN_OUT"
