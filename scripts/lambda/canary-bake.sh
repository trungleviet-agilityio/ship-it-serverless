#!/usr/bin/env bash
# Judge a canary (ADR 0012 L7) while `live` sends a weight to <version>. Needs the AWS CLI with deploy credentials and
# jq, nothing else: the probes never leave the Lambda API, so the credentialed job allows no execute-api host (review
# M1). Names derive from ENV (default dev).
# 1. Probes. For <minutes>, one probe every CANARY_PROBE_INTERVAL seconds (default 5): `lambda invoke` of the ALIAS
#    (--qualifier live), so the alias weights decide which version serves it, with the HTTP API v2 event smoke-invoke
#    sends (lambda_http_event in lib.sh), for GET /health, /version and / in rotation. Each probe records the
#    ExecutedVersion the CLI prints and the statusCode of the payload. Judgment, per probe:
#      - served by <version> with a FunctionError, or with a statusCode that is not 2xx: failed. With the Lambda Web
#        Adapter an app 500 is a successful invoke whose payload says 500, so the status is the real signal;
#      - a failed `lambda invoke` call, or an answer without ExecutedVersion: failed too (the version is unknown, so it
#        may be the new one: fail closed);
#      - served by another version: not judged (a failure there is counted and warned about, it is not the canary's).
#    Lab traffic is synthetic: the probes are the traffic the canary is judged on.
# 2. Enough evidence. At least CANARY_MIN_HITS probes (default 3) must have been served by <version>. With a small
#    weight that can miss by chance (10 percent of 60 probes is 6 expected hits), so the bake is extended, not failed:
#    probing goes on, with a warning, until the minimum is reached or CANARY_EXTEND_PROBES more probes were sent
#    (default: as many as the planned bake, so the bake at most doubles). Still too few hits then fails: raise
#    canary_percent or bake_minutes.
# 3. Crash-only second signal. The Lambda Errors metric (crashes and timeouts, not HTTP 500) of the new version through
#    the alias (dimensions FunctionName, Resource=<function>:live, ExecutedVersion=<version>), Sum since the bake
#    started. CloudWatch metrics arrive late, so Errors and Invocations are read up to CANARY_METRIC_ATTEMPTS times
#    (default 7), CANARY_METRIC_POLL seconds apart (default 30, so about 3 minutes): the window has settled once
#    Invocations counts at least the probes the new version served. Any error fails at once; a window that never
#    settles is judged on what it shows, with a warning.
# Passes only with zero failed probes, enough hits and zero errors. The caller removes the weight on failure
# (shift-alias.sh --clear-weights) and moves `live` on success.
# Prints on stdout (also on failure): CANARY_PROBES=<n>, CANARY_NEW_HITS=<n>, CANARY_FAILED_PROBES=<n>,
# CANARY_ERRORS=<n>, CANARY_INVOCATIONS=<n>.
#
# Usage: ENV=dev scripts/lambda/canary-bake.sh <version> <minutes>   (<minutes> 1 to 30)
# Exit codes: 0 the canary is healthy, 1 it is not (or a check failed).
# Test overrides (whole seconds or counts): CANARY_PROBE_INTERVAL, CANARY_MIN_HITS, CANARY_EXTEND_PROBES,
# CANARY_METRIC_POLL, CANARY_METRIC_ATTEMPTS (the self-tests set the waits to 0).

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 2 ] || die "usage: ENV=dev scripts/lambda/canary-bake.sh <version> <minutes>"
version="$1" minutes="$2"
require_cmd aws "the AWS CLI is preinstalled on GitHub runners"
require_cmd jq "apt-get install jq"
app_names
[[ "$version" =~ ^[1-9][0-9]*$ ]] || die "the version must be a published version number, got '${version}'"
[[ "$minutes" =~ ^[1-9][0-9]?$ ]] && [ "$minutes" -le 30 ] || die "the bake time must be 1 to 30 minutes, got '${minutes}'"
interval="${CANARY_PROBE_INTERVAL:-5}" min_hits="${CANARY_MIN_HITS:-3}" extend="${CANARY_EXTEND_PROBES:-}"
metric_poll="${CANARY_METRIC_POLL:-30}" metric_attempts="${CANARY_METRIC_ATTEMPTS:-7}"
for n in "$interval" "$min_hits" "$metric_poll" "$metric_attempts" "${extend:-0}"; do
  [[ "$n" =~ ^[0-9]+$ ]] || die "CANARY_PROBE_INTERVAL, CANARY_MIN_HITS, CANARY_EXTEND_PROBES, CANARY_METRIC_POLL and CANARY_METRIC_ATTEMPTS must be whole numbers"
done
[ "$metric_attempts" -ge 1 ] || die "CANARY_METRIC_ATTEMPTS must be at least 1"

planned=$((minutes * 60 / (interval > 0 ? interval : 5)))
extend="${extend:-$planned}"
probes=0 hits=0 failed=0 other_failed=0 errors="" invocations=""
work="$(mktemp -d)"
# The counts are printed on every exit, so a failed bake still shows how far it got.
trap 'rm -rf "$work"; printf "CANARY_PROBES=%s\nCANARY_NEW_HITS=%s\nCANARY_FAILED_PROBES=%s\nCANARY_ERRORS=%s\nCANARY_INVOCATIONS=%s\n" "$probes" "$hits" "$failed" "${errors:-unknown}" "${invocations:-unknown}"' EXIT

