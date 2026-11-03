#!/usr/bin/env bash
# Publish one immutable Lambda version for one image digest (ADR 0012 L6, L7, L8). Needs the AWS CLI with deploy
# credentials and jq. Names derive from ENV (default dev).
#
# Rollback and re-run path: when a published version already has the description `sha=<sha> digest=<digest>` (and
# its image is that digest), it is reused and nothing changes.
# Otherwise, in this order:
#   0. read the environment first: it must name this environment (APP_ENV=<env>), or nothing is changed;
#   1. UpdateFunctionCode with <repository uri>@<digest> (by digest, never by tag), then wait for the update;
#   2. merge IMAGE_DIGEST=<digest> into the environment Terraform set (read back first). The environment must name this
#      environment (APP_ENV=<env>); no other key may change. Then wait again. ADR 0012 L6: the digest is set BEFORE
#      PublishVersion, so every version carries its own;
#   3. PublishVersion with the description above, and wait until the version is Active;
#   4. prove the version: its resolved image URI ends with @<digest>, its IMAGE_DIGEST is <digest>, and its description
#      is the one asked for (PublishVersion returns an existing version when nothing changed).
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

# verify_version <n>: the version runs <digest> and carries IMAGE_DIGEST=<digest> and the description.
verify_version() {
  local problem
  aws_json "get-function (version $1)" aws lambda get-function --function-name "$FUNCTION" --qualifier "$1" --output json
  problem="$(printf '%s' "$RUN_OUT" | jq -r --arg d "$digest" --arg desc "$description" '
    [
      (if ((.Code.ResolvedImageUri // "") | endswith("@" + $d)) then empty else "its resolved image is not @" + $d end),
      (if (.Configuration.Environment.Variables.IMAGE_DIGEST // "") == $d then empty else "its IMAGE_DIGEST is not " + $d end),
      (if (.Configuration.Description // "") == $desc then empty else "its description is not \"" + $desc + "\" (PublishVersion returned an existing version with the same code and configuration)" end)
    ] | .[0] // ""')"
  [ -z "$problem" ] || die "version $1 refused: ${problem}"
}

# wait_updated: the waiter polls GetFunction until LastUpdateStatus is Successful (fails on Failed).
wait_updated() {
  run_capture aws lambda wait function-updated-v2 --function-name "$FUNCTION"
  [ "$RUN_RC" -eq 0 ] || die "the update of ${FUNCTION} did not finish (exit code $RUN_RC): $RUN_ERR"
}

# --- Reuse: a version that already serves this commit and digest (rollback, or a re-run after the publish).
aws_json "list-versions-by-function" aws lambda list-versions-by-function --function-name "$FUNCTION" --output json
existing="$(printf '%s' "$RUN_OUT" | jq -r --arg desc "$description" '
  [(.Versions // [])[] | select(.Version != "$LATEST" and (.Description // "") == $desc) | .Version | tonumber]
  | max // empty')"
if [ -n "$existing" ]; then
  verify_version "$existing"
  ok "version ${existing} already serves ${digest} (commit ${sha}): reused, nothing published"
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
# read_env: RUN_OUT holds the environment variables of the unpublished function.
read_env() {
  aws_json "get-function-configuration" aws lambda get-function-configuration --function-name "$FUNCTION" --query 'Environment.Variables' --output json
}

# --- 0. Refuse before any change when the environment is not Terraform's.
read_env
problem="$(env_problem "$RUN_OUT")"
[ -z "$problem" ] || die "publish refused: ${problem}"

# --- 1. Code, by digest.
run_capture aws lambda update-function-code --function-name "$FUNCTION" --image-uri "${repo}@${digest}" --query LastUpdateStatus --output text
[ "$RUN_RC" -eq 0 ] || die "update-function-code failed (exit code $RUN_RC): $RUN_ERR"
wait_updated
log "code of ${FUNCTION} updated to ${digest}"

# --- 2. IMAGE_DIGEST, merged into the environment Terraform owns (read again: it is the base of the update).
read_env
current="$RUN_OUT"
problem="$(env_problem "$current")"
[ -z "$problem" ] || die "publish refused: ${problem}"
merged="$(printf '%s' "$current" | jq -c --arg d "$digest" '. + {IMAGE_DIGEST: $d}')"
# Only IMAGE_DIGEST may differ; any other change would be drift Terraform must make.
printf '%s\n%s' "$current" "$merged" | jq -s -e '(.[0] | del(.IMAGE_DIGEST)) == (.[1] | del(.IMAGE_DIGEST))' >/dev/null \
  || die "publish refused: the merge would change a key other than IMAGE_DIGEST"
if [ "$(printf '%s' "$current" | jq -r '.IMAGE_DIGEST // ""')" = "$digest" ]; then
  log "IMAGE_DIGEST is already ${digest}"
else
  run_capture aws lambda update-function-configuration --function-name "$FUNCTION" \
    --environment "$(jq -cn --argjson v "$merged" '{Variables: $v}')" --query LastUpdateStatus --output text
  [ "$RUN_RC" -eq 0 ] || die "update-function-configuration failed (exit code $RUN_RC): $RUN_ERR"
  wait_updated
  log "IMAGE_DIGEST set to ${digest}"
fi

# --- 3. Publish and wait until the version can be invoked.
run_capture aws lambda publish-version --function-name "$FUNCTION" --description "$description" --query Version --output text
[ "$RUN_RC" -eq 0 ] || die "publish-version failed (exit code $RUN_RC): $RUN_ERR"
version="$RUN_OUT"
[[ "$version" =~ ^[0-9]+$ ]] || die "publish-version returned '$(printf '%s' "$version" | redact_ids)', not a version number"
run_capture aws lambda wait published-version-active --function-name "$FUNCTION" --qualifier "$version"
[ "$RUN_RC" -eq 0 ] || die "version ${version} did not become Active (exit code $RUN_RC): $RUN_ERR"

# --- 4. Prove it.
verify_version "$version"
ok "published version ${version}: ${description}"
printf 'VERSION=%s\nREUSED=false\n' "$version"
