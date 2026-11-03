#!/usr/bin/env bash
# Negative OIDC test (PLAN N1 and N8, ADR 0007 S31): the job's GitHub token must be refused by each named role.
# It asks STS directly with an unsigned call, so only an explicit AccessDenied passes. A success means the trust is
# too broad; any other error (network, bad ARN, throttling) fails too, because it proves nothing about the trust.
# Prints the token's `sub` and `job_workflow_ref` (they hold no account ID), never the token or the account.
#
# Usage: scripts/aws/assert-web-identity-denied.sh <plan|apply|deploy>...
# Env:   ACCOUNT  AWS account ID (masked)   REGION  AWS region   ENV  environment name (default dev)
#        ACTIONS_ID_TOKEN_REQUEST_URL and _TOKEN (set by GitHub when the job has id-token: write)

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -ge 1 ] || die "usage: scripts/aws/assert-web-identity-denied.sh <plan|apply|deploy>..."

mask "${ACCOUNT:?ACCOUNT is not set}"
token="$(oidc_token)"
printf 'Token sub: %s\n' "$(jwt_claim "$token" sub)" >&2
printf 'Token job_workflow_ref: %s\n' "$(jwt_claim "$token" job_workflow_ref)" >&2

for role in "$@"; do
  assert_denied "the ${role} role" AccessDenied web_identity_call "$role" "$token"
done