# probe_path <n>: the path of probe n (0-based), in rotation.
probe_path() {
  case $(($1 % 3)) in 0) printf '/health' ;; 1) printf '/version' ;; *) printf '/' ;; esac
}

# probe: one invoke of the alias, judged as described above.
probe() {
  local path out="$work/probe.json" meta executed fn_error status label
  path="$(probe_path "$probes")"
  probes=$((probes + 1))
  label="probe ${probes} (GET ${path})"
  rm -f "$out"
  run_capture aws lambda invoke --function-name "$FUNCTION" --qualifier "$ALIAS" \
    --cli-binary-format raw-in-base64-out --payload "$(lambda_http_event "$path" canary-bake)" --output json "$out"
  if [ "$RUN_RC" -ne 0 ]; then
    failed=$((failed + 1))
    warn "${label}: the invoke failed (exit code ${RUN_RC}), the serving version is unknown: ${RUN_ERR}"
    return 0
  fi
  meta="$RUN_OUT"
  executed="$(printf '%s' "$meta" | jq -r '.ExecutedVersion // ""' 2>/dev/null)" || executed=""
  fn_error="$(printf '%s' "$meta" | jq -r '.FunctionError // ""' 2>/dev/null)" || fn_error=""
  status="$(jq -r 'if type == "object" and (.statusCode | type) == "number" then .statusCode else "none" end' "$out" 2>/dev/null)" || status="none"
  if [ -z "$executed" ]; then
    failed=$((failed + 1))
    warn "${label}: the answer names no ExecutedVersion, so it may be the new version (status ${status})"
    return 0
  fi
  if [ "$executed" != "$version" ]; then
    case "${fn_error}:${status}" in
      :2[0-9][0-9]) ;;
      *) other_failed=$((other_failed + 1)); warn "${label}: served by version ${executed} (not the canary): ${fn_error:+FunctionError ${fn_error}, }status ${status}" ;;
    esac
    return 0
  fi
  hits=$((hits + 1))
  case "${fn_error}:${status}" in
    :2[0-9][0-9]) ;;
    *)
      failed=$((failed + 1))
      warn "${label}: served by version ${version}: ${fn_error:+FunctionError ${fn_error}, }status ${status}: $(head -c 300 "$out" 2>/dev/null | redact_ids)"
      ;;
  esac
}

start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "baking version ${version} for ${minutes} minute(s): ${planned} invokes of ${ALIAS} (GET /health, /version, / in rotation)"
while [ "$probes" -lt "$planned" ]; do
  probe
  if [ "$probes" -lt "$planned" ]; then sleep "$interval"; fi
done
if [ "$hits" -lt "$min_hits" ] && [ "$failed" -eq 0 ]; then
  warn "only ${hits} of ${probes} probes reached version ${version} (minimum ${min_hits}): extending the bake by up to ${extend} probes"
  cap=$((planned + extend))
  while [ "$hits" -lt "$min_hits" ] && [ "$failed" -eq 0 ] && [ "$probes" -lt "$cap" ]; do
    sleep "$interval"
    probe
  done
fi
log "probes done: ${probes} sent, ${hits} served by version ${version}, ${failed} failed, ${other_failed} failed on another version"

[ "$failed" -eq 0 ] || die "canary failed: ${failed} probe(s) served by version ${version} (or by an unknown version) were not 2xx"
[ "$hits" -ge "$min_hits" ] \
  || die "canary failed: only ${hits} of ${probes} probes reached version ${version}, the minimum is ${min_hits} (raise canary_percent or bake_minutes)"

# metric_sum <metric name>: the Sum of the metric for the version through the alias since the bake started.
metric_sum() {
  local end
  end="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  run_capture aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name "$1" \
    --dimensions "Name=FunctionName,Value=${FUNCTION}" "Name=Resource,Value=${FUNCTION}:${ALIAS}" "Name=ExecutedVersion,Value=${version}" \
    --start-time "$start" --end-time "$end" --period 60 --statistics Sum --output json
  [ "$RUN_RC" -eq 0 ] || die "get-metric-statistics ($1) failed (exit code $RUN_RC): $RUN_ERR"
  printf '%s' "$RUN_OUT" | jq -er '[(.Datapoints // [])[].Sum] | add // 0 | floor' 2>/dev/null \
    || die "get-metric-statistics ($1) returned no datapoint list"
}
attempt=1
while :; do
  errors="$(metric_sum Errors)"
  [ "$errors" -eq 0 ] || die "canary failed: version ${version} reported ${errors} error(s) (crashes or timeouts) in the bake window"
  invocations="$(metric_sum Invocations)"
  if [ "$invocations" -ge "$hits" ]; then break; fi
  if [ "$attempt" -ge "$metric_attempts" ]; then
    warn "the metrics show ${invocations} of the ${hits} invocations of version ${version} after ${attempt} reads: judged on what they show"
    break
  fi
  log "metrics not settled (${invocations} of ${hits} invocations of version ${version}); reading again in ${metric_poll}s"
  attempt=$((attempt + 1))
  sleep "$metric_poll"
done
ok "canary healthy: ${probes} probes, ${hits} on version ${version}, 0 failed, 0 errors, ${invocations} invocation(s) in the metrics"
