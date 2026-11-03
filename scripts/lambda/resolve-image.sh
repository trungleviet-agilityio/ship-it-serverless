#!/usr/bin/env bash
# Resolve the digest ECR holds for a commit (ADR 0012 L8, rollback): the image pushed by an earlier app-deploy run under
# the immutable tag <commit sha>. Needs the AWS CLI with deploy credentials. Names derive from ENV (default dev).
# The answer must be a single image manifest, like scripts/image/ecr-push.sh requires.
#
# Prints on stdout: IMAGE_DIGEST=<sha256:...>, ready to append to $GITHUB_ENV.
#
# Usage: ENV=dev scripts/lambda/resolve-image.sh <commit sha>
# Exit codes: 0 resolved, 1 no such image or a failure.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 1 ] || die "usage: ENV=dev scripts/lambda/resolve-image.sh <commit sha>"
sha="$1"
require_cmd aws "the AWS CLI is preinstalled on GitHub runners"
app_names
valid_sha "$sha" || die "the commit must be 40 lowercase hex characters"

run_capture aws ecr describe-images --repository-name "$REPOSITORY" --image-ids "imageTag=${sha}" \
  --query 'imageDetails[0].[imageDigest,imageManifestMediaType]' --output text
if [ "$RUN_RC" -ne 0 ]; then
  case "$RUN_ERR" in
    *ImageNotFoundException*) die "no image tagged ${sha} in ${REPOSITORY}: pick a commit that app-deploy pushed (ECR keeps the last 20)" ;;
    *) die "describe-images failed (exit code $RUN_RC): $RUN_ERR" ;;
  esac
fi
digest="" media=""
IFS=$'\t' read -r digest media <<<"$RUN_OUT"
valid_digest "$digest" || die "ECR returned an image digest in an unexpected format"
case "$media" in
  application/vnd.docker.distribution.manifest.v2+json | application/vnd.oci.image.manifest.v1+json) ;;
  *) die "the image tagged ${sha} is not a single image manifest (media type: $(printf '%s' "$media" | redact_ids))" ;;
esac
ok "commit ${sha} is ${digest} in ${REPOSITORY}"
printf 'IMAGE_DIGEST=%s\n' "$digest"
