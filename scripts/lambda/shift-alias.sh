#!/usr/bin/env bash
# Move the serving alias `live` (ADR 0012 L7, L8). Needs the AWS CLI with deploy credentials and jq. Names derive from
# ENV (default dev).
#   <version>                    all at once: `live` points at <version>, with no additional weights;
#   <version> --weight <pct>     canary: `live` keeps its primary version and sends <pct> percent (1 to 50) to <version>;
#   --clear-weights              abort a canary: the additional weights are removed, the primary keeps 100 percent.
# A release to the version that is already the primary is a no-op (a rollback or a re-run of a version that is live):
# all at once changes nothing when `live` already points at <version> with no additional weights, and a canary never
# weights the primary (that would be AdditionalVersionWeights on the version that already gets the rest); both print a
# notice and exit 0 without UpdateAlias. All at once to the primary while another version still has a weight clears
# that weight.
# Prints the alias state on stdout as key=value lines (ALIAS_VERSION=<primary>, ALIAS_WEIGHTS=<json of the additional
# weights>, ALIAS_CHANGED=<true|false>), ready to append to $GITHUB_OUTPUT. ALIAS_CHANGED=false tells the workflow to
# skip the canary bake.
#
# Usage: ENV=dev scripts/lambda/shift-alias.sh <version> [--weight <pct>]
#        ENV=dev scripts/lambda/shift-alias.sh --clear-weights
# Exit codes: 0 the alias is in the asked state, 1 refused or failed.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

usage="usage: ENV=dev scripts/lambda/shift-alias.sh <version> [--weight <pct>] | --clear-weights"
mode="" version="" pct=""
case "$#:${1:-}:${2:-}" in
  1:--clear-weights:) mode=clear ;;
  1:*:) mode=all; version="$1" ;;
  3:*:--weight) mode=weight; version="$1"; pct="$3" ;;
  *) die "$usage" ;;
esac
require_cmd aws "the AWS CLI is preinstalled on GitHub runners"
require_cmd jq "apt-get install jq"
app_names
if [ "$mode" != clear ]; then
  [[ "$version" =~ ^[1-9][0-9]*$ ]] || die "the version must be a published version number (not \$LATEST, not an alias), got '${version}'"
fi
if [ "$mode" = weight ]; then
  [[ "$pct" =~ ^[1-9][0-9]?$ ]] && [ "$pct" -le 50 ] || die "the canary weight must be a whole percent from 1 to 50, got '${pct}'"
fi

# alias_call <command...>: an alias call that must succeed; RUN_OUT holds the alias JSON.
alias_call() {
  run_capture "$@"
  [ "$RUN_RC" -eq 0 ] || die "${2} ${3} failed (exit code $RUN_RC): $RUN_ERR"
  printf '%s' "$RUN_OUT" | jq -e '.FunctionVersion | type == "string"' >/dev/null 2>&1 || die "${2} ${3} returned no alias"
}

# noop <reason>: the alias is already in the asked state: print it and stop.
noop() {
  local weights
  weights="$(printf '%s' "$RUN_OUT" | jq -c '.RoutingConfig.AdditionalVersionWeights // {}')"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then printf '::notice::%s\n' "$1" >&2; else log "$1"; fi
  printf 'ALIAS_VERSION=%s\nALIAS_WEIGHTS=%s\nALIAS_CHANGED=false\n' "$version" "$weights"
  exit 0
}

if [ "$mode" != clear ]; then
  alias_call aws lambda get-alias --function-name "$FUNCTION" --name "$ALIAS" --output json
  primary="$(printf '%s' "$RUN_OUT" | jq -r '.FunctionVersion')"
  current_weights="$(printf '%s' "$RUN_OUT" | jq -c '.RoutingConfig.AdditionalVersionWeights // {}')"
  if [ "$primary" = "$version" ]; then
    if [ "$mode" = weight ]; then
      noop "version ${version} is already the primary of ${ALIAS}: nothing to canary, the alias is unchanged"
    elif [ "$current_weights" = "{}" ]; then
      noop "version ${version} is already the primary of ${ALIAS} with no additional weights: nothing to move"
    fi
  fi
fi

case "$mode" in
  all)
    alias_call aws lambda update-alias --function-name "$FUNCTION" --name "$ALIAS" --function-version "$version" \
      --routing-config '{"AdditionalVersionWeights":{}}' --output json
    ;;
  weight)
    weights="$(jq -cn --arg v "$version" --argjson p "$pct" '{AdditionalVersionWeights: {($v): ($p / 100)}}')"
    alias_call aws lambda update-alias --function-name "$FUNCTION" --name "$ALIAS" --function-version "$primary" \
      --routing-config "$weights" --output json
    ;;
  clear)
    alias_call aws lambda update-alias --function-name "$FUNCTION" --name "$ALIAS" \
      --routing-config '{"AdditionalVersionWeights":{}}' --output json
    ;;
esac

state="$RUN_OUT"
primary="$(printf '%s' "$state" | jq -r '.FunctionVersion')"
weights="$(printf '%s' "$state" | jq -c '.RoutingConfig.AdditionalVersionWeights // {}')"
case "$mode" in
  all) [ "$primary" = "$version" ] && [ "$weights" = "{}" ] || die "the alias did not move: primary ${primary}, weights ${weights}" ;;
  weight)
    printf '%s' "$weights" | jq -e --arg v "$version" 'keys == [$v]' >/dev/null \
      || die "the alias does not route to ${version}: weights ${weights}"
    ;;
  clear) [ "$weights" = "{}" ] || die "the additional weights were not removed: ${weights}" ;;
esac
ok "${ALIAS} -> version ${primary}, additional weights ${weights}"
printf 'ALIAS_VERSION=%s\nALIAS_WEIGHTS=%s\nALIAS_CHANGED=true\n' "$primary" "$weights"
