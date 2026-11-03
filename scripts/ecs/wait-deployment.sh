#!/usr/bin/env bash
# Wait for an ECS rollout and report the truth (ADR 0005, F17). `aws ecs wait services-stable` also succeeds
# after a circuit-breaker rollback, so this reads the rolloutState of the deployment for the task definition we
# registered. Needs the AWS CLI and jq. Never prints ARNs: 12-digit runs are replaced in every message.
# A failing describe-services call is retried (throttling, a network blip) up to MAX_DESCRIBE_FAILURES times in a
# row; the redacted error is printed each time, and the script never guesses the cause.
#
# Usage:
#   scripts/ecs/wait-deployment.sh <cluster> <service> <task definition arn> [timeout seconds, default DEFAULT_WAIT_TIMEOUT in lib.sh]
#   scripts/ecs/wait-deployment.sh --evaluate <task definition arn> < describe-services.json
# Evaluate mode prints one word on stdout and a message on stderr:
#   SUCCESS (exit 0), CONTINUE (exit 10), FAILED, ROLLED_BACK, NOT_UP (exit 1).
# Test override: ECS_WAIT_POLL (seconds between polls, default 15).

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

require_cmd jq "brew install jq"

# evaluate <td arn>: read describe-services JSON on stdin and decide.
evaluate() {
  local td="$1" out state msg
  out="$(jq -r --arg td "$td" '
    def redact: gsub("[0-9]{12}"; "<redacted>");
    (.services // []) as $s
    | if ($s | length) == 0 or ((.failures // []) | any(.reason == "MISSING")) then
        "NOT_UP\tstack is not up (service not found)"
      elif $s[0].status != "ACTIVE" then
        "NOT_UP\tstack is not up (service is not ACTIVE)"
      else
        ($s[0].deployments // []) as $d
        | ($d | map(select(.taskDefinition == $td)) | .[0]) as $mine
        | ($d | map(select(.status == "PRIMARY")) | .[0]) as $primary
        | if $mine == null then
            (if $primary != null then "ROLLED_BACK\tthe deployment is gone and the service runs another revision (rolled back by the circuit breaker)"
             else "NOT_UP\tstack is not up (service has no primary deployment)" end)
          elif $mine.rolloutState == "COMPLETED" and $mine.status == "PRIMARY" then
            "SUCCESS\trollout completed"
          elif $mine.rolloutState == "COMPLETED" then
            "FAILED\tthe deployment completed but a newer deployment replaced it"
          elif $mine.rolloutState == "FAILED" then
            "FAILED\trollout failed (circuit breaker rollback in progress): " + (($mine.rolloutStateReason // "no reason given") | redact)
              + " | last events: " + ([($s[0].events // [])[:5][].message | redact] | join(" ; "))
          else
            "CONTINUE\trollout " + ($mine.rolloutState // "pending")
          end
      end
  ')" || die "could not read describe-services JSON"
  state="${out%%$'\t'*}"
  msg="${out#*$'\t'}"
  printf '%s\n' "$state"
  case "$state" in
    SUCCESS) ok "$msg"; return 0 ;;
    CONTINUE) log "$msg"; return 10 ;;
    *) die "$msg" ;;
  esac
}

if [ "${1:-}" = "--evaluate" ]; then
  [ $# -eq 2 ] || die "usage: scripts/ecs/wait-deployment.sh --evaluate <task definition arn>"
  rc=0
  evaluate "$2" || rc=$?
  exit "$rc"
fi

{ [ $# -ge 3 ] && [ $# -le 4 ]; } || die "usage: scripts/ecs/wait-deployment.sh <cluster> <service> <task definition arn> [timeout seconds]"
cluster="$1" service="$2" td="$3" timeout="${4:-$DEFAULT_WAIT_TIMEOUT}"
poll="${ECS_WAIT_POLL:-15}"
MAX_DESCRIBE_FAILURES=3
require_cmd aws "the AWS CLI is preinstalled on GitHub runners"

start="$SECONDS" failures=0
while :; do
  run_capture aws ecs describe-services --cluster "$cluster" --services "$service" --output json
  if [ "$RUN_RC" -ne 0 ]; then
    failures=$((failures + 1))
    warn "describe-services failed (exit code $RUN_RC, $failures of $MAX_DESCRIBE_FAILURES): $RUN_ERR"
    [ "$failures" -lt "$MAX_DESCRIBE_FAILURES" ] \
      || die "describe-services failed $MAX_DESCRIBE_FAILURES times in a row (last exit code $RUN_RC): $RUN_ERR"
  else
    failures=0
    rc=0
    printf '%s' "$RUN_OUT" | evaluate "$td" >/dev/null || rc=$?
    case "$rc" in
      0) exit 0 ;;
      10) ;;
      *) exit 1 ;;
    esac
  fi
  if [ $((SECONDS - start)) -ge "$timeout" ]; then
    die "timeout after ${timeout}s: the rollout is still IN_PROGRESS"
  fi
  sleep "$poll"
done
