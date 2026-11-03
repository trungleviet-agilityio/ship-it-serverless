#!/usr/bin/env bash
# Publish one immutable Lambda version for one image digest (ADR 0012 L6, L7, L8). Needs the AWS CLI with deploy
# credentials and jq. Names derive from ENV (default dev).
#
# Rollback and re-run path: when a published version already serves this commit and digest, it is reused and nothing
# changes. A version qualifies by its description `sha=<sha> digest=<digest>` or, failing that, by its IMAGE_DIGEST
# (the newest such version wins); either way its resolved image must end with @<digest> and its IMAGE_DIGEST must be
# <digest>. A version found by IMAGE_DIGEST alone (for example version 1, which Terraform published at create with its
# own description) is reused with a warning.
# Otherwise, in this order:
#   0. read the environment first: it must name this environment (APP_ENV=<env>), or nothing is changed;
#   1. UpdateFunctionCode with <repository uri>@<digest> (by digest, never by tag), then wait for the update;
#   2. ONE UpdateFunctionConfiguration that merges IMAGE_DIGEST=<digest> into the environment Terraform set (read back
#      first; no other key may change) and sets the function description `sha=<sha> digest=<digest>`. Then wait again.
#      ADR 0012 L6, L7 (review B1): the digest and the description are set BEFORE PublishVersion, so every version
#      carries its own digest, and $LATEST differs from a version Terraform published with the same image;
#   3. PublishVersion with the same description, and wait until the version is Active;
#   4. prove the version: its resolved image URI ends with @<digest> and its IMAGE_DIGEST is <digest>. PublishVersion
#      returns the last version when code and configuration are unchanged since it was published; such a version is
#      accepted when image and IMAGE_DIGEST match (REUSED=true, with a warning that names its other description).
# Terraform ignores the function description (ADR 0012 L3), so a later apply does not undo step 2.
# The environment holds the secret ARN (with the account ID) and the image URI holds the registry host: neither is
# ever printed. Error text goes through the account ID redaction.
#
# Prints on stdout: VERSION=<n> and REUSED=<true|false>, ready to append to $GITHUB_OUTPUT.
#
# Usage: ENV=dev scripts/lambda/publish.sh <repository uri> <digest> <commit sha>
#   <repository uri> is <account>.dkr.ecr.<region>.amazonaws.com/<prefix>-<env>-app
# Exit codes: 0 published or reused, 1 refused or failed.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 3 ] || die "usage: ENV=dev scripts/lambda/publish.sh <repository uri> <digest> <commit sha>"
repo="$1" digest="$2" sha="$3"
require_cmd aws "the AWS CLI is preinstalled on GitHub runners"
require_cmd jq "apt-get install jq"
app_names

repo_re="^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/${REPOSITORY}\$"
[[ "$repo" =~ $repo_re ]] || die "the repository must be <account>.dkr.ecr.<region>.amazonaws.com/${REPOSITORY} (a tag, a digest or another repository is refused)"
valid_digest "$digest" || die "the digest must be sha256:<64 hex>"
valid_sha "$sha" || die "the commit must be 40 lowercase hex characters"
description="$(lambda_version_description "$sha" "$digest")"

# aws_json <label> <command...>: run an AWS call that must succeed and print JSON; RUN_OUT holds the answer.
aws_json() {
  local label="$1"
  shift
  run_capture "$@"
  [ "$RUN_RC" -eq 0 ] || die "${label} failed (exit code $RUN_RC): $RUN_ERR"
  if [ -z "$RUN_OUT" ] || ! printf '%s' "$RUN_OUT" | jq empty >/dev/null 2>&1; then die "${label} returned no JSON"; fi
}

