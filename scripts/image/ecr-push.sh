#!/usr/bin/env bash
# Push the local image to ECR by immutable tag and report the digest ECR holds (ADR 0005, F5, F16). If the tag
# exists already (a re-run), nothing is pushed and the stored image is reused, so a rebuilt image never replaces
# the one that was scanned. The digest comes from ECR, not from the local build, and must be a single image
# manifest. Needs the AWS CLI with deploy credentials, docker, and ACCOUNT and REGION in the environment.
# The registry login lives in a temporary DOCKER_CONFIG that is removed on exit.
#
# Prints on stdout: IMAGE_DIGEST=<sha256:...> and IMAGE_REF=<registry>/<repo>@<digest>.
#
# Usage: ACCOUNT=... REGION=... scripts/image/ecr-push.sh <repository> <tag> <local image> >> "$GITHUB_ENV"

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/../lib.sh"

[ $# -eq 3 ] || die "usage: scripts/image/ecr-push.sh <repository> <tag> <local image>"
repo="$1" tag="$2" image="$3"
account="${ACCOUNT:-}" region="${REGION:-}"
[ -n "$account" ] && [ -n "$region" ] || die "ACCOUNT and REGION must be set"
registry="${account}.dkr.ecr.${region}.amazonaws.com"
require_cmd aws "the AWS CLI is preinstalled on GitHub runners"
require_cmd docker "install Docker"

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

push() {
  DOCKER_CONFIG="$(mktemp -d)"
  export DOCKER_CONFIG
  trap 'rm -rf "$DOCKER_CONFIG"' EXIT
  aws ecr get-login-password | docker login --username AWS --password-stdin "$registry" >/dev/null
  docker tag "$image" "${registry}/${repo}:${tag}"
  docker push --quiet "${registry}/${repo}:${tag}" >/dev/null
}

lookup
if [ -n "$digest" ]; then
  log "tag ${tag} already exists in ECR (a re-run); reusing it, no push"
else
  push
  lookup
fi

printf '%s' "$digest" | grep -Eq '^sha256:[0-9a-f]{64}$' || die "ECR returned an image digest in an unexpected format"
case "$media" in
  application/vnd.docker.distribution.manifest.v2+json | application/vnd.oci.image.manifest.v1+json) ;;
  *) die "the pushed artifact is not a single image manifest (media type: $media)" ;;
esac
log "image digest: ${digest}"
printf 'IMAGE_DIGEST=%s\nIMAGE_REF=%s/%s@%s\n' "$digest" "$registry" "$repo" "$digest"
