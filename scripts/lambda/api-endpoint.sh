#!/usr/bin/env bash
# Print the endpoint of the environment's HTTP API (ADR 0012 L2), found by its name <prefix>-<env>-api with
# apigatewayv2 GetApis (the deploy role may GET /apis). Exactly one API must have the name. Needs the AWS CLI with deploy
# credentials and jq. Names derive from ENV (default dev).
#
# Prints on stdout: API_ENDPOINT=https://<api id>.execute-api.<region>.amazonaws.com, ready to append to $GITHUB_OUTPUT
# or $GITHUB_ENV. The endpoint holds no account ID.
#
# Usage: ENV=dev scripts/lambda/api-endpoint.sh
# Exit codes: 0 found, 1 none, several, or a failure.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 0 ] || die "usage: ENV=dev scripts/lambda/api-endpoint.sh"
require_cmd aws "the AWS CLI is preinstalled on GitHub runners"
require_cmd jq "apt-get install jq"
app_names

# The CLI follows NextToken itself for get-apis.
run_capture aws apigatewayv2 get-apis --output json
[ "$RUN_RC" -eq 0 ] || die "get-apis failed (exit code $RUN_RC): $RUN_ERR"
endpoints="$(printf '%s' "$RUN_OUT" | jq -r --arg name "$API" '[(.Items // [])[] | select(.Name == $name) | .ApiEndpoint] | .[]' 2>/dev/null)" \
  || die "get-apis returned no API list"
count="$(printf '%s' "$endpoints" | grep -c . || true)"
[ "$count" -eq 1 ] || die "expected exactly one HTTP API named ${API}, found ${count} (run terraform-iac apply for ${ENV})"
[[ "$endpoints" =~ ^https://[a-z0-9]+\.execute-api\.[a-z0-9-]+\.amazonaws\.com$ ]] \
  || die "the endpoint of ${API} has an unexpected form: '$(printf '%s' "$endpoints" | redact_ids)'"
ok "${API}: ${endpoints}"
printf 'API_ENDPOINT=%s\n' "$endpoints"
