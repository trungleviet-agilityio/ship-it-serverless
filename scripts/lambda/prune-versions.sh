#!/usr/bin/env bash
# Delete old published versions (ADR 0012 L8): keep the newest <keep> numbered versions (default DEFAULT_KEEP_VERSIONS
# in lib.sh, 10) and every version the alias `live` references (its primary and its additional weights); delete the
# rest, oldest first. ECR keeps 20 images, so no kept version points at a deleted image.
# Every delete names a version qualifier: `lambda delete-function --function-name <function> --qualifier <n>`. A call
# without a qualifier would delete the whole function; the deploy role cannot (DeleteFunction is allowed on qualified
# ARNs only, ADR 0012 L9) and this script refuses before calling. Needs the AWS CLI with deploy credentials and jq.
# Names derive from ENV (default dev).
# Prints PRUNED=<count> on stdout, also when the script fails (an EXIT trap), so a summary shows how far it got.
#
# Usage: ENV=dev scripts/lambda/prune-versions.sh [keep]   (keep: 2 to 50)
# Exit codes: 0 pruned (or nothing to prune), 1 refused or failed.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -le 1 ] || die "usage: ENV=dev scripts/lambda/prune-versions.sh [keep]"
keep="${1:-$DEFAULT_KEEP_VERSIONS}"
[[ "$keep" =~ ^[1-9][0-9]?$ ]] && [ "$keep" -ge 2 ] && [ "$keep" -le 50 ] || die "keep must be a whole number from 2 to 50, got '${keep}'"
require_cmd aws "the AWS CLI is preinstalled on GitHub runners"
require_cmd jq "apt-get install jq"
app_names

count=0
trap 'printf "PRUNED=%s\n" "$count"' EXIT

# delete_version <n>: the only delete in this script, always with a numbered qualifier.
delete_version() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] || die "refusing to delete without a numbered version qualifier (got '${1:-}')"
  run_capture aws lambda delete-function --function-name "$FUNCTION" --qualifier "$1"
  [ "$RUN_RC" -eq 0 ] || die "delete-function ${FUNCTION}:$1 failed (exit code $RUN_RC): $RUN_ERR"
  log "deleted version $1"
  count=$((count + 1))
}

run_capture aws lambda get-alias --function-name "$FUNCTION" --name "$ALIAS" --output json
[ "$RUN_RC" -eq 0 ] || die "get-alias ${ALIAS} failed (exit code $RUN_RC): $RUN_ERR"
referenced="$(printf '%s' "$RUN_OUT" | jq -c '[.FunctionVersion] + ((.RoutingConfig.AdditionalVersionWeights // {}) | keys)' 2>/dev/null)" \
  || die "get-alias returned no alias"
printf '%s' "$referenced" | jq -e 'length > 0 and all(test("^[0-9]+$"))' >/dev/null \
  || die "the alias ${ALIAS} references something other than numbered versions: ${referenced}"

run_capture aws lambda list-versions-by-function --function-name "$FUNCTION" --output json
[ "$RUN_RC" -eq 0 ] || die "list-versions-by-function failed (exit code $RUN_RC): $RUN_ERR"
doomed="$(printf '%s' "$RUN_OUT" | jq -r --argjson keep "$keep" --argjson ref "$referenced" '
  [(.Versions // [])[] | .Version | select(test("^[0-9]+$")) | tonumber] | sort | reverse
  | .[$keep:] | map(tostring) | map(select(. as $v | $ref | index($v) | not)) | reverse | .[]' 2>/dev/null)" \
  || die "list-versions-by-function returned no version list"

if [ -z "$doomed" ]; then
  ok "nothing to prune (keeping the newest ${keep} and the versions of ${ALIAS}: $(printf '%s' "$referenced" | jq -r 'join(", ")'))"
  exit 0
fi
for v in $doomed; do delete_version "$v"; done
ok "pruned ${count} version(s); kept the newest ${keep} and the versions of ${ALIAS}"
