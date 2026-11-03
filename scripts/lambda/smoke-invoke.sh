#!/usr/bin/env bash
# Smoke-invoke one published version before it gets any traffic (ADR 0012 L7). Needs the AWS CLI with deploy
# credentials and jq. Names derive from ENV (default dev).
# The version is invoked directly (--qualifier), not through the alias, with an API Gateway HTTP API payload v2.0
# event, the same shape the HTTP API sends, so the Lambda Web Adapter forwards it to the app as a GET request:
#   GET /health   must answer 200;
#   GET /version  must answer 200 with JSON git_sha == <commit sha> and image_digest == <digest>.
# A FunctionError (the handler or the adapter failed), a non-200 invoke status or an unreadable payload fails. A body
# with isBase64Encoded is decoded first. /health is tried SMOKE_ATTEMPTS times (default 3, SMOKE_RETRY_SLEEP seconds
# apart, default 5), because the first invoke of a new version is a cold start.
#
# Usage: ENV=dev scripts/lambda/smoke-invoke.sh <version> <commit sha> <digest>
# Exit codes: 0 the version answers as expected, 1 it does not.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 3 ] || die "usage: ENV=dev scripts/lambda/smoke-invoke.sh <version> <commit sha> <digest>"
version="$1" sha="$2" digest="$3"
require_cmd aws "the AWS CLI is preinstalled on GitHub runners"
require_cmd jq "apt-get install jq"
app_names
[[ "$version" =~ ^[0-9]+$ ]] || die "the version must be a published version number (not \$LATEST or an alias)"
valid_sha "$sha" || die "the commit must be 40 lowercase hex characters"
valid_digest "$digest" || die "the digest must be sha256:<64 hex>"
attempts="${SMOKE_ATTEMPTS:-3}" retry_sleep="${SMOKE_RETRY_SLEEP:-5}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# event <path>: an HTTP API payload v2.0 event for GET <path> (no account ID: accountId is "anonymous").
event() {
  jq -cn --arg path "$1" --arg id "smoke-$RANDOM" --argjson now "$(date +%s)" '{
    version: "2.0", routeKey: "$default", rawPath: $path, rawQueryString: "",
    headers: {accept: "application/json", host: "smoke-invoke.invalid", "user-agent": "smoke-invoke"},
    requestContext: {
      accountId: "anonymous", apiId: "smoke", domainName: "smoke-invoke.invalid", domainPrefix: "smoke-invoke",
      http: {method: "GET", path: $path, protocol: "HTTP/1.1", sourceIp: "127.0.0.1", userAgent: "smoke-invoke"},
      requestId: $id, routeKey: "$default", stage: "$default",
      time: ($now | strftime("%d/%b/%Y:%H:%M:%S +0000")), timeEpoch: ($now * 1000)
    },
    isBase64Encoded: false
  }'
}

# invoke <path>: invoke the version; sets STATUS (HTTP status of the app) and BODY, or dies.
invoke() {
  local out="$work/response.json" meta problem
  rm -f "$out"
  run_capture aws lambda invoke --function-name "$FUNCTION" --qualifier "$version" \
    --cli-binary-format raw-in-base64-out --payload "$(event "$1")" --output json "$out"
  [ "$RUN_RC" -eq 0 ] || die "invoke of version ${version} (GET $1) failed (exit code $RUN_RC): $RUN_ERR"
  meta="$RUN_OUT"
  problem="$(printf '%s' "$meta" | jq -r '
    if (.FunctionError // "") != "" then "FunctionError " + .FunctionError
    elif (.StatusCode // 0) != 200 then "invoke status " + ((.StatusCode // "none") | tostring)
    else "" end' 2>/dev/null)" || die "invoke of version ${version} returned unreadable metadata"
  [ -z "$problem" ] || die "version ${version} failed GET $1: ${problem}: $(head -c 500 "$out" 2>/dev/null | redact_ids)"
  if [ ! -f "$out" ] || ! jq -e 'type == "object" and (.statusCode | type) == "number"' "$out" >/dev/null 2>&1; then
    die "version ${version} returned no HTTP API response for GET $1 (statusCode missing)"
  fi
  STATUS="$(jq -r '.statusCode' "$out")"
  if [ "$(jq -r '.isBase64Encoded // false' "$out")" = "true" ]; then
    BODY="$(jq -r '.body // ""' "$out" | base64 -d 2>/dev/null)" || die "version ${version} returned a body that is not valid base64 for GET $1"
  else
    BODY="$(jq -r '.body // ""' "$out")"
  fi
}

STATUS="" BODY=""
n=1
while :; do
  invoke /health
  [ "$STATUS" != 200 ] || break
  [ "$n" -lt "$attempts" ] || die "version ${version}: GET /health answered ${STATUS} ${n} time(s), expected 200"
  warn "version ${version}: GET /health answered ${STATUS} (attempt ${n} of ${attempts}); retrying in ${retry_sleep}s"
  n=$((n + 1))
  sleep "$retry_sleep"
done
ok "version ${version}: GET /health is 200"

invoke /version
[ "$STATUS" = 200 ] || die "version ${version}: GET /version answered ${STATUS}, expected 200"
got="$(printf '%s' "$BODY" | jq -r '[.git_sha // "missing", .image_digest // "missing"] | @tsv' 2>/dev/null)" \
  || die "version ${version}: GET /version is not JSON"
got_sha="${got%%$'\t'*}" got_digest="${got#*$'\t'}"
[ "$got_sha" = "$sha" ] || die "version ${version}: /version git_sha is '$(printf '%s' "$got_sha" | redact_ids)', expected ${sha}"
[ "$got_digest" = "$digest" ] || die "version ${version}: /version image_digest is '$(printf '%s' "$got_digest" | redact_ids)', expected ${digest}"
ok "version ${version}: /version shows commit ${sha} and ${digest}"
