#!/usr/bin/env bash
# Smoke-invoke one published version before it gets any traffic (ADR 0012 L7). Needs the AWS CLI with deploy
# credentials and jq. Names derive from ENV (default dev).
# The version is invoked directly (--qualifier), not through the alias, with an API Gateway HTTP API payload v2.0
# event (lambda_http_event in lib.sh), the same shape the HTTP API sends, so the Lambda Web Adapter forwards it to the
# app as a GET request:
#   GET /health   must answer 200;
#   GET /version  must answer 200 with JSON git_sha == <commit sha> and image_digest == <digest>.
# A body with isBase64Encoded is decoded first. Retries (the first invoke of a new version is a cold start, and a
# version can still be Pending): each path is tried up to SMOKE_ATTEMPTS times (default 3) while the invoke fails (the
# CLI call fails, except AccessDeniedException, which never heals) or answers with a FunctionError (the adapter or the
# app did not start in time). Attempt n waits n * SMOKE_RETRY_SLEEP seconds first (default 5, so 5 s then 10 s).
# A clean HTTP answer is judged as it is, as before: /health may answer non-200 up to SMOKE_ATTEMPTS times (a cold
# start can answer 503 once), /version is judged on its first clean answer. An unreadable invoke status or payload, or
# an invoke status other than 200, fails at once.
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
[[ "$attempts" =~ ^[1-9][0-9]?$ ]] && [[ "$retry_sleep" =~ ^[0-9]+$ ]] || die "SMOKE_ATTEMPTS must be 1 to 99 and SMOKE_RETRY_SLEEP whole seconds"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# invoke <path>: invoke the version once. Sets STATUS (HTTP status of the app) and BODY on a clean answer and returns 0;
# returns 2 with RETRY_REASON set when the call failed or answered a FunctionError (worth a retry); dies on anything
# else.
invoke() {
  local out="$work/response.json" meta problem
  rm -f "$out"
  STATUS="" BODY="" RETRY_REASON=""
  run_capture aws lambda invoke --function-name "$FUNCTION" --qualifier "$version" \
    --cli-binary-format raw-in-base64-out --payload "$(lambda_http_event "$1" smoke-invoke)" --output json "$out"
  if [ "$RUN_RC" -ne 0 ]; then
    case "$RUN_ERR" in
      *AccessDeniedException*) die "invoke of version ${version} (GET $1) failed (exit code $RUN_RC): $RUN_ERR" ;;
    esac
    RETRY_REASON="the invoke failed (exit code $RUN_RC): $RUN_ERR"
    return 2
  fi
  meta="$RUN_OUT"
  problem="$(printf '%s' "$meta" | jq -r '
    if (.FunctionError // "") != "" then "FunctionError " + .FunctionError
    elif (.StatusCode // 0) != 200 then "invoke status " + ((.StatusCode // "none") | tostring)
    else "" end' 2>/dev/null)" || die "invoke of version ${version} returned unreadable metadata"
  case "$problem" in
    "") ;;
    FunctionError*)
      RETRY_REASON="${problem}: $(head -c 500 "$out" 2>/dev/null | redact_ids)"
      return 2
      ;;
    *) die "version ${version} failed GET $1: ${problem}: $(head -c 500 "$out" 2>/dev/null | redact_ids)" ;;
  esac
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

# get <path> <clean answers allowed>: invoke until a clean answer, at most SMOKE_ATTEMPTS invokes in all. A clean
# answer that is not 200 is retried only while fewer than <clean answers allowed> were seen. CLEAN counts them.
get() {
  local path="$1" allowed="$2" n=1 rc
  CLEAN=0
  while :; do
    rc=0
    invoke "$path" || rc=$?
    if [ "$rc" -eq 0 ]; then
      CLEAN=$((CLEAN + 1))
      [ "$STATUS" != 200 ] || return 0
      [ "$CLEAN" -lt "$allowed" ] && [ "$n" -lt "$attempts" ] || return 0
      warn "version ${version}: GET ${path} answered ${STATUS} (attempt ${n} of ${attempts}); retrying in $((n * retry_sleep))s"
    else
      [ "$n" -lt "$attempts" ] || die "version ${version} failed GET ${path} ${n} time(s): ${RETRY_REASON}"
      warn "version ${version}: GET ${path}: ${RETRY_REASON} (attempt ${n} of ${attempts}); retrying in $((n * retry_sleep))s"
    fi
    sleep $((n * retry_sleep))
    n=$((n + 1))
  done
}

STATUS="" BODY="" RETRY_REASON="" CLEAN=0
get /health "$attempts"
[ "$STATUS" = 200 ] || die "version ${version}: GET /health answered ${STATUS} ${CLEAN} time(s), expected 200"
ok "version ${version}: GET /health is 200"

get /version 1
[ "$STATUS" = 200 ] || die "version ${version}: GET /version answered ${STATUS}, expected 200"
got="$(printf '%s' "$BODY" | jq -r '[.git_sha // "missing", .image_digest // "missing"] | @tsv' 2>/dev/null)" \
  || die "version ${version}: GET /version is not JSON"
got_sha="${got%%$'\t'*}" got_digest="${got#*$'\t'}"
[ "$got_sha" = "$sha" ] || die "version ${version}: /version git_sha is '$(printf '%s' "$got_sha" | redact_ids)', expected ${sha}"
[ "$got_digest" = "$digest" ] || die "version ${version}: /version image_digest is '$(printf '%s' "$got_digest" | redact_ids)', expected ${digest}"
ok "version ${version}: /version shows commit ${sha} and ${digest}"
