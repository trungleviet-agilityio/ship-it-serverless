#!/usr/bin/env bash
# Push the image archive the build job saved to ECR by immutable tag, with crane, and report the digest ECR holds
# (ADR 0005, F5, F16; ADR 0012 L7, review L6). No Docker: the deploy job runs with sudo and containers disabled.
#   1. The archive (a `docker save` tarball, scripts/image/export.sh) must have the sha256 the build job reported, or
#      nothing else happens: the bytes pushed are the bytes that were built, smoke tested and scanned.
#   2. If the tag exists already (a re-run), nothing is pushed and the stored image is reused, so a rebuilt image never
#      replaces the one that was scanned. A push that loses a race to the same immutable tag is reused the same way.
#   3. Otherwise `crane push <archive> <registry>/<repository>:<tag>`, then the digest is read back from ECR. It must
#      be a single image manifest, and equal the digest crane reported for the push.
# crane logs in through a temporary DOCKER_CONFIG directory created under <temp dir> (default $RUNNER_TEMP) and
# removed on exit, success or failure (the same pattern as the promotion copy). The password travels through a
# pipe, never an argument. The registry host holds the account ID: logs carry the digest and the tag only, and error
# text goes through the account ID redaction.
# Needs the AWS CLI with deploy credentials, crane (scripts/ci/install-tools.sh <dir> crane), and ACCOUNT and REGION in
# the environment.
#
# Prints on stdout: IMAGE_DIGEST=<sha256:...> and IMAGE_REF=<registry>/<repo>@<digest>.
#
# Usage: ACCOUNT=... REGION=... scripts/image/ecr-push.sh <repository> <tag> <image tar> <expected sha256> [temp dir] >> "$GITHUB_ENV"
# Exit codes: 0 pushed or reused, 1 refused or failed.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

usage="usage: ACCOUNT=... REGION=... scripts/image/ecr-push.sh <repository> <tag> <image tar> <expected sha256> [temp dir]"
{ [ $# -eq 4 ] || [ $# -eq 5 ]; } || die "$usage"
repo="$1" tag="$2" tar_file="$3" expected="$4" temp_base="${5:-${RUNNER_TEMP:-}}"
account="${ACCOUNT:-}" region="${REGION:-}"
[ -n "$account" ] && [ -n "$region" ] || die "ACCOUNT and REGION must be set"
[[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die "expected sha256 must be 64 hex characters"
[ -f "$tar_file" ] || die "image tar not found: $tar_file"
[ -n "$temp_base" ] && [ -d "$temp_base" ] || die "a temp dir is needed: pass one or set RUNNER_TEMP"
registry="${account}.dkr.ecr.${region}.amazonaws.com"
require_cmd aws "the AWS CLI is preinstalled on GitHub runners"
require_cmd crane "scripts/ci/install-tools.sh <dir> crane"

# 1. Before any AWS call: the archive is the one the build job reported.
[ "$(sha256_of "$tar_file")" = "$expected" ] || die "image tar sha256 differs from the build job output; refusing to push it"
ok "image tar sha256 matches the build job output"

# lookup: sets digest and media from ECR, or leaves digest empty when the tag does not exist.
lookup() {
  run_capture aws ecr describe-images --repository-name "$repo" --image-ids "imageTag=${tag}" \
    --query 'imageDetails[0].[imageDigest,imageManifestMediaType]' --output text
  digest="" media=""
  if [ "$RUN_RC" -eq 0 ]; then
    IFS=$'\t' read -r digest media <<<"$RUN_OUT"
  else
    case "$RUN_ERR" in
      *ImageNotFoundException*) ;;
      *) die "describe-images failed (exit code $RUN_RC): $RUN_ERR" ;;
    esac
  fi
}

# ecr_login: log crane in to the registry. The password travels through a pipe, never an argument.
ecr_login() {
  aws ecr get-login-password --region "$region" | crane auth login "$registry" --username AWS --password-stdin
}

# push: log in and push the archive; sets pushed_digest to the digest crane reported, or empty when the tag was taken
# meanwhile (immutable tags).
push() {
  DOCKER_CONFIG="$(mktemp -d "${temp_base%/}/crane-config.XXXXXX")" || die "cannot create a temp directory under the temp dir"
  export DOCKER_CONFIG
  trap 'rm -rf "$DOCKER_CONFIG"' EXIT
  run_capture ecr_login
  [ "$RUN_RC" -eq 0 ] || die "registry login failed (exit code ${RUN_RC}): ${RUN_ERR}"
  pushed_digest=""
  run_capture crane push "$tar_file" "${registry}/${repo}:${tag}"
  if [ "$RUN_RC" -ne 0 ]; then
    local push_rc="$RUN_RC" push_err="$RUN_ERR"
    lookup
    [ -n "$digest" ] || die "crane push failed (exit code ${push_rc}): ${push_err}"
    warn "the push was refused, but tag ${tag} exists now (another run pushed it first): reusing the stored image"
    return 0
  fi
  # crane prints the pushed reference, <registry>/<repository>@sha256:<hex>.
  pushed_digest="${RUN_OUT##*@}"
  valid_digest "$pushed_digest" || die "crane push printed no digest for the pushed image"
  lookup
}

lookup
if [ -n "$digest" ]; then
  log "tag ${tag} already exists in ECR (a re-run); reusing it, no push"
else
  push
  if [ -n "$pushed_digest" ] && [ "$digest" != "$pushed_digest" ]; then
    die "ECR holds ${digest:-nothing} under tag ${tag}, but crane pushed ${pushed_digest}"
  fi
fi

valid_digest "$digest" || die "ECR returned an image digest in an unexpected format"
case "$media" in
  application/vnd.docker.distribution.manifest.v2+json | application/vnd.oci.image.manifest.v1+json) ;;
  *) die "the pushed artifact is not a single image manifest (media type: $(printf '%s' "$media" | redact_ids))" ;;
esac
log "image digest: ${digest}"
printf 'IMAGE_DIGEST=%s\nIMAGE_REF=%s/%s@%s\n' "$digest" "$registry" "$repo" "$digest"