# verify_version <n>: the version runs <digest> and carries IMAGE_DIGEST=<digest>, or the script dies. Sets
# VERSION_DESCRIPTION to the description of the version (it may differ from ours: see step 4 above).
verify_version() {
  local problem
  aws_json "get-function (version $1)" aws lambda get-function --function-name "$FUNCTION" --qualifier "$1" --output json
  problem="$(printf '%s' "$RUN_OUT" | jq -r --arg d "$digest" '
    [
      (if ((.Code.ResolvedImageUri // "") | endswith("@" + $d)) then empty else "its resolved image is not @" + $d end),
      (if (.Configuration.Environment.Variables.IMAGE_DIGEST // "") == $d then empty else "its IMAGE_DIGEST is not " + $d end)
    ] | .[0] // ""')"
  [ -z "$problem" ] || die "version $1 refused: ${problem}"
  VERSION_DESCRIPTION="$(printf '%s' "$RUN_OUT" | jq -r '.Configuration.Description // ""')"
}

# reused_notice <n>: the warning for a version whose image and IMAGE_DIGEST match but whose description is not ours.
reused_notice() {
  warn "version $1 runs ${digest} with IMAGE_DIGEST ${digest} but its description is \"$(printf '%s' "$VERSION_DESCRIPTION" | redact_ids)\", not \"${description}\" (published by Terraform, or by an earlier run with the same code and configuration): reused"
}

# wait_updated: the waiter polls GetFunction until LastUpdateStatus is Successful (fails on Failed).
wait_updated() {
  run_capture aws lambda wait function-updated-v2 --function-name "$FUNCTION"
  [ "$RUN_RC" -eq 0 ] || die "the update of ${FUNCTION} did not finish (exit code $RUN_RC): $RUN_ERR"
}

# --- Reuse: a version that already serves this commit and digest (rollback, a re-run after the publish, or the version
# Terraform published at create). By description first, else by IMAGE_DIGEST; the newest match wins.
aws_json "list-versions-by-function" aws lambda list-versions-by-function --function-name "$FUNCTION" --output json
existing="$(printf '%s' "$RUN_OUT" | jq -r --arg desc "$description" --arg d "$digest" '
  [(.Versions // [])[] | select((.Version // "") | test("^[0-9]+$"))] as $numbered
  | ([$numbered[] | select((.Description // "") == $desc) | .Version | tonumber] | max)
    // ([$numbered[] | select((.Environment.Variables.IMAGE_DIGEST // "") == $d) | .Version | tonumber] | max)
    // empty')"
if [ -n "$existing" ]; then
  verify_version "$existing"
  if [ "$VERSION_DESCRIPTION" = "$description" ]; then
    ok "version ${existing} already serves ${digest} (commit ${sha}): reused, nothing published"
  else
    reused_notice "$existing"
  fi
  printf 'VERSION=%s\nREUSED=true\n' "$existing"
  exit 0
fi

# env_problem <environment json>: why the deploy may not touch this function's environment, or nothing.
env_problem() {
  printf '%s' "$1" | jq -r --arg env "$ENV" '
    if type != "object" then "the function has no environment variables (Terraform sets them)"
    elif .APP_ENV != $env then "APP_ENV must be " + $env + " (a hand-made function is never deployed to)"
    else "" end'
}
# read_config: CONFIG_ENV holds the environment variables of the unpublished function and CONFIG_DESCRIPTION its
# description.
read_config() {
  aws_json "get-function-configuration" aws lambda get-function-configuration --function-name "$FUNCTION" \
    --query '{Variables: Environment.Variables, Description: Description}' --output json
  CONFIG_ENV="$(printf '%s' "$RUN_OUT" | jq -c '.Variables')"
  CONFIG_DESCRIPTION="$(printf '%s' "$RUN_OUT" | jq -r '.Description // ""')"
}

# --- 0. Refuse before any change when the environment is not Terraform's.
read_config
problem="$(env_problem "$CONFIG_ENV")"
[ -z "$problem" ] || die "publish refused: ${problem}"

# --- 1. Code, by digest.
run_capture aws lambda update-function-code --function-name "$FUNCTION" --image-uri "${repo}@${digest}" --query LastUpdateStatus --output text
[ "$RUN_RC" -eq 0 ] || die "update-function-code failed (exit code $RUN_RC): $RUN_ERR"
wait_updated
log "code of ${FUNCTION} updated to ${digest}"

# --- 2. IMAGE_DIGEST (merged into the environment Terraform owns, read again: it is the base of the update) and the
# description, in one configuration update.
read_config
current="$CONFIG_ENV"
problem="$(env_problem "$current")"
[ -z "$problem" ] || die "publish refused: ${problem}"
merged="$(printf '%s' "$current" | jq -c --arg d "$digest" '. + {IMAGE_DIGEST: $d}')"
# Only IMAGE_DIGEST may differ; any other change would be drift Terraform must make.
printf '%s\n%s' "$current" "$merged" | jq -s -e '(.[0] | del(.IMAGE_DIGEST)) == (.[1] | del(.IMAGE_DIGEST))' >/dev/null \
  || die "publish refused: the merge would change a key other than IMAGE_DIGEST"
if [ "$(printf '%s' "$current" | jq -r '.IMAGE_DIGEST // ""')" = "$digest" ] && [ "$CONFIG_DESCRIPTION" = "$description" ]; then
  log "IMAGE_DIGEST and the description already name ${digest}"
else
  run_capture aws lambda update-function-configuration --function-name "$FUNCTION" \
    --environment "$(jq -cn --argjson v "$merged" '{Variables: $v}')" --description "$description" \
    --query LastUpdateStatus --output text
  [ "$RUN_RC" -eq 0 ] || die "update-function-configuration failed (exit code $RUN_RC): $RUN_ERR"
  wait_updated
  log "IMAGE_DIGEST and the description set to ${digest}"
fi

# --- 3. Publish and wait until the version can be invoked.
run_capture aws lambda publish-version --function-name "$FUNCTION" --description "$description" --query Version --output text
[ "$RUN_RC" -eq 0 ] || die "publish-version failed (exit code $RUN_RC): $RUN_ERR"
version="$RUN_OUT"
[[ "$version" =~ ^[0-9]+$ ]] || die "publish-version returned '$(printf '%s' "$version" | redact_ids)', not a version number"
run_capture aws lambda wait published-version-active --function-name "$FUNCTION" --qualifier "$version"
[ "$RUN_RC" -eq 0 ] || die "version ${version} did not become Active (exit code $RUN_RC): $RUN_ERR"

# --- 4. Prove it. A version with another description is the last one, returned because nothing changed.
verify_version "$version"
if [ "$VERSION_DESCRIPTION" = "$description" ]; then
  ok "published version ${version}: ${description}"
  printf 'VERSION=%s\nREUSED=false\n' "$version"
else
  reused_notice "$version"
  printf 'VERSION=%s\nREUSED=true\n' "$version"
fi
