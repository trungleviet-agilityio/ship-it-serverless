#!/usr/bin/env bash
# Judge a canary (ADR 0012 L7) while `live` sends a weight to <version>. Needs curl, the AWS CLI with deploy credentials
# and jq. Names derive from ENV (default dev).
# 1. For <minutes>, one GET /health through the HTTP API every CANARY_PROBE_INTERVAL seconds (default 5), so
#    60 / interval probes per minute, each with a 5 second timeout. A probe that is not 2xx (or gets no answer) counts
#    as failed. Lab traffic is synthetic: the probes are the traffic the canary is judged on.
# 2. After CANARY_METRIC_DELAY seconds (default 60; CloudWatch metrics arrive late), the Lambda Errors metric of the
#    new version through the alias (dimensions FunctionName, Resource=<function>:live, ExecutedVersion=<version>),
#    Sum over the bake window. Invocations of the same dimensions are read too: zero means the canary saw no traffic,
#    which is reported but not a failure.
# Passes only with zero failed probes and zero errors. The caller removes the weight on failure (shift-alias.sh
# --clear-weights) and moves `live` on success.
# Prints on stdout: CANARY_PROBES=<n>, CANARY_FAILED_PROBES=<n>, CANARY_ERRORS=<n>, CANARY_INVOCATIONS=<n>.
#
# Usage: ENV=dev scripts/lambda/canary-bake.sh <api endpoint> <version> <minutes>
#   <api endpoint> is https://<api id>.execute-api.<region>.amazonaws.com (api-endpoint.sh); <minutes> 1 to 30
# Exit codes: 0 the canary is healthy, 1 it is not (or a check failed).
# Test overrides: CANARY_PROBE_INTERVAL, CANARY_METRIC_DELAY (seconds; 0 in the self-tests).

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 3 ] || die "usage: ENV=dev scripts/lambda/canary-bake.sh <api endpoint> <version> <minutes>"
endpoint="$1" version="$2" minutes="$3"
require_cmd curl "curl is preinstalled on GitHub runners"
require_cmd aws "the AWS CLI is preinstalled on GitHub runners"
require_cmd jq "apt-get install jq"
app_names
[[ "$endpoint" =~ ^https://[a-z0-9]+\.execute-api\.[a-z0-9-]+\.amazonaws\.com$ ]] \
  || die "the API endpoint must be https://<api id>.execute-api.<region>.amazonaws.com, got '$(printf '%s' "$endpoint" | redact_ids)'"
[[ "$version" =~ ^[1-9][0-9]*$ ]] || die "the version must be a published version number, got '${version}'"
[[ "$minutes" =~ ^[1-9][0-9]?$ ]] && [ "$minutes" -le 30 ] || die "the bake time must be 1 to 30 minutes, got '${minutes}'"
interval="${CANARY_PROBE_INTERVAL:-5}" metric_delay="${CANARY_METRIC_DELAY:-60}"
[[ "$interval" =~ ^[0-9]+$ ]] && [[ "$metric_delay" =~ ^[0-9]+$ ]] || die "CANARY_PROBE_INTERVAL and CANARY_METRIC_DELAY must be whole seconds"

probes=$((minutes * 60 / (interval > 0 ? interval : 5)))
failed=0 errors="" invocations=""
trap 'printf "CANARY_PROBES=%s\nCANARY_FAILED_PROBES=%s\nCANARY_ERRORS=%s\nCANARY_INVOCATIONS=%s\n" "$probes" "$failed" "${errors:-unknown}" "${invocations:-unknown}"' EXIT

start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "baking version ${version} for ${minutes} minute(s): ${probes} probes of GET /health through the API"
i=0
while [ "$i" -lt "$probes" ]; do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "${endpoint}/health" 2>/dev/null)" || code="000"
  case "$code" in
    2[0-9][0-9]) ;;
    *) failed=$((failed + 1)); warn "probe $((i + 1)) of ${probes}: GET /health answered ${code}" ;;
  esac
  i=$((i + 1))
  if [ "$i" -lt "$probes" ]; then sleep "$interval"; fi
done
log "probes done: ${failed} of ${probes} failed; reading the metrics in ${metric_delay}s"
sleep "$metric_delay"
end="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# metric_sum <metric name>: the Sum of the metric for the version through the alias over the bake window.
metric_sum() {
  run_capture aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name "$1" \
    --dimensions "Name=FunctionName,Value=${FUNCTION}" "Name=Resource,Value=${FUNCTION}:${ALIAS}" "Name=ExecutedVersion,Value=${version}" \
    --start-time "$start" --end-time "$end" --period 60 --statistics Sum --output json
  [ "$RUN_RC" -eq 0 ] || die "get-metric-statistics ($1) failed (exit code $RUN_RC): $RUN_ERR"
  printf '%s' "$RUN_OUT" | jq -er '[(.Datapoints // [])[].Sum] | add // 0 | floor' 2>/dev/null \
    || die "get-metric-statistics ($1) returned no datapoint list"
}
errors="$(metric_sum Errors)"
invocations="$(metric_sum Invocations)"
if [ "$invocations" = 0 ]; then
  warn "the metrics show no invocation of version ${version} yet (low weight or late metrics): the judgment rests on the probes"
fi

[ "$failed" -eq 0 ] || die "canary failed: ${failed} of ${probes} probes were not 2xx"
[ "$errors" -eq 0 ] || die "canary failed: version ${version} reported ${errors} error(s) in the bake window"
ok "canary healthy: ${probes} probes, 0 failed, 0 errors, ${invocations} invocation(s) of version ${version}"
